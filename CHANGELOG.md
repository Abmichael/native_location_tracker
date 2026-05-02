# Changelog

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
