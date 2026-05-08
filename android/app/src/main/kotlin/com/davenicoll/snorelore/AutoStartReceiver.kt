package com.davenicoll.snorelore

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fired by AlarmManager at the user-configured auto-schedule start time.
 *
 * Job: bring SnoreLore back to the foreground so the Dart side can
 * begin recording. We intentionally do NOT do any recording from native
 * code — the recorder, classifier, and storage all live in Dart, so
 * the only thing the receiver does is launch MainActivity with a flag
 * that tells the Flutter side to auto-start.
 *
 * Activity launches from receivers are normally restricted in the
 * background (Android 10+), but `setExactAndAllowWhileIdle` paired
 * with USE_EXACT_ALARM (or user-granted SCHEDULE_EXACT_ALARM) puts us
 * in the alarm-clock category, which is allowed to launch UI.
 */
class AutoStartReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_FIRE = "com.davenicoll.snorelore.AUTO_START_FIRE"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        // Persist the flag so Dart sees it on cold launch even if the
        // activity launch below is somehow delayed by the system.
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean("flutter.snorelore_pending_auto_start", true)
            .putLong(
                "flutter.snorelore_pending_auto_start_at",
                System.currentTimeMillis()
            )
            .apply()

        // Clear the scheduled-at marker so Dart knows nothing is pending.
        AutoStartScheduler.clearScheduled(context)

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra("snorelore_auto_start", true)
            }
        if (launch != null) {
            try {
                context.startActivity(launch)
            } catch (_: Throwable) {
                // Background launch denied — Dart will still pick up the
                // pending flag the next time the user opens the app.
            }
        }
    }
}
