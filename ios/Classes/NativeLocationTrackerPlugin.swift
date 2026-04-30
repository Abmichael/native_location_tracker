import Flutter
import UIKit
import CoreLocation

public class NativeLocationTrackerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var stateEventSink: FlutterEventSink?
  private let locationManager = LocationManager()
  private var sessionId: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dev.nativelocation.tracker/methods", binaryMessenger: registrar.messenger())
    let instance = NativeLocationTrackerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    
    let eventChannel = FlutterEventChannel(name: "dev.nativelocation.tracker/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)

    // Native state observability channel (P0.4)
    let stateChannel = FlutterEventChannel(name: "dev.nativelocation.tracker/state", binaryMessenger: registrar.messenger())
    stateChannel.setStreamHandler(StateStreamHandler(plugin: instance))

    // Register BGTaskScheduler (P0.10)
    if #available(iOS 13.0, *) {
        BackgroundTaskManager.shared.registerBGTask()
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }
        
        sessionId = args["sessionId"] as? String
        let distanceFilter = (args["effectiveDistanceMeters"] as? Int ?? args["distanceFilterMeters"] as? Int ?? 10)
        let priority = args["priority"] as? String ?? args["mode"] as? String ?? "high"
        let useSignificantChangeFallback = args["useSignificantChangeFallback"] as? Bool ?? true
        
        locationManager.configure(
            distanceFilter: Double(distanceFilter),
            priority: priority,
            useSignificantChangeFallback: useSignificantChangeFallback,
            sessionId: sessionId
        )
        
        locationManager.startTracking { [weak self] location in
            self?.sendLocation(location)
        }
        result(true)
        
    case "stop":
        locationManager.stopTracking()
        sessionId = nil
        result(true)
        
    case "updateParams":
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }
        
        let distanceFilter = args["distanceFilterMeters"] as? Int ?? 10
        let priority = args["priority"] as? String ?? "high"
        
        locationManager.updateParams(
            distanceFilter: Double(distanceFilter),
            priority: priority
        )
        result(true)

    case "setUploadConfig":
        // Configure native uploader with URL and auth tokens
        let config = call.arguments as? [String: Any]
        let uploader = NativeLocationUploader.shared
        uploader.uploadUrl = config?["uploadUrl"] as? String
        uploader.authToken = config?["authToken"] as? String
        uploader.refreshToken = config?["refreshToken"] as? String
        uploader.refreshUrl = config?["refreshUrl"] as? String
        uploader.apiBaseUrl = config?["apiBaseUrl"] as? String
        uploader.persistConfig()
        NSLog("[NativeLocationTracker] Upload config set: url=\(uploader.uploadUrl ?? "nil")")
        result(true)

    case "setHttpFallbackEnabled":
        // On iOS, native upload is always the primary path (no WebSocket fallback toggle needed)
        result(true)
        
    case "isServiceRunning":
        result(locationManager.isTracking)

    case "getSessionId":
        result(locationManager.sessionId)

    case "getNativeState":
        // P0.4: native state observability
        let pendingCount = NativeLocationVault.shared.getPendingCount()
        let uploader = NativeLocationUploader.shared
        var state: [String: Any?] = [
            "isTracking": locationManager.isTracking,
            "sessionId": sessionId,
            "pendingCount": pendingCount,
            "uploaderState": locationManager.isTracking ? "active" : "idle"
        ]
        if uploader.lastUploadAt > 0 {
            state["lastUploadAt"] = uploader.lastUploadAt
        }
        state["lastError"] = uploader.lastError
        result(state)

    case "getUploadConfig":
        // Return the latest native-stored upload/auth config.
        // Important for refresh-token rotation: native may rotate while Flutter
        // is backgrounded/killed, so Dart must re-sync.
        let defaults = UserDefaults.standard
        let uploadUrl = defaults.string(forKey: "nlt_upload_url")
        let authToken = defaults.string(forKey: "nlt_auth_token")
        let refreshToken = defaults.string(forKey: "nlt_refresh_token")
        let apiBaseUrl = defaults.string(forKey: "nlt_api_base_url")
        result([
            "uploadUrl": uploadUrl as Any,
            "authToken": authToken as Any,
            "refreshToken": refreshToken as Any,
            "apiBaseUrl": apiBaseUrl as Any,
        ])

    case "clearUploadConfig":
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "nlt_upload_url")
        defaults.removeObject(forKey: "nlt_auth_token")
        defaults.removeObject(forKey: "nlt_refresh_token")
        defaults.removeObject(forKey: "nlt_api_base_url")
        result(true)

    case "setAuthTokens":
        let args = call.arguments as? [String: Any]
        let accessToken = args?["accessToken"] as? String
        let refreshToken = args?["refreshToken"] as? String

        let defaults = UserDefaults.standard
        if let accessToken = accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let header = trimmed.hasPrefix("Bearer ") ? trimmed : "Bearer \(trimmed)"
            defaults.set(header, forKey: "nlt_auth_token")
        } else {
            defaults.removeObject(forKey: "nlt_auth_token")
        }

        if let refreshToken = refreshToken, !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(refreshToken, forKey: "nlt_refresh_token")
        } else {
            defaults.removeObject(forKey: "nlt_refresh_token")
        }

        result(true)
        
    case "requestIgnoreBatteryOptimizations":
        result(false)
        
    case "isIgnoringBatteryOptimizations":
        result(true)
        
    default:
        result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
  
  private func sendLocation(_ location: CLLocation) {
      guard let sink = eventSink else { return }
      
      let source: String
      if location.horizontalAccuracy <= 10 {
          source = "gps"
      } else if location.horizontalAccuracy <= 100 {
          source = "fused"
      } else {
          source = "network"
      }
      
      let data: [String: Any] = [
          "lat": location.coordinate.latitude,
          "lng": location.coordinate.longitude,
          "accuracy": location.horizontalAccuracy,
          "altitude": location.altitude,
          "speed": max(0, location.speed),
          "bearing": max(0, location.course),
          "time": Int(location.timestamp.timeIntervalSince1970 * 1000),
          "isMock": false,
          "source": source
      ]
      sink(data)
  }
}

/// Helper to handle the state EventChannel separately from location events.
private class StateStreamHandler: NSObject, FlutterStreamHandler {
    weak var plugin: NativeLocationTrackerPlugin?
    init(plugin: NativeLocationTrackerPlugin) { self.plugin = plugin }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        plugin?.stateEventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        plugin?.stateEventSink = nil
        return nil
    }
}
