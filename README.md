# native_location_tracker

A **native-first** background location tracking plugin for Flutter.

Designed for ride-hailing, logistics, fleet management, and any app that needs
reliable GPS tracking even when the app is backgrounded or killed.

## Features

- **Native persistence** — Locations are stored in an on-device SQLite database
  (Android and iOS) before upload. No data is lost if the network drops.
- **Batch HTTP upload** — Queued locations are uploaded in paginated batches
  with configurable endpoints and auth tokens.
- **Token refresh** — Native-side 401 recovery with configurable refresh URL.
  Tokens are rotated and persisted so background uploads continue after the
  Flutter engine is killed.
- **Adaptive sampling** — Location interval and accuracy adjust automatically
  based on speed and battery level.
- **Motion-state pacing** — Uses speed-based heuristics (Android) and
  CMMotionActivity (iOS) to switch between still / walking / driving presets.
- **Foreground service** — Proper Android foreground notification with
  customizable title and text.
- **Background uploads on iOS** — Uses `BGTaskScheduler` and `NWPathMonitor`
  for opportunistic flushes and network-restore triggers.

## Getting Started

### 1. Install

```yaml
dependencies:
  native_location_tracker: ^0.1.0
```

### 2. Platform setup

#### Android

Add to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

#### iOS

Add to your `Info.plist`:

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We need your location to track your trip.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need your location to show your position on the map.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
    <string>processing</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>dev.nativelocation.bgflush</string>
