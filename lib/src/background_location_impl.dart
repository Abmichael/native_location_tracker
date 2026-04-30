import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_location_manager.dart';
import 'location_point.dart';
import 'policy.dart';
import 'tracking_options.dart';
import 'upload_config.dart';

/// Main entry point for background location tracking.
///
/// Usage:
/// ```dart
/// import 'package:native_location_tracker/native_location_tracker.dart';
///
/// // Initialize with upload configuration
/// await BackgroundLocation.initialize(
///   config: UploadConfig(
///     uploadUrl: 'https://api.example.com/location/update',
///     accessToken: myToken,
///     refreshToken: myRefreshToken,
///     refreshUrl: 'https://api.example.com/auth/refresh',
///   ),
/// );
///
/// // Start tracking
/// await BackgroundLocation.instance.startTracking(
///   TrackingOptions(sessionId: 'trip-123', mode: TrackingMode.fast),
/// );
/// ```
class BackgroundLocation {
  static BackgroundLocationImpl? _instance;

  /// Register the upload configuration for server communication.
  ///
  /// Must be called before using the instance.
  static Future<void> initialize({required UploadConfig config}) async {
    _instance = BackgroundLocationImpl(config: config);
    await _instance!._initialize();
  }

  /// Get the singleton instance.
  ///
  /// Throws if [initialize] has not been called.
  static BackgroundLocationManager get instance {
    if (_instance == null) {
      throw StateError(
        'BackgroundLocation not initialized. Call BackgroundLocation.initialize() first.',
      );
    }
    return _instance!;
  }

  /// Check if the manager has been initialized.
  static bool get isInitialized => _instance != null;

  /// Dispose of the manager (call on app shutdown).
  static void dispose() {
    _instance?.dispose();
    _instance = null;
  }

  /// Persist tokens from Dart -> native storage.
  ///
  /// Call this after login and after any Dart-side refresh so native background
  /// components never keep an older refresh token.
  static Future<void> setNativeAuthTokens({
    required String accessToken,
    required String refreshToken,
  }) =>
      BackgroundLocationImpl.setNativeAuthTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );

  /// Read the latest native-stored upload config (including tokens).
  ///
  /// Native-side uploads can refresh/rotate tokens while Flutter is not
  /// running. This allows the Dart side to re-sync and avoid using a consumed
  /// refresh token.
  static Future<NativeUploadConfig?> getNativeUploadConfig() =>
      BackgroundLocationImpl.getNativeUploadConfig();

  /// Clear native-stored upload config (including tokens).
  ///
  /// Useful on logout to ensure native background components can't keep using
  /// old tokens.
  static Future<void> clearNativeUploadConfig() =>
      BackgroundLocationImpl.clearNativeUploadConfig();
}

/// Implementation of BackgroundLocationManager using platform channels.
class BackgroundLocationImpl implements BackgroundLocationManager {
  static const MethodChannel _methodChannel = MethodChannel(
    'dev.nativelocation.tracker/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'dev.nativelocation.tracker/events',
  );
  static const EventChannel _stateEventChannel = EventChannel(
    'dev.nativelocation.tracker/state',
  );

  static const String _prefKeyIsTracking = 'nlt_is_tracking';
  static const String _prefKeySessionId = 'nlt_session_id';

  final UploadConfig _config;

  final StreamController<LocationPoint> _locationStreamController =
      StreamController.broadcast();

  final StreamController<NativeTrackingState> _nativeStateController =
      StreamController.broadcast();
  StreamSubscription<dynamic>? _nativeStateSubscription;

  StreamSubscription<dynamic>? _nativeEventSubscription;
  String? _deviceId;
  TrackingOptions? _currentOptions;
  bool _isPaused = false;
  bool _isInitialized = false;

  // For adaptive sampling
  double? _lastSpeed;
  DateTime? _lastParamsUpdate;

  BackgroundLocationImpl({required UploadConfig config}) : _config = config;

  /// Read the latest native-stored upload config (including tokens).
  static Future<NativeUploadConfig?> getNativeUploadConfig() async {
    try {
      final raw = await _methodChannel.invokeMethod('getUploadConfig');
      if (raw is! Map) return null;
      return NativeUploadConfig.fromPlatformMap(raw);
    } catch (_) {
      return null;
    }
  }

  /// Clear native-stored upload config (including tokens).
  static Future<void> clearNativeUploadConfig() async {
    try {
      await _methodChannel.invokeMethod('clearUploadConfig');
    } catch (_) {
      // Best-effort.
    }
  }

