import 'location_point.dart';
import 'tracking_options.dart';

/// Abstract interface for background location management.
///
/// This interface defines the contract for background location tracking
/// implementations. Platform-specific implementations should extend this
/// interface and be registered via [BackgroundLocation.register].
///
/// Example usage:
/// ```dart
/// // In main.dart, register the platform implementation
/// BackgroundLocation.register(PlatformBackgroundLocationManager());
///
/// // Later, use the instance
/// final manager = BackgroundLocation.instance;
/// await manager.startTracking(TrackingOptions(sessionId: 'trip-123'));
///
/// // Listen for updates
/// manager.locationStream.listen((point) {
///   print('New location: ${point.lat}, ${point.lng}');
/// });
///
/// // Stop when done
/// await manager.stopTracking();
/// ```
abstract class BackgroundLocationManager {
  /// Start background location tracking with the given options.
  ///
  /// This will:
  /// 1. Start the native background service (foreground service on Android)
  /// 2. Begin capturing location updates at the specified interval
  /// 3. Persist captured locations to the native buffer
  /// 4. Attempt to upload buffered locations to the server
  ///
  /// Throws if location permissions are not granted or if already tracking.
  Future<void> startTracking(TrackingOptions options);

  /// Stop background location tracking completely.
  ///
  /// This will:
  /// 1. Stop the native background service
  /// 2. Stop capturing new location updates
  /// 3. Attempt to flush any remaining buffered locations
  ///
  /// Does not throw if not currently tracking.
  Future<void> stopTracking();

  /// Update the Android foreground service notification while tracking.
  ///
  /// This lets the host app reflect current status (e.g., "Active trip...")
  /// without restarting tracking.
  ///
  /// No-op on platforms without a foreground-service notification.
  Future<void> updateNotification({
    String? title,
    String? text,
    String? icon,
  });

  /// Temporarily pause tracking without stopping the service.
  ///
  /// While paused:
  /// - Location updates continue to be captured and queued
  /// - Upload to server is paused
  /// - The background service remains active
  ///
  /// Use [resumeTracking] to resume server synchronization.
  Future<void> pauseTracking();

  /// Resume tracking after a pause.
  ///
  /// This will:
  /// 1. Resume server synchronization
  /// 2. Attempt to flush any locations queued during pause
  ///
  /// Has no effect if not paused or not tracking.
  Future<void> resumeTracking();

  /// Check if tracking is currently active.
  ///
  /// Returns true if tracking is started (even if paused).
  Future<bool> isTracking();

  /// Check if tracking is currently paused.
  ///
  /// Returns true if tracking is started but sync is paused.
  Future<bool> isPaused();

  /// Stream of location updates.
  ///
  /// Emits [LocationPoint] objects as they are captured.
  /// This stream is broadcast and can have multiple listeners.
  ///
  /// The stream emits even when paused (locations are being captured).
  Stream<LocationPoint> get locationStream;

  /// Get the current tracking options, or null if not tracking.
  TrackingOptions? get currentOptions;

  /// Force an immediate attempt to upload queued locations.
  ///
  /// Returns the number of locations pending (native handles actual upload).
  /// Does not throw on network errors (locations remain queued).
  Future<int> flushQueue();

  /// Get the number of locations pending upload.
  Future<int> getPendingCount();

  /// Get the timestamp of the last successful upload, or null if never synced.
  Future<DateTime?> getLastSyncTime();

  /// Clear all queued locations without uploading.
  ///
  /// Use with caution - this will permanently delete un-uploaded data.
  Future<void> clearQueue();

  /// Dispose of resources.
  ///
  /// Call this when the manager is no longer needed (app shutdown).
  void dispose();
}

/// Status of the background location tracking.
enum TrackingStatus {
  /// Not tracking - service is stopped
  stopped,

  /// Actively tracking and uploading
  active,

  /// Tracking but upload is paused
  paused,

  /// Starting up (transitional state)
  starting,

  /// Stopping (transitional state)
  stopping,
}

/// Information about the current tracking state.
class TrackingState {
  /// Current tracking status
  final TrackingStatus status;

  /// Current tracking options (null if stopped)
  final TrackingOptions? options;

  /// Number of locations pending upload
  final int pendingCount;

  /// Timestamp of last successful upload
  final DateTime? lastSyncTime;

  /// Whether network is available for upload
  final bool hasNetwork;

  const TrackingState({
    required this.status,
    this.options,
    this.pendingCount = 0,
    this.lastSyncTime,
    this.hasNetwork = true,
  });

  @override
  String toString() {
    return 'TrackingState(status: $status, pending: $pendingCount, '
        'lastSync: $lastSyncTime)';
  }
}
