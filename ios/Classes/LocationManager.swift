import CoreLocation
import UIKit

/// Manages location updates for background tracking on iOS.
///
/// **Native-first**: every location received is written to the native SQLite
/// vault (`NativeLocationVault`) synchronously.  After writing, the manager
/// evaluates whether an upload flush should be triggered.
///
/// The Dart EventChannel callback is still invoked for UI-facing streams,
/// but persistence and upload are entirely handled natively.
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var onLocationUpdate: ((CLLocation) -> Void)?
    private(set) var isTracking = false
    
    // Configuration
    private var distanceFilter: CLLocationDistance = 10
    private var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    private var useSignificantChangeFallback = true
    private(set) var sessionId: String?

    // Track whether this is a "fast" session so STILL doesn't over-throttle.
    private var isFastSession: Bool = true
    
    // Upload thresholds — checked after every location write
    private var batchThreshold = 20
    private var timeThreshold: TimeInterval = 30 // seconds
    private var lastFlushAt = Date.distantPast
    
    // Device ID
    private lazy var deviceId: String? = UIDevice.current.identifierForVendor?.uuidString

    // Motion state manager (P0.13 / M3)
    private let motionManager = MotionStateManager.shared

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .automotiveNavigation
        locationManager.showsBackgroundLocationIndicator = true

        // Wire motion-driven pacing (P0.13)
        motionManager.onPacingChanged = { [weak self] pacing in
            guard let self = self, self.isTracking else { return }
            NSLog("[LocationManager] Motion pacing change: \(pacing.label)")

            if self.isFastSession {
                // FAST sessions keep high-accuracy pacing even when motion is classified as still.
                self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
                self.locationManager.distanceFilter = min(self.distanceFilter, 5)
            } else {
                self.locationManager.desiredAccuracy = pacing.desiredAccuracy
                self.locationManager.distanceFilter = pacing.distanceFilter
            }
        }
    }
    
    /// Configure the location manager with tracking options.
    func configure(
        distanceFilter: Double,
        priority: String,
        useSignificantChangeFallback: Bool,
        sessionId: String?
    ) {
        self.distanceFilter = distanceFilter
        self.useSignificantChangeFallback = useSignificantChangeFallback
        self.sessionId = sessionId
        
        switch priority.lowercased() {
        case "high", "fast":
            desiredAccuracy = kCLLocationAccuracyBest
            locationManager.activityType = .automotiveNavigation
            isFastSession = true
            batchThreshold = 3
            timeThreshold = 3
        case "balanced":
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.activityType = .automotiveNavigation
            isFastSession = false
            batchThreshold = 20
            timeThreshold = 30
        case "lowpower":
            desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.activityType = .other
            isFastSession = false
            batchThreshold = 20
            timeThreshold = 30
        default:
            desiredAccuracy = kCLLocationAccuracyBest
            isFastSession = true
            batchThreshold = 3
            timeThreshold = 3
        }
        
        locationManager.desiredAccuracy = desiredAccuracy
        locationManager.distanceFilter = self.distanceFilter
    }

    /// Start tracking with the given callback.
    func startTracking(callback: @escaping (CLLocation) -> Void) {
        onLocationUpdate = callback
        
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        
        locationManager.startUpdatingLocation()
        
        if useSignificantChangeFallback {
            locationManager.startMonitoringSignificantLocationChanges()
        }

        // Start NWPathMonitor for network-restore flush (P0.11)
        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.startNetworkMonitor()
            BackgroundTaskManager.shared.scheduleBGFlush()
        }

        // Restore upload config from UserDefaults
        NativeLocationUploader.shared.restoreConfig()

        // Start motion-state detection (P0.13)
        motionManager.start()
        
        isTracking = true
    }

    /// Stop all tracking.
    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()

        motionManager.stop()

        if #available(iOS 13.0, *) {
            BackgroundTaskManager.shared.stopNetworkMonitor()
        }

        // Final flush
        NativeLocationUploader.shared.flushPending()

        isTracking = false
    }
    
    /// Update tracking parameters dynamically.
    func updateParams(distanceFilter: Double, priority: String) {
        self.distanceFilter = distanceFilter
        
        switch priority.lowercased() {
        case "high":
            desiredAccuracy = kCLLocationAccuracyBest
        case "balanced":
            desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        case "lowpower":
            desiredAccuracy = kCLLocationAccuracyHundredMeters
        default:
            break
        }
        
        locationManager.desiredAccuracy = desiredAccuracy
        locationManager.distanceFilter = self.distanceFilter
    }

    // MARK: - Battery

    private func getBatteryPct() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) * 100 : nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Filter out old cached locations
        let age = -location.timestamp.timeIntervalSinceNow
        if age > 60 { return }
        
        // Filter out inaccurate locations
        if location.horizontalAccuracy < 0 { return }
        if location.horizontalAccuracy > 100 && desiredAccuracy == kCLLocationAccuracyBest { return }

        // --- Native-first: write to vault immediately (P0.8) ---
        let source: String
        if location.horizontalAccuracy <= 10 {
            source = "gps"
        } else if location.horizontalAccuracy <= 100 {
            source = "fused"
        } else {
            source = "network"
        }

        NativeLocationVault.shared.add(
            sessionId: sessionId,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            timestampMs: Int64(location.timestamp.timeIntervalSince1970 * 1000),
            speedMps: location.speed >= 0 ? location.speed : nil,
            headingDeg: location.course >= 0 ? location.course : nil,
            accuracyM: location.horizontalAccuracy,
            altitudeM: location.altitude,
            deviceId: deviceId,
            source: source,
            isMock: false,
            batteryPct: getBatteryPct(),
            motionState: motionManager.currentMotionState
        )

        // Evaluate upload trigger (P0.9)
        let pendingCount = NativeLocationVault.shared.getPendingCount()
        let timeSinceFlush = Date().timeIntervalSince(lastFlushAt)
        if pendingCount >= batchThreshold || timeSinceFlush >= timeThreshold {
            lastFlushAt = Date()
            NativeLocationUploader.shared.flushPending()
        }

        // Still notify Dart for UI streams
        onLocationUpdate?(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("LocationManager error: \(error.localizedDescription)")
        
        if useSignificantChangeFallback && !CLLocationManager.significantLocationChangeMonitoringAvailable() {
            NSLog("Significant location change monitoring not available")
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        
        switch status {
        case .authorizedAlways:
            if isTracking {
                locationManager.startUpdatingLocation()
            }
        case .authorizedWhenInUse:
            NSLog("Location authorized when in use - background tracking limited")
            if isTracking {
                locationManager.startUpdatingLocation()
            }
        case .denied, .restricted:
            NSLog("Location access denied or restricted")
            stopTracking()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
    
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        NSLog("Location updates paused by system — significant changes still active")
    }
    
    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        NSLog("Location updates resumed")
    }
}
