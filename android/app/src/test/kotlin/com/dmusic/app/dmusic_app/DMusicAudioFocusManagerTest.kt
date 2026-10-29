package com.dmusic.app.dmusic_app

import android.app.Application
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Looper
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class DMusicAudioFocusManagerTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val audio get() = shadowOf(context.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
    private val actions = mutableListOf<String>()
    private lateinit var focus: DMusicAudioFocusManager

    @Before
    fun setUp() {
        // AGP's isolated unit-test manifest omits AndroidX's merged permission.
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(
            "${context.packageName}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
        focus = DMusicAudioFocusManager(context) { actions.add(it) }
    }

    @After
    fun tearDown() = focus.dispose()

    @Test
    fun focusIsRequestedOnlyAfterRealPlaybackAndReleasedOnOrdinaryPause() {
        focus.setPlaying(false)
        assertNull(audio.lastAudioFocusRequest)
        focus.setPlaying(true)
        assertNotNull(audio.lastAudioFocusRequest)
        focus.setPlaying(false)
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
    }

    @Test
    fun transientLossPausesAndGainResumesWithExplicitPlay() {
        focus.setPlaying(true)
        change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        focus.setPlaying(false)
        assertEquals(listOf(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE), actions)
        assertNull(audio.lastAbandonedAudioFocusRequest)
        change(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(listOf(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE,
            DMusicAppWidgetProvider.ACTION_WIDGET_PLAY), actions)
        change(AudioManager.AUDIOFOCUS_GAIN)
        assertEquals(2, actions.size)
    }

    @Test
    fun permanentLossCancelsPendingTransientResume() {
        focus.setPlaying(true)
        change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        focus.setPlaying(false)
        change(AudioManager.AUDIOFOCUS_LOSS)
        change(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(actions.contains(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY))
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
    }

    @Test
    fun duckingDoesNotPausePlayback() {
        focus.setPlaying(true)
        change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)
        change(AudioManager.AUDIOFOCUS_GAIN)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun deniedFocusPausesPlayback() {
        audio.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        focus.setPlaying(true)
        assertEquals(listOf(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE), actions)
    }

    @Test
    fun headphoneUnplugPausesAndCancelsResume() {
        focus.setPlaying(true)
        change(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        focus.setPlaying(false)
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        shadowOf(Looper.getMainLooper()).idle()
        change(AudioManager.AUDIOFOCUS_GAIN)
        assertFalse(actions.contains(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY))
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
    }

    @Test
    fun disposeStopsNoisyAndFocusCallbacks() {
        focus.setPlaying(true)
        val listener = audio.lastAudioFocusRequest.listener
        focus.dispose()
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(actions.isEmpty())
        assertNotNull(audio.lastAbandonedAudioFocusRequest)
    }

    private fun change(value: Int) = audio.lastAudioFocusRequest.listener.onAudioFocusChange(value)
}
