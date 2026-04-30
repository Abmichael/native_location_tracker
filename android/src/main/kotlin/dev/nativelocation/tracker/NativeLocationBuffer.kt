package dev.nativelocation.tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException

/**
 * Native-side location buffer — the **single source of truth** for background
 * location persistence on Android.
 *
 * Locations are written synchronously (on a single-thread executor) from the
 * foreground service callback.  Each point receives a native-generated UUIDv4
 * (`pointId`) at capture time for deterministic idempotency.
 *
 * The upload payload matches the canonical schema defined in
 * `docs/LOCATION_BATCH_SCHEMA.md`.
 */
class NativeLocationBuffer(private val context: Context) {

    companion object {
        private const val TAG = "NativeLocationBuffer"
        private const val DB_NAME = "nlt_locations.db"
        // Bump to 2: adds point_id, motion_state columns.
        private const val DB_VERSION = 2
        private const val TABLE_LOCATIONS = "locations"
        
        private const val COL_ID = "_id"
        private const val COL_POINT_ID = "point_id"
        private const val COL_SESSION_ID = "session_id"
        private const val COL_LAT = "lat"
        private const val COL_LNG = "lng"
        private const val COL_TIMESTAMP = "timestamp"
        private const val COL_SPEED = "speed"
        private const val COL_BEARING = "heading"
        private const val COL_ACCURACY = "accuracy"
        private const val COL_ALTITUDE = "altitude"
        private const val COL_DEVICE_ID = "device_id"
        private const val COL_SOURCE = "source"
        private const val COL_IS_MOCK = "is_mock"
        private const val COL_BATTERY_LEVEL = "battery_level"
        private const val COL_MOTION_STATE = "motion_state"
        private const val COL_STATUS = "status"  // 0 = pending, 1 = sent
        
        private const val PREFS_NAME = "nlt_buffer_config"
        private const val KEY_UPLOAD_URL = "upload_url"
        private const val KEY_AUTH_TOKEN = "auth_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"
        private const val KEY_API_BASE_URL = "api_base_url"
        private const val KEY_REFRESH_URL = "refresh_url"
        
        const val STATUS_PENDING = 0
        const val STATUS_SENT = 1
        
        private const val MAX_BUFFER_SIZE = 10000  // Hard FIFO cap per backlog
        private const val UPLOAD_BATCH_SIZE = 50
    }
    
    private val dbHelper: DatabaseHelper
    private val executor = Executors.newSingleThreadExecutor()
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    
    init {
        dbHelper = DatabaseHelper(context)
    }
    
    /**
     * Add a location to the buffer.
     *
     * A UUIDv4 `pointId` is generated at capture time for idempotent uploads.
     */
    fun add(
        sessionId: String?,
        lat: Double,
        lng: Double,
        timestamp: Long,
        speed: Double?,
        bearing: Double?,
        accuracy: Double?,
        altitude: Double?,
        deviceId: String?,
        source: String?,
        isMock: Boolean,
        batteryLevel: Double?,
        motionState: String? = null
    ) {
        if (executor.isShutdown) return
        try {
            executor.execute {
                try {
                    val db = dbHelper.writableDatabase

                    // Enforce hard FIFO cap
                    trimBufferIfNeeded(db)

                    val pointId = UUID.randomUUID().toString()

                    val values = ContentValues().apply {
                        put(COL_POINT_ID, pointId)
                        put(COL_SESSION_ID, sessionId)
                        put(COL_LAT, lat)
                        put(COL_LNG, lng)
                        put(COL_TIMESTAMP, timestamp)
                        put(COL_SPEED, speed)
                        put(COL_BEARING, bearing)
                        put(COL_ACCURACY, accuracy)
                        put(COL_ALTITUDE, altitude)
                        put(COL_DEVICE_ID, deviceId)
                        put(COL_SOURCE, source)
                        put(COL_IS_MOCK, if (isMock) 1 else 0)
                        put(COL_BATTERY_LEVEL, batteryLevel)
                        put(COL_MOTION_STATE, motionState)
                        put(COL_STATUS, STATUS_PENDING)
                    }

                    db.insert(TABLE_LOCATIONS, null, values)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to add location: ${e.message}")
                }
            }
        } catch (_: RejectedExecutionException) {
            // Race: executor shut down while a late callback tried to enqueue.
        }
    }
    