</array>
<key>NSMotionUsageDescription</key>
<string>Motion detection improves battery life by reducing GPS polling when stationary.</string>
```

### 3. Initialize

```dart
import 'package:native_location_tracker/native_location_tracker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await BackgroundLocation.initialize(
    config: UploadConfig(
      uploadUrl: 'https://api.example.com/location/update',
      accessToken: myAccessToken,
      refreshToken: myRefreshToken,
      refreshUrl: 'https://api.example.com/auth/refresh',
    ),
  );

  runApp(MyApp());
}
```

### 4. Start tracking

```dart
await BackgroundLocation.instance.startTracking(
  TrackingOptions(
    sessionId: 'trip-123',
    mode: TrackingMode.fast,
    notificationTitle: 'Trip active',
    notificationText: 'Tap to open',
  ),
);
```

### 5. Listen for updates

```dart
BackgroundLocation.instance.locationStream.listen((point) {
  print('${point.lat}, ${point.lng} @ ${point.timestamp}');
});
```

### 6. Stop tracking

```dart
await BackgroundLocation.instance.stopTracking();
```

## Upload Payload

The native uploader POSTs JSON to your `uploadUrl`:

```json
{
  "points": [
    {
      "lat": 9.0192,
      "lng": 38.7525,
      "timestamp": 1700000000000,
      "heading": 90.0,
      "speed": 45.0,
      "accuracy": 5.0
    }
  ]
}
```

> **Note:** By default, speed is converted from m/s to km/h before upload.

### Matching a different API

Pass a `PayloadFormat` to change the shape. The defaults reproduce the body
above exactly, so you only describe what differs:

```dart
await BackgroundLocation.initialize(
  config: UploadConfig(
    uploadUrl: 'https://api.example.com/trips/abc/points',
    payload: PayloadFormat(
      fields: {LocationField.time: 'recordedAt'},   // rename a field
      timeFormat: TimeFormat.iso8601Utc,            // "2026-09-01T09:00:00.000Z"
      speedUnit: SpeedUnit.metersPerSecond,         // skip the km/h conversion
      extras: {'deviceId': deviceId},               // fixed root-level fields
    ),
  ),
);
```

Which produces:

```json
{
  "deviceId": "device-1",
  "points": [
    {
      "lat": 9.0192,
      "lng": 38.7525,
      "recordedAt": "2026-09-01T09:00:00.000Z",
      "speed": 12.5
    }
  ]
}
```

| Option | Default | What it does |
| --- | --- | --- |
| `rootKey` | `'points'` | Key the array sits under. `null` POSTs a bare array as the whole body. |
| `fields` | `{}` | Wire names, where they differ from `lat` / `lng` / `timestamp` / `accuracy` / `speed` / `heading`. |
| `timeFormat` | `epochMillis` | Also `epochSeconds` or `iso8601Utc`. |
| `speedUnit` | `kilometersPerHour` | `metersPerSecond` sends what the platform reported, unconverted. |
| `extras` | `{}` | Fixed values merged into the root of every request. Ignored when `rootKey` is `null`. |
| `omitNull` | `true` | Leave a field out when the platform did not report it, rather than sending `null`. |

The format is data rather than a callback because the uploader runs where no
Dart is alive — an Android foreground service, an iOS background `URLSession`
that outlives the app. It is persisted alongside the upload URL so a batch
finishing after the process is gone still sends the right shape. It cannot
express nested envelopes, non-JSON encodings, or values computed at send time.

## Refusals that are permanent

By default every non-2xx is retried on the next flush. That is right for a
tunnel and wrong for an answer that will never change, so a phone can end up
uploading to a dead endpoint indefinitely.

Name the responses that mean *stop*:

```dart
UploadConfig(
  uploadUrl: 'https://api.example.com/trips/abc/points',
  terminal: TerminalResponse(
    statuses: {409, 410},          // gone, or claimed by another device
    messages: ['unknown link'],    // fallback — see below
  ),
)
```

On a match the batch is dropped, tracking stops, and the state stream reports
`uploaderState: 'terminal'` with `lastError` naming the status. Configuring a
new upload clears it.

**Prefer `statuses`.** `messages` exists for the case where the natural status
is one the uploader must keep treating as retryable — `401` is the example,
because it drives token refresh and cannot be made terminal wholesale even on an
endpoint where nothing can be refreshed. It matches case-insensitively as a
substring of the response body, depends on server copy nobody has promised to
keep stable, and will stop working silently the day that copy changes. On iOS's
background-transfer path no body reaches the delegate, so a message-only rule
cannot fire there.

## Token Refresh

If you provide a `refreshUrl`, the native uploader will POST
`{ "refreshToken": "<token>" }` on HTTP 401 and expects back:

```json
{
  "accessToken": "new-access-token",
  "refreshToken": "new-refresh-token"
}
```

(Or wrapped in a `"data"` object.)

## Tracking Modes

| Mode | Interval | Distance | Priority | Use case |
|------|----------|----------|----------|----------|
| `fast` | 2s | 5m | High accuracy | Active trips |
| `lowPower` | 60s | 100m | Balanced | Background monitoring |

Use the factory constructors for common presets:

```dart
TrackingOptions.city(sessionId: 'trip')    // Fast, tight tracking
TrackingOptions.longHaul(sessionId: 'haul') // Low power, wide filter
```

## API Reference

### `BackgroundLocation.initialize({required UploadConfig config})`
Initializes the background location manager. This must be called before using the `BackgroundLocation.instance`.
- `config`: An `UploadConfig` object specifying the URLs and tokens for native batch uploading.

### `BackgroundLocation.instance`
The singleton instance of `BackgroundLocationManager` used to control tracking.

### `BackgroundLocationManager`
- `startTracking(TrackingOptions options)`: Starts the native background service (Foreground Service on Android) and begins capturing locations based on the provided options.
- `stopTracking()`: Stops the background service and stops capturing new locations.
- `pauseTracking()`: Temporarily pauses tracking without stopping the service. Capturing continues, but uploads are paused.
- `resumeTracking()`: Resumes tracking and server synchronization after a pause.
- `isTracking()`: Returns a `Future<bool>` indicating if tracking is currently active (even if paused).
- `locationStream`: A `Stream<LocationPoint>` that emits new location points as they are captured.
- `flushQueue()`: Forces an immediate attempt to upload queued locations to the server. Returns the pending count.
- `getPendingCount()`: Returns a `Future<int>` indicating the number of locations currently buffered natively.

### `TrackingOptions`
Options for starting the tracking service.
- `sessionId`: String to identify the tracking session (e.g., a trip ID).
- `mode`: The `TrackingMode` to use (`fast` or `lowPower`). Defaults to `lowPower`.
- `intervalSeconds`: Desired time between location updates.
- `distanceFilterMeters`: Desired distance between location updates.
- `notificationTitle` / `notificationText`: (Android only) Text for the persistent Foreground Service notification.
- `notificationTapUri`: (Android only) Opaque URI opened via `ACTION_VIEW` (scoped to the app's package) when the notification is tapped — e.g. a deep link to a tracking screen. The plugin does not interpret it; the app composes the full URI. If null, the app's default launcher intent is used.

### `UploadConfig`
Configuration for native-side HTTP uploads.
- `uploadUrl`: Full URL where location batches are POSTed.
- `accessToken`: Bearer access token.
- `refreshToken`: Refresh token for native-side 401 recovery.
- `refreshUrl`: Full URL for token refresh.
- `apiBaseUrl`: Base URL of the API.

## Architecture

```
┌──────────────────────────────────────────┐
│                 Dart / Flutter            │
│  BackgroundLocation.instance             │
│    ├── locationStream (UI)               │
│    ├── nativeStateStream (status)        │
│    └── startTracking / stopTracking      │
└──────────┬──────────┬────────────────────┘
           │MethodChannel    │EventChannel
┌──────────▼──────────▼────────────────────┐
│            Native Platform               │
│  ┌─────────────────────────────────┐     │
│  │ LocationForegroundService (Android)   │
│  │ CLLocationManager (iOS)               │
│  └───────────┬─────────────────────┘     │
│              ▼                           │
│  ┌─────────────────────────────────┐     │
│  │ NativeLocationBuffer / Vault    │     │
│  │ (SQLite — single source of truth)    │
│  └───────────┬─────────────────────┘     │
│              ▼                           │
│  ┌─────────────────────────────────┐     │
│  │ NativeLocationUploader          │     │
│  │ (HTTP POST + token refresh)     │     │
│  └─────────────────────────────────┘     │
└──────────────────────────────────────────┘
```

## License

MIT — see [LICENSE](LICENSE).
