# Changelog

## 0.6.0

- **The uploader can be told which refusals are permanent.** `UploadConfig`
  takes a `TerminalResponse` naming the HTTP statuses — and, as a fallback, the
  response-body fragments — that mean "stop" rather than "try again later":

  ```dart
  UploadConfig(
    uploadUrl: '.../points',
    terminal: TerminalResponse(
      statuses: {409, 410},
      messages: ['unknown link'],   // only where a status cannot be agreed
    ),
  )
  ```

  Until now every non-2xx was retried indefinitely. That is right for a tunnel
  and wrong for an answer that will never change — a trip that has ended, a
  session claimed by another device, a revoked token. A phone would keep
  uploading to a dead endpoint for as long as the app stayed installed.

  On a terminal response the batch is **dropped rather than kept** (it can never
  be delivered, and the queue is not keyed by upload URL, so holding it would
  eventually post those points to whatever session the device is configured for
  next), tracking is stopped, and `uploaderState` becomes `terminal` with
  `lastError` naming the status. A new `setUploadConfig` clears the flag, so the
  next session starts clean.

  Statuses are the mechanism to prefer. `messages` is a heuristic for the case
  where the natural status is one the uploader must keep treating as retryable
  — `401`, which drives token refresh, is the example that motivated it. It
  matches case-insensitively as a substring, depends on server copy nobody has
  promised to keep stable, and will stop working silently the day that copy is
  reworded. On iOS's background-transfer path there is no body to match at all,
  so a message-only rule cannot fire there.

  **Nothing changes for an existing integration**: the default is empty, and an
  empty `TerminalResponse` retries everything exactly as before.

## 0.5.0

- **The uploaded body's shape is now configurable.** `UploadConfig` takes a
  `PayloadFormat` describing the envelope key, the field names, how the time of
  a fix is written, the unit speed is sent in, and any fixed root-level fields
  the API wants alongside the points:

  ```dart
  UploadConfig(
    uploadUrl: '.../points',
    payload: PayloadFormat(
      fields: {LocationField.time: 'recordedAt'},
      timeFormat: TimeFormat.iso8601Utc,
      speedUnit: SpeedUnit.metersPerSecond,
      extras: {'deviceId': deviceId},
    ),
  )
  ```

  Until now the body was fixed — `{points: [{lat, lng, timestamp, ...}]}`, with
  speed always converted to km/h because one backend wanted it that way. Any
  API that named a field differently, wanted an ISO timestamp, or wanted the
  platform's own speed could not be used without forking the plugin.

  **Nothing changes for an existing integration.** The defaults reproduce the
  old body exactly, including the km/h conversion; the new `SpeedUnit` is how
  you opt out of it rather than something you now opt into.

  The format is data, not a callback, because the uploader runs where no Dart
  is alive — an Android foreground service, an iOS background `URLSession` that
  outlives the app. It is persisted alongside the upload URL, so a batch
  finishing after the process is gone still sends the right shape. An
  unreadable or absent stored format falls back to the default rather than
  failing the upload, which would strand points on the device with no way to
  say why.

## 0.4.3

- **iOS**: The plugin now captures the background-`URLSession` completion handler
  itself via Flutter's app-delegate forwarding (`addApplicationDelegate` +
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)`), so iOS
  can relaunch the app to finish suspended upload transfers. **No host
  `AppDelegate` wiring is required** — this replaces the manual
  `backgroundCompletionHandler` setup hinted at in 0.4.2.

## 0.4.2

- **iOS**: Fixed the background upload path. It previously created a
  `dataTask` with a completion handler on the background `URLSession`, which is
  unsupported (background sessions only allow file-based upload/download tasks
  and throw on completion-handler tasks) — so the BGProcessingTask flush never
  worked. Background flushes now use a delegate-driven `uploadTask(fromFile:)`
  that completes even while the app is suspended; queued rows are marked
  in-flight when enqueued and deleted once the server confirms `2xx` (or reset
  to pending on failure). The foreground/active path is unchanged. Added
  `NativeLocationUploader.backgroundCompletionHandler` for optional host
  `AppDelegate` relaunch wiring.

## 0.4.1

- **iOS**: Raised minimum iOS deployment target to 14.0 (was 13.0) for SwiftPM.
- **Android**: Updated background location implementation and dependency versions.

## 0.4.0

- **Android**: Migrated to Flutter's built-in Kotlin support. The plugin no longer applies the Kotlin Gradle Plugin, removing the Flutter KGP compatibility warning.
- **iOS**: Added Swift Package Manager support while retaining CocoaPods compatibility.
- **Compatibility**: Raised the minimum SDK versions to Dart 3.12 and Flutter 3.44.

## 0.3.1

- **Wider compatibility**: Relaxed the `device_info_plus` constraint to `>=11.1.1 <14.0.0`. The plugin only uses stable `androidInfo.id` / `iosInfo.identifierForVendor` APIs, so the previous `^13.1.0` pin needlessly forced consumers onto `win32 ^6` and conflicted with apps still on the `win32 5.x` plugin ecosystem.

## 0.3.0

- **Notification tap target**: Added `TrackingOptions.notificationTapUri` (Android). When set, tapping the foreground notification fires an `ACTION_VIEW` intent for the given URI (scoped to the host app's package) instead of the default launcher intent. The plugin treats the URI as opaque — the host app composes it (e.g. a deep link to a tracking screen). Falls back to the launcher intent when null.

## 0.2.1

- **pubspec.yaml Imporovement**: Added correct git links, shortened description and updated packages to latest versions.

## 0.2.0

- **Privacy Improvement**: Removed `ACCESS_BACKGROUND_LOCATION` and `RECEIVE_BOOT_COMPLETED` permissions on Android.
- **Compliance**: Removed boot persistence and background restart workers (WorkManager) to simplify Play Store review and improve battery efficiency.
- **Footprint**: Removed Android `WorkManager` dependency, reducing plugin binary size.
- **Documentation**: Updated manifest requirements and setup guides in README.

## 0.1.0

- Initial release.
- Native-first background location tracking on Android and iOS.
- SQLite-backed persistence (NativeLocationBuffer / NativeLocationVault).
- Batch HTTP upload with paginated drain.
- Token refresh with configurable refresh URL.
- Adaptive sampling based on speed and battery level.
- Motion-state pacing (speed heuristics on Android, CMMotionActivity on iOS).
- Android foreground service with customizable notification.
- Boot persistence (Android BootReceiver + WorkManager).
- iOS BGTaskScheduler and NWPathMonitor support.
- Example app with simulated points and native state display.
