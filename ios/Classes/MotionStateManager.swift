import CoreMotion
import CoreLocation

/// Manages motion-state detection via CMMotionActivityManager (P0.13).
///
/// Detects still vs walking vs running vs in_vehicle and adjusts
/// CLLocationManager parameters natively.  The last detected motion state
/// is available for storage alongside each location point.
final class MotionStateManager {

    static let shared = MotionStateManager()

    // MARK: - Pacing presets

    struct PacingParams {
        let desiredAccuracy: CLLocationAccuracy
        let distanceFilter: CLLocationDistance
        let label: String
    }

    static let stillPacing = PacingParams(
        desiredAccuracy: kCLLocationAccuracyHundredMeters,
        distanceFilter: 50,
        label: "still"
    )
    static let walkingPacing = PacingParams(
        desiredAccuracy: kCLLocationAccuracyNearestTenMeters,
        distanceFilter: 15,
        label: "walking"
    )
    static let runningPacing = PacingParams(
        desiredAccuracy: kCLLocationAccuracyBest,
        distanceFilter: 10,
        label: "running"
    )
    static let inVehiclePacing = PacingParams(
        desiredAccuracy: kCLLocationAccuracyBest,
        distanceFilter: 10,
        label: "in_vehicle"
    )
    static let unknownPacing = PacingParams(
        desiredAccuracy: kCLLocationAccuracyBest,
        distanceFilter: 15,
        label: "unknown"
    )

    // MARK: - State

    /// The last detected motion state label (stored w/ each location point).
    private(set) var currentMotionState: String = "unknown"

    /// Current pacing derived from the motion state.
    private(set) var currentPacing: PacingParams = unknownPacing

    /// Callback invoked when pacing parameters should change.
    var onPacingChanged: ((PacingParams) -> Void)?

    private let activityManager = CMMotionActivityManager()
    private var isRunning = false

    // MARK: - Start / Stop

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            NSLog("[MotionStateManager] Motion activity not available on this device")
            return
        }
        guard !isRunning else { return }
        isRunning = true

        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }

            // Ignore low-confidence results
            if activity.confidence == .low { return }

            let newState: String
            if activity.stationary {
                newState = "still"
            } else if activity.automotive {
                newState = "in_vehicle"
            } else if activity.running || activity.cycling {
                newState = "running"
            } else if activity.walking {
                newState = "walking"
            } else {
                newState = "unknown"
            }

            self.applyMotionState(newState)
        }

        NSLog("[MotionStateManager] Started CMMotionActivity updates")
    }

    func stop() {
        guard isRunning else { return }
        activityManager.stopActivityUpdates()
        isRunning = false
        NSLog("[MotionStateManager] Stopped CMMotionActivity updates")
    }

    // MARK: - Internal

    private func applyMotionState(_ newState: String) {
        guard newState != currentMotionState else { return }

        let oldState = currentMotionState
        currentMotionState = newState

        let newPacing: PacingParams
        switch newState {
        case "still":      newPacing = Self.stillPacing
        case "walking":    newPacing = Self.walkingPacing
        case "running":    newPacing = Self.runningPacing
        case "in_vehicle": newPacing = Self.inVehiclePacing
        default:           newPacing = Self.unknownPacing
        }

        currentPacing = newPacing
        NSLog("[MotionStateManager] \(oldState) → \(newState) — accuracy: \(newPacing.desiredAccuracy) / distance: \(newPacing.distanceFilter)")
        onPacingChanged?(newPacing)
    }
}
