/// A field the uploader can put in each point.
enum LocationField {
  latitude,
  longitude,

  /// When the fix was taken. Named `time` rather than `timestamp` because
  /// `timestamp` is only the *default wire name* for it — see [PayloadFormat].
  time,

  accuracy,
  speed,
  heading,
}

/// How the time of a fix is written on the wire.
enum TimeFormat {
  /// Milliseconds since the epoch, as a number. The default, and what this
  /// plugin has always sent.
  epochMillis,

  /// Whole seconds since the epoch, as a number.
  epochSeconds,

  /// `2026-09-01T09:00:00.000Z` — an ISO 8601 string in UTC. What most
  /// JSON APIs that parse into a date type expect.
  iso8601Utc,
}

/// The unit a speed is sent in.
enum SpeedUnit {
  /// What the platform actually reports, on both Android and iOS.
  metersPerSecond,

  /// The default, for backwards compatibility only. Earlier versions of this
  /// plugin multiplied every speed by 3.6 with no way to turn it off, because
  /// one backend wanted km/h — so a project that wanted the platform's own
  /// figure silently got one 3.6 times too large.
  kilometersPerHour,
}

/// The shape of the JSON body the native uploader POSTs.
///
/// The uploader runs where no Dart code is alive — an Android foreground
/// service, an iOS background `URLSession` that outlives the app — so the
/// shape cannot be a callback you supply. It has to be data: this object is
/// handed down at [BackgroundLocation.initialize] and persisted natively, so
/// a batch that uploads after the app is killed still knows what to send.
///
/// The defaults reproduce exactly what the plugin sent before this existed:
///
/// ```json
/// { "points": [ { "lat": 9.01, "lng": 38.75, "timestamp": 1700000000000 } ] }
/// ```
///
/// To fit a different API, change only what differs:
///
/// ```dart
/// PayloadFormat(
///   fields: {LocationField.time: 'recordedAt'},
///   timeFormat: TimeFormat.iso8601Utc,
///   speedUnit: SpeedUnit.metersPerSecond,
///   extras: {'deviceId': deviceId},
/// )
/// ```
class PayloadFormat {
  /// The key the array of points sits under.
  ///
  /// Set to `null` to POST a bare JSON array as the whole body, for an API
  /// that takes `[ {...}, {...} ]` with no envelope.
  final String? rootKey;

  /// Wire names for the fields, where they differ from the defaults
  /// (`lat`, `lng`, `timestamp`, `accuracy`, `speed`, `heading`).
  ///
  /// Only the entries you provide are overridden; anything absent keeps its
  /// default name.
  final Map<LocationField, String> fields;

  final TimeFormat timeFormat;

  final SpeedUnit speedUnit;

  /// Fixed values merged into the root of every request alongside [rootKey].
  ///
  /// For the things an API wants on the envelope rather than per point — a
  /// device id, a session id, a schema version. Values must be JSON-encodable
  /// primitives, and are sent unchanged on every batch, so this is not the
  /// place for anything that has to be computed at send time.
  ///
  /// Ignored when [rootKey] is null, since a bare array has no root to merge
  /// them into.
  final Map<String, Object?> extras;

  /// Whether to leave a field out entirely when the platform did not report
  /// it, rather than sending null.
  ///
  /// On by default: an accuracy of `null` says the phone did not know, and an
  /// API that reads a missing key as "unknown" is better served by its
  /// absence than by a null it may coerce to zero.
  final bool omitNull;

  const PayloadFormat({
    this.rootKey = 'points',
    this.fields = const {},
    this.timeFormat = TimeFormat.epochMillis,
    this.speedUnit = SpeedUnit.kilometersPerHour,
    this.extras = const {},
    this.omitNull = true,
  });

  /// The wire name this format uses for [field].
  String nameOf(LocationField field) => fields[field] ?? _defaultNames[field]!;

  static const Map<LocationField, String> _defaultNames = {
    LocationField.latitude: 'lat',
    LocationField.longitude: 'lng',
    LocationField.time: 'timestamp',
    LocationField.accuracy: 'accuracy',
    LocationField.speed: 'speed',
    LocationField.heading: 'heading',
  };

  /// The form the native side reads.
  ///
  /// Field names are flattened to a plain string map and the enums to their
  /// wire spellings, so both platforms can parse this with their own JSON
  /// reader and no shared schema.
  Map<String, Object?> toMap() => {
    'rootKey': rootKey,
    'fields': {
      for (final field in LocationField.values)
        _defaultNames[field]!: nameOf(field),
    },
    'timeFormat': switch (timeFormat) {
      TimeFormat.epochMillis => 'epoch_millis',
      TimeFormat.epochSeconds => 'epoch_seconds',
      TimeFormat.iso8601Utc => 'iso8601_utc',
    },
    'speedUnit': switch (speedUnit) {
      SpeedUnit.metersPerSecond => 'mps',
      SpeedUnit.kilometersPerHour => 'kmh',
    },
    'extras': extras,
    'omitNull': omitNull,
  };
}
