import Foundation

/// The shape of the JSON body uploaded to the host app's endpoint.
///
/// Handed down from Dart as a JSON string (see `PayloadFormat` there) and
/// persisted, so a batch that a background `URLSession` finishes long after the
/// app was suspended still knows what the server expects. Anything missing or
/// unparseable falls back to the format this plugin sent before it was
/// configurable, so an old stored config — or none at all — behaves as it did.
struct PayloadFormat {
    private static let lat = "lat"
    private static let lng = "lng"
    private static let time = "timestamp"
    private static let accuracy = "accuracy"
    private static let speed = "speed"
    private static let heading = "heading"

    private static let defaultNames: [String: String] = [
        lat: lat, lng: lng, time: time,
        accuracy: accuracy, speed: speed, heading: heading,
    ]

    let rootKey: String?
    let names: [String: String]
    let timeFormat: String
    let speedUnit: String
    let extras: [String: Any]
    let omitNull: Bool

    /// What the plugin has always sent.
    static let `default` = PayloadFormat(
        rootKey: "points",
        names: defaultNames,
        timeFormat: "epoch_millis",
        // Not the platform's unit. Kept because changing it would silently
        // divide every existing integration's speeds by 3.6.
        speedUnit: "kmh",
        extras: [:],
        omitNull: true
    )

    static func from(_ json: String?) -> PayloadFormat {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // A malformed format must not cost the batch: the old shape is
            // wrong for this server but recoverable, where refusing to build a
            // body strands every point on the device with nothing to say why.
            if let json, !json.isEmpty {
                NSLog("[NativeLocationTracker] Unreadable payload format, using the default")
            }
            return .default
        }

        var names = defaultNames
        if let fields = root["fields"] as? [String: Any] {
            for key in defaultNames.keys {
                if let mapped = fields[key] as? String, !mapped.isEmpty {
                    names[key] = mapped
                }
            }
        }

        // An explicit null means "post a bare array", which is different from
        // the key being absent.
        let hasRootKey = root.index(forKey: "rootKey") != nil
        let rootKey = hasRootKey ? root["rootKey"] as? String : "points"

        return PayloadFormat(
            rootKey: rootKey,
            names: names,
            timeFormat: root["timeFormat"] as? String ?? "epoch_millis",
            speedUnit: root["speedUnit"] as? String ?? "kmh",
            extras: root["extras"] as? [String: Any] ?? [:],
            omitNull: root["omitNull"] as? Bool ?? true
        )
    }

    func buildBody(rows: [LocationRow]) -> Data? {
        let points: [[String: Any]] = rows.map { row in
            var pt: [String: Any] = [
                name(Self.lat): row.lat,
                name(Self.lng): row.lng,
                name(Self.time): formatTime(row.timestampMs),
            ]

            put(&pt, name(Self.heading), row.headingDeg)
            put(&pt, name(Self.speed), row.speedMps.map(convertSpeed))
            put(&pt, name(Self.accuracy), row.accuracyM)

            return pt
        }

        // A bare array as the whole body, for an API that takes no envelope.
        // Extras have nowhere to go in that case and are dropped.
        guard let key = rootKey else {
            return try? JSONSerialization.data(withJSONObject: points)
        }

        var body: [String: Any] = [key: points]
        for (k, v) in extras { body[k] = v }

        return try? JSONSerialization.data(withJSONObject: body)
    }

    private func name(_ field: String) -> String {
        names[field] ?? field
    }

    private func put(_ target: inout [String: Any], _ key: String, _ value: Double?) {
        if let value {
            target[key] = value
        } else if !omitNull {
            // An absent key says the phone did not know. A null may be read as
            // zero at the far end, which is a different and false claim.
            target[key] = NSNull()
        }
    }

    private func convertSpeed(_ metersPerSecond: Double) -> Double {
        speedUnit == "mps" ? metersPerSecond : metersPerSecond * 3.6
    }

    private func formatTime(_ epochMillis: Int64) -> Any {
        switch timeFormat {
        case "epoch_seconds":
            return epochMillis / 1000
        case "iso8601_utc":
            return Self.isoFormatter.string(
                from: Date(timeIntervalSince1970: Double(epochMillis) / 1000.0)
            )
        default:
            return epochMillis
        }
    }

    /// `DateFormatter` is expensive to build and this runs per point, so it is
    /// shared — it is only read after construction, which is safe.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
