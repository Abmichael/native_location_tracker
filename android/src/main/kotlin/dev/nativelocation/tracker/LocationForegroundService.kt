package dev.nativelocation.tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.Handler
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList

class LocationForegroundService : Service() {

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_GO_OFFLINE = "ACTION_GO_OFFLINE"
        const val ACTION_UPDATE_PARAMS = "ACTION_UPDATE_PARAMS"
        const val ACTION_UPDATE_NOTIFICATION = "ACTION_UPDATE_NOTIFICATION"
        const val ACTION_SET_UPLOAD_CONFIG = "ACTION_SET_UPLOAD_CONFIG"
        const val CHANNEL_ID = "nlt_location_channel"
        const val NOTIFICATION_ID = 12345
        const val UPLOAD_WORK_NAME = "LocationUploadWorker"

        // SharedPreferences keys for persisting effective tracking params
        const val KEY_EFFECTIVE_INTERVAL_MS = "effective_interval_ms"
        const val KEY_EFFECTIVE_DISTANCE_M = "effective_distance_m"
        const val KEY_EFFECTIVE_PRIORITY = "effective_priority"
        const val KEY_NOTIFICATION_TITLE = "notification_title"
        const val KEY_NOTIFICATION_TEXT = "notification_text"
        const val KEY_NOTIFICATION_ICON = "notification_icon"
        const val KEY_STARTED_AT_MS = "service_started_at_ms"
        
        var isServiceRunning = false
        private var plugin: NativeLocationTrackerPlugin? = null
        private var serviceInstance: LocationForegroundService? = null

        fun setPlugin(plugin: NativeLocationTrackerPlugin?) {
            this.plugin = plugin
        }

