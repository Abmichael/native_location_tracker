import Foundation

/// What became of one upload attempt.
///
/// Three, not two: "it did not work" and "it will never work" call for opposite
/// things — one keeps the batch for the next flush, the other stops the tracker.
enum UploadOutcome {
    case success

    /// Try again later: a tunnel, a timeout, a server having a bad minute.
    case retry

    /// Refused for good. Retrying it can only waste battery.
    case terminal
}

/// Which upload responses mean "stop" rather than "try again later".
///
/// Handed down from Dart as a JSON string (see `TerminalResponse` there) and
/// persisted, so a batch uploading long after the app was suspended still knows
/// which refusals are permanent.
///
/// Empty unless the host app configures it, which is the behaviour this plugin
/// had before: every non-2xx retried forever.
struct TerminalResponse {
    private let statuses: Set<Int>
    /// Lower-cased once, at parse time — matching runs per response.
    private let messages: [String]

    static let none = TerminalResponse(statuses: [], messages: [])

    static func from(_ json: String?) -> TerminalResponse {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            if let json, !json.isEmpty {
                // Unreadable config must not invent a permanent refusal.
                // Falling back to "nothing is terminal" keeps retrying, which
                // wastes battery; the other way round throws away a live trip.
                NSLog("[NativeLocationTracker] Unreadable terminal-response config, ignoring it")
            }
            return .none
        }

        let statuses = Set((root["statuses"] as? [Any] ?? []).compactMap { value -> Int? in
            guard let status = value as? Int, status > 0 else { return nil }
            return status
        })

        let messages = (root["messages"] as? [Any] ?? []).compactMap { value -> String? in
            guard let message = value as? String, !message.isEmpty else { return nil }
            return message.lowercased()
        }

        return TerminalResponse(statuses: statuses, messages: messages)
    }

    var isEmpty: Bool { statuses.isEmpty && messages.isEmpty }

    /// Whether reading the response body could tell us anything.
    var hasMessages: Bool { !messages.isEmpty }

    /// Whether this response will never succeed.
    ///
    /// `body` may be nil — it is best-effort, and a status match does not need
    /// it. The background upload path has no body to offer, so a message-only
    /// rule will not fire there; that is a documented limitation of matching on
    /// copy rather than on a status.
    func matches(status: Int, body: String?) -> Bool {
        if statuses.contains(status) { return true }
        guard !messages.isEmpty, let body, !body.isEmpty else { return false }

        let haystack = body.lowercased()
        return messages.contains { haystack.contains($0) }
    }

    func describe(status: Int) -> String { "terminal_response_\(status)" }
}
