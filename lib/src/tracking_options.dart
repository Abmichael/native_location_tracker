/// Tracking mode that determines update frequency and battery usage.
///
/// The mode affects the interval and distance filter used for location updates.
enum TrackingMode {
  /// Low power mode for battery efficiency.
  ///
  /// Recommended settings:
  /// - Interval: 60+ seconds
  /// - Distance filter: 100+ meters
  /// - Use case: Long-haul trips, delivery tracking
  lowPower,

  /// Fast mode for high-frequency updates.
  ///
  /// Recommended settings:
  /// - Interval: 3-10 seconds
  /// - Distance filter: 5-20 meters
  /// - Use case: City rides, real-time tracking
  fast,
}

/// Configuration options for background location tracking.
///
/// These options control how frequently locations are captured,
/// how they are batched for upload, and platform-specific behaviors.
class TrackingOptions {
  /// Session identifier for grouping location points.
  ///
  /// This is typically a trip ID or tracking session UUID.
  /// Required for server-side correlation of location batches.
  final String sessionId;

  /// Tracking mode that determines update frequency.
  ///
  /// Defaults to [TrackingMode.lowPower] for battery efficiency.
  final TrackingMode mode;

  /// Desired interval between location updates in seconds.
  ///
  /// Note: This is a hint to the platform and may not be exact.
  /// Actual intervals depend on platform capabilities and power state.
  final int intervalSeconds;

  /// Minimum distance change (in meters) required to trigger an update.
  ///
  /// Setting to 0 disables distance filtering (updates on interval only).
  final int distanceFilterMeters;

  /// Number of location events to send per batch upload.
  ///
  /// Larger batches are more efficient but may be delayed if points
  /// accumulate slowly.
  final int batchSize;

  /// Whether to use significant location change monitoring as fallback on iOS.
  ///
  /// When true, the system will fall back to significant-change monitoring
  /// if high-frequency updates become unavailable (e.g., app suspended).
  /// This provides coarser updates but ensures some tracking continues.
  final bool useSignificantChangeFallback;

  /// Title shown in the Android foreground service notification.
  final String notificationTitle;

  /// Text shown in the Android foreground service notification.
  final String notificationText;

  /// Icon resource name for Android notification (without extension).
  ///
  /// If null, uses the app's launcher icon.
  final String? notificationIcon;

  /// Whether adaptive sampling based on speed should be enabled.
  ///
  /// When true, the tracker may adjust intervals based on movement speed:
  /// - Stationary (< 2 km/h): Longer intervals
  /// - Moving fast (> 30 km/h): Uses fast mode settings
  final bool enableAdaptiveSampling;

  /// Heartbeat interval while motion is STILL.
  ///
  /// Backend considers a driver offline after a short TTL (see backend TTL.DRIVER_ACTIVE).
  /// When the motion classifier reports `still`, native pacing may produce few or
  /// no new GPS points. This heartbeat forces periodic `/location/update` calls
  /// using the last known location to keep driver presence fresh.
  ///
  /// - Set to `0` to disable.
  /// - Default `12` seconds (beats the current 20s TTL).
  final int stillHeartbeatSeconds;

  const TrackingOptions({
    required this.sessionId,
    this.mode = TrackingMode.lowPower,
    this.intervalSeconds = 30,
    this.distanceFilterMeters = 50,
    this.batchSize = 50,
    this.useSignificantChangeFallback = true,
    this.notificationTitle = 'Location tracking active',
    this.notificationText = 'Tap to open app',
    this.notificationIcon,
    this.enableAdaptiveSampling = true,
    this.stillHeartbeatSeconds = 12,
  });

  /// Create options optimized for city/short rides.
  ///
  /// Uses fast mode with 5-second intervals and 10-meter filter.
  factory TrackingOptions.city({
    required String sessionId,
    String notificationTitle = 'Tracking your ride',
    String notificationText = 'Tap to view trip details',
  }) {
    return TrackingOptions(
      sessionId: sessionId,
      mode: TrackingMode.fast,
      intervalSeconds: 2,
      distanceFilterMeters: 5,
      batchSize: 20,
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
  }

  /// Create options optimized for long-haul/delivery tracking.
  ///
  /// Uses low power mode with 60-second intervals and 100-meter filter.
  factory TrackingOptions.longHaul({
    required String sessionId,
    String notificationTitle = 'Delivery tracking active',
    String notificationText = 'Tap to view route',
  }) {
    return TrackingOptions(
      sessionId: sessionId,
      mode: TrackingMode.lowPower,
      intervalSeconds: 60,
      distanceFilterMeters: 100,
      batchSize: 50,
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
  }

  /// Convert to a map for passing to native platform code.
  Map<String, dynamic> toNativeArgs() {
    return {
      'sessionId': sessionId,
      'mode': mode.name,
      'intervalMs': intervalSeconds * 1000,
      'distanceFilterMeters': distanceFilterMeters,
      'batchSize': batchSize,
      'useSignificantChangeFallback': useSignificantChangeFallback,
      'notificationTitle': notificationTitle,
      'notificationText': notificationText,
      'notificationIcon': notificationIcon,
      'enableAdaptiveSampling': enableAdaptiveSampling,
      'stillHeartbeatMs': stillHeartbeatSeconds <= 0 ? 0 : stillHeartbeatSeconds * 1000,
    };
  }

  /// Create a copy with modified fields.
  TrackingOptions copyWith({
    String? sessionId,
    TrackingMode? mode,
    int? intervalSeconds,
    int? distanceFilterMeters,
    int? batchSize,
    bool? useSignificantChangeFallback,
    String? notificationTitle,
    String? notificationText,
    String? notificationIcon,
    bool? enableAdaptiveSampling,
    int? stillHeartbeatSeconds,
  }) {
    return TrackingOptions(
      sessionId: sessionId ?? this.sessionId,
      mode: mode ?? this.mode,
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
      distanceFilterMeters: distanceFilterMeters ?? this.distanceFilterMeters,
      batchSize: batchSize ?? this.batchSize,
      useSignificantChangeFallback:
          useSignificantChangeFallback ?? this.useSignificantChangeFallback,
      notificationTitle: notificationTitle ?? this.notificationTitle,
      notificationText: notificationText ?? this.notificationText,
      notificationIcon: notificationIcon ?? this.notificationIcon,
      enableAdaptiveSampling:
          enableAdaptiveSampling ?? this.enableAdaptiveSampling,
      stillHeartbeatSeconds: stillHeartbeatSeconds ?? this.stillHeartbeatSeconds,
    );
  }

  @override
  String toString() {
    return 'TrackingOptions(sessionId: $sessionId, mode: $mode, '
        'interval: ${intervalSeconds}s, distance: ${distanceFilterMeters}m)';
  }
}
