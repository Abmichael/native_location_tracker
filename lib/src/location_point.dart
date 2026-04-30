/// Source of the location data.
enum LocationSource {
  /// GPS satellite fix.
  gps,

  /// Cell tower / Wi-Fi network fix.
  network,

  /// Fused provider (Android FusedLocationProvider or equivalent).
  fused,

  /// Passive / opportunistic fix.
  passive,
}

/// A single location point captured by the background tracker.
///
/// This is a lightweight, framework-independent model. If your app already
/// uses a different location model, you can map from this class in your
/// stream listener.
class LocationPoint {
  /// Latitude in degrees.
  final double lat;

  /// Longitude in degrees.
  final double lng;

  /// Timestamp in epoch milliseconds (UTC).
  final int timestamp;

  /// Speed in meters per second (null if unavailable).
  final double? speed;

  /// Heading/bearing in degrees from north (0-360, null if unavailable).
  final double? heading;

  /// Horizontal accuracy in meters (null if unavailable).
  final double? accuracy;

  /// Altitude in meters above sea level (null if unavailable).
  final double? altitude;

  /// Device unique identifier.
  final String? deviceId;

  /// Source of the location fix.
  final LocationSource? source;

  /// Session ID for grouping location points (e.g., trip ID).
  final String? sessionId;

  /// Whether this is a mock/simulated location.
  final bool? isMock;

  /// Battery level at time of capture (0–100).
  final double? batteryLevel;

  const LocationPoint({
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.speed,
    this.heading,
    this.accuracy,
    this.altitude,
    this.deviceId,
    this.source,
    this.sessionId,
    this.isMock,
    this.batteryLevel,
  });

  /// Convert to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'timestamp': timestamp,
        if (speed != null) 'speed': speed,
        if (heading != null) 'heading': heading,
        if (accuracy != null) 'accuracy': accuracy,
        if (altitude != null) 'altitude': altitude,
        if (deviceId != null) 'deviceId': deviceId,
        if (source != null) 'source': source!.name,
        if (sessionId != null) 'sessionId': sessionId,
        if (isMock != null) 'isMock': isMock,
        if (batteryLevel != null) 'batteryLevel': batteryLevel,
      };

  /// Create from a JSON-compatible map.
  factory LocationPoint.fromJson(Map<String, dynamic> json) {
    return LocationPoint(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      timestamp: (json['timestamp'] as num).toInt(),
      speed: (json['speed'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      deviceId: json['deviceId'] as String?,
      source: json['source'] != null
          ? LocationSource.values.firstWhere(
              (e) => e.name == json['source'],
              orElse: () => LocationSource.gps,
            )
          : null,
      sessionId: json['sessionId'] as String?,
      isMock: json['isMock'] as bool?,
      batteryLevel: (json['batteryLevel'] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      'LocationPoint(lat: $lat, lng: $lng, timestamp: $timestamp, '
      'speed: $speed, heading: $heading, accuracy: $accuracy)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocationPoint &&
        other.lat == lat &&
        other.lng == lng &&
        other.timestamp == timestamp;
  }

  @override
  int get hashCode => Object.hash(lat, lng, timestamp);
}
