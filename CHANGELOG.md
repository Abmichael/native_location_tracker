# Changelog

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
