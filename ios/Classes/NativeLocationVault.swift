import Foundation
import SQLite3

/// Native-side SQLite vault for background location persistence on iOS (P0.8).
///
/// Points are written synchronously from CLLocationManager callbacks.
/// Each point receives a UUIDv4 `pointId` at capture time for idempotent uploads.
/// Storage is bounded with a hard FIFO cap (MAX_RECORDS).
final class NativeLocationVault {

    // MARK: - Constants

    static let shared = NativeLocationVault()

    private let maxRecords = 10_000
    private let trimBatch = 100

    private let dbQueue = DispatchQueue(label: "dev.nativelocation.vault", qos: .userInitiated)
    private var db: OpaquePointer?

    // MARK: - Init / Open

    private init() {
        openDatabase()
    }

    deinit {
        close()
    }

    private func openDatabase() {
        let fileURL = Self.databaseURL()
        let path = fileURL.path

        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            NSLog("[NativeLocationVault] Failed to open database at \(path)")
            return
        }

        // WAL mode for better concurrent read/write
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        createTables()
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS locations (
            _id INTEGER PRIMARY KEY AUTOINCREMENT,
            point_id TEXT NOT NULL,
            session_id TEXT,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            speed_mps REAL,
            heading_deg REAL,
            accuracy_m REAL,
            altitude_m REAL,
            device_id TEXT,
            source TEXT,
            is_mock INTEGER DEFAULT 0,
            battery_pct REAL,
            motion_state TEXT,
            status INTEGER DEFAULT 0
        )
        """
        exec(sql)
        exec("CREATE INDEX IF NOT EXISTS idx_status ON locations (status)")
        exec("CREATE INDEX IF NOT EXISTS idx_session ON locations (session_id)")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_point_id ON locations (point_id)")
    }

    // MARK: - Write

    /// Insert a location point (called synchronously from CLLocationManager callback).
    func add(
        sessionId: String?,
        lat: Double,
        lng: Double,
        timestampMs: Int64,
        speedMps: Double?,
        headingDeg: Double?,
        accuracyM: Double?,
        altitudeM: Double?,
        deviceId: String?,
        source: String?,
        isMock: Bool,
        batteryPct: Double?,
        motionState: String?
    ) {
        dbQueue.sync {
            guard let db = self.db else { return }

            // Enforce FIFO cap
            trimIfNeeded()

            let pointId = UUID().uuidString

            let sql = """
            INSERT INTO locations
                (point_id, session_id, lat, lng, timestamp_ms, speed_mps, heading_deg,
                 accuracy_m, altitude_m, device_id, source, is_mock, battery_pct,
                 motion_state, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("[NativeLocationVault] prepare INSERT failed: \(errorMessage())")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (pointId as NSString).utf8String, -1, nil)
            bindOptionalText(stmt, 2, sessionId)
            sqlite3_bind_double(stmt, 3, lat)
            sqlite3_bind_double(stmt, 4, lng)
            sqlite3_bind_int64(stmt, 5, timestampMs)
            bindOptionalDouble(stmt, 6, speedMps)
            bindOptionalDouble(stmt, 7, headingDeg)
            bindOptionalDouble(stmt, 8, accuracyM)
            bindOptionalDouble(stmt, 9, altitudeM)
            bindOptionalText(stmt, 10, deviceId)
            bindOptionalText(stmt, 11, source)
            sqlite3_bind_int(stmt, 12, isMock ? 1 : 0)
            bindOptionalDouble(stmt, 13, batteryPct)
            bindOptionalText(stmt, 14, motionState)

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[NativeLocationVault] INSERT failed: \(errorMessage())")
            }
        }
    }

    // MARK: - Read

    /// Fetch a batch of pending locations ordered by timestamp ASC.
    func getPendingBatch(limit: Int = 50) -> [LocationRow] {
        var rows: [LocationRow] = []
        dbQueue.sync {
            guard let db = self.db else { return }

            let sql = """
            SELECT _id, point_id, session_id, lat, lng, timestamp_ms,
                   speed_mps, heading_deg, accuracy_m, altitude_m,
                   device_id, source, is_mock, battery_pct, motion_state
            FROM locations
            WHERE status = 0
            ORDER BY timestamp_ms ASC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let row = LocationRow(
                    id: sqlite3_column_int64(stmt, 0),
                    pointId: String(cString: sqlite3_column_text(stmt, 1)),
                    sessionId: columnTextOrNil(stmt, 2),
                    lat: sqlite3_column_double(stmt, 3),
                    lng: sqlite3_column_double(stmt, 4),
                    timestampMs: sqlite3_column_int64(stmt, 5),
                    speedMps: columnDoubleOrNil(stmt, 6),
                    headingDeg: columnDoubleOrNil(stmt, 7),
                    accuracyM: columnDoubleOrNil(stmt, 8),
                    altitudeM: columnDoubleOrNil(stmt, 9),
                    deviceId: columnTextOrNil(stmt, 10),
                    source: columnTextOrNil(stmt, 11),
                    isMock: sqlite3_column_int(stmt, 12) == 1,
                    batteryPct: columnDoubleOrNil(stmt, 13),
                    motionState: columnTextOrNil(stmt, 14)
                )
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: - Mark / Delete

    /// Delete rows that were successfully uploaded (called after confirmed 2xx).
    func deleteSent(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        dbQueue.sync {
            guard let db = self.db else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM locations WHERE _id IN (\(placeholders))"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }
            sqlite3_step(stmt)
        }
    }

    /// Mark rows as in-flight (status = 1) to avoid re-fetching during paginated upload.
    func markInFlight(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        dbQueue.sync {
            guard let db = self.db else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = "UPDATE locations SET status = 1 WHERE _id IN (\(placeholders))"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), id)
            }
            sqlite3_step(stmt)
        }
    }

    /// Reset in-flight rows back to pending (e.g. on upload failure).
    func resetInFlight() {
        dbQueue.sync {
            exec("UPDATE locations SET status = 0 WHERE status = 1")
        }
    }

    // MARK: - Counts

    func getPendingCount() -> Int {
        var count = 0
        dbQueue.sync {
            guard let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM locations WHERE status = 0"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return count
    }

    // MARK: - FIFO Trim

    private func trimIfNeeded() {
        guard let db = self.db else { return }
        var stmt: OpaquePointer?
        let countSql = "SELECT COUNT(*) FROM locations"
        guard sqlite3_prepare_v2(db, countSql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let totalCount = Int(sqlite3_column_int64(stmt, 0))

        if totalCount >= maxRecords {
            let deleteCount = trimBatch
            exec("""
                DELETE FROM locations WHERE _id IN (
                    SELECT _id FROM locations ORDER BY timestamp_ms ASC LIMIT \(deleteCount)
                )
            """)
            NSLog("[NativeLocationVault] Trimmed \(deleteCount) oldest rows (total was \(totalCount))")
        }
    }

    // MARK: - Close

    func close() {
        dbQueue.sync {
            if let db = self.db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = self.db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("[NativeLocationVault] exec failed: \(errorMessage()) — SQL: \(sql.prefix(200))")
        }
    }

    private func errorMessage() -> String {
        if let db = self.db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "no db"
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, index, (v as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let v = value {
            sqlite3_bind_double(stmt, index, v)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnTextOrNil(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnDoubleOrNil(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private static func databaseURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nlt_locations.sqlite")
    }
}

// MARK: - Model

struct LocationRow {
    let id: Int64
    let pointId: String
    let sessionId: String?
    let lat: Double
    let lng: Double
    let timestampMs: Int64
    let speedMps: Double?
    let headingDeg: Double?
    let accuracyM: Double?
    let altitudeM: Double?
    let deviceId: String?
    let source: String?
    let isMock: Bool
    let batteryPct: Double?
    let motionState: String?
}
