package com.davenicoll.snorelore

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build

/**
 * Wraps AlarmManager scheduling for the auto-start flow. Called from
 * the Flutter method channel; persists the next firing timestamp so
 * the UI can show "Will start at HH:MM".
 */
object AutoStartScheduler {
    private const val PREFS = "snorelore_auto_start"
    private const val KEY_SCHEDULED_AT = "scheduled_at_epoch_ms"
    private const val ALARM_REQUEST_CODE = 0xA1A2

    fun schedule(context: Context, fireAtEpochMs: Long): Boolean {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return false

        // Pre-S, we can always set exact. On S+ we need the user to have
        // either USE_EXACT_ALARM (auto-granted) or SCHEDULE_EXACT_ALARM.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            && !am.canScheduleExactAlarms()) {
            return false
        }

        val pi = pendingIntent(context)
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtEpochMs, pi)
        } catch (_: SecurityException) {
            return false
        }
        prefs(context).edit().putLong(KEY_SCHEDULED_AT, fireAtEpochMs).apply()
        return true
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        am?.cancel(pendingIntent(context))
        clearScheduled(context)
    }

    fun scheduledAt(context: Context): Long {
        return prefs(context).getLong(KEY_SCHEDULED_AT, 0L)
    }

    fun clearScheduled(context: Context) {
        prefs(context).edit().remove(KEY_SCHEDULED_AT).apply()
    }

    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return false
        return am.canScheduleExactAlarms()
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, AutoStartReceiver::class.java).apply {
            action = AutoStartReceiver.ACTION_FIRE
        }
        return PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun prefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }
}
