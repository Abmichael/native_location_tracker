import Foundation

/// Native iOS uploader that uses a **background URLSession** so transfers
/// can complete even when the app is suspended (P0.9).
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

    // MARK: - State

    private var isUploading = false
    private let uploadQueue = DispatchQueue(label: "dev.nativelocation.uploader", qos: .utility)

    /// Last successful upload timestamp (epoch ms).
    private(set) var lastUploadAt: Int64 = 0

    /// Last error message, if any.
    private(set) var lastError: String?

    private let batchSize = 50

    // MARK: - Background URLSession

    /// Background session so the OS can finish uploads after suspension.
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

    // MARK: - Upload

    /// Trigger a paginated upload of all pending rows.
    ///
    /// Called from:
    /// - Location callback (when pendingCount >= batchSize or time threshold)
    /// - NWPathMonitor on network restore
    /// - BGTaskScheduler flush
    func flushPending(useBackground: Bool = false) {
        uploadQueue.async { [weak self] in
            self?.flushPendingSync(useBackground: useBackground)
        }
    }

    private func flushPendingSync(useBackground: Bool) {
        guard !isUploading else { return }
        guard let url = uploadUrl, !url.isEmpty else {
            NSLog("[NativeUploader] No upload URL configured")
            return
        }

        isUploading = true
        defer { isUploading = false }

        let vault = NativeLocationVault.shared

        // Paginate: keep uploading batches until empty or failure
        while true {
            let batch = vault.getPendingBatch(limit: batchSize)
            if batch.isEmpty { break }

            let sessionGroups = Dictionary(grouping: batch, by: { $0.sessionId ?? "unknown" })

            var anyFailed = false
            for (sessionId, rows) in sessionGroups {
                let success = uploadBatch(
                    url: url,
                    sessionId: sessionId,
                    rows: rows,
                    useBackground: useBackground
                )
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

    /// Upload a single batch synchronously and return success/failure.
    private func uploadBatch(url: String, sessionId: String, rows: [LocationRow], useBackground: Bool) -> Bool {
        return uploadBatchInternal(url: url, sessionId: sessionId, rows: rows, useBackground: useBackground, allowRefresh: true)
    }

    private func uploadBatchInternal(url: String, sessionId: String, rows: [LocationRow], useBackground: Bool, allowRefresh: Bool) -> Bool {
        guard let requestURL = URL(string: url) else { return false }

        // Build backend DTO payload for POST /location/update:
        // { points: [ { lat, lng, timestamp?, heading?, speed?, accuracy? } ] }
        // NOTE: backend expects speed in km/h.
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

        let payload: [String: Any] = [
            "points": points
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            NSLog("[NativeUploader] Failed to serialize payload")
            return false
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        // Use semaphore for synchronous wait
        let sem = DispatchSemaphore(value: 0)
        var statusCode = -1
        var responseError: Error?

        let session = useBackground ? backgroundSession : foregroundSession
        let task = session.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                statusCode = httpResponse.statusCode
            }
            responseError = error
            sem.signal()
        }
        task.resume()
        sem.wait()

        if statusCode == 401 && allowRefresh {
            NSLog("[NativeUploader] 401 — attempting token refresh")
            if refreshAccessToken() {
                return uploadBatchInternal(url: url, sessionId: sessionId, rows: rows, useBackground: useBackground, allowRefresh: false)
            }
        }

        if statusCode >= 200 && statusCode < 300 {
            return true
        } else {
            lastError = "HTTP \(statusCode): \(responseError?.localizedDescription ?? "unknown")"
            NSLog("[NativeUploader] Upload failed: \(lastError ?? "?")")
            return false
        }
    }

    // MARK: - Token Refresh

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

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            NSLog("[NativeUploader] Background session task failed: \(error.localizedDescription)")
            // Reset in-flight rows so they can be retried
            NativeLocationVault.shared.resetInFlight()
        }
    }
}
