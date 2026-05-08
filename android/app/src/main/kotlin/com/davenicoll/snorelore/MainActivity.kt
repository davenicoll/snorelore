package com.davenicoll.snorelore

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "snorelore/fgs"

    override fun onNewIntent(newIntent: Intent) {
        super.onNewIntent(newIntent)
        // Keep the activity's `intent` in sync so consumePendingAutoStart
        // (and anything else reading `getIntent()`) sees the alarm's
        // extras even when we're launched on top of an existing
        // singleTop instance.
        intent = newIntent
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, RecordingService::class.java)
                        intent.action = RecordingService.ACTION_START
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "stop" -> {
                        val intent = Intent(this, RecordingService::class.java)
                        intent.action = RecordingService.ACTION_STOP
                        startService(intent)
                        result.success(null)
                    }
                    "update" -> {
                        val intent = Intent(this, RecordingService::class.java)
                        intent.action = RecordingService.ACTION_UPDATE
                        intent.putExtra(
                            RecordingService.EXTRA_TITLE,
                            call.argument<String>("title")
                        )
                        intent.putExtra(
                            RecordingService.EXTRA_CONTENT,
                            call.argument<String>("content")
                        )
                        startService(intent)
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    "scheduleAutoStart" -> {
                        val at = (call.argument<Number>("epochMs"))?.toLong()
                        if (at == null) {
                            result.error("ARG", "epochMs required", null)
                        } else {
                            val ok = AutoStartScheduler.schedule(this, at)
                            result.success(ok)
                        }
                    }
                    "cancelAutoStart" -> {
                        AutoStartScheduler.cancel(this)
                        result.success(null)
                    }
                    "autoStartScheduledAt" -> {
                        val at = AutoStartScheduler.scheduledAt(this)
                        result.success(if (at == 0L) null else at)
                    }
                    "canScheduleExact" -> {
                        result.success(AutoStartScheduler.canScheduleExact(this))
                    }
                    "openExactAlarmSettings" -> {
                        openExactAlarmSettings()
                        result.success(null)
                    }
                    "consumePendingAutoStart" -> {
                        result.success(consumePendingAutoStart())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun consumePendingAutoStart(): Boolean {
        val prefs = getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)
        val pending = prefs.getBoolean(
            "flutter.snorelore_pending_auto_start", false)
        // Also check the launch intent — if the activity was created
        // by the alarm, consume that too.
        val fromIntent = intent?.getBooleanExtra(
            "snorelore_auto_start", false) ?: false
        if (pending || fromIntent) {
            prefs.edit()
                .remove("flutter.snorelore_pending_auto_start")
                .remove("flutter.snorelore_pending_auto_start_at")
                .apply()
            return true
        }
        return false
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
        intent.data = Uri.parse("package:$packageName")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (_: Throwable) {
            // Some OEMs don't ship the screen — fall back to app info.
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            fallback.data = Uri.parse("package:$packageName")
            fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try { startActivity(fallback) } catch (_: Throwable) {}
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (isIgnoringBatteryOptimizations()) return
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
        intent.data = Uri.parse("package:$packageName")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }
}
