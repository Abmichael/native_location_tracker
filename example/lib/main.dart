import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:native_location_tracker/native_location_tracker.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  // Ensure Flutter binding is initialized before calling any native channels.
  WidgetsFlutterBinding.ensureInitialized();

  // Configure your upload endpoint and auth tokens.
  // The BackgroundLocation plugin uses this configuration to perform batch 
  // uploads directly from the native side (Android Service / iOS BGTask).
  // This means uploads will continue even if the Flutter engine is suspended.
  await BackgroundLocation.initialize(
    config: UploadConfig(
      // The endpoint where location batches will be POSTed.
      // For Android emulator, 10.0.2.2 points to the host machine.
      uploadUrl: 'http://10.0.2.2:8000/location/update',
      // Access token to be sent in the Authorization header (Bearer prefix added automatically).
      accessToken: 'YOUR_ACCESS_TOKEN',
      // Refresh token used to recover from HTTP 401 Unauthorized errors automatically.
      refreshToken: 'YOUR_REFRESH_TOKEN',
      // Endpoint to POST the refresh token and receive new tokens.
      refreshUrl: 'http://10.0.2.2:8000/auth/refresh',
      // Base URL used for auxiliary native API calls if any.
      apiBaseUrl: 'http://10.0.2.2:8000',
    ),
  );

  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_location_tracker example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  // Controller for the session ID input field. Session IDs help group locations
  // (e.g., a specific trip or delivery task).
  final _sessionController = TextEditingController();
  
  // Default tracking mode. Fast mode tracks more aggressively, suitable for live trips.
  TrackingMode _mode = TrackingMode.fast;

  // Stream subscriptions for location updates and native state changes.
  StreamSubscription<LocationPoint>? _locationSub;
  StreamSubscription<NativeTrackingState>? _stateSub;
  
  // Timer to periodically poll native state in case we miss an event.
  Timer? _pollTimer;

  bool _isTracking = false;
  NativeTrackingState? _nativeState;

  // Local list of captured points to display in the UI.
  final List<LocationPoint> _points = <LocationPoint>[];

  // UI-only simulated points to test the UI without actually moving.
  bool _simulating = false;
  Timer? _simTimer;

  @override
  void initState() {
    super.initState();
    _bindStreams();
    unawaited(_refreshNativeState());
    
    // Periodically refresh the native state (e.g., pending count and last upload time)
    // to keep the UI up-to-date.
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshNativeState());
    });
  }

  /// Listens to the streams provided by the BackgroundLocation singleton.
  void _bindStreams() {
    _locationSub?.cancel();
    
    // Listen to actual location points as they are captured by the native side.
    _locationSub = BackgroundLocation.instance.locationStream.listen((point) {
      if (!mounted) return;
      setState(() {
        _points.insert(0, point);
        if (_points.length > 100) _points.removeLast(); // Keep recent 100 points
      });
    });

    // Listen to changes in the native tracking state (upload success, queue size, etc.)
    final impl = BackgroundLocation.instance as BackgroundLocationImpl;
    _stateSub?.cancel();
    _stateSub = impl.nativeStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _nativeState = state;
        _isTracking = state.isTracking;
      });
    });
  }

  /// Fetches the latest native tracking state manually.
  Future<void> _refreshNativeState() async {
    try {
      final impl = BackgroundLocation.instance as BackgroundLocationImpl;
      final state = await impl.getNativeState();
      if (!mounted) return;
      setState(() {
        _nativeState = state;
        _isTracking = state.isTracking;
      });
    } catch (e) {
      // Best effort; log silently or handle as needed.
      debugPrint('Failed to refresh native state: $e');
    }
  }

  /// Requests the necessary permissions for background location tracking.
  Future<bool> _requestPermissions() async {
    // 1. Notification permission (Required for Android 13+ Foreground Service)
    final notificationStatus = await Permission.notification.request();
    if (!notificationStatus.isGranted) return false;

    // 2. Location When In Use (Base location requirement)
    final whenInUseStatus = await Permission.locationWhenInUse.request();
    if (!whenInUseStatus.isGranted) return false;

    // 3. Optional: Background Location. You might want to request this specifically
    // depending on your app's needs. If not granted, tracking may stop when the app
    // goes into the background on certain Android/iOS versions.
    // final bgStatus = await Permission.locationAlways.request();

    return true;
  }

  /// Starts the tracking service with the selected options.
  Future<void> _start() async {
    if (!await _requestPermissions()) {
      _snack('Permissions denied', isError: true);
      return;
    }

    // Android specific: Request ignoring battery optimizations for better reliability.
    final impl = BackgroundLocation.instance as BackgroundLocationImpl;
    await impl.requestIgnoreBatteryOptimizations();

    // Use a custom session ID or generate one if empty.
    final sessionId = _sessionController.text.trim().isNotEmpty
        ? _sessionController.text.trim()
        : 'example-${DateTime.now().millisecondsSinceEpoch}';

    // Configure the tracking options.
    final options = TrackingOptions(
      sessionId: sessionId,
      mode: _mode,
      // Notification title and text are used for the Android Foreground Service.
      notificationTitle:
          _mode == TrackingMode.fast ? 'Trip tracking active' : 'Tracking active',
      notificationText: 'Tap to return to the app',
    );

    try {
      await BackgroundLocation.instance.startTracking(options);
      _snack('Started tracking ($sessionId)');
      await _refreshNativeState();
    } catch (e) {
      _snack('Start failed: $e', isError: true);
    }
  }

  /// Stops the tracking service.
  Future<void> _stop() async {
    try {
      await BackgroundLocation.instance.stopTracking();
      _snack('Stopped');
      await _refreshNativeState();
    } catch (e) {
      _snack('Stop failed: $e', isError: true);
    }
  }

  /// Injects mock points into the native buffer for testing the upload mechanism.
  /// (Android Debug builds only)
  Future<void> _injectMockPoints() async {
    try {
      final impl = BackgroundLocation.instance as BackgroundLocationImpl;
      final res = await impl.debugInsertMockPoints(count: 25);
      _snack('Injected: ${res?['uploaded'] ?? 0} uploaded (success=${res?['success']})');
      await _refreshNativeState();
    } catch (e) {
      _snack('Inject failed: $e', isError: true);
    }
  }

  /// Toggles a UI-only simulation of points for testing without walking around.
  void _toggleSim() {
    if (_simulating) {
      _simTimer?.cancel();
      _simTimer = null;
      setState(() => _simulating = false);
      _snack('UI-only simulation stopped');
      return;
    }

    final random = Random();
    double lat = 9.0192;
    double lng = 38.7525;

    _simTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      lat += (random.nextDouble() - 0.5) * 0.001;
      lng += (random.nextDouble() - 0.5) * 0.001;

      final point = LocationPoint(
        lat: lat,
        lng: lng,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        speed: 5 + random.nextDouble() * 15,
        heading: random.nextDouble() * 360,
        accuracy: 5 + random.nextDouble() * 10,
        source: LocationSource.gps,
        sessionId: 'ui-sim',
        isMock: true,
      );

      if (!mounted) return;
      setState(() {
        _points.insert(0, point);
        if (_points.length > 100) _points.removeLast();
      });
    });

    setState(() => _simulating = true);
    _snack('UI-only simulation started');
  }

  /// Helper to show Snackbars for user feedback.
  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _locationSub?.cancel();
    _stateSub?.cancel();
    _simTimer?.cancel();
    _sessionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _nativeState;
    final lastUpload = state?.lastUploadAt;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracker Example'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: _refreshNativeState,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh native state',
          ),
        ],
      ),
      body: Column(
        children: [
          // Control Panel Card
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status Header
                  Row(
                    children: [
                      Icon(
                        _isTracking ? Icons.location_on : Icons.location_off,
                        color: _isTracking ? Colors.green : Colors.grey,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isTracking ? 'Tracking Active' : 'Tracking Stopped',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              'Pending points: ${state?.pendingCount ?? '-'} | '
                              'Uploader state: ${state?.uploaderState ?? '-'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  
                  // Session ID Input
                  TextField(
                    controller: _sessionController,
                    decoration: const InputDecoration(
                      labelText: 'Session ID (e.g., trip ID)',
                      border: OutlineInputBorder(),
                      helperText: 'Leave empty for auto-generated ID'
                    ),
                    enabled: !_isTracking,
                  ),
                  const SizedBox(height: 12),
                  
                  // Tracking Mode Dropdown
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      const Text('Tracking Mode:'),
                      DropdownButton<TrackingMode>(
                        value: _mode,
                        onChanged: _isTracking
                            ? null
                            : (v) => setState(() => _mode = v!),
                        items: const [
                          DropdownMenuItem(
                            value: TrackingMode.fast,
                            child: Text('Fast (Active Trip)'),
                          ),
                          DropdownMenuItem(
                            value: TrackingMode.lowPower,
                            child: Text('Low Power (Background)'),
                          ),
                        ],
                      ),
                      // Last Upload Info
                      Text(
                        lastUpload != null
                            ? 'Last Upload: ${_fmtAgo(lastUpload)}'
                            : 'Last Upload: -',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  
                  // Error display
                  if ((state?.lastError ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Last Error: ${state?.lastError}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.red),
                    ),
                  ],
                  const SizedBox(height: 16),
                  
                  // Action Buttons
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _isTracking ? _stop : _start,
                        icon: Icon(_isTracking ? Icons.stop : Icons.play_arrow),
                        label: Text(_isTracking ? 'Stop Tracking' : 'Start Tracking'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _injectMockPoints,
                        icon: const Icon(Icons.add_location_alt_outlined),
                        label: const Text('Inject 25 (Android)'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _toggleSim,
                        icon: Icon(_simulating
                            ? Icons.stop_circle
                            : Icons.bug_report_outlined),
                        label: Text(_simulating ? 'Stop UI Sim' : 'Start UI Sim'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 0),
          
          // Locations List
          Expanded(
            child: _points.isEmpty
                ? const Center(child: Text('No location points yet'))
                : ListView.builder(
                    itemCount: _points.length,
                    itemBuilder: (context, index) {
                      final p = _points[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          p.isMock == true
                              ? Icons.bug_report_outlined
                              : Icons.location_on,
                          color: p.isMock == true ? Colors.orange : Colors.blue,
                        ),
                        title: Text(
                          'Lat: ${p.lat.toStringAsFixed(5)}, Lng: ${p.lng.toStringAsFixed(5)}',
                        ),
                        subtitle: Text(
                          'Accuracy: ${p.accuracy?.toStringAsFixed(0) ?? '?'}m | '
                          'Speed: ${p.speed?.toStringAsFixed(1) ?? '?'}m/s\n'
                          'Time: ${_fmtTs(p.timestamp)} | Source: ${p.source?.name}',
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Formats timestamp in ms to HH:MM:SS
  static String _fmtTs(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  /// Formats duration since a given DateTime
  static String _fmtAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}
