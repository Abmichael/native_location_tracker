import 'tracking_options.dart';

/// Speed thresholds for adaptive sampling (in km/h).
class SpeedThresholds {
  /// Speed below which the user is considered stationary
  static const double stationary = 2.0;

  /// Speed above which fast mode is recommended
  static const double fast = 30.0;

  /// Walking speed threshold
  static const double walking = 6.0;

  /// Running/cycling speed threshold
  static const double running = 15.0;
}

/// Effective tracking parameters after applying policy.
class EffectiveTrackingParams {
  /// Interval between location updates in milliseconds
  final int intervalMs;

  /// Distance filter in meters
  final int distanceFilterMeters;

  /// Location accuracy priority (platform-specific)
  final LocationPriority priority;

  /// Reason for these parameters
  final String reason;

  const EffectiveTrackingParams({
    required this.intervalMs,
    required this.distanceFilterMeters,
    required this.priority,
    required this.reason,
  });

  @override
  String toString() {
    return 'EffectiveTrackingParams(interval: ${intervalMs}ms, '
        'distance: ${distanceFilterMeters}m, priority: $priority, '
        'reason: $reason)';
  }
}

/// Location accuracy priority for native platforms.
enum LocationPriority {
  /// High accuracy (GPS-level)
  high,

  /// Balanced accuracy
  balanced,

  /// Low power (network-based)
  lowPower,

  /// Passive (no active requests, just listen)
  passive,
}

/// Policy engine for adaptive sampling and tracking parameters.
///
/// This class determines the optimal tracking parameters based on:
/// - User-selected [TrackingMode]
/// - Current speed (for adaptive sampling)
/// - Battery level (optional)
/// - Other environmental factors
class TrackingPolicy {
  /// Get default parameters for a tracking mode.
  static EffectiveTrackingParams getDefaultParams(TrackingMode mode) {
    switch (mode) {
      case TrackingMode.lowPower:
        return const EffectiveTrackingParams(
          intervalMs: 60000, // 60 seconds
          distanceFilterMeters: 100,
          priority: LocationPriority.balanced,
          reason: 'Low power mode defaults',
        );
      case TrackingMode.fast:
        return const EffectiveTrackingParams(
          intervalMs: 2000, // 2 seconds
          distanceFilterMeters: 5,
          priority: LocationPriority.high,
          reason: 'Fast mode defaults',
        );
    }
  }

  /// Calculate effective parameters based on options and current state.
  ///
  /// If [enableAdaptive] is true and speed is provided, parameters
  /// may be adjusted based on movement.
  static EffectiveTrackingParams calculateParams({
    required TrackingOptions options,
    double? currentSpeedMps, // meters per second
    double? batteryLevel, // 0.0 - 1.0
  }) {
    // Convert speed to km/h for threshold comparison
    final speedKmh = currentSpeedMps != null ? currentSpeedMps * 3.6 : null;

    // Start with user-specified values
    int intervalMs = options.intervalSeconds * 1000;
    int distanceMeters = options.distanceFilterMeters;
    LocationPriority priority;
    String reason;

    // Determine base priority from mode
    switch (options.mode) {
      case TrackingMode.lowPower:
        priority = LocationPriority.balanced;
        reason = 'Low power mode';
        break;
      case TrackingMode.fast:
        priority = LocationPriority.high;
        reason = 'Fast mode';
        break;
    }

    // Apply adaptive sampling if enabled
    if (options.enableAdaptiveSampling && speedKmh != null) {
      if (speedKmh < SpeedThresholds.stationary) {
        // Stationary - use very low frequency
        intervalMs = _max(intervalMs, 120000); // At least 2 minutes
        distanceMeters = _max(distanceMeters, 50);
        priority = LocationPriority.lowPower;
        reason = 'Adaptive: stationary (${speedKmh.toStringAsFixed(1)} km/h)';
      } else if (speedKmh > SpeedThresholds.fast) {
        // Fast movement - use high frequency
        intervalMs = _min(intervalMs, 2000); // At most 2 seconds
        distanceMeters = _min(distanceMeters, 10);
        priority = LocationPriority.high;
        reason = 'Adaptive: fast movement (${speedKmh.toStringAsFixed(1)} km/h)';
      } else if (speedKmh < SpeedThresholds.walking) {
        // Walking - moderate frequency
        intervalMs = _max(intervalMs, 30000); // At least 30 seconds
        distanceMeters = _max(distanceMeters, 30);
        priority = LocationPriority.balanced;
        reason = 'Adaptive: walking (${speedKmh.toStringAsFixed(1)} km/h)';
      }
      // Otherwise, use user-specified values
    }

    // Apply battery-aware adjustments
    if (batteryLevel != null && batteryLevel < 0.15) {
      // Critical battery - extend intervals
      intervalMs = _max(intervalMs, 60000);
      distanceMeters = _max(distanceMeters, 100);
      priority = LocationPriority.lowPower;
      reason += ' | Battery critical (${(batteryLevel * 100).toInt()}%)';
    } else if (batteryLevel != null && batteryLevel < 0.30) {
      // Low battery - slightly extend intervals
      intervalMs = (intervalMs * 1.5).toInt();
      reason += ' | Battery low (${(batteryLevel * 100).toInt()}%)';
    }

    return EffectiveTrackingParams(
      intervalMs: intervalMs,
      distanceFilterMeters: distanceMeters,
      priority: priority,
      reason: reason,
    );
  }

