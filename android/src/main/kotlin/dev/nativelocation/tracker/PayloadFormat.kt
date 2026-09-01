package dev.nativelocation.tracker

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The shape of the JSON body uploaded to the host app's endpoint.
 *
 * Handed down from Dart as a JSON string (see `PayloadFormat` there) and
 * persisted, so a batch uploading long after the app was killed still knows
 * what the server expects. Anything missing or unparseable falls back to the
 * format this plugin sent before it was configurable, so an old stored config
 * — or none at all — behaves exactly as it used to.
 */
internal class PayloadFormat private constructor(
    private val rootKey: String?,
    private val names: Map<String, String>,
    private val timeFormat: String,
    private val speedUnit: String,
    private val extras: JSONObject?,
    private val omitNull: Boolean
) {
    companion object {
        private const val TAG = "NLTPayloadFormat"

        private const val LAT = "lat"
        private const val LNG = "lng"
        private const val TIME = "timestamp"
        private const val ACCURACY = "accuracy"
        private const val SPEED = "speed"
        private const val HEADING = "heading"

        private val DEFAULT_NAMES = mapOf(
            LAT to LAT,
            LNG to LNG,
            TIME to TIME,
            ACCURACY to ACCURACY,
            SPEED to SPEED,
            HEADING to HEADING
        )

        /** What the plugin has always sent. */
        private fun default() = PayloadFormat(
            rootKey = "points",
            names = DEFAULT_NAMES,
            timeFormat = "epoch_millis",
            // Not the platform's unit. Kept because changing it would silently
            // divide every existing integration's speeds by 3.6.
            speedUnit = "kmh",
            extras = null,
            omitNull = true
        )

        fun from(json: String?): PayloadFormat {
            if (json.isNullOrBlank()) return default()

            return try {
                val root = JSONObject(json)

                val names = HashMap(DEFAULT_NAMES)
                root.optJSONObject("fields")?.let { fields ->
                    for (key in DEFAULT_NAMES.keys) {
                        val mapped = fields.optString(key, "")
                        if (mapped.isNotEmpty()) names[key] = mapped
                    }
                }

                PayloadFormat(
                    // `has` rather than `optString`, so an explicit null —
                    // meaning "post a bare array" — is not read as absent.
                    rootKey = if (root.isNull("rootKey")) null
                    else root.optString("rootKey", "points"),
                    names = names,
                    timeFormat = root.optString("timeFormat", "epoch_millis"),
                    speedUnit = root.optString("speedUnit", "kmh"),
                    extras = root.optJSONObject("extras"),
                    omitNull = root.optBoolean("omitNull", true)
                )
            } catch (e: Exception) {
                // A malformed format must not cost the batch. Falling back
                // sends the old shape, which is wrong for this server but
                // recoverable; throwing here would strand every point on the
                // device with nothing to say why.
                Log.w(TAG, "Unreadable payload format, using the default: ${e.message}")
                default()
            }
        }
    }

    fun buildBody(locations: List<NativeLocationBuffer.LocationEntry>): String {
        val points = JSONArray()

        for (loc in locations) {
            val point = JSONObject()
            point.put(names.getValue(LAT), loc.lat)
            point.put(names.getValue(LNG), loc.lng)
            point.put(names.getValue(TIME), formatTime(loc.timestamp))

            putOptional(point, names.getValue(HEADING), loc.bearing)
            putOptional(point, names.getValue(SPEED), loc.speed?.let { convertSpeed(it) })
            putOptional(point, names.getValue(ACCURACY), loc.accuracy)

            points.put(point)
        }

        // A bare array as the whole body, for an API that takes no envelope.
        // Extras have nowhere to go in that case and are dropped.
        val key = rootKey ?: return points.toString()

        val body = JSONObject()
        body.put(key, points)

        extras?.let { extra ->
            val keys = extra.keys()
            while (keys.hasNext()) {
                val name = keys.next()
                body.put(name, extra.get(name))
            }
        }

        return body.toString()
    }

    private fun putOptional(target: JSONObject, name: String, value: Double?) {
        when {
            value != null -> target.put(name, value)
            // An absent key says the phone did not know. A null may be read as
            // zero at the far end, which is a different and false claim.
            !omitNull -> target.put(name, JSONObject.NULL)
        }
    }

    private fun convertSpeed(metersPerSecond: Double): Double =
        if (speedUnit == "mps") metersPerSecond else metersPerSecond * 3.6

    private fun formatTime(epochMillis: Long): Any = when (timeFormat) {
        "epoch_seconds" -> epochMillis / 1000
        "iso8601_utc" -> isoFormatter().format(Date(epochMillis))
        else -> epochMillis
    }

    /**
     * Built per call rather than shared: [SimpleDateFormat] is not thread-safe
     * and uploads run on a pool.
     */
    private fun isoFormatter(): SimpleDateFormat =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
}
