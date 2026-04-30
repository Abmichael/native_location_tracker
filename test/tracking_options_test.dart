import 'package:flutter_test/flutter_test.dart';
import 'package:native_location_tracker/native_location_tracker.dart';

void main() {
  group('TrackingOptions', () {
    test('creates with default values', () {
      final options = TrackingOptions(sessionId: 'test-123');
      
      expect(options.sessionId, 'test-123');
      expect(options.mode, TrackingMode.lowPower);
      expect(options.intervalSeconds, 30);
      expect(options.distanceFilterMeters, 50);
      expect(options.batchSize, 50);
      expect(options.useSignificantChangeFallback, true);
    });

    test('city factory creates fast mode options', () {
      final options = TrackingOptions.city(sessionId: 'city-trip');
      
      expect(options.mode, TrackingMode.fast);
      expect(options.intervalSeconds, 2);
      expect(options.distanceFilterMeters, 5);
      expect(options.batchSize, 20);
    });

    test('longHaul factory creates low power options', () {
      final options = TrackingOptions.longHaul(sessionId: 'delivery');
      
      expect(options.mode, TrackingMode.lowPower);
      expect(options.intervalSeconds, 60);
      expect(options.distanceFilterMeters, 100);
      expect(options.batchSize, 50);
    });

    test('toNativeArgs converts correctly', () {
      final options = TrackingOptions(
        sessionId: 'test',
        mode: TrackingMode.fast,
        intervalSeconds: 10,
        distanceFilterMeters: 20,
      );
      
      final args = options.toNativeArgs();
      
      expect(args['sessionId'], 'test');
      expect(args['mode'], 'fast');
      expect(args['intervalMs'], 10000);
      expect(args['distanceFilterMeters'], 20);
    });

    test('copyWith creates modified copy', () {
      final original = TrackingOptions(sessionId: 'original');
      final modified = original.copyWith(
        sessionId: 'modified',
        mode: TrackingMode.fast,
      );
      
      expect(modified.sessionId, 'modified');
      expect(modified.mode, TrackingMode.fast);
      expect(original.sessionId, 'original'); // Original unchanged
    });
  });

  group('TrackingPolicy', () {
    test('getDefaultParams returns correct values for lowPower', () {
      final params = TrackingPolicy.getDefaultParams(TrackingMode.lowPower);
      
      expect(params.intervalMs, 60000);
      expect(params.distanceFilterMeters, 100);
      expect(params.priority, LocationPriority.balanced);
    });

    test('getDefaultParams returns correct values for fast', () {
      final params = TrackingPolicy.getDefaultParams(TrackingMode.fast);
      
      expect(params.intervalMs, 2000);
      expect(params.distanceFilterMeters, 5);
      expect(params.priority, LocationPriority.high);
    });

    test('calculateParams applies adaptive sampling for stationary', () {
      final options = TrackingOptions(
        sessionId: 'test',
        mode: TrackingMode.fast,
        intervalSeconds: 5,
      );
      
      final params = TrackingPolicy.calculateParams(
        options: options,
        currentSpeedMps: 0.3, // ~1 km/h - stationary
      );
      
      expect(params.intervalMs, greaterThanOrEqualTo(120000));
      expect(params.priority, LocationPriority.lowPower);
      expect(params.reason, contains('stationary'));
    });

    test('calculateParams applies adaptive sampling for fast movement', () {
      final options = TrackingOptions(
        sessionId: 'test',
        mode: TrackingMode.lowPower,
        intervalSeconds: 60,
      );
      
      final params = TrackingPolicy.calculateParams(
        options: options,
        currentSpeedMps: 15.0, // ~54 km/h - fast
      );
      
      expect(params.intervalMs, lessThanOrEqualTo(2000));
      expect(params.priority, LocationPriority.high);
      expect(params.reason, contains('fast movement'));
    });

    test('calculateParams adjusts for critical battery', () {
      final options = TrackingOptions(
        sessionId: 'test',
        mode: TrackingMode.fast,
        intervalSeconds: 5,
        enableAdaptiveSampling: false,
      );
      
      final params = TrackingPolicy.calculateParams(
        options: options,
        batteryLevel: 0.10, // 10% battery
      );
      
      expect(params.intervalMs, greaterThanOrEqualTo(60000));
      expect(params.priority, LocationPriority.lowPower);
      expect(params.reason, contains('Battery critical'));
    });

    test('shouldRecord returns true when distance exceeds filter', () {
      final result = TrackingPolicy.shouldRecord(
        lastLat: 9.0,
        lastLng: 38.0,
        newLat: 9.001,
        newLng: 38.0,
        distanceFilterMeters: 50,
      );
      
      // ~111 meters difference should trigger recording
      expect(result, true);
    });

    test('shouldRecord returns false when distance is below filter', () {
      // Use same coordinates - distance should be 0
      final result = TrackingPolicy.shouldRecord(
        lastLat: 9.0,
        lastLng: 38.0,
        newLat: 9.0,  // Same point
        newLng: 38.0,
        distanceFilterMeters: 50,
      );
      
      // Same location should not trigger recording
      expect(result, false);
    });
  });

  group('LocationPoint', () {
    test('fromJson / toJson round-trip', () {
      final point = LocationPoint(
        lat: 9.0192,
        lng: 38.7525,
        timestamp: 1700000000000,
        speed: 12.5,
        heading: 90.0,
        accuracy: 5.0,
        altitude: 2400.0,
        source: LocationSource.gps,
        sessionId: 'trip-1',
        isMock: false,
      );

      final json = point.toJson();
      final restored = LocationPoint.fromJson(json);

      expect(restored.lat, point.lat);
      expect(restored.lng, point.lng);
      expect(restored.timestamp, point.timestamp);
      expect(restored.speed, point.speed);
      expect(restored.heading, point.heading);
      expect(restored.accuracy, point.accuracy);
      expect(restored.source, LocationSource.gps);
      expect(restored.sessionId, 'trip-1');
    });

    test('equality by lat/lng/timestamp', () {
      final a = LocationPoint(lat: 9.0, lng: 38.0, timestamp: 1000);
      final b = LocationPoint(lat: 9.0, lng: 38.0, timestamp: 1000);
      final c = LocationPoint(lat: 9.1, lng: 38.0, timestamp: 1000);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('UploadConfig', () {
    test('authHeader prepends Bearer', () {
      final config = UploadConfig(
        uploadUrl: 'https://api.example.com/location/update',
        accessToken: 'my-token',
      );
      expect(config.authHeader, 'Bearer my-token');
    });

    test('authHeader is null when no token', () {
      final config = UploadConfig(
        uploadUrl: 'https://api.example.com/location/update',
      );
      expect(config.authHeader, isNull);
    });
  });
}
