package com.dmusic.app.dmusic_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.SystemClock
import android.util.Log
import java.util.UUID

/** Playback reports and widget writes have one owner: the main application process. */
object DMusicWidgetPlaybackState {
    private const val KEY_OWNER = "playback_process_owner"
    private const val KEY_GENERATION = "playback_generation"
    private const val KEY_HEARTBEAT = "playback_heartbeat_elapsed"
    private const val CHECK_ACTION = "com.dmusic.app.CHECK_WIDGET_PLAYBACK"
    private const val CHECK_REQUEST = 2207
    private val lease = WidgetPlaybackLease(UUID.randomUUID().toString())
    private var heartbeatElapsed = -1L

    val generation: Long get() = lease.generation
    val closed: Boolean get() = lease.closed

    fun openSession(): Long {
        heartbeatElapsed = -1L
        return lease.attach()
    }

    fun accepts(generation: Long): Boolean = lease.accepts(generation)

    fun record(editor: SharedPreferences.Editor, isPlaying: Boolean) {
        heartbeatElapsed = if (isPlaying && !lease.closed) SystemClock.elapsedRealtime() else -1L
        editor.putBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, isPlaying && !lease.closed)
            .putString(KEY_OWNER, lease.processToken)
            .putLong(KEY_GENERATION, lease.generation)
            .putLong(KEY_HEARTBEAT, heartbeatElapsed)
    }

    fun isPlaying(prefs: SharedPreferences): Boolean =
        prefs.getLong(KEY_GENERATION, -1L) == lease.generation && lease.isFreshPlaying(
            prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false),
            prefs.getString(KEY_OWNER, null),
            maxOf(heartbeatElapsed, prefs.getLong(KEY_HEARTBEAT, -1L)),
            SystemClock.elapsedRealtime(),
        )

    fun afterPublish(context: Context, prefs: SharedPreferences) {
        if (isPlaying(prefs)) scheduleCheck(context) else cancelCheck(context)
    }

    fun widgetRemoved(context: Context) = cancelCheck(context)

    fun heartbeat(context: Context, generation: Long) {
        if (!lease.accepts(generation)) return
        val prefs = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
        val wasPlaying = isPlaying(prefs)
        heartbeatElapsed = SystemClock.elapsedRealtime()
        if (!wasPlaying) {
            // Only the live MediaController renews playback, including after a
            // delayed system check. UI attachment is not evidence of playback.
            DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        } else {
            scheduleCheck(context)
        }
    }

    fun endSession(context: Context, expectedGeneration: Long? = null): Boolean {
        if (!lease.close(expectedGeneration)) return false
        heartbeatElapsed = -1L
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = false)
        return true
    }

    fun checkPlayback(context: Context) {
        val prefs = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
        if (isPlaying(prefs)) {
            scheduleCheck(context)
        } else if (prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false)) {
            // A process restart changes owner token even if no exit callback ran.
            // Only repair the display: do not interrupt potentially live audio.
            DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = false)
        } else {
            cancelCheck(context)
        }
    }

    private fun checkIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, CHECK_REQUEST,
        Intent(context, DMusicWidgetPlaybackCheckReceiver::class.java).setAction(CHECK_ACTION),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun scheduleCheck(context: Context) {
        try {
            val widgetManager = AppWidgetManager.getInstance(context)
            if (widgetManager.getAppWidgetIds(ComponentName(context, DMusicAppWidgetProvider::class.java)).isEmpty()) {
                cancelCheck(context)
                return
            }
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val now = SystemClock.elapsedRealtime()
            alarms.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                maxOf(heartbeatElapsed + lease.timeoutMs + 1L, now + 1_000L),
                checkIntent(context),
            )
        } catch (error: Exception) {
            Log.w("DMusicWidget", "Widget expiry check could not be scheduled", error)
        }
    }

    private fun cancelCheck(context: Context) {
        try {
            (context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager)?.cancel(checkIntent(context))
        } catch (error: Exception) {
            Log.w("DMusicWidget", "Widget expiry check could not be canceled", error)
        }
    }
}

class DMusicWidgetPlaybackCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.dmusic.app.CHECK_WIDGET_PLAYBACK") {
            DMusicWidgetPlaybackState.checkPlayback(context.applicationContext)
        }
    }
}