  /// Persist tokens from Dart -> native storage.
  static Future<void> setNativeAuthTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    try {
      await _methodChannel.invokeMethod('setAuthTokens', {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      });
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _initialize() async {
    if (_isInitialized) return;

    // Get device ID
    await _getDeviceId();

    // Check if we were tracking before app restart
    await _restoreTrackingState();

    // Subscribe to native location events
    _subscribeToNativeEvents();

    // Subscribe to native state events
    _subscribeToNativeState();

    // Configure native-side uploads with URL and auth token
    await _configureNativeUpload();

    _isInitialized = true;
  }

  /// Configure native-side upload URL and auth token.
  Future<void> _configureNativeUpload() async {
    try {
      await _methodChannel.invokeMethod('setUploadConfig', {
        'uploadUrl': _config.uploadUrl,
        'authToken': _config.authHeader,
        'refreshToken': _config.refreshToken,
        'refreshUrl': _config.refreshUrl,
        'apiBaseUrl': _config.apiBaseUrl,
      });
    } catch (e) {
      print('NativeLocationTracker: Failed to configure native upload: $e');
    }
  }

  Future<void> _getDeviceId() async {
    if (_deviceId != null) return;

    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      _deviceId = androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      _deviceId = iosInfo.identifierForVendor;
    }
  }

