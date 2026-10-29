package com.dmusic.app.dmusic_app

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
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
import java.nio.ByteBuffer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class DMusicEngineBridgeTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val prefs get() = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
    private val bridges = mutableListOf<DMusicEngineBridge>()

    @Before
    fun setUp() {
        DMusicWidgetPlaybackState.endSession(context)
        prefs.edit().clear().commit()
    }

    @After
    fun tearDown() {
        bridges.asReversed().forEach { it.onEngineDetached() }
        shadowOf(Looper.getMainLooper()).idle()
        DMusicWidgetPlaybackState.endSession(context)
    }

    private fun bridge(messenger: FakeMessenger = FakeMessenger()): DMusicEngineBridge =
        DMusicEngineBridge(context, messenger).also { bridges.add(it) }

    private fun generation(messenger: FakeMessenger): Long {
        val session = messenger.call("connectPlaybackSession") as Map<*, *>
        return (session["generation"] as Number).toLong()
    }

    @Test
    fun activityDetachAndReattachKeepTheOpenEngineEpoch() {
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        val generation = generation(messenger)
        val activity = Robolectric.buildActivity(Activity::class.java).create().get()

        bridge.onActivityAttached(activity)
        bridge.onActivityDetached()
        bridge.onActivityAttached(activity)

        assertEquals(generation, DMusicWidgetPlaybackState.generation)
        assertTrue(DMusicWidgetPlaybackState.accepts(generation))
        assertTrue(messenger.outgoing.isEmpty())
    }

    @Test
    fun finishingDetachClosesTheEpochBeforeDartRuns() {
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        val generation = generation(messenger)
        val activity = Robolectric.buildActivity(Activity::class.java).create().get()
        bridge.onActivityAttached(activity)
        DMusicAppWidgetProvider.updateAllWidgets(context, title = "Saved song", isPlaying = true)
        activity.finish()

        bridge.onActivityDetached()

        assertTrue(DMusicWidgetPlaybackState.closed)
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertEquals("Saved song", prefs.getString(DMusicAppWidgetProvider.KEY_TITLE, null))
        assertEquals("onTaskDismissed", messenger.outgoing.single().method)
        assertEquals(generation, (messenger.outgoing.single().arguments as Map<*, *>)["generation"])
    }

    @Test
    fun finishingActivityPublishesBeforeDetachAndCannotBeRearmedByOldUpdates() {
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        val generation = generation(messenger)
        val activity = Robolectric.buildActivity(Activity::class.java).create().get()
        bridge.onActivityAttached(activity)
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        activity.finish()

        DMusicEngineBridge.onActivityFinishing(activity)

        assertTrue(DMusicWidgetPlaybackState.closed)
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertEquals("onTaskDismissed", messenger.outgoing.single().method)
        bridge.onActivityDetached()
        DMusicEngineBridge.onActivityFinishing(activity)
        assertEquals(1, messenger.outgoing.size)
        assertEquals(false, messenger.call("updateWidget", mapOf("generation" to generation, "isPlaying" to true)))
        assertEquals(false, messenger.call("mediaSessionActive", mapOf("generation" to generation, "active" to true)))
        DMusicWidgetPlaybackState.heartbeat(context, generation)
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
    }

    @Test
    fun nonFinishingOrReplacedActivityCannotCloseCurrentPlayback() {
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        val generation = generation(messenger)
        val oldActivity = Robolectric.buildActivity(Activity::class.java).create().get()
        bridge.onActivityAttached(oldActivity)
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)

        DMusicEngineBridge.onActivityFinishing(oldActivity)
        assertTrue(DMusicWidgetPlaybackState.accepts(generation))
        val currentActivity = Robolectric.buildActivity(Activity::class.java).create().get()
        bridge.onActivityAttached(currentActivity)
        oldActivity.finish()
        DMusicEngineBridge.onActivityFinishing(oldActivity)

        assertTrue(DMusicWidgetPlaybackState.accepts(generation))
        assertTrue(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false))
        assertTrue(messenger.outgoing.isEmpty())
    }

    @Test
    fun finishingActivityClosesWidgetEvenWithoutADartConnection() {
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        val activity = Robolectric.buildActivity(Activity::class.java).create().get()
        bridge.onActivityAttached(activity)
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        activity.finish()

        DMusicEngineBridge.onActivityFinishing(activity)

        assertTrue(DMusicWidgetPlaybackState.closed)
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertTrue(messenger.outgoing.isEmpty())
        val session = messenger.call("connectPlaybackSession") as Map<*, *>
        assertEquals(true, session["closed"])
        assertEquals(DMusicWidgetPlaybackState.generation, session["generation"])
    }

    @Test
    fun dartMetadataCannotPublishPlayingState() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val generation = generation(messenger)

        assertEquals(true, messenger.call("updateWidget", mapOf(
            "generation" to generation,
            "title" to "Restored song",
            "isPlaying" to true,
        )))

        assertEquals("Restored song", prefs.getString(DMusicAppWidgetProvider.KEY_TITLE, null))
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, false))
        assertFalse(DMusicWidgetPlaybackState.isPlaying(prefs))
    }

    @Test
    fun oldExitStopAndIdleCannotCloseOrDisconnectAReopenedEpoch() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val oldGeneration = generation(messenger)
        assertEquals(true, messenger.call("beginPlaybackExit", mapOf("generation" to oldGeneration)))
        val session = messenger.call("openPlaybackSession") as Map<*, *>
        val newGeneration = (session["generation"] as Number).toLong()

        assertTrue(newGeneration > oldGeneration)
        assertEquals(false, messenger.call("beginPlaybackExit", mapOf("generation" to oldGeneration)))
        assertEquals(false, messenger.call("stopPlaybackService", mapOf("generation" to oldGeneration)))
        assertEquals(false, messenger.call("mediaSessionActive", mapOf(
            "generation" to oldGeneration, "active" to false,
        )))
        assertTrue(DMusicWidgetPlaybackState.accepts(newGeneration))
    }

    @Test
    fun engineDetachClosesOnlyItsOwnEpoch() {
        val firstMessenger = FakeMessenger()
        val first = bridge(firstMessenger)
        val oldGeneration = generation(firstMessenger)
        val secondMessenger = FakeMessenger()
        val second = bridge(secondMessenger)
        val newGeneration = generation(secondMessenger)

        first.onEngineDetached()

        assertTrue(newGeneration > oldGeneration)
        assertTrue(DMusicWidgetPlaybackState.accepts(newGeneration))
        second.onEngineDetached()
        assertTrue(DMusicWidgetPlaybackState.closed)
        assertNull(secondMessenger.handler)
    }

    @Test
    fun explicitPlayReopensBeforeDeliveringTheControl() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val oldGeneration = generation(messenger)
        messenger.call("checkPendingAction")
        shadowOf(Looper.getMainLooper()).idle()
        messenger.call("beginPlaybackExit", mapOf("generation" to oldGeneration))
        messenger.outgoing.clear()

        assertTrue(DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY))

        assertEquals(listOf("onPlaybackSessionOpened", "onWidgetAction"), messenger.outgoing.map { it.method })
        val opened = messenger.outgoing[0].arguments as Map<*, *>
        val action = messenger.outgoing[1].arguments as Map<*, *>
        assertTrue((opened["generation"] as Number).toLong() > oldGeneration)
        assertEquals(opened["generation"], action["generation"])
        assertEquals(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY, action["action"])
    }

    @Test
    fun closedSessionPauseDoesNotReopenOrDeliver() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val generation = generation(messenger)
        messenger.call("checkPendingAction")
        shadowOf(Looper.getMainLooper()).idle()
        messenger.call("beginPlaybackExit", mapOf("generation" to generation))
        messenger.outgoing.clear()

        assertTrue(DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE))

        assertTrue(DMusicWidgetPlaybackState.closed)
        assertEquals(generation, DMusicWidgetPlaybackState.generation)
        assertTrue(messenger.outgoing.isEmpty())
    }

    @Test
    fun coldLaunchActionIsDeliveredOnceAfterRestoration() {
        assertFalse(DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT))
        val messenger = FakeMessenger()
        val bridge = bridge(messenger)
        bridge.onActivityAttached(Robolectric.buildActivity(Activity::class.java).create().get())
        generation(messenger)

        assertTrue(messenger.outgoing.isEmpty())
        assertEquals(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT, messenger.call("checkPendingAction"))
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(messenger.outgoing.isEmpty())
        assertNull(messenger.call("checkPendingAction"))
    }

    @Test
    fun connectDoesNotDeliverControlsBeforeRestorationGate() {
        val messenger = FakeMessenger()
        bridge(messenger)
        generation(messenger)

        assertTrue(DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT))
        assertTrue(messenger.outgoing.isEmpty())
        assertEquals(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT, messenger.call("checkPendingAction"))
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(messenger.outgoing.isEmpty())
    }

    @Test
    fun aQueuedControlFromTheClosedEpochCannotReachTheReopenedOne() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val oldGeneration = generation(messenger)
        DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT)
        messenger.call("beginPlaybackExit", mapOf("generation" to oldGeneration))

        DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY)

        assertEquals(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY, messenger.call("checkPendingAction"))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf("onPlaybackSessionOpened"), messenger.outgoing.map { it.method })
        assertNull(messenger.call("checkPendingAction"))
    }

    @Test
    fun restorationFinishingAfterExitStillAllowsTheNextExplicitControl() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val oldGeneration = generation(messenger)
        DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT)
        messenger.call("beginPlaybackExit", mapOf("generation" to oldGeneration))

        assertNull(messenger.call("checkPendingAction"))
        assertTrue(DMusicEngineBridge.dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY))

        assertEquals(listOf("onPlaybackSessionOpened", "onWidgetAction"), messenger.outgoing.map { it.method })
        assertEquals(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY,
            (messenger.outgoing.last().arguments as Map<*, *>)["action"])
        assertNull(messenger.call("checkPendingAction"))
    }

    @Test
    fun ordinaryStopKeepsTheEpochReusableByTheAttachedUi() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val generation = generation(messenger)
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)

        assertEquals(true, messenger.call("stopPlaybackService", mapOf("generation" to generation)))

        assertTrue(DMusicWidgetPlaybackState.accepts(generation))
        assertFalse(prefs.getBoolean(DMusicAppWidgetProvider.KEY_IS_PLAYING, true))
        assertEquals(true, messenger.call("updateWidget", mapOf(
            "generation" to generation, "title" to "Next UI selection",
        )))
        assertEquals("Next UI selection", prefs.getString(DMusicAppWidgetProvider.KEY_TITLE, null))
    }

    @Test
    fun stopAfterAnExplicitExitKeepsTheEpochClosed() {
        val messenger = FakeMessenger()
        bridge(messenger)
        val generation = generation(messenger)
        messenger.call("beginPlaybackExit", mapOf("generation" to generation))

        assertEquals(true, messenger.call("stopPlaybackService", mapOf("generation" to generation)))

        assertTrue(DMusicWidgetPlaybackState.closed)
    }

    private class FakeMessenger : BinaryMessenger {
        private val codec = StandardMethodCodec.INSTANCE
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        val outgoing = mutableListOf<MethodCall>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            if (message != null) outgoing.add(codec.decodeMethodCall(readable(message)))
            callback?.reply(null)
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }

        fun call(method: String, arguments: Any? = null): Any? {
            var replied = false
            var value: Any? = null
            requireNotNull(handler).onMessage(readable(codec.encodeMethodCall(MethodCall(method, arguments)))) { reply ->
                replied = true
                value = reply?.let { codec.decodeEnvelope(readable(it)) }
            }
            check(replied) { "Native method $method did not reply" }
            return value
        }

        private fun readable(buffer: ByteBuffer): ByteBuffer = buffer.duplicate().apply { flip() }
    }
}
