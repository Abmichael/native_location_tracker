package dev.nativelocation.tracker

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.EventChannel

class NativeLocationTrackerPlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel : MethodChannel
  private lateinit var eventChannel : EventChannel
  private lateinit var stateEventChannel : EventChannel
  private lateinit var context: Context
  private lateinit var prefs: SharedPreferences
  private var eventSink: EventChannel.EventSink? = null
  private var stateEventSink: EventChannel.EventSink? = null

  companion object {
    const val PREFS_NAME = "nlt_prefs"
    const val KEY_SESSION_ID = "session_id"
  }

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "dev.nativelocation.tracker/methods")
    channel.setMethodCallHandler(this)
    
    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "dev.nativelocation.tracker/events")
    eventChannel.setStreamHandler(this)

    // Native state observability channel (P0.4)
    stateEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "dev.nativelocation.tracker/state")
    stateEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stateEventSink = events
      }
      override fun onCancel(arguments: Any?) {
        stateEventSink = null
      }
    })
    
    context = flutterPluginBinding.applicationContext
    prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    LocationForegroundService.setPlugin(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "start" -> {
        val intent = Intent(context, LocationForegroundService::class.java)
        intent.action = LocationForegroundService.ACTION_START
        
        // Pass all config as extras
        val config = call.arguments as? Map<String, Any>
        config?.forEach { (k, v) -> 
          when (v) {
            is String -> intent.putExtra(k, v)
            is Int -> intent.putExtra(k, v)
            is Long -> intent.putExtra(k, v.toInt())
            is Double -> intent.putExtra(k, v)
            is Boolean -> intent.putExtra(k, v)
          }
        }
        
        // Save tracking session id
        val sessionId = config?.get("sessionId") as? String
        prefs.edit()
          .putString(KEY_SESSION_ID, sessionId)
          .apply()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(intent)
        } else {
          context.startService(intent)
        }
        result.success(true)
      }
      "stop" -> {
        val intent = Intent(context, LocationForegroundService::class.java)
        intent.action = LocationForegroundService.ACTION_STOP
        context.startService(intent)
        
        // Clear tracking state
        prefs.edit()
          .remove(KEY_SESSION_ID)
          .apply()
          
        result.success(true)
      }
      "updateParams" -> {
        val intent = Intent(context, LocationForegroundService::class.java)
        intent.action = LocationForegroundService.ACTION_UPDATE_PARAMS
        
        val config = call.arguments as? Map<String, Any>
        config?.forEach { (k, v) -> 
          when (v) {
            is String -> intent.putExtra(k, v)
            is Int -> intent.putExtra(k, v)
            is Long -> intent.putExtra(k, v.toInt())
            is Double -> intent.putExtra(k, v)
            is Boolean -> intent.putExtra(k, v)
          }
        }
        context.startService(intent)
        result.success(true)
      }

      "updateNotification" -> {
        val intent = Intent(context, LocationForegroundService::class.java)
        intent.action = LocationForegroundService.ACTION_UPDATE_NOTIFICATION

        val config = call.arguments as? Map<String, Any>
        config?.forEach { (k, v) ->
          when (v) {
            is String -> intent.putExtra(k, v)
            is Int -> intent.putExtra(k, v)
            is Long -> intent.putExtra(k, v.toInt())
            is Double -> intent.putExtra(k, v)
            is Boolean -> intent.putExtra(k, v)
          }
        }

        // If the service isn't running this is a harmless no-op.
        // Use startService() to avoid O+ startForegroundService() requirements.
        context.startService(intent)
        result.success(true)
      }
      "setUploadConfig" -> {
        // Configure native upload URL and auth token
        val config = call.arguments as? Map<String, Any>
        
        val uploadUrl = config?.get("uploadUrl") as? String
        val authToken = config?.get("authToken") as? String
        val refreshToken = config?.get("refreshToken") as? String
        val refreshUrl = config?.get("refreshUrl") as? String
        val apiBaseUrl = config?.get("apiBaseUrl") as? String
        
        android.util.Log.i("NativeLocationTrackerPlugin", "Setting upload config: url=$uploadUrl")
        
        // Save to main prefs (for LocationForegroundService to read on startup)
        prefs.edit()
          .putString("upload_url", uploadUrl)
          .putString("auth_token", authToken)
          .putString("refresh_token", refreshToken)
          .putString("refresh_url", refreshUrl)
          .putString("api_base_url", apiBaseUrl)
          .commit()  // Use commit() for synchronous write
        
        // Also save to NativeBuffer's prefs directly
        val bufferPrefs = context.getSharedPreferences("nlt_buffer_config", Context.MODE_PRIVATE)
        bufferPrefs.edit()
          .putString("upload_url", uploadUrl)
          .putString("auth_token", authToken)
          .putString("refresh_token", refreshToken)
          .putString("refresh_url", refreshUrl)
          .putString("api_base_url", apiBaseUrl)
          .commit()  // Use commit() for synchronous write
        
        android.util.Log.i("NativeLocationTrackerPlugin", "Upload config saved to both prefs")
        
        // If service is running, also send intent to update it
        if (LocationForegroundService.isServiceRunning) {
          val intent = Intent(context, LocationForegroundService::class.java)
          intent.action = LocationForegroundService.ACTION_SET_UPLOAD_CONFIG
          uploadUrl?.let { intent.putExtra("uploadUrl", it) }
          authToken?.let { intent.putExtra("authToken", it) }
          context.startService(intent)
        }
        
        result.success(true)
      }
      "isServiceRunning" -> {
        result.success(LocationForegroundService.isServiceRunning)
      }
      "getSessionId" -> {
        val sessionId = prefs.getString(KEY_SESSION_ID, null)
        result.success(sessionId)
      }
      "requestIgnoreBatteryOptimizations" -> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
          val packageName = context.packageName
          if (!pm.isIgnoringBatteryOptimizations(packageName)) {
            val intent = Intent()
            intent.action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            intent.data = Uri.parse("package:$packageName")
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            context.startActivity(intent)
            result.success(true)
          } else {
            result.success(false) // Already ignored
          }
        } else {
          result.success(false)
        }
      }
      "isIgnoringBatteryOptimizations" -> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
          result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
        } else {
          result.success(true)
        }
      }
      "getNativeState" -> {
        // P0.4: Return native tracking state so Dart UI can display status
        // without owning a DB.
        val sessionId = prefs.getString(KEY_SESSION_ID, null)
        val isTracking = LocationForegroundService.isServiceRunning
        val pendingCount = if (isTracking) {
          try { LocationForegroundService.getNativePendingCountStatic() } catch (_: Exception) { 0 }
        } else 0
        val lastUploadAt = prefs.getLong("last_upload_at", 0L)
        val lastError = prefs.getString("last_upload_error", null)

        result.success(mapOf(
          "isTracking" to isTracking,
          "sessionId" to sessionId,
          "pendingCount" to pendingCount,
          "lastUploadAt" to if (lastUploadAt > 0) lastUploadAt else null,
          "lastError" to lastError,
          "uploaderState" to if (isTracking) "active" else "idle"
        ))
      }

      // Return the latest native-stored upload/auth config.
      // This is critical for refresh-token rotation: native may rotate tokens
      // while Flutter is backgrounded/killed, so Dart must re-sync.
      "getUploadConfig" -> {
        try {
          val bufferPrefs = context.getSharedPreferences("nlt_buffer_config", Context.MODE_PRIVATE)
          val uploadUrl = bufferPrefs.getString("upload_url", null) ?: prefs.getString("upload_url", null)
          val authToken = bufferPrefs.getString("auth_token", null) ?: prefs.getString("auth_token", null)
          val refreshToken = bufferPrefs.getString("refresh_token", null) ?: prefs.getString("refresh_token", null)
          val apiBaseUrl = bufferPrefs.getString("api_base_url", null) ?: prefs.getString("api_base_url", null)

          result.success(mapOf(
            "uploadUrl" to uploadUrl,
            "authToken" to authToken,
            "refreshToken" to refreshToken,
            "apiBaseUrl" to apiBaseUrl
          ))
        } catch (e: Exception) {
          result.error("get_upload_config_failed", e.message, null)
        }
      }

      "clearUploadConfig" -> {
        try {
          // Clear both the plugin prefs and the native buffer prefs.
          prefs.edit()
            .remove("upload_url")
            .remove("auth_token")
            .remove("refresh_token")
            .remove("api_base_url")
            .commit()

          val bufferPrefs = context.getSharedPreferences("nlt_buffer_config", Context.MODE_PRIVATE)
          bufferPrefs.edit()
            .remove("upload_url")
            .remove("auth_token")
            .remove("refresh_token")
            .remove("api_base_url")
            .commit()

          result.success(true)
        } catch (e: Exception) {
          result.error("clear_upload_config_failed", e.message, null)
        }
      }

      // Persist updated tokens from Dart -> native.
      // Keeps native uploader in sync when Dart refreshes/rotates tokens.
      "setAuthTokens" -> {
        try {
          val config = call.arguments as? Map<String, Any>
          val accessTokenRaw = config?.get("accessToken") as? String
          val refreshToken = config?.get("refreshToken") as? String

          val authHeader = accessTokenRaw
            ?.trim()
            ?.let { if (it.startsWith("Bearer ")) it else "Bearer $it" }

          // Save to main prefs.
          val editor = prefs.edit()
          if (authHeader.isNullOrBlank()) editor.remove("auth_token") else editor.putString("auth_token", authHeader)
          if (refreshToken.isNullOrBlank()) editor.remove("refresh_token") else editor.putString("refresh_token", refreshToken)
          editor.commit()

          // Save to NativeBuffer prefs.
          val bufferPrefs = context.getSharedPreferences("nlt_buffer_config", Context.MODE_PRIVATE)
          val bufferEditor = bufferPrefs.edit()
          if (authHeader.isNullOrBlank()) bufferEditor.remove("auth_token") else bufferEditor.putString("auth_token", authHeader)
          if (refreshToken.isNullOrBlank()) bufferEditor.remove("refresh_token") else bufferEditor.putString("refresh_token", refreshToken)
          bufferEditor.commit()

          result.success(true)
        } catch (e: Exception) {
          result.error("set_auth_tokens_failed", e.message, null)
        }
      }

      // Debug/testing only: inject mock points into native buffer and flush.
      "debugInsertMockPoints" -> {
        try {
          if (!dev.nativelocation.tracker.BuildConfig.DEBUG) {
            result.error("debug_only", "debugInsertMockPoints is only available in debug builds", null)
            return
          }
          val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
          val count = (args["count"] as? Number)?.toInt() ?: 10
          val sessionId = args["sessionId"] as? String
          val baseLat = (args["lat"] as? Number)?.toDouble() ?: 9.0192
          val baseLng = (args["lng"] as? Number)?.toDouble() ?: 38.7525

          val buffer = NativeLocationBuffer(context)
          val deviceId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)

          val now = System.currentTimeMillis()
          for (i in 0 until count) {
            buffer.add(
              sessionId = sessionId,
              lat = baseLat + (i * 0.00005),
              lng = baseLng + (i * 0.00005),
              timestamp = now - ((count - i) * 1000L),
              speed = 12.0,
              bearing = 90.0,
              accuracy = 5.0,
              altitude = 0.0,
              deviceId = deviceId,
              source = "debug",
              isMock = true,
              batteryLevel = null,
              motionState = "in_vehicle",
            )
          }

          buffer.uploadPendingLocations { success, uploaded ->
            buffer.close()
            result.success(mapOf(
              "success" to success,
              "uploaded" to uploaded,
            ))
          }
        } catch (e: Exception) {
          result.error("debug_insert_failed", e.message, null)
        }
      }
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    stateEventChannel.setStreamHandler(null)
    LocationForegroundService.setPlugin(null)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  fun onLocationUpdate(locationData: Map<String, Any>) {
    android.os.Handler(android.os.Looper.getMainLooper()).post {
      eventSink?.success(locationData)
    }
  }

  /**
   * Emit native tracking state to the state EventChannel (P0.4).
   * Called by the service on significant state changes.
   */
  fun emitStateUpdate(state: Map<String, Any?>) {
    android.os.Handler(android.os.Looper.getMainLooper()).post {
      stateEventSink?.success(state)
    }
  }
}