  void _subscribeToNativeEvents() {
    _nativeEventSubscription?.cancel();
    _nativeEventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          _handleNativeLocationEvent(event);
        }
      },
      onError: (error) {
        print('NativeLocationTracker: Native event error: $error');
      },
    );
  }

  /// Subscribe to native state events.
  void _subscribeToNativeState() {
    if (!Platform.isAndroid) return; // iOS will get this later
    _nativeStateSubscription?.cancel();
    _nativeStateSubscription =
        _stateEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          try {
            _nativeStateController.add(NativeTrackingState(
              isTracking: event['isTracking'] as bool? ?? false,
              sessionId: event['sessionId'] as String?,
              pendingCount: event['pendingCount'] as int? ?? 0,
              lastUploadAt: event['lastUploadAt'] is int &&
                      (event['lastUploadAt'] as int) > 0
                  ? DateTime.fromMillisecondsSinceEpoch(
                      event['lastUploadAt'] as int)
                  : null,
              lastError: event['lastError'] as String?,
              uploaderState: event['uploaderState'] as String? ?? 'unknown',
            ));
          } catch (e) {
            print('NativeLocationTracker: Error parsing native state: $e');
          }
        }
      },
      onError: (error) {
        print('NativeLocationTracker: Native state error: $error');
      },
    );
  }

  void _handleNativeLocationEvent(Map<dynamic, dynamic> event) {
    try {
      final point = LocationPoint(
        lat: (event['lat'] as num).toDouble(),
        lng: (event['lng'] as num).toDouble(),
        timestamp: (event['time'] as num).toInt(),
        speed: (event['speed'] as num?)?.toDouble(),
        heading: (event['bearing'] as num?)?.toDouble(),
        accuracy: (event['accuracy'] as num?)?.toDouble(),
        altitude: (event['altitude'] as num?)?.toDouble(),
        deviceId: _deviceId,
        source: _parseSource(event['source'] as String?),
        sessionId: _currentOptions?.sessionId,
        isMock: event['isMock'] as bool? ?? false,
      );

      _lastSpeed = point.speed;
      _locationStreamController.add(point);
    } catch (e) {
      print('NativeLocationTracker: Error processing native event: $e');
    }
  }

  LocationSource? _parseSource(String? source) {
    if (source == null) return null;
    switch (source.toLowerCase()) {
      case 'gps':
        return LocationSource.gps;
      case 'network':
        return LocationSource.network;
      case 'fused':
        return LocationSource.fused;
      case 'passive':
        return LocationSource.passive;
      default:
        return LocationSource.gps;
    }
  }

  Future<void> _saveTrackingState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyIsTracking, _currentOptions != null);
    if (_currentOptions != null) {
      await prefs.setString(_prefKeySessionId, _currentOptions!.sessionId);
    } else {
      await prefs.remove(_prefKeySessionId);
    }
  }

  Future<void> _restoreTrackingState() async {
    final prefs = await SharedPreferences.getInstance();

    bool isRunning = false;
    try {
      isRunning =
          await _methodChannel.invokeMethod<bool>('isServiceRunning') ?? false;
    } catch (e) {
      print('NativeLocationTracker: Error checking service status: $e');
    }

    if (isRunning) {
      String? sessionId = prefs.getString(_prefKeySessionId);

      if (sessionId == null) {
        try {
          sessionId = await _methodChannel.invokeMethod<String>('getSessionId');
        } catch (e) {
          print(
              'NativeLocationTracker: Failed to get session ID from native: $e');
        }
      }

      if (sessionId != null) {
        _currentOptions = TrackingOptions(sessionId: sessionId);
        await _configureNativeUpload();
        await _saveTrackingState();
        print(
          'NativeLocationTracker: Restored tracking state for session $sessionId',
        );
      } else {
        print(
          'NativeLocationTracker: Service running but no session ID found. Stopping.',
        );
        await stopTracking();
      }
    } else {
      final wasTracking = prefs.getBool(_prefKeyIsTracking) ?? false;
      final sessionId = prefs.getString(_prefKeySessionId);

      if (wasTracking && sessionId != null) {
        print('NativeLocationTracker: Service was killed, restarting...');
        _currentOptions = TrackingOptions(sessionId: sessionId);
        await _configureNativeUpload();

        final params = _currentOptions!.getEffectiveParams();
        final args = {
          ..._currentOptions!.toNativeArgs(),
          'priority': params.priority.name,
          'effectiveIntervalMs': params.intervalMs,
          'effectiveDistanceMeters': params.distanceFilterMeters,
        };

        try {
          await _methodChannel.invokeMethod('start', args);
          print('NativeLocationTracker: Service restarted');
        } catch (e) {
          print('NativeLocationTracker: Failed to restart service: $e');
          _currentOptions = null;
          await _saveTrackingState();
        }
      } else {
        _currentOptions = null;
        await _saveTrackingState();
      }
    }
  }

  @override
  Future<void> startTracking(TrackingOptions options) async {
    if (_currentOptions != null) {
      throw StateError('Already tracking. Call stopTracking() first.');
    }

    _currentOptions = options;
    _isPaused = false;

    await _configureNativeUpload();

    final params = options.getEffectiveParams();

    final args = {
      ...options.toNativeArgs(),
      'priority': params.priority.name,
      'effectiveIntervalMs': params.intervalMs,
      'effectiveDistanceMeters': params.distanceFilterMeters,
    };

    await _methodChannel.invokeMethod('start', args);
    await _saveTrackingState();
  }

  @override
  Future<void> stopTracking() async {
    _currentOptions = null;
    _isPaused = false;

    await _methodChannel.invokeMethod('stop');
    await _saveTrackingState();
  }

  @override
  Future<void> updateNotification({
    String? title,
    String? text,
    String? icon,
  }) async {
    if (!Platform.isAndroid) return;

    final isRunning = await isTracking();
    if (!isRunning) return;

    final args = <String, dynamic>{
      if (title != null) 'notificationTitle': title,
      if (text != null) 'notificationText': text,
      if (icon != null) 'notificationIcon': icon,
    };

    try {
      await _methodChannel.invokeMethod('updateNotification', args);
    } catch (e) {
      print('NativeLocationTracker: Failed to update notification: $e');
    }

    if (_currentOptions != null) {
      _currentOptions = _currentOptions!.copyWith(
        notificationTitle: title,
        notificationText: text,
        notificationIcon: icon,
      );
      await _saveTrackingState();
    }
  }

  @override
  Future<void> pauseTracking() async {
    if (_currentOptions == null) return;
    _isPaused = true;
  }

  @override
  Future<void> resumeTracking() async {
    if (_currentOptions == null) return;
    _isPaused = false;
  }

  @override
  Future<bool> isTracking() async {
    if (_currentOptions != null) return true;

    try {
      final isRunning = await _methodChannel.invokeMethod<bool>(
        'isServiceRunning',
      );
      return isRunning ?? false;
    } catch (e) {
      print('NativeLocationTracker: Error checking service status: $e');
      return false;
    }
  }

  @override
  Future<bool> isPaused() async {
    return _isPaused;
  }

  @override
  Stream<LocationPoint> get locationStream => _locationStreamController.stream;

  @override
  TrackingOptions? get currentOptions => _currentOptions;

  @override
  Future<int> flushQueue() async {
    final state = await getNativeState();
    return state.pendingCount;
  }

  @override
  Future<int> getPendingCount() async {
    final state = await getNativeState();
    return state.pendingCount;
  }

  @override
  Future<DateTime?> getLastSyncTime() async {
    final state = await getNativeState();
    return state.lastUploadAt;
  }

  @override
  Future<void> clearQueue() async {
    // No-op: native vault lifecycle is managed natively.
  }

  @override
  void dispose() {
    _nativeEventSubscription?.cancel();
    _nativeStateSubscription?.cancel();
    _locationStreamController.close();
    _nativeStateController.close();
  }

  // ============== Additional Helper Methods ==============

  /// Stream of native tracking state updates.
  Stream<NativeTrackingState> get nativeStateStream =>
      _nativeStateController.stream;

  /// Debug/testing helper (Android only): inject mock points into the native
  /// buffer and trigger an immediate flush.
  Future<Map<String, Object?>?> debugInsertMockPoints({
    int count = 10,
    double? lat,
    double? lng,
  }) async {
    if (!Platform.isAndroid) return null;
    final sessionId = _currentOptions?.sessionId;
    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
      'debugInsertMockPoints',
      {
        'count': count,
        'sessionId': sessionId,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      },
    );
    return result?.map((k, v) => MapEntry(k?.toString() ?? '', v));
  }

  /// One-shot query of native tracking state.
  Future<NativeTrackingState> getNativeState() async {
    try {
      final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        'getNativeState',
      );
      if (result == null) {
        return NativeTrackingState(isTracking: false, uploaderState: 'unknown');
      }
      return NativeTrackingState(
        isTracking: result['isTracking'] as bool? ?? false,
        sessionId: result['sessionId'] as String?,
        pendingCount: result['pendingCount'] as int? ?? 0,
        lastUploadAt: result['lastUploadAt'] is int &&
                (result['lastUploadAt'] as int) > 0
            ? DateTime.fromMillisecondsSinceEpoch(result['lastUploadAt'] as int)
            : null,
        lastError: result['lastError'] as String?,
        uploaderState: result['uploaderState'] as String? ?? 'unknown',
      );
    } catch (e) {
      print('NativeLocationTracker: Error getting native state: $e');
      return NativeTrackingState(isTracking: false, uploaderState: 'error');
    }
  }

  /// Request to ignore battery optimizations (Android only).
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    return await _methodChannel.invokeMethod<bool>(
          'requestIgnoreBatteryOptimizations',
        ) ??
        false;
  }

  /// Check if battery optimizations are being ignored (Android only).
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    return await _methodChannel.invokeMethod<bool>(
          'isIgnoringBatteryOptimizations',
        ) ??
        false;
  }

  /// Get the current tracking state for UI display.
  Future<TrackingState> getTrackingState() async {
    final nativeState = await getNativeState();
    return TrackingState(
      status: _currentOptions == null
          ? TrackingStatus.stopped
          : _isPaused
              ? TrackingStatus.paused
              : TrackingStatus.active,
      options: _currentOptions,
      pendingCount: nativeState.pendingCount,
      lastSyncTime: nativeState.lastUploadAt,
      hasNetwork: true,
    );
  }

  /// Update tracking parameters dynamically (for adaptive sampling).
  Future<void> updateTrackingParams() async {
    if (_currentOptions == null) return;

    final now = DateTime.now();
    if (_lastParamsUpdate != null &&
        now.difference(_lastParamsUpdate!).inSeconds < 30) {
      return;
    }

    final params = _currentOptions!.getEffectiveParams(
      currentSpeedMps: _lastSpeed,
    );

    await _methodChannel.invokeMethod('updateParams', {
      'intervalMs': params.intervalMs,
      'distanceFilterMeters': params.distanceFilterMeters,
      'priority': params.priority.name,
    });

    _lastParamsUpdate = now;
  }
}

