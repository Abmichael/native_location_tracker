package dev.nativelocation.tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/**
 * Manages motion-state-driven pacing using **permissionless heuristics**.
 *
 * We intentionally do NOT use ActivityRecognition APIs, because they require
 * `android.permission.ACTIVITY_RECOGNITION`, which triggers Google Play “Health
 * apps policy” scrutiny.
 *
 * Instead, we derive a coarse motion state from recent location speed.
 */
class MotionStateManager(private val context: Context) {

    // Pacing presets for each motion state
    data class PacingParams(
        val intervalMs: Long,
        val distanceMeters: Float,
        val priority: Int,
        val label: String
    )

    companion object {
        private const val TAG = "MotionStateManager"

        val STILL_PACING = PacingParams(
            intervalMs = 120_000L, // 2 min
            distanceMeters = 50f,
            priority = Priority.PRIORITY_LOW_POWER,
            label = "still"
        )
        val WALKING_PACING = PacingParams(
            intervalMs = 15_000L, // 15 sec
            distanceMeters = 15f,
            priority = Priority.PRIORITY_BALANCED_POWER_ACCURACY,
            label = "walking"
        )
        val RUNNING_PACING = PacingParams(
            intervalMs = 10_000L,
            distanceMeters = 10f,
            priority = Priority.PRIORITY_HIGH_ACCURACY,
            label = "running"
        )
        val IN_VEHICLE_PACING = PacingParams(
            intervalMs = 5_000L, // 5 sec
            distanceMeters = 10f,
            priority = Priority.PRIORITY_HIGH_ACCURACY,
            label = "in_vehicle"
        )
        val UNKNOWN_PACING = PacingParams(
            intervalMs = 10_000L,
            distanceMeters = 15f,
            priority = Priority.PRIORITY_HIGH_ACCURACY,
            label = "unknown"
        )
    }

    /** The last detected motion state label (for storage w/ each point). */
    @Volatile
    var currentMotionState: String = "unknown"
        private set

    /** Current pacing params derived from motion state. */
    @Volatile
    var currentPacing: PacingParams = UNKNOWN_PACING
        private set

    /** Callback invoked when pacing parameters change. */
    var onPacingChanged: ((PacingParams) -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var pollRunnable: Runnable? = null

    // Poll interval for activity recognition (lightweight)
    private val pollIntervalMs = 10_000L // 10 sec

    /**
     * Start polling activity recognition.
     *
     * Uses `getLastActivity()` approach (no PendingIntent receiver) for
     * simplicity.  Activity updates are checked periodically.
     */
    fun start() {
        schedulePoll()
        Log.i(TAG, "Motion state detection started")
    }

    fun stop() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        pollRunnable = null
        Log.i(TAG, "Motion state detection stopped")
    }

    private fun schedulePoll() {
        pollRunnable = object : Runnable {
            override fun run() {
                pollActivity()
                handler.postDelayed(this, pollIntervalMs)
            }
        }
        handler.post(pollRunnable!!)
    }

    private fun pollActivity() {
        try {
            LocationServices.getFusedLocationProviderClient(context)
                .lastLocation
                .addOnSuccessListener { location ->
                    // Location object doesn't directly provide activity, so
                    // we derive a coarse signal from speed.
                    if (location != null) {
                        updateMotionStateFromSpeed(location.speed)
                    }
                }
        } catch (e: SecurityException) {
            // Location permission may be missing/revoked.
            Log.w(TAG, "Permission denied for speed-based motion detection: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "Error polling activity: ${e.message}")
        }
    }

    /**
     * Derive motion state from speed as a supplementary signal.
     *
     * This is a fallback; the ActivityRecognitionClient result is preferred
     * when available.
     */
    private fun updateMotionStateFromSpeed(speedMps: Float) {
        val speedKmh = speedMps * 3.6

        val newState = when {
            speedKmh < 2.0 -> "still"
            speedKmh < 6.0 -> "walking"
            speedKmh < 15.0 -> "running"
            else -> "in_vehicle"
        }

        applyMotionState(newState)
    }

    private fun applyMotionState(newState: String) {
        if (newState == currentMotionState) return

        val oldState = currentMotionState
        currentMotionState = newState

        val newPacing = when (newState) {
            "still" -> STILL_PACING
            "walking" -> WALKING_PACING
            "running" -> RUNNING_PACING
            "in_vehicle" -> IN_VEHICLE_PACING
            else -> UNKNOWN_PACING
        }

        if (newPacing != currentPacing) {
            currentPacing = newPacing
            Log.i(TAG, "Motion state: $oldState → $newState — pacing: ${newPacing.intervalMs}ms / ${newPacing.distanceMeters}m / ${newPacing.label}")
            onPacingChanged?.invoke(newPacing)
        }
    }
}
