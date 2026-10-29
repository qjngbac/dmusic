package com.dmusic.app.dmusic_app

import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log

/** Observes audio_service's single session; never creates a second session or notification. */
class DMusicMediaSessionObserver(
    context: Context,
    private val generation: () -> Long,
    private val onPlayingChanged: (Boolean) -> Unit,
    private val onAction: (String) -> Unit,
) {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var browser: MediaBrowserCompat? = null
    private var controller: MediaControllerCompat? = null
    private var controllerCallback: MediaControllerCompat.Callback? = null
    private var connectionGeneration = -1L
    private var controllerGeneration = -1L
    private var focusGeneration = -1L
    private var active = false
    private var disposed = false
    private var lastPlaying: Boolean? = null
    private var focus = newFocusManager()

    private val poll = object : Runnable {
        override fun run() {
            val current = controller ?: return
            if (!isCurrent(current, controllerGeneration)) return
            publishPlaying(isPlaying(current.playbackState))
        }
    }

    private val renewIndicator = object : Runnable {
        override fun run() {
            val current = controller ?: return
            if (!isCurrent(current, controllerGeneration) || lastPlaying != true) return
            DMusicAppWidgetProvider.renewPlaybackIndicator(context)
            handler.postDelayed(this, DMusicAppWidgetProvider.PLAYBACK_INDICATOR_RENEW_MS)
        }
    }

    fun setActive(isActive: Boolean) {
        if (disposed) return
        val sessionGeneration = generation()
        if (!isActive) {
            disconnect()
            return
        }
        if (active && connectionGeneration == sessionGeneration) return
        disconnect()
        if (!DMusicWidgetPlaybackState.accepts(sessionGeneration)) return
        active = true
        connectionGeneration = sessionGeneration
        lateinit var connectingBrowser: MediaBrowserCompat
        val callback = object : MediaBrowserCompat.ConnectionCallback() {
            override fun onConnected() {
                if (!isCurrent(connectingBrowser, sessionGeneration)) return
                try {
                    attachController(MediaControllerCompat(context, connectingBrowser.sessionToken), sessionGeneration)
                } catch (error: Exception) {
                    Log.w("DMusicAudio", "Media controller connection failed", error)
                    disconnect()
                }
            }

            override fun onConnectionSuspended() {
                if (isCurrent(connectingBrowser, sessionGeneration)) disconnect()
            }

            override fun onConnectionFailed() {
                if (isCurrent(connectingBrowser, sessionGeneration)) disconnect()
            }
        }
        connectingBrowser = MediaBrowserCompat(context,
            ComponentName(context, "com.ryanheise.audioservice.AudioService"), callback, null)
        browser = connectingBrowser
        connectingBrowser.connect()
    }

    internal fun attachController(newController: MediaControllerCompat, sessionGeneration: Long = generation()) {
        if (disposed || sessionGeneration != generation() || !DMusicWidgetPlaybackState.accepts(sessionGeneration)) return
        detachController()
        focus.dispose()
        focus = newFocusManager()
        if (controllerGeneration != sessionGeneration) lastPlaying = null
        active = true
        connectionGeneration = sessionGeneration
        controllerGeneration = sessionGeneration
        controller = newController
        focusGeneration = sessionGeneration
        val callback = object : MediaControllerCompat.Callback() {
            override fun onPlaybackStateChanged(state: PlaybackStateCompat?) {
                if (isCurrent(newController, sessionGeneration)) publishPlaying(isPlaying(state))
            }

            override fun onSessionDestroyed() {
                if (isCurrent(newController, sessionGeneration)) disconnect()
            }
        }
        controllerCallback = callback
        newController.registerCallback(callback, handler)
        publishPlaying(isPlaying(newController.playbackState))
    }

    fun dispose() {
        if (disposed) return
        disconnect()
        disposed = true
        focus.dispose()
    }

    private fun publishPlaying(playing: Boolean) {
        handler.removeCallbacks(poll)
        handler.removeCallbacks(renewIndicator)
        focus.setPlaying(playing)
        if (lastPlaying != playing) {
            lastPlaying = playing
            onPlayingChanged(playing)
        }
        if (playing) {
            DMusicWidgetPlaybackState.heartbeat(context, controllerGeneration)
            handler.postDelayed(poll, 10_000L)
            handler.postDelayed(renewIndicator, DMusicAppWidgetProvider.PLAYBACK_INDICATOR_RENEW_MS)
        }
    }

    private fun disconnect() {
        active = false
        val ownerGeneration = if (controller != null) controllerGeneration else connectionGeneration
        val shouldNotify = ownerGeneration == generation() &&
            DMusicWidgetPlaybackState.accepts(ownerGeneration)
        detachController()
        browser?.disconnect()
        browser = null
        if (shouldNotify && lastPlaying != false) {
            lastPlaying = false
            onPlayingChanged(false)
        }
        focus.dispose()
        focus = newFocusManager()
    }

    private fun detachController() {
        handler.removeCallbacks(poll)
        handler.removeCallbacks(renewIndicator)
        controllerCallback?.let { callback -> controller?.unregisterCallback(callback) }
        controllerCallback = null
        controller = null
    }

    private fun newFocusManager() = DMusicAudioFocusManager(context) { action ->
        if (!disposed && focusGeneration == generation() && DMusicWidgetPlaybackState.accepts(focusGeneration)) {
            onAction(action)
        }
    }

    private fun isCurrent(current: MediaControllerCompat, sessionGeneration: Long): Boolean =
        !disposed && active && controller === current && sessionGeneration == generation() &&
            DMusicWidgetPlaybackState.accepts(sessionGeneration)

    private fun isCurrent(current: MediaBrowserCompat, sessionGeneration: Long): Boolean =
        !disposed && active && browser === current && sessionGeneration == generation() &&
            DMusicWidgetPlaybackState.accepts(sessionGeneration)

    private fun isPlaying(state: PlaybackStateCompat?): Boolean = when (state?.state) {
        PlaybackStateCompat.STATE_PLAYING, PlaybackStateCompat.STATE_BUFFERING,
        PlaybackStateCompat.STATE_CONNECTING -> true
        else -> false
    }
}
