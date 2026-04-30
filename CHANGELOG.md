# Changelog

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
