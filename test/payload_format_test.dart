import 'package:flutter_test/flutter_test.dart';
import 'package:native_location_tracker/native_location_tracker.dart';

/// The format crosses to native as a JSON map and is then persisted and read
/// back by code that outlives the app, so what matters is that the map is
/// complete, self-describing, and unchanged by default — an existing
/// integration that never sets one must keep sending exactly what it did.
void main() {
  group('PayloadFormat defaults', () {
    test('reproduces the format this plugin has always sent', () {
      final map = const PayloadFormat().toMap();

      expect(map['rootKey'], 'points');
      expect(map['timeFormat'], 'epoch_millis');
      // Not the platform's unit, and deliberately so: switching the default
      // would quietly divide every existing integration's speeds by 3.6.
      expect(map['speedUnit'], 'kmh');
      expect(map['omitNull'], true);
      expect(map['extras'], isEmpty);
      expect(map['fields'], {
        'lat': 'lat',
        'lng': 'lng',
        'timestamp': 'timestamp',
        'accuracy': 'accuracy',
        'speed': 'speed',
        'heading': 'heading',
      });
    });

    test('names every field, so native never has to guess a default', () {
      // The map is the whole contract. A field left out of it would read as
      // absent on the other side rather than as unchanged.
      final fields = const PayloadFormat().toMap()['fields'] as Map;

      expect(fields.length, LocationField.values.length);
    });
  });

  group('PayloadFormat overrides', () {
    test('renames only what it is given', () {
      final map = const PayloadFormat(
        fields: {LocationField.time: 'recordedAt'},
      ).toMap();

      final fields = map['fields'] as Map;
      expect(fields['timestamp'], 'recordedAt');
      // Everything else keeps its default name.
      expect(fields['lat'], 'lat');
      expect(fields['speed'], 'speed');
    });

    test('carries the time format and speed unit through', () {
      final map = const PayloadFormat(
        timeFormat: TimeFormat.iso8601Utc,
        speedUnit: SpeedUnit.metersPerSecond,
      ).toMap();

      expect(map['timeFormat'], 'iso8601_utc');
      expect(map['speedUnit'], 'mps');
    });

    test('epoch seconds is distinct from epoch millis', () {
      expect(
        const PayloadFormat(
          timeFormat: TimeFormat.epochSeconds,
        ).toMap()['timeFormat'],
        'epoch_seconds',
      );
    });

    test('a null root key survives as an explicit null', () {
      // Native tells "post a bare array" from "the key was not sent" by the
      // presence of the key, so it has to be there holding null.
      final map = const PayloadFormat(rootKey: null).toMap();

      expect(map.containsKey('rootKey'), isTrue);
      expect(map['rootKey'], isNull);
    });

    test('extras ride along unchanged', () {
      final map = const PayloadFormat(
        extras: {'deviceId': 'device-1', 'schema': 2},
      ).toMap();

      expect(map['extras'], {'deviceId': 'device-1', 'schema': 2});
    });

    test('omitNull can be turned off', () {
      expect(const PayloadFormat(omitNull: false).toMap()['omitNull'], false);
    });
  });

  group('nameOf', () {
    test('answers with the override where there is one', () {
      const format = PayloadFormat(fields: {LocationField.time: 'recordedAt'});

      expect(format.nameOf(LocationField.time), 'recordedAt');
      expect(format.nameOf(LocationField.latitude), 'lat');
    });
  });
}
