import Foundation
import BackgroundTasks
import Network

/// Manages BGTaskScheduler flush (P0.10) and NWPathMonitor network observer (P0.11).
///
/// - BGTaskScheduler: registers a background task that performs an opportunistic
///   upload flush when iOS decides to grant background time.
/// - NWPathMonitor: flushes immediately when network is restored.
@available(iOS 13.0, *)
final class BackgroundTaskManager {

    static let shared = BackgroundTaskManager()
    static let bgTaskIdentifier = "dev.nativelocation.bgflush"

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "dev.nativelocation.networkMonitor", qos: .utility)
    private var wasUnsatisfied = false

    private init() {}

    // MARK: - BGTaskScheduler (P0.10)

    /// Call once at app launch (e.g. in `application(_:didFinishLaunchingWithOptions:)`
    /// or the Flutter plugin `register(with:)` if it executes early enough).
    func registerBGTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil
        ) { task in
            self.handleBGTask(task as! BGProcessingTask)
        }
    }

    /// Schedule the next opportunistic flush.
    func scheduleBGFlush() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Earliest: 5 min from now (OS decides actual timing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BackgroundTaskManager] BGFlush scheduled")
        } catch {
            NSLog("[BackgroundTaskManager] Failed to schedule BGFlush: \(error)")
        }
    }

    private func handleBGTask(_ task: BGProcessingTask) {
        // Schedule the next occurrence before doing work
        scheduleBGFlush()

        task.expirationHandler = {
            NSLog("[BackgroundTaskManager] BGTask expiring")
        }

        NSLog("[BackgroundTaskManager] BGTask running — flushing pending locations")
        NativeLocationUploader.shared.flushPending(useBackground: true)

        // Mark complete (flush is synchronous internally on the upload queue)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - NWPathMonitor (P0.11)

    func startNetworkMonitor() {
        stopNetworkMonitor()

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                if self.wasUnsatisfied {
                    NSLog("[BackgroundTaskManager] Network restored — triggering flush")
                    NativeLocationUploader.shared.flushPending()
                }
                self.wasUnsatisfied = false
            } else {
                self.wasUnsatisfied = true
            }
        }

        monitor.start(queue: monitorQueue)
        NSLog("[BackgroundTaskManager] NWPathMonitor started")
    }

    func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}
