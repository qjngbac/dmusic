package com.dmusic.app.dmusic_app

import android.app.Application
import android.content.Context
import android.media.AudioManager
import android.os.Looper
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class DMusicMediaSessionObserverTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val changes = mutableListOf<Boolean>()
    private val sessions = mutableListOf<MediaSessionCompat>()
    private lateinit var observer: DMusicMediaSessionObserver
    private var generation = 0L

    @Before
    fun setUp() {
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(
            "${context.packageName}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
        generation = DMusicWidgetPlaybackState.openSession()
        observer = DMusicMediaSessionObserver(context, { generation }, { changes.add(it) }, {})
    }

    @After
    fun tearDown() {
        observer.dispose()
        sessions.forEach { it.release() }
    }

    @Test
    fun actualSessionStatesControlPlayingAndFocus() {
        val audio = shadowOf(context.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
        val session = session(PlaybackStateCompat.STATE_PAUSED)
        observer.attachController(MediaControllerCompat(context, session.sessionToken))
        assertNull(audio.lastAudioFocusRequest)
        for (state in listOf(PlaybackStateCompat.STATE_PLAYING, PlaybackStateCompat.STATE_BUFFERING,
            PlaybackStateCompat.STATE_CONNECTING)) {
            publish(session, state)
            assertEquals(true, changes.last())
            publish(session, PlaybackStateCompat.STATE_PAUSED)
            assertEquals(false, changes.last())
        }
        assertNotNull(audio.lastAudioFocusRequest)
        publish(session, PlaybackStateCompat.STATE_PLAYING)
        publish(session, PlaybackStateCompat.STATE_STOPPED)
        assertEquals(false, changes.last())
    }

    @Test
    fun oldSessionCallbacksCannotPauseReplacement() {
        val old = session(PlaybackStateCompat.STATE_PLAYING)
        val oldController = MediaControllerCompat(context, old.sessionToken)
        observer.attachController(oldController)
        val replacement = session(PlaybackStateCompat.STATE_PLAYING)
        observer.attachController(MediaControllerCompat(context, replacement.sessionToken))
        publish(old, PlaybackStateCompat.STATE_PAUSED)
        old.release()
        dispatchDestroyed(oldController)
        assertEquals(true, changes.last())
    }

    @Test
    fun queuedStateFromOldGenerationCannotChangeNewSession() {
        val old = session(PlaybackStateCompat.STATE_PLAYING)
        observer.attachController(MediaControllerCompat(context, old.sessionToken))
        generation = DMusicWidgetPlaybackState.openSession()
        publish(old, PlaybackStateCompat.STATE_PAUSED)
        assertEquals(true, changes.last())
    }

    @Test
    fun sessionDestructionClearsPlaying() {
        val session = session(PlaybackStateCompat.STATE_PLAYING)
        val controller = MediaControllerCompat(context, session.sessionToken)
        observer.attachController(controller)
        session.release()
        dispatchDestroyed(controller)
        assertEquals(false, changes.last())
    }

    @Test
    fun nativePollingKeepsLivePlayingLeaseFresh() {
        val session = session(PlaybackStateCompat.STATE_PLAYING)
        observer.attachController(MediaControllerCompat(context, session.sessionToken))
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(40))
        val prefs = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
        assertTrue(DMusicWidgetPlaybackState.isPlaying(prefs))
        publish(session, PlaybackStateCompat.STATE_PAUSED)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(31))
        assertFalse(DMusicWidgetPlaybackState.isPlaying(prefs))
    }

    @Test
    fun idleDetachesControllerAndIgnoresLaterPlayback() {
        val session = session(PlaybackStateCompat.STATE_PLAYING)
        observer.attachController(MediaControllerCompat(context, session.sessionToken))
        observer.setActive(false)
        publish(session, PlaybackStateCompat.STATE_PLAYING)
        assertEquals(false, changes.last())
        val prefs = context.getSharedPreferences(DMusicAppWidgetProvider.PREF_NAME, Context.MODE_PRIVATE)
        DMusicAppWidgetProvider.updateAllWidgets(context, isPlaying = true)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(31))
        assertFalse(DMusicWidgetPlaybackState.isPlaying(prefs))
    }

    private fun session(state: Int): MediaSessionCompat = MediaSessionCompat(context, "observer-test").also {
        sessions.add(it)
        it.isActive = true
        publish(it, state)
    }

    private fun publish(session: MediaSessionCompat, state: Int) {
        session.setPlaybackState(PlaybackStateCompat.Builder().setState(state, 0L, 1f).build())
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun dispatchDestroyed(controller: MediaControllerCompat) {
        // Robolectric does not forward MediaSession.release to framework controllers.
        shadowOf(controller.mediaController as android.media.session.MediaController).executeOnSessionDestroyed()
        shadowOf(Looper.getMainLooper()).idle()
    }
}
