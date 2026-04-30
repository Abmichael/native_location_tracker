/// Native-first background location tracking for Flutter.
///
/// This package provides robust background location tracking with:
/// - Cross-platform support (Android + iOS)
/// - Native-first persistence (SQLite on both platforms)
/// - Automatic batch uploads via native HTTP
/// - Adaptive sampling based on speed and motion state
/// - Configurable tracking modes (lowPower vs fast)
///
/// ## Architecture
///
/// **Native is the single source of truth** for persistence and upload.
/// Dart observes native state and provides UI-facing streams only.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:native_location_tracker/native_location_tracker.dart';
///
/// // Initialize with your upload endpoint
/// await BackgroundLocation.initialize(
///   config: UploadConfig(
///     uploadUrl: 'https://api.example.com/location/update',
///     accessToken: myToken,
///   ),
/// );
///
/// // Start tracking
/// await BackgroundLocation.instance.startTracking(
///   TrackingOptions(sessionId: 'trip-123', mode: TrackingMode.fast),
/// );
///
/// // Listen for updates
/// BackgroundLocation.instance.locationStream.listen((point) {
///   print('Location: ${point.lat}, ${point.lng}');
/// });
///
/// // Stop when done
/// await BackgroundLocation.instance.stopTracking();
/// ```
///
/// ## Platform Setup
///
/// See README.md for Android manifest and iOS Info.plist configuration.
library native_location_tracker;

// Models
export 'src/location_point.dart';
export 'src/upload_config.dart';

// Core API
export 'src/tracking_options.dart';
export 'src/background_location_manager.dart';
export 'src/background_location_impl.dart'
    show BackgroundLocation, BackgroundLocationImpl, NativeTrackingState, NativeUploadConfig;

// Policy
export 'src/policy.dart';
