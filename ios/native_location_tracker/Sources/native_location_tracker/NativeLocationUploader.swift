import Foundation

/// Native iOS uploader.
///
/// Two upload paths, chosen by the caller:
/// - **Foreground / active** (`useBackground: false`): synchronous, paginated
///   upload on a default session. Used from location callbacks and the
///   network-restore flush, i.e. whenever the app already has execution time.
/// - **Background / suspended-safe** (`useBackground: true`): each pending batch
///   is handed to a **background `URLSession` upload task** (file-based, no
///   completion handler) so the transfer completes even if the app is suspended
///   or terminated. Rows are deleted in the session delegate once the server
///   confirms 2xx. Used from the BGProcessingTask flush.
///
/// Upload payload matches the backend DTO for `POST /location/update`.
final class NativeLocationUploader: NSObject, URLSessionDataDelegate {

    static let shared = NativeLocationUploader()

    // MARK: - Config (set from Dart via plugin)

    private let configLock = NSLock()
    private var _uploadUrl: String?
    private var _authToken: String?
    private var _refreshToken: String?
    private var _refreshUrl: String?
    private var _apiBaseUrl: String?

    var uploadUrl: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return _uploadUrl }
        set { configLock.lock(); _uploadUrl = newValue; configLock.unlock() }
    }
    var authToken: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return _authToken }
        set { configLock.lock(); _authToken = newValue; configLock.unlock() }
    }
    var refreshToken: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return _refreshToken }
        set { configLock.lock(); _refreshToken = newValue; configLock.unlock() }
    }
    /// Full URL for token refresh (POST). If nil, native token refresh is disabled.
    var refreshUrl: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return _refreshUrl }
        set { configLock.lock(); _refreshUrl = newValue; configLock.unlock() }
    }
    var apiBaseUrl: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return _apiBaseUrl }
        set { configLock.lock(); _apiBaseUrl = newValue; configLock.unlock() }
    }

    /// Set by the host `AppDelegate` from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// so the app can be relaunched to finish background transfers. Optional.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - State

    private var isUploading = false
    private let uploadQueue = DispatchQueue(label: "dev.nativelocation.uploader", qos: .utility)

    /// Last successful upload timestamp (epoch ms).
    private(set) var lastUploadAt: Int64 = 0

    /// Last error message, if any.
    private(set) var lastError: String?

    private let batchSize = 50

    // MARK: - Sessions

    /// Background session so the OS can finish uploads after suspension.
    /// Background sessions require file-based upload/download tasks and a
    /// delegate (completion-handler tasks are unsupported and throw).
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.nativelocation.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Standard (foreground) session for immediate uploads while app is active.
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Persist config to UserDefaults

    func persistConfig() {
        let defaults = UserDefaults.standard
        defaults.set(uploadUrl, forKey: "nlt_upload_url")
        defaults.set(authToken, forKey: "nlt_auth_token")
        defaults.set(refreshToken, forKey: "nlt_refresh_token")
        defaults.set(refreshUrl, forKey: "nlt_refresh_url")
        defaults.set(apiBaseUrl, forKey: "nlt_api_base_url")
    }

    func restoreConfig() {
        let defaults = UserDefaults.standard
        uploadUrl = defaults.string(forKey: "nlt_upload_url")
        authToken = defaults.string(forKey: "nlt_auth_token")
        refreshToken = defaults.string(forKey: "nlt_refresh_token")
        refreshUrl = defaults.string(forKey: "nlt_refresh_url")
        apiBaseUrl = defaults.string(forKey: "nlt_api_base_url")
    }

    // MARK: - Flush entry point

    /// Trigger an upload of all pending rows.
    ///
    /// Called from:
    /// - Location callback (pendingCount >= batchSize or time threshold) — foreground
    /// - NWPathMonitor on network restore — foreground
    /// - BGTaskScheduler flush — background (suspended-safe)
    func flushPending(useBackground: Bool = false) {
        uploadQueue.async { [weak self] in
            guard let self = self else { return }
            if useBackground {
                self.enqueueBackgroundUploads()
            } else {
                self.flushPendingSync()
            }
        }
    }

    // MARK: - Foreground (synchronous) path

    private func flushPendingSync() {
        guard !isUploading else { return }
        guard let url = uploadUrl, !url.isEmpty else {
            NSLog("[NativeUploader] No upload URL configured")
            return
        }

        isUploading = true
        defer { isUploading = false }

        let vault = NativeLocationVault.shared

        // Paginate: delete-on-success drives progression to the next batch.
        while true {
            let batch = vault.getPendingBatch(limit: batchSize)
            if batch.isEmpty { break }

            let sessionGroups = Dictionary(grouping: batch, by: { $0.sessionId ?? "unknown" })

            var anyFailed = false
            for (_, rows) in sessionGroups {
                let success = uploadBatchSync(url: url, rows: rows, allowRefresh: true)
                if success {
                    vault.deleteSent(ids: rows.map { $0.id })
                    lastUploadAt = Int64(Date().timeIntervalSince1970 * 1000)
                    lastError = nil
                } else {
                    anyFailed = true
                    break
                }
            }

            if anyFailed { break }
        }
    }

    private func uploadBatchSync(url: String, rows: [LocationRow], allowRefresh: Bool) -> Bool {
        guard let requestURL = URL(string: url), let body = buildBody(rows: rows) else { return false }

        var request = buildRequest(url: requestURL)
        request.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var statusCode = -1
        var responseError: Error?

        let task = foregroundSession.dataTask(with: request) { _, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            responseError = error
            sem.signal()
        }
        task.resume()
        sem.wait()

        if statusCode == 401 && allowRefresh {
            NSLog("[NativeUploader] 401 — attempting token refresh")
            if refreshAccessToken() {
                return uploadBatchSync(url: url, rows: rows, allowRefresh: false)
            }
        }

        if statusCode >= 200 && statusCode < 300 {
            return true
        }
        lastError = "HTTP \(statusCode): \(responseError?.localizedDescription ?? "unknown")"
        NSLog("[NativeUploader] Upload failed: \(lastError ?? "?")")
        return false
    }

    // MARK: - Background (suspended-safe) path

    /// Hand every pending batch to the background session as a file-based upload
    /// task. Rows are marked in-flight now and deleted in the delegate on 2xx.
    private func enqueueBackgroundUploads() {
        guard let urlString = uploadUrl, !urlString.isEmpty,
              let requestURL = URL(string: urlString) else {
            NSLog("[NativeUploader] No upload URL configured (background)")
            return
        }

        let vault = NativeLocationVault.shared

        // getPendingBatch returns status=0 rows; marking in-flight below ensures
        // the next iteration (and any concurrent foreground flush) skips them.
        while true {
            let batch = vault.getPendingBatch(limit: batchSize)
            if batch.isEmpty { break }

            let groups = Dictionary(grouping: batch, by: { $0.sessionId ?? "unknown" })
            for (_, rows) in groups {
                guard let body = buildBody(rows: rows) else { continue }
                let ids = rows.map { $0.id }

                // Background uploads must read the body from a file.
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nlt_\(UUID().uuidString).json")
                do {
                    try body.write(to: fileURL)
                } catch {
                    NSLog("[NativeUploader] Failed to stage background body: \(error)")
                    continue
                }

                let request = buildRequest(url: requestURL)
                let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
                task.taskDescription = encodeTaskInfo(ids: ids, file: fileURL.path)
                vault.markInFlight(ids: ids)
                task.resume()
            }
        }
    }

    // MARK: - Shared request/payload building

    private func buildRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Backend DTO for POST /location/update:
    /// `{ points: [ { lat, lng, timestamp, heading?, speed?, accuracy? } ] }`.
    /// NOTE: backend expects speed in km/h.
    private func buildBody(rows: [LocationRow]) -> Data? {
        let points: [[String: Any]] = rows.map { row in
            var pt: [String: Any] = [
                "lat": row.lat,
                "lng": row.lng,
                "timestamp": row.timestampMs,
            ]
            if let v = row.headingDeg { pt["heading"] = v }
            if let v = row.speedMps { pt["speed"] = v * 3.6 }
            if let v = row.accuracyM { pt["accuracy"] = v }
            return pt
        }
        return try? JSONSerialization.data(withJSONObject: ["points": points])
    }

    private func encodeTaskInfo(ids: [Int64], file: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["ids": ids, "file": file]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeTaskInfo(_ s: String?) -> (ids: [Int64], file: String?)? {
        guard let s = s, let data = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let ids = (dict["ids"] as? [Any])?.compactMap { ($0 as? NSNumber)?.int64Value } ?? []
        return (ids, dict["file"] as? String)
    }

    // MARK: - Token Refresh (foreground path only)

    private func refreshAccessToken() -> Bool {
        guard let rt = refreshToken, !rt.isEmpty,
              let refreshURLString = refreshUrl, !refreshURLString.isEmpty else {
            NSLog("[NativeUploader] Cannot refresh: missing refreshToken or refreshUrl")
            return false
        }

        guard let url = URL(string: refreshURLString) else { return false }

        let body = try? JSONSerialization.data(withJSONObject: ["refreshToken": rt])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var success = false

        foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            defer { sem.signal() }
            guard let data = data,
                  let httpRes = response as? HTTPURLResponse,
                  httpRes.statusCode >= 200, httpRes.statusCode < 300,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            let dataObj = (json["data"] as? [String: Any]) ?? json
            if let newAccess = dataObj["accessToken"] as? String,
               let newRefresh = dataObj["refreshToken"] as? String {
                self?.authToken = "Bearer \(newAccess)"
                self?.refreshToken = newRefresh
                self?.persistConfig()
                success = true
                NSLog("[NativeUploader] Token refreshed successfully")
            }
        }.resume()

        sem.wait()
        return success
    }

    // MARK: - URLSessionDelegate (background tasks)

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Only background upload tasks carry taskDescription; foreground tasks
        // use completion handlers and are handled synchronously above.
        guard let info = decodeTaskInfo(task.taskDescription) else {
            if let error = error {
                NSLog("[NativeUploader] Session task failed: \(error.localizedDescription)")
            }
            return
        }

        // Remove the staged body file regardless of outcome.
        if let file = info.file {
            try? FileManager.default.removeItem(atPath: file)
        }

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if error == nil && status >= 200 && status < 300 {
            NativeLocationVault.shared.deleteSent(ids: info.ids)
            lastUploadAt = Int64(Date().timeIntervalSince1970 * 1000)
            lastError = nil
        } else {
            // Return the rows to pending so a later flush retries them.
            NativeLocationVault.shared.resetPending(ids: info.ids)
            lastError = error?.localizedDescription ?? "HTTP \(status)"
            NSLog("[NativeUploader] Background upload failed: \(lastError ?? "?")")
        }
    }

    /// Called when all background events for the session have been delivered —
    /// lets the host app release its stored completion handler.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