    /**
     * Get pending locations for upload, ordered FIFO by timestamp.
     */
    fun getPendingBatch(limit: Int = UPLOAD_BATCH_SIZE): List<LocationEntry> {
        val locations = mutableListOf<LocationEntry>()
        try {
            val db = dbHelper.readableDatabase
            val cursor = db.query(
                TABLE_LOCATIONS,
                null,
                "$COL_STATUS = ?",
                arrayOf(STATUS_PENDING.toString()),
                null,
                null,
                "$COL_TIMESTAMP ASC",
                limit.toString()
            )
            
            cursor.use {
                while (it.moveToNext()) {
                    locations.add(LocationEntry(
                        id = it.getLong(it.getColumnIndexOrThrow(COL_ID)),
                        pointId = it.getStringOrNull(COL_POINT_ID) ?: UUID.randomUUID().toString(),
                        sessionId = it.getString(it.getColumnIndexOrThrow(COL_SESSION_ID)),
                        lat = it.getDouble(it.getColumnIndexOrThrow(COL_LAT)),
                        lng = it.getDouble(it.getColumnIndexOrThrow(COL_LNG)),
                        timestamp = it.getLong(it.getColumnIndexOrThrow(COL_TIMESTAMP)),
                        speed = it.getDoubleOrNull(COL_SPEED),
                        bearing = it.getDoubleOrNull(COL_BEARING),
                        accuracy = it.getDoubleOrNull(COL_ACCURACY),
                        altitude = it.getDoubleOrNull(COL_ALTITUDE),
                        deviceId = it.getString(it.getColumnIndexOrThrow(COL_DEVICE_ID)),
                        source = it.getString(it.getColumnIndexOrThrow(COL_SOURCE)),
                        isMock = it.getInt(it.getColumnIndexOrThrow(COL_IS_MOCK)) == 1,
                        batteryLevel = it.getDoubleOrNull(COL_BATTERY_LEVEL),
                        motionState = it.getStringOrNull(COL_MOTION_STATE)
                    ))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get pending batch: ${e.message}")
        }
        return locations
    }
    
    /**
     * Mark locations as sent.
     */
    fun markSent(ids: List<Long>) {
        if (ids.isEmpty()) return
        try {
            val db = dbHelper.writableDatabase
            val idList = ids.joinToString(",")
            db.execSQL("UPDATE $TABLE_LOCATIONS SET $COL_STATUS = $STATUS_SENT WHERE $COL_ID IN ($idList)")

            // Delete only the rows we just sent.
            db.execSQL("DELETE FROM $TABLE_LOCATIONS WHERE $COL_ID IN ($idList)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to mark locations as sent: ${e.message}")
        }
    }
    
    /**
     * Get count of pending locations.
     */
    fun getPendingCount(): Int {
        return try {
            val db = dbHelper.readableDatabase
            val cursor = db.rawQuery(
                "SELECT COUNT(*) FROM $TABLE_LOCATIONS WHERE $COL_STATUS = ?",
                arrayOf(STATUS_PENDING.toString())
            )
            cursor.use {
                if (it.moveToFirst()) it.getInt(0) else 0
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get pending count: ${e.message}")
            0
        }
    }
    
    /**
     * Save upload configuration (synchronous - uses SharedPreferences).
     */
    fun setConfig(key: String, value: String?) {
        Log.i(TAG, "Setting config: $key = ${value?.take(50)}...")
        if (value == null) {
            prefs.edit().remove(key).apply()
        } else {
            prefs.edit().putString(key, value).commit()  // Use commit() for synchronous write
        }
    }
    
    /**
     * Get upload configuration (synchronous - uses SharedPreferences).
     */
    fun getConfig(key: String): String? {
        val value = prefs.getString(key, null)
        Log.d(TAG, "Getting config: $key = ${value?.take(50) ?: "null"}")
        return value
    }
    
    /**
     * Upload pending locations in paginated batches (LIMIT 50 per request).
     *
     * On success, rows are deleted immediately then the next page is fetched
     * until the queue is drained or a failure occurs.
     */
    fun uploadPendingLocations(callback: (success: Boolean, count: Int) -> Unit) {
        executor.execute {
            val uploadUrl = getConfig(KEY_UPLOAD_URL)
            val authToken = getConfig(KEY_AUTH_TOKEN)
            
            if (uploadUrl.isNullOrBlank()) {
                Log.w(TAG, "No upload URL configured (key=$KEY_UPLOAD_URL)")
                callback(false, 0)
                return@execute
            }
            
            Log.i(TAG, "Uploading to: $uploadUrl")
            
            var totalUploaded = 0
            var anyFailed = false
            var requestCount = 0
            val maxRequestsPerFlush = 10

            // Paginate: keep fetching batches until empty or failure.
            uploadLoop@ while (true) {
                val batch = getPendingBatch()
                if (batch.isEmpty()) break

                // Group by session
                val sessionGroups = batch.groupBy { it.sessionId ?: "unknown" }

                for ((sessionId, locations) in sessionGroups) {
                    try {
                        val success = doUpload(uploadUrl, authToken, sessionId, locations)
                        requestCount += 1
                        if (success) {
                            markSent(locations.map { it.id })
                            totalUploaded += locations.size
                        } else {
                            anyFailed = true
                        }

                        // Prevent hammering the server/terminal during large backlogs.
                        // The next periodic tick will continue draining.
                        if (requestCount >= maxRequestsPerFlush) {
                            Log.i(TAG, "Reached maxRequestsPerFlush=$maxRequestsPerFlush; pausing drain until next tick")
                            break@uploadLoop
                        }

                        try {
                            Thread.sleep(200)
                        } catch (_: InterruptedException) {
                            // ignore
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Upload failed for session $sessionId: ${e.message}")
                        anyFailed = true
                    }
                }

                // Stop pagination on any failure to avoid tight retry loop.
                if (anyFailed) break
            }
            
            callback(!anyFailed, totalUploaded)
        }
    }

    
    private fun doUpload(url: String, authToken: String?, sessionId: String, locations: List<LocationEntry>): Boolean {
        return doUploadInternal(url, authToken, sessionId, locations, allowRefresh = true)
    }

    private fun doUploadInternal(
        url: String,
        authToken: String?,
        sessionId: String,
        locations: List<LocationEntry>,
        allowRefresh: Boolean
    ): Boolean {
        var connection: HttpURLConnection? = null
        try {
            // Build payload matching POST /location/update DTO:
            // { points: [ { lat, lng, timestamp?, heading?, speed?, accuracy? } ] }
            // NOTE: backend expects speed in km/h.
                val json = JSONObject().apply {
                    put("points", JSONArray().apply {
                        for (loc in locations) {
                            put(JSONObject().apply {
                                put("lat", loc.lat)
                                put("lng", loc.lng)
                                put("timestamp", loc.timestamp)
                                loc.bearing?.let { put("heading", it) }
                                loc.speed?.let { put("speed", it * 3.6) }
                                loc.accuracy?.let { put("accuracy", it) }
                            })
                        }
                    })
                }
            
            connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            authToken?.let { connection.setRequestProperty("Authorization", it) }
            connection.doOutput = true
            connection.connectTimeout = 15000
            connection.readTimeout = 15000
            
            OutputStreamWriter(connection.outputStream).use { writer ->
                writer.write(json.toString())
                writer.flush()
            }
            
            val responseCode = connection.responseCode
            Log.i(TAG, "Upload response: $responseCode for ${locations.size} locations")

            if (responseCode == 401 && allowRefresh) {
                Log.w(TAG, "Upload unauthorized (401). Attempting refresh-token rotation...")
                val refreshed = refreshAccessToken()
                if (refreshed) {
                    val newAuth = getConfig(KEY_AUTH_TOKEN)
                    return doUploadInternal(url, newAuth, sessionId, locations, allowRefresh = false)
                }
            }

            return responseCode in 200..299
        } catch (e: Exception) {
            Log.e(TAG, "Upload error: ${e.message}")
            return false
        } finally {
            connection?.disconnect()
        }
    }

    private fun refreshAccessToken(): Boolean {
        val refreshToken = getConfig(KEY_REFRESH_TOKEN)
        val refreshUrl = getConfig(KEY_REFRESH_URL)

        if (refreshToken.isNullOrBlank() || refreshUrl.isNullOrBlank()) {
            Log.w(TAG, "Cannot refresh token: missing refreshToken/refreshUrl")
            return false
        }

        var connection: HttpURLConnection? = null
        return try {

            val payload = JSONObject().apply {
                put("refreshToken", refreshToken)
            }

            connection = URL(refreshUrl).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            connection.doOutput = true
            connection.connectTimeout = 15000
            connection.readTimeout = 15000

            OutputStreamWriter(connection.outputStream).use { writer ->
                writer.write(payload.toString())
                writer.flush()
            }

            val responseCode = connection.responseCode
            if (responseCode !in 200..299) {
                Log.w(TAG, "Refresh failed: HTTP $responseCode")
                return false
            }

            val responseBody = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(responseBody)
            val data = if (json.has("data") && json.get("data") is JSONObject) {
                json.getJSONObject("data")
            } else {
                json
            }

            val newAccessToken = data.optString("accessToken", "")
            val newRefreshToken = data.optString("refreshToken", "")

            if (newAccessToken.isBlank() || newRefreshToken.isBlank()) {
                Log.w(TAG, "Refresh response missing tokens")
                return false
            }

            // Store rotated tokens for subsequent uploads.
            setConfig(KEY_AUTH_TOKEN, "Bearer $newAccessToken")
            setConfig(KEY_REFRESH_TOKEN, newRefreshToken)

            Log.i(TAG, "✅ Token refreshed successfully")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Refresh error: ${e.message}")
            false
        } finally {
            connection?.disconnect()
        }
    }
    
    private fun trimBufferIfNeeded(db: SQLiteDatabase) {
        try {
            val cursor = db.rawQuery("SELECT COUNT(*) FROM $TABLE_LOCATIONS", null)
            val count = cursor.use {
                if (it.moveToFirst()) it.getInt(0) else 0
            }
            
            if (count > MAX_BUFFER_SIZE) {
                // Delete oldest entries (keep most recent MAX_BUFFER_SIZE)
                val deleteCount = count - MAX_BUFFER_SIZE
                db.execSQL("""
                    DELETE FROM $TABLE_LOCATIONS 
                    WHERE $COL_ID IN (
                        SELECT $COL_ID FROM $TABLE_LOCATIONS 
                        ORDER BY $COL_TIMESTAMP ASC 
                        LIMIT $deleteCount
                    )
                """)
                Log.i(TAG, "Trimmed $deleteCount old locations from buffer")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to trim buffer: ${e.message}")
        }
    }
    
    private fun android.database.Cursor.getDoubleOrNull(columnName: String): Double? {
        val index = getColumnIndex(columnName)
        return if (index >= 0 && !isNull(index)) getDouble(index) else null
    }

    private fun android.database.Cursor.getStringOrNull(columnName: String): String? {
        val index = getColumnIndex(columnName)
        return if (index >= 0 && !isNull(index)) getString(index) else null
    }
    
    fun close() {
        executor.shutdown()
        dbHelper.close()
    }
    
    data class LocationEntry(
        val id: Long,
        val pointId: String,
        val sessionId: String?,
        val lat: Double,
        val lng: Double,
        val timestamp: Long,
        val speed: Double?,
        val bearing: Double?,
        val accuracy: Double?,
        val altitude: Double?,
        val deviceId: String?,
        val source: String?,
        val isMock: Boolean,
        val batteryLevel: Double?,
        val motionState: String? = null
    )
    
    private inner class DatabaseHelper(context: Context) : 
        SQLiteOpenHelper(context, DB_NAME, null, DB_VERSION) {
        
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("""
                CREATE TABLE $TABLE_LOCATIONS (
                    $COL_ID INTEGER PRIMARY KEY AUTOINCREMENT,
                    $COL_POINT_ID TEXT NOT NULL,
                    $COL_SESSION_ID TEXT,
                    $COL_LAT REAL NOT NULL,
                    $COL_LNG REAL NOT NULL,
                    $COL_TIMESTAMP INTEGER NOT NULL,
                    $COL_SPEED REAL,
                    $COL_BEARING REAL,
                    $COL_ACCURACY REAL,
                    $COL_ALTITUDE REAL,
                    $COL_DEVICE_ID TEXT,
                    $COL_SOURCE TEXT,
                    $COL_IS_MOCK INTEGER DEFAULT 0,
                    $COL_BATTERY_LEVEL REAL,
                    $COL_MOTION_STATE TEXT,
                    $COL_STATUS INTEGER DEFAULT 0
                )
            """)
            
            // Indices for efficient querying
            db.execSQL("CREATE INDEX idx_status ON $TABLE_LOCATIONS ($COL_STATUS)")
            db.execSQL("CREATE INDEX idx_session ON $TABLE_LOCATIONS ($COL_SESSION_ID)")
            db.execSQL("CREATE UNIQUE INDEX idx_point_id ON $TABLE_LOCATIONS ($COL_POINT_ID)")
        }
        
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                // v1 -> v2: add point_id and motion_state columns
                try {
                    db.execSQL("ALTER TABLE $TABLE_LOCATIONS ADD COLUMN $COL_POINT_ID TEXT")
                    db.execSQL("ALTER TABLE $TABLE_LOCATIONS ADD COLUMN $COL_MOTION_STATE TEXT")
                    // Back-fill existing rows with generated UUIDs
                    val cursor = db.rawQuery("SELECT $COL_ID FROM $TABLE_LOCATIONS WHERE $COL_POINT_ID IS NULL", null)
                    cursor.use {
                        while (it.moveToNext()) {
                            val rowId = it.getLong(0)
                            db.execSQL(
                                "UPDATE $TABLE_LOCATIONS SET $COL_POINT_ID = ? WHERE $COL_ID = ?",
                                arrayOf(UUID.randomUUID().toString(), rowId)
                            )
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Migration v1->v2 issue (may be fresh install): ${e.message}")
                }
            }
        }
    }
}
