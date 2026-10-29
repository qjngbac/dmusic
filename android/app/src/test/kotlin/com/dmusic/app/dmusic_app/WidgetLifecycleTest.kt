package com.dmusic.app.dmusic_app

import android.app.Activity
import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AnimationDrawable
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.RemoteViews
import android.widget.TextView
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter
import org.xmlpull.v1.XmlPullParser
import java.lang.reflect.Proxy
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class WidgetLifecycleTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val prefs get() = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
    private val alarms get() = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    private val partialActionCounts = mutableListOf<Int>()
    private var previousWindowVisibility: String? = null

    @Before
    fun setUp() {
        previousWindowVisibility = System.getProperty("robolectric.areWindowsMarkedVisible")
        System.setProperty("robolectric.areWindowsMarkedVisible", "true")
        ReflectionHelpers.setStaticField(DMusicAppWidgetProvider::class.java, "firstPlaybackIndicator", true)
        ReflectionHelpers.setStaticField(DMusicAppWidgetProvider::class.java, "lastIndicatorRenewalElapsed", -700L)
        DMusicWidgetPlaybackState.endSession(context)
        prefs.edit().clear().commit()
        context.registerReceiver(DMusicWidgetPlaybackCheckReceiver(),
            IntentFilter("com.dmusic.app.CHECK_WIDGET_PLAYBACK"))
        installPartialUpdateService()
    }

    @After
    fun tearDown() {
        DMusicWidgetPlaybackState.endSession(context)
        val previous = previousWindowVisibility
        if (previous == null) {
            System.clearProperty("robolectric.areWindowsMarkedVisible")
        } else {
            System.setProperty("robolectric.areWindowsMarkedVisible", previous)
        }
    }

    @Test
    fun oldEngineExitDoesNotClearNewSessionPlayback() {
        val first = DMusicWidgetPlaybackState.openSession()
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)

        assertFalse(DMusicWidgetPlaybackState.endSession(context, first))

        assertTrue(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false))
        assertTrue(DMusicWidgetPlaybackState.isPlaying(prefs))
    }

    @Test
    fun endingPlaybackSessionPreservesSongMetadata() {
        val session = DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context,
            title = "芬芳一生", artist = "毛不易", isPlaying = true)

        assertTrue(DMusicWidgetPlaybackState.endSession(context, session))

        assertFalse(DMusicWidgetPlaybackState.isPlaying(prefs))
        assertEquals("芬芳一生", prefs.getString(DMusicAppWidgetProvider.KEY_TITLE, null))
        assertEquals("毛不易", prefs.getString(DMusicAppWidgetProvider.KEY_ARTIST, null))
    }

    @Test
    fun playbackWithoutWidgetsDoesNotScheduleWakeupChecks() {
        val generation = DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        DMusicWidgetPlaybackState.heartbeat(context, generation)

        assertTrue(shadowOf(alarms).scheduledAlarms.isEmpty())
    }

    @Test
    fun heartbeatExtendsLeaseWithoutWritingHeartbeatToDisk() {
        val generation = DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        val before = prefs.all
        ShadowSystemClock.advanceBy(Duration.ofSeconds(20))
        DMusicWidgetPlaybackState.heartbeat(context, generation)

        assertEquals(before, prefs.all)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(20))
        assertTrue(DMusicWidgetPlaybackState.isPlaying(prefs))
        ShadowSystemClock.advanceBy(Duration.ofSeconds(11))
        DMusicWidgetPlaybackState.checkPlayback(context)
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
    }

    @Test
    fun overdueCheckDoesNotResetRenewedPlayback() {
        val generation = DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(25))
        DMusicWidgetPlaybackState.heartbeat(context, generation)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(10))
        DMusicWidgetPlaybackState.checkPlayback(context)

        assertTrue(DMusicWidgetPlaybackState.isPlaying(prefs))
    }

    @Test
    fun oldProcessSnapshotIsNotRenderedAsLivePlayback() {
        DMusicWidgetPlaybackState.openSession()
        prefs.edit().putBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true)
            .putString("playback_process_owner", "a-terminated-process")
            .putLong("playback_generation", DMusicWidgetPlaybackState.generation)
            .putLong("playback_heartbeat_elapsed", SystemClock.elapsedRealtime()).commit()

        DMusicWidgetPlaybackState.checkPlayback(context)

        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
    }

    @Test
    fun scheduledCheckRepaintsExpiredWidgetWithoutOpeningActivity() {
        val widgets = shadowOf(AppWidgetManager.getInstance(context))
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        assertPlaybackIcon(widgetId, playing = true)
        val pendingCheck = requireNotNull(shadowOf(alarms).scheduledAlarms.single().operation)
        assertTrue(shadowOf(RuntimeEnvironment.getApplication()).hasReceiverForIntent(shadowOf(pendingCheck).savedIntent))

        ShadowSystemClock.advanceBy(Duration.ofSeconds(31))
        pendingCheck.send()
        shadowOf(Looper.getMainLooper()).idle()

        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertPlaybackIcon(widgetId, playing = false)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity)
    }

    @Test
    fun optionsChangePersistsPausedStateForADeadProcess() {
        val manager = AppWidgetManager.getInstance(context)
        val widgets = shadowOf(manager)
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        DMusicWidgetPlaybackState.openSession()
        prefs.edit().putBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true)
            .putString("playback_process_owner", "a-terminated-process")
            .putLong("playback_generation", DMusicWidgetPlaybackState.generation)
            .putLong("playback_heartbeat_elapsed", SystemClock.elapsedRealtime()).commit()

        DMusicAppWidgetProvider().onAppWidgetOptionsChanged(context, manager, widgetId, Bundle())

        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertPlaybackIcon(widgetId, playing = false)
        widgets.reconstructWidgetViewAsIfPhoneWasRotated(widgetId)
        assertPlaybackIcon(widgetId, playing = false)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity)
    }

    @Test
    fun optionsChangePreservesLivePlayback() {
        val manager = AppWidgetManager.getInstance(context)
        val widgets = shadowOf(manager)
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, title = "Live song", isPlaying = true)
        val snapshot = prefs.all

        DMusicAppWidgetProvider().onAppWidgetOptionsChanged(context, manager, widgetId, Bundle())

        assertPlaybackIcon(widgetId, playing = true)
        assertEquals(snapshot, prefs.all)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedActivity)
    }

    @Test
    fun hostExpiryFramesStopAtPlayAfterTwoSeconds() {
        val frames = mutableListOf<Int>()
        val durations = mutableListOf<Int>()
        val oneShot = mutableListOf<Boolean>()
        context.resources.getXml(R.drawable.widget_playback_expiry).use { xml ->
            while (xml.next() != XmlPullParser.END_DOCUMENT) {
                if (xml.eventType == XmlPullParser.START_TAG && xml.name == "animation-list") {
                    oneShot.add(xml.getAttributeBooleanValue(
                        "http://schemas.android.com/apk/res/android", "oneshot", false))
                }
                if (xml.eventType == XmlPullParser.START_TAG && xml.name == "item") {
                    frames.add(xml.getAttributeResourceValue(
                        "http://schemas.android.com/apk/res/android", "drawable", 0))
                    durations.add(xml.getAttributeIntValue(
                        "http://schemas.android.com/apk/res/android", "duration", 0))
                }
            }
        }
        assertEquals(listOf(R.drawable.ic_widget_pause, R.drawable.ic_widget_play), frames)
        assertEquals(listOf(2_000, 1), durations)
        assertEquals(listOf(true), oneShot)
    }

    @Test
    fun visibleHostReturnsToPlayWithoutAnyAppCallbackWithinTwoSeconds() {
        val widgets = shadowOf(AppWidgetManager.getInstance(context))
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        val host = Robolectric.buildActivity(Activity::class.java).setup().visible()
        try {
            val view = widgets.getViewFor(widgetId)
            host.get().setContentView(view)
            drawHost(view)
            assertPlaybackIcon(widgetId, playing = true)
            alarms.cancel(requireNotNull(shadowOf(alarms).scheduledAlarms.single().operation))
            val snapshot = prefs.all

            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(2_001))
            drawHost(view)

            assertEquals(snapshot, prefs.all)
            assertTrue(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false))
            assertPlaybackIcon(widgetId, playing = false)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(40))
            drawHost(view)
            assertPlaybackIcon(widgetId, playing = false)
        } finally {
            host.pause().stop().destroy()
        }
    }

    @Test
    fun renewalsKeepItPlayingWithoutRewritingMetadataAndStopAfterDeath() {
        val widgets = shadowOf(AppWidgetManager.getInstance(context))
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        val generation = DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, title = "Unchanged song", isPlaying = true)
        val host = Robolectric.buildActivity(Activity::class.java).setup().visible()
        try {
            val view = widgets.getViewFor(widgetId)
            host.get().setContentView(view)
            drawHost(view)
            val snapshot = prefs.all
            var previousVisibility = view.findViewById<View>(R.id.widget_playback_indicator_a).visibility
            repeat(12) {
                shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1_000))
                DMusicWidgetPlaybackState.heartbeat(context, generation)
                DMusicAppWidgetProvider.renewPlaybackIndicator(context)
                assertSame(view, widgets.getViewFor(widgetId))
                val visibility = view.findViewById<View>(R.id.widget_playback_indicator_a).visibility
                assertNotEquals(previousVisibility, visibility)
                previousVisibility = visibility
                drawHost(view)
                assertPlaybackIcon(widgetId, playing = true)
                assertEquals("Unchanged song",
                    view.findViewById<TextView>(R.id.widget_song_name).text.toString())
                assertEquals(snapshot, prefs.all)
            }
            assertEquals(12, partialActionCounts.size)
            assertEquals(1, partialActionCounts.distinct().size)
            assertEquals(partialActionCounts.first(), partialActionCounts.last())
            alarms.cancel(requireNotNull(shadowOf(alarms).scheduledAlarms.single().operation))
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(2_001))
            drawHost(view)
            assertPlaybackIcon(widgetId, playing = false)
            DMusicWidgetPlaybackState.endSession(context, generation)
            assertPlaybackIcon(widgetId, playing = false)
            DMusicWidgetPlaybackState.heartbeat(context, generation)
            assertPlaybackIcon(widgetId, playing = false)
        } finally {
            host.pause().stop().destroy()
        }
    }

    @Test
    fun playbackOverlayDoesNotInterceptButtonTouches() {
        val widgets = shadowOf(AppWidgetManager.getInstance(context))
        val widgetId = widgets.createWidget(DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card)
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        val host = Robolectric.buildActivity(Activity::class.java).setup().visible()
        try {
            val view = widgets.getViewFor(widgetId)
            host.get().setContentView(view)
            drawHost(view)
            val button = view.findViewById<View>(R.id.widget_btn_play_pause)
            assertTrue(button.hasOnClickListeners())
            var clicks = 0
            button.setOnClickListener { clicks++ }
            val parent = button.parent as ViewGroup
            val now = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(now, now, action, parent.width / 2f, parent.height / 2f, 0)
                parent.dispatchTouchEvent(event)
                event.recycle()
            }
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(1, clicks)
        } finally {
            host.pause().stop().destroy()
        }
    }

    @Test
    fun removingLastWidgetCancelsPendingChecks() {
        shadowOf(AppWidgetManager.getInstance(context)).createWidget(
            DMusicAppWidgetProvider::class.java, R.layout.widget_vinyl_card,
        )
        DMusicWidgetPlaybackState.openSession()
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        assertFalse(shadowOf(alarms).scheduledAlarms.isEmpty())

        DMusicAppWidgetProvider().onDisabled(context)

        assertTrue(shadowOf(alarms).scheduledAlarms.isEmpty())
    }

    private fun installPartialUpdateService() {
        val manager = AppWidgetManager.getInstance(context)
        val widgets = shadowOf(manager)
        val serviceType = Class.forName("com.android.internal.appwidget.IAppWidgetService")
        val service = Proxy.newProxyInstance(serviceType.classLoader, arrayOf(serviceType)) { _, method, args ->
            if (method.name == "partiallyUpdateAppWidgetIds") {
                val infos = ReflectionHelpers.getField<Map<Int, Any>>(widgets, "widgetInfos")
                for (id in args[1] as IntArray) {
                    val cached = ReflectionHelpers.getField<RemoteViews>(infos.getValue(id), "lastRemoteViews")
                    ReflectionHelpers.callInstanceMethod<Any?>(cached, "mergeRemoteViews",
                        ClassParameter.from(RemoteViews::class.java, args[2] as RemoteViews))
                    partialActionCounts.add(ReflectionHelpers.getField<List<*>>(cached, "mActions").size)
                    cached.reapply(context, widgets.getViewFor(id))
                }
            }
            null
        }
        ReflectionHelpers.setField(manager, "mService", service)
    }

    private fun assertPlaybackIcon(widgetId: Int, playing: Boolean) {
        val view = shadowOf(AppWidgetManager.getInstance(context)).getViewFor(widgetId)
        val indicators = listOf(R.id.widget_playback_indicator_a, R.id.widget_playback_indicator_b)
            .map { view.findViewById<ProgressBar>(it) }
            .filter { it.visibility == View.VISIBLE }
        if (indicators.isEmpty()) {
            assertFalse(playing)
            val icon = view.findViewById<ImageView>(R.id.widget_btn_play_pause)
            assertEquals(R.drawable.ic_widget_play, shadowOf(icon.drawable).createdFromResId)
        } else {
            val animation = indicators.single().indeterminateDrawable as AnimationDrawable
            assertTrue(animation.isOneShot)
            assertEquals(2, animation.numberOfFrames)
            assertSame(animation.getFrame(if (playing) 0 else 1), animation.current)
        }
    }

    private fun drawHost(view: View) {
        assertEquals(View.VISIBLE, view.windowVisibility)
        view.measure(
            View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(200, View.MeasureSpec.EXACTLY),
        )
        view.layout(0, 0, 400, 200)
        val canvas = Canvas(Bitmap.createBitmap(400, 200, Bitmap.Config.ARGB_8888))
        view.draw(canvas)
        for (id in listOf(R.id.widget_playback_indicator_a, R.id.widget_playback_indicator_b)) {
            val indicator = view.findViewById<ProgressBar>(id)
            if (indicator.visibility == View.VISIBLE) indicator.draw(canvas)
        }
    }
}