/// Native-stored upload/auth config snapshot.
class NativeUploadConfig {
  final String? uploadUrl;
  final String? apiBaseUrl;

  /// Auth header as stored by native (usually `Bearer <token>`).
  final String? authHeader;

  /// Refresh token stored by native (rotates; old tokens are one-time use).
  final String? refreshToken;

  const NativeUploadConfig({
    required this.uploadUrl,
    required this.apiBaseUrl,
    required this.authHeader,
    required this.refreshToken,
  });

  String? get accessToken {
    final header = authHeader;
    if (header == null) return null;
    final trimmed = header.trim();
    const prefix = 'Bearer ';
    if (trimmed.startsWith(prefix)) {
      final token = trimmed.substring(prefix.length).trim();
      return token.isEmpty ? null : token;
    }
    return trimmed.isEmpty ? null : trimmed;
  }

  static NativeUploadConfig fromPlatformMap(Map raw) {
    String? asString(dynamic v) => v is String ? v : null;

    return NativeUploadConfig(
      uploadUrl: asString(raw['uploadUrl']),
      apiBaseUrl: asString(raw['apiBaseUrl']),
      authHeader: asString(raw['authToken']),
      refreshToken: asString(raw['refreshToken']),
    );
  }
}

/// Native tracking state emitted by the platform service.
///
/// Allows Dart UI to display upload/tracking status without owning a
/// persistent database.
class NativeTrackingState {
  /// Whether the native service is currently tracking.
  final bool isTracking;

  /// The active session ID, if tracking.
  final String? sessionId;

  /// Number of points in the native buffer awaiting upload.
  final int pendingCount;

  /// Timestamp of the last successful upload.
  final DateTime? lastUploadAt;

  /// Last error message from the native uploader, if any.
  final String? lastError;

  /// Current state of the native uploader (e.g. "active", "idle", "error").
  final String uploaderState;

  const NativeTrackingState({
    required this.isTracking,
    this.sessionId,
    this.pendingCount = 0,
    this.lastUploadAt,
    this.lastError,
    this.uploaderState = 'unknown',
  });

  @override
  String toString() =>
      'NativeTrackingState(tracking: $isTracking, session: $sessionId, '
      'pending: $pendingCount, uploader: $uploaderState)';
}