        fun getNativePendingCountStatic(): Int {
            return serviceInstance?.getNativePendingCount() ?: 0
        }
    }

    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback
    private lateinit var prefs: SharedPreferences
    private lateinit var nativeBuffer: NativeLocationBuffer

    @Volatile
    private var isStopping: Boolean = false

    // WakeLock held while tracking is active (P0.5)
    private var wakeLock: PowerManager.WakeLock? = null

    // Periodic upload handler
    private val uploadHandler = Handler(Looper.getMainLooper())
    private var uploadRunnable: Runnable? = null
    private var uploadIntervalMs: Long = 30000  // Default 30 seconds

    // STILL heartbeat (presence) — keeps backend TTL.DRIVER_ACTIVE fresh.
    private var stillHeartbeatMs: Long = 12_000L
    private val heartbeatHandler = Handler(Looper.getMainLooper())
    private var heartbeatRunnable: Runnable? = null
    private var lastHeartbeatAtMs: Long = 0L

    // Last known location snapshot for heartbeat
    private var lastLat: Double? = null
    private var lastLng: Double? = null
    private var lastBearing: Double? = null
    private var lastAccuracy: Double? = null
    private var lastLocationAtMs: Long = 0L
    
    // Current tracking parameters
    private var currentIntervalMs: Long = 5000
    private var currentDistanceMeters: Float = 10f
    private var currentPriority: Int = Priority.PRIORITY_HIGH_ACCURACY
    private var baseIntervalMs: Long = 5000
    private var baseDistanceMeters: Float = 10f
    private var basePriority: Int = Priority.PRIORITY_HIGH_ACCURACY
    private var sessionId: String? = null
    private var deviceId: String? = null
    private var notificationTitle: String = "Location tracking"
    private var notificationText: String = "Tap to open app"
    private var notificationIconName: String? = null

    // Elapsed time base for notification chronometer
    private var startedAtMs: Long = 0L

    // Motion state manager (P0.12 / M3)
    private lateinit var motionStateManager: MotionStateManager

    override fun onCreate() {
        super.onCreate()
        serviceInstance = this
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        prefs = getSharedPreferences(NativeLocationTrackerPlugin.PREFS_NAME, Context.MODE_PRIVATE)
        nativeBuffer = NativeLocationBuffer(this)

        // Motion state detection (P0.12)
        motionStateManager = MotionStateManager(this)
        motionStateManager.onPacingChanged = { pacing ->
            // Native adaptive pacing: merge motion state with configured base params.
            // In FAST sessions, never degrade to multi-minute intervals just because the
            // activity classifier says STILL (e.g., stop lights, emulator idle).
            val isFastSession = baseIntervalMs <= 10_000L || basePriority == Priority.PRIORITY_HIGH_ACCURACY

            val effective = if (isFastSession) {
                MotionStateManager.PacingParams(
                    intervalMs = baseIntervalMs.coerceIn(2_000L, 5_000L),
                    distanceMeters = minOf(baseDistanceMeters, 5f),
                    priority = Priority.PRIORITY_HIGH_ACCURACY,
                    label = pacing.label
                )
            } else {
                pacing
            }

            android.util.Log.i(
                "LocationService",
                "Motion pacing change: ${effective.label} → ${effective.intervalMs}ms / ${effective.distanceMeters}m",
            )

            currentIntervalMs = effective.intervalMs
            currentDistanceMeters = effective.distanceMeters
            currentPriority = effective.priority
            // Persist new effective params
            persistEffectiveParams()
            // Re-request location updates with new params
            fusedLocationClient.removeLocationUpdates(locationCallback)
            requestLocationUpdates()
        }
        
        // Get device ID
        deviceId = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ANDROID_ID
        )
        
        // Load upload config from prefs (set by Dart side)
        loadUploadConfigFromPrefs()
        
        locationCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                for (location in locationResult.locations) {
                    handleLocation(location)
                }
            }
        }
        
        android.util.Log.i("LocationService", "Service created, deviceId=$deviceId")
    }

    private fun loadUploadConfigFromPrefs() {
        // Check for upload URL in the main prefs (set by NativeLocationTrackerPlugin)
        val uploadUrl = prefs.getString("upload_url", null)
        val authToken = prefs.getString("auth_token", null)
        
        if (uploadUrl != null) {
            nativeBuffer.setConfig("upload_url", uploadUrl)
            android.util.Log.i("LocationService", "Loaded upload URL from prefs: $uploadUrl")
        }
        if (authToken != null) {
            nativeBuffer.setConfig("auth_token", authToken)
            android.util.Log.i("LocationService", "Loaded auth token from prefs")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                isStopping = false
                // If the user changed permissions to "Ask every time" (or revoked
                // them), starting a location-type FGS will throw SecurityException.
                // Fail gracefully and clear tracking state so we don't crash-loop.
                if (!hasAnyLocationPermission()) {
                    android.util.Log.w(
                        "LocationService",
                        "Missing location permission; refusing to start location FGS",
                    )
                    prefs.edit()
                        .remove(NativeLocationTrackerPlugin.KEY_SESSION_ID)
                        .apply()
                    isServiceRunning = false
                    stopSelf()
                    return START_NOT_STICKY
                }

                // Critical: call startForeground() ASAP after startForegroundService()
                // to avoid ForegroundServiceDidNotStartInTimeException.
                try {
                    startForegroundService()
                } catch (e: SecurityException) {
                    android.util.Log.e(
                        "LocationService",
                        "Failed to start location FGS (permissions/eligibility): ${e.message}",
                    )
                    prefs.edit()
                        .remove(NativeLocationTrackerPlugin.KEY_SESSION_ID)
                        .apply()
                    isServiceRunning = false
                    stopSelf()
                    return START_NOT_STICKY
                }

                parseConfig(intent)
                persistEffectiveParams()
                updateForegroundNotification()
                acquireWakeLock()
                requestLocationUpdates()
                motionStateManager.start()
                startPeriodicUpload()
                startStillHeartbeat()
                isServiceRunning = true
            }
            ACTION_STOP -> {
                handleStop(goOffline = false)
            }
            ACTION_GO_OFFLINE -> {
                handleStop(goOffline = true)
            }
            ACTION_UPDATE_PARAMS -> {
                updateParams(intent)
            }
            ACTION_UPDATE_NOTIFICATION -> {
                if (!isServiceRunning) return START_STICKY

                intent.getStringExtra("notificationTitle")?.let { notificationTitle = it }
                intent.getStringExtra("notificationText")?.let { notificationText = it }
                if (intent.hasExtra("notificationIcon")) {
                    notificationIconName = intent.getStringExtra("notificationIcon")
                }

                persistEffectiveParams()
                updateForegroundNotification()
            }
            ACTION_SET_UPLOAD_CONFIG -> {
                val uploadUrl = intent.getStringExtra("uploadUrl")
                val authToken = intent.getStringExtra("authToken")
                uploadUrl?.let { nativeBuffer.setConfig("upload_url", it) }
                authToken?.let { nativeBuffer.setConfig("auth_token", it) }
            }
        }
        return START_STICKY
    }

    private fun handleStop(goOffline: Boolean) {
        isStopping = true
        // Ensure tracking state is cleared.
        prefs.edit()
            .remove(NativeLocationTrackerPlugin.KEY_SESSION_ID)
            .remove(KEY_STARTED_AT_MS)
            .apply()



        stopPeriodicUpload()
        stopStillHeartbeat()
        motionStateManager.stop()
        // Final upload attempt before stopping
        nativeBuffer.uploadPendingLocations { _, _ -> }
        releaseWakeLock()
        stopForegroundService()
        isServiceRunning = false

        // Emit final native state update (P0.4)
        emitNativeState()
    }

    private fun resolveNotificationSmallIconResId(): Int {
        // Default: host app launcher icon.
        val defaultIcon = try { applicationInfo.icon } catch (_: Exception) { 0 }

        val name = notificationIconName
        if (name.isNullOrBlank()) return if (defaultIcon != 0) defaultIcon else android.R.drawable.ic_menu_mylocation

        val pkg = packageName
        val res = resources
        val drawableId = res.getIdentifier(name, "drawable", pkg)
        if (drawableId != 0) return drawableId
        val mipmapId = res.getIdentifier(name, "mipmap", pkg)
        if (mipmapId != 0) return mipmapId

        return if (defaultIcon != 0) defaultIcon else android.R.drawable.ic_menu_mylocation
    }

    private fun buildForegroundNotification(): Notification {
        val notificationIntent = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val stopIntent = Intent(this, LocationForegroundService::class.java).apply {
            action = ACTION_GO_OFFLINE
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(notificationTitle)
            .setContentText(notificationText)
            .setSmallIcon(resolveNotificationSmallIconResId())
            .setContentIntent(contentPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setUsesChronometer(true)
            .setWhen(startedAtMs)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Go offline",
                stopPendingIntent,
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        }

        return builder.build().also { n ->
            n.flags = n.flags or
                Notification.FLAG_ONGOING_EVENT or
                Notification.FLAG_NO_CLEAR or
                Notification.FLAG_FOREGROUND_SERVICE
        }
    }

    private fun updateForegroundNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildForegroundNotification())
        } catch (_: Exception) {
            // Best effort.
        }
    }

    private fun parseConfig(intent: Intent) {
        sessionId = intent.getStringExtra("sessionId")
        
        // Parse interval (Dart passes ints)
        currentIntervalMs = when {
            intent.hasExtra("effectiveIntervalMs") -> intent.getIntExtra("effectiveIntervalMs", intent.getIntExtra("intervalMs", 5000)).toLong()
            intent.hasExtra("intervalMs") -> intent.getIntExtra("intervalMs", 5000).toLong()
            else -> 5000L
        }
        
        // Parse distance filter
        currentDistanceMeters = when {
            intent.hasExtra("effectiveDistanceMeters") -> intent.getIntExtra("effectiveDistanceMeters", 10).toFloat()
            intent.hasExtra("distanceFilterMeters") -> intent.getIntExtra("distanceFilterMeters", 10).toFloat()
            else -> 10f
        }
        
        // Parse priority
        val priorityStr = intent.getStringExtra("priority") ?: intent.getStringExtra("mode") ?: "high"
        currentPriority = when (priorityStr.lowercase()) {
            "high", "fast" -> Priority.PRIORITY_HIGH_ACCURACY
            "balanced", "lowpower" -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
            "lowpower", "passive" -> Priority.PRIORITY_LOW_POWER
            else -> Priority.PRIORITY_HIGH_ACCURACY
        }
        
        // Parse notification text
        notificationTitle = intent.getStringExtra("notificationTitle") ?: "Location tracking"
        notificationText = intent.getStringExtra("notificationText") ?: "Tap to open app"
        notificationIconName = intent.getStringExtra("notificationIcon")
            ?: prefs.getString(KEY_NOTIFICATION_ICON, null)

        // Start timestamp for elapsed timer (persisted for restarts)
        startedAtMs = prefs.getLong(KEY_STARTED_AT_MS, 0L)
        if (startedAtMs <= 0L) {
            startedAtMs = System.currentTimeMillis()
            prefs.edit().putLong(KEY_STARTED_AT_MS, startedAtMs).apply()
        }

        // Heartbeat interval while STILL (ms). 0 disables.
        stillHeartbeatMs = intent.getIntExtra("stillHeartbeatMs", 12_000).toLong()
        if (stillHeartbeatMs < 0) stillHeartbeatMs = 0L

        recomputeUploadInterval()
        
        // Capture configured base params (before motion overrides)
        baseIntervalMs = currentIntervalMs
        baseDistanceMeters = currentDistanceMeters
        basePriority = currentPriority
    }

    /**
     * Persist current effective tracking params.
     */
    private fun persistEffectiveParams() {
        prefs.edit()
            .putLong(KEY_EFFECTIVE_INTERVAL_MS, currentIntervalMs)
            .putFloat(KEY_EFFECTIVE_DISTANCE_M, currentDistanceMeters)
            .putInt(KEY_EFFECTIVE_PRIORITY, currentPriority)
            .putString(KEY_NOTIFICATION_TITLE, notificationTitle)
            .putString(KEY_NOTIFICATION_TEXT, notificationText)
            .putString(KEY_NOTIFICATION_ICON, notificationIconName)
            .putLong(KEY_STARTED_AT_MS, startedAtMs)
            .apply()
    }

    /**
     * Acquire a PARTIAL_WAKE_LOCK so the CPU stays active while tracking,
     * even under Doze (P0.5).  Released on stop or destroy.
     */
    private fun acquireWakeLock() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "nlt:tracking"
            ).apply {
                // Safety timeout: 12 hours to prevent leaks on missed stop.
                acquire(12 * 60 * 60 * 1000L)
            }
            android.util.Log.i("LocationService", "PARTIAL_WAKE_LOCK acquired")
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
                android.util.Log.i("LocationService", "PARTIAL_WAKE_LOCK released")
            }
        }
        wakeLock = null
    }

    /**
     * Return the current battery percentage (0–100), or null if unavailable.
     */
    private fun getBatteryLevel(): Double? {
        return try {
            val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            if (level != null && level > 0) level.toDouble() else null
        } catch (_: Exception) { null }
    }

    private fun updateParams(intent: Intent) {
        if (!isServiceRunning) return

        val newIntervalMs = intent.getIntExtra("intervalMs", currentIntervalMs.toInt()).toLong()
        val newDistanceMeters = intent.getIntExtra(
            "distanceFilterMeters",
            currentDistanceMeters.toInt(),
        ).toFloat()
        val priorityStr = intent.getStringExtra("priority") ?: "high"
        val newPriority = when (priorityStr.lowercase()) {
            "high" -> Priority.PRIORITY_HIGH_ACCURACY
            "balanced" -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
            "lowpower" -> Priority.PRIORITY_LOW_POWER
            else -> currentPriority
        }

        var notificationChanged = false

        intent.getStringExtra("notificationTitle")?.let {
            if (it != notificationTitle) {
                notificationTitle = it
                notificationChanged = true
            }
        }
        intent.getStringExtra("notificationText")?.let {
            if (it != notificationText) {
                notificationText = it
                notificationChanged = true
            }
        }
        if (intent.hasExtra("notificationIcon")) {
            val icon = intent.getStringExtra("notificationIcon")
            if (icon != notificationIconName) {
                notificationIconName = icon
                notificationChanged = true
            }
        }

        val trackingChanged =
            newIntervalMs != currentIntervalMs ||
                newDistanceMeters != currentDistanceMeters ||
                newPriority != currentPriority

        if (trackingChanged) {
            currentIntervalMs = newIntervalMs
            currentDistanceMeters = newDistanceMeters
            currentPriority = newPriority
            recomputeUploadInterval()

            fusedLocationClient.removeLocationUpdates(locationCallback)
            requestLocationUpdates()
            startPeriodicUpload()

            // Update base params too (app-level updates)
            baseIntervalMs = currentIntervalMs
            baseDistanceMeters = currentDistanceMeters
            basePriority = currentPriority
        }

        if (trackingChanged || notificationChanged) {
            persistEffectiveParams()
        }
        if (notificationChanged) {
            updateForegroundNotification()
        }
    }

    private fun handleLocation(location: Location) {
        if (isStopping) return
        android.util.Log.i("LocationService", "📍 Location received: ${location.latitude}, ${location.longitude}")

        // Cache last known location for STILL heartbeats
        lastLat = location.latitude
        lastLng = location.longitude
        lastBearing = if (location.hasBearing()) location.bearing.toDouble() else null
        lastAccuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else null
        lastLocationAtMs = System.currentTimeMillis()
        
        val isMock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }
        
        val source = when {
            location.provider == "gps" -> "gps"
            location.provider == "network" -> "network"
            location.provider == "fused" -> "fused"
            else -> "fused"
        }
        
        android.util.Log.i("LocationService", "📍 Adding to buffer: session=$sessionId, source=$source")
        
        // Always save to native buffer (for when Flutter is not running)
        nativeBuffer.add(
            sessionId = sessionId,
            lat = location.latitude,
            lng = location.longitude,
            timestamp = location.time,
            speed = location.speed.toDouble(),
            bearing = location.bearing.toDouble(),
            accuracy = location.accuracy.toDouble(),
            altitude = location.altitude,
            deviceId = deviceId,
            source = source,
            isMock = isMock,
            batteryLevel = getBatteryLevel(),
            motionState = motionStateManager.currentMotionState
        )
        
        // Also send to Flutter if available
        sendLocationToPlugin(location)
    }

    private fun startStillHeartbeat() {
        stopStillHeartbeat()
        if (stillHeartbeatMs <= 0) return

        heartbeatRunnable = object : Runnable {
            override fun run() {
                try {
                    val motion = motionStateManager.currentMotionState
                    val now = System.currentTimeMillis()
                    val lat = lastLat
                    val lng = lastLng

                    // Only send a presence heartbeat if we haven't received a real
                    // GPS/fused location for a while. This avoids extra traffic while moving,
                    // but keeps backend TTL.DRIVER_ACTIVE fresh when the OS stops emitting points.
                    val noRecentRealPoint = lastLocationAtMs > 0L &&
                        (now - lastLocationAtMs) >= stillHeartbeatMs

                    if (lat != null && lng != null && noRecentRealPoint) {
                        if (now - lastHeartbeatAtMs >= stillHeartbeatMs) {
                            lastHeartbeatAtMs = now

                            nativeBuffer.add(
                                sessionId = sessionId,
                                lat = lat,
                                lng = lng,
                                timestamp = now,
                                speed = 0.0,
                                bearing = lastBearing,
                                accuracy = lastAccuracy,
                                altitude = null,
                                deviceId = deviceId,
                                source = "heartbeat",
                                isMock = false,
                                batteryLevel = null,
                                motionState = motion,
                            )

                            // Trigger an upload attempt soon (don’t wait for long intervals).
                            uploadRunnable?.let { uploadHandler.post(it) }
                        }
                    }
                } catch (_: Exception) {
                    // Best effort.
                } finally {
                    heartbeatRunnable?.let { heartbeatHandler.postDelayed(it, stillHeartbeatMs) }
                }
            }
        }

        heartbeatHandler.postDelayed(heartbeatRunnable!!, stillHeartbeatMs)
    }

    private fun recomputeUploadInterval() {
        val isFastSession =
            currentPriority == Priority.PRIORITY_HIGH_ACCURACY || currentIntervalMs <= 10_000L

        uploadIntervalMs = if (isFastSession) {
            currentIntervalMs.coerceIn(2_000L, 5_000L)
        } else {
            30_000L
        }

        // Keep heartbeat as a fallback only when it is tighter than the upload tick.
        if (stillHeartbeatMs in 1 until uploadIntervalMs) {
            uploadIntervalMs = stillHeartbeatMs
        }
    }

    private fun stopStillHeartbeat() {
        heartbeatRunnable?.let { heartbeatHandler.removeCallbacks(it) }
        heartbeatRunnable = null
        lastHeartbeatAtMs = 0L
    }

    private fun sendLocationToPlugin(location: Location) {
        val isMock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }
        
        val source = when {
            location.provider == "gps" -> "gps"
            location.provider == "network" -> "network"
            location.provider == "fused" -> "fused"
            else -> "gps"
        }
        
        val data = mapOf(
            "lat" to location.latitude,
            "lng" to location.longitude,
            "accuracy" to location.accuracy.toDouble(),
            "altitude" to location.altitude,
            "speed" to location.speed.toDouble(),
            "bearing" to location.bearing.toDouble(),
            "time" to location.time,
            "isMock" to isMock,
            "source" to source
        )
        plugin?.onLocationUpdate(data)
    }

    private fun startForegroundService() {
        createNotificationChannel()

        // Ensure we have a base timestamp for the chronometer.
        startedAtMs = prefs.getLong(KEY_STARTED_AT_MS, 0L)
        if (startedAtMs <= 0L) {
            startedAtMs = System.currentTimeMillis()
            prefs.edit().putLong(KEY_STARTED_AT_MS, startedAtMs).apply()
        }

        val notification = buildForegroundNotification()

        android.util.Log.i("LocationService", "Starting foreground with notification flags: ${notification.flags}")
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun hasAnyLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun stopForegroundService() {
        fusedLocationClient.removeLocationUpdates(locationCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun requestLocationUpdates() {
        android.util.Log.i("LocationService", "🔄 Requesting location updates: interval=${currentIntervalMs}ms, distance=${currentDistanceMeters}m, priority=$currentPriority")
        
        val locationRequest = LocationRequest.Builder(currentPriority, currentIntervalMs)
            .setMinUpdateIntervalMillis(currentIntervalMs / 2)
            .setMinUpdateDistanceMeters(currentDistanceMeters)
            .setWaitForAccurateLocation(false)
            .build()

        try {
            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                locationCallback,
                Looper.getMainLooper()
            )
            android.util.Log.i("LocationService", "✅ Location updates requested successfully")
        } catch (e: SecurityException) {
            // Handle permission loss
            android.util.Log.e("LocationService", "❌ Permission denied: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)

            // Android forbids deleting a notification channel while a foreground
            // service is associated with it. Also, channel importance cannot be
            // changed after creation.
            val existing = manager.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val serviceChannel = NotificationChannel(
                    CHANNEL_ID,
                    "Location Tracking",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Background location tracking for ride services"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(serviceChannel)
                android.util.Log.i("LocationService", "Created notification channel")
            }
        }
    }


    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        android.util.Log.i("LocationService", "App task removed, triggering upload and re-registering location updates...")
        
        // Trigger immediate upload of any buffered locations
        nativeBuffer.uploadPendingLocations { success, count ->
            android.util.Log.i("LocationService", "Background upload: success=$success, count=$count")
        }
        
        // Re-request location updates to ensure they continue after app is killed
        // This is critical because the Flutter engine being killed can disrupt location callbacks
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                fusedLocationClient.removeLocationUpdates(locationCallback)
                requestLocationUpdates()
                android.util.Log.i("LocationService", "✅ Re-registered location updates after task removal")
            } catch (e: Exception) {
                android.util.Log.e("LocationService", "❌ Failed to re-register location updates: ${e.message}")
            }
        }, 1000) // Small delay to let things settle
    }
    
    override fun onDestroy() {
        super.onDestroy()
        isStopping = true
        serviceInstance = null
        motionStateManager.stop()
        releaseWakeLock()
        stopPeriodicUpload()
        stopStillHeartbeat()
        nativeBuffer.close()
    }
    
    // ============== Periodic Upload ==============
    
    private fun startPeriodicUpload() {
        stopPeriodicUpload()
        
        uploadRunnable = object : Runnable {
            override fun run() {
                performUpload()
                uploadHandler.postDelayed(this, uploadIntervalMs)
            }
        }
        
        // Start after initial delay
        // Run immediately once, then on interval.
        uploadHandler.post(uploadRunnable!!)
    }
    
    private fun stopPeriodicUpload() {
        uploadRunnable?.let { uploadHandler.removeCallbacks(it) }
        uploadRunnable = null
    }
    
    private fun performUpload() {
        val pendingCount = nativeBuffer.getPendingCount()
        if (pendingCount > 0) {
            android.util.Log.i("LocationService", "Uploading $pendingCount buffered locations...")
            nativeBuffer.uploadPendingLocations { success, count ->
                android.util.Log.i("LocationService", "Native upload: success=$success, count=$count")
                // Persist last upload metadata for state observability
                if (count > 0) {
                    prefs.edit()
                        .putLong("last_upload_at", System.currentTimeMillis())
                        .apply()
                }
                if (!success) {
                    prefs.edit()
                        .putString("last_upload_error", "Upload failed at ${System.currentTimeMillis()}")
                        .apply()
                }
                // Emit state update to Dart (P0.4)
                emitNativeState()
            }
        }
    }

    /**
     * Emit current native tracking state to the Dart state EventChannel (P0.4).
     */
    private fun emitNativeState() {
        plugin?.emitStateUpdate(mapOf(
            "isTracking" to isServiceRunning,
            "sessionId" to sessionId,
            "pendingCount" to nativeBuffer.getPendingCount(),
            "lastUploadAt" to prefs.getLong("last_upload_at", 0L),
            "lastError" to prefs.getString("last_upload_error", null),
            "uploaderState" to if (isServiceRunning) "active" else "idle"
        ))
    }
    
    fun getNativePendingCount(): Int {
        return nativeBuffer.getPendingCount()
    }
}