  /// Determine if a location update should be recorded based on distance.
  ///
  /// Returns true if the new location is far enough from the last recorded
  /// location to be worth storing.
  static bool shouldRecord({
    required double lastLat,
    required double lastLng,
    required double newLat,
    required double newLng,
    required int distanceFilterMeters,
    int? minTimeDeltaMs,
    int? lastTimestamp,
    int? newTimestamp,
  }) {
    // Calculate approximate distance using Haversine formula
    final distance = _haversineDistance(lastLat, lastLng, newLat, newLng);

    // Check distance filter
    if (distance >= distanceFilterMeters) {
      return true;
    }

    // Check time filter if provided
    if (minTimeDeltaMs != null &&
        lastTimestamp != null &&
        newTimestamp != null) {
      final timeDelta = newTimestamp - lastTimestamp;
      if (timeDelta >= minTimeDeltaMs) {
        return true;
      }
    }

    return false;
  }

  /// Calculate approximate distance between two points in meters.
  static double _haversineDistance(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadius = 6371000.0; // meters
    final dLat = _toRadians(lat2 - lat1);
    final dLng = _toRadians(lng2 - lng1);

    final a = _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(_toRadians(lat1)) *
            _cos(_toRadians(lat2)) *
            _sin(dLng / 2) *
            _sin(dLng / 2);

    final c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    return earthRadius * c;
  }

  static double _toRadians(double degrees) => degrees * 3.141592653589793 / 180;
  static double _sin(double x) => _taylorSin(x);
  static double _cos(double x) => _taylorCos(x);
  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 10; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }

  static double _atan2(double y, double x) {
    // Simplified atan2 using dart:math would be better but we're avoiding imports
    if (x > 0) return _atan(y / x);
    if (x < 0 && y >= 0) return _atan(y / x) + 3.141592653589793;
    if (x < 0 && y < 0) return _atan(y / x) - 3.141592653589793;
    if (x == 0 && y > 0) return 3.141592653589793 / 2;
    if (x == 0 && y < 0) return -3.141592653589793 / 2;
    return 0;
  }

  static double _atan(double x) {
    // Taylor series approximation for atan
    if (x.abs() > 1) {
      return (x > 0 ? 1 : -1) * (3.141592653589793 / 2 - _atan(1 / x));
    }
    double result = 0;
    double term = x;
    for (int i = 1; i <= 15; i += 2) {
      result += term / i;
      term *= -x * x;
    }
    return result;
  }

  static double _taylorSin(double x) {
    // Normalize to [-pi, pi]
    while (x > 3.141592653589793) x -= 2 * 3.141592653589793;
    while (x < -3.141592653589793) x += 2 * 3.141592653589793;

    double result = 0;
    double term = x;
    for (int i = 1; i <= 15; i += 2) {
      result += term;
      term *= -x * x / ((i + 1) * (i + 2));
    }
    return result;
  }

  static double _taylorCos(double x) {
    // Normalize to [-pi, pi]
    while (x > 3.141592653589793) x -= 2 * 3.141592653589793;
    while (x < -3.141592653589793) x += 2 * 3.141592653589793;

    double result = 1;
    double term = 1;
    for (int i = 2; i <= 16; i += 2) {
      term *= -x * x / ((i - 1) * i);
      result += term;
    }
    return result;
  }

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;
}

/// Extension for convenient params access on TrackingOptions.
extension TrackingOptionsPolicy on TrackingOptions {
  /// Get effective tracking parameters based on current state.
  EffectiveTrackingParams getEffectiveParams({
    double? currentSpeedMps,
    double? batteryLevel,
  }) {
    return TrackingPolicy.calculateParams(
      options: this,
      currentSpeedMps: currentSpeedMps,
      batteryLevel: batteryLevel,
    );
  }
}
