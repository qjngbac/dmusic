package com.dmusic.app.dmusic_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/** Audio focus follows the live service session, independently of the Activity. */
class DMusicAudioFocusManager(context: Context, private val onAction: (String) -> Unit) {
    private val context = context.applicationContext
    private val audioManager = this.context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private var playing = false
    private var resumeOnFocusGain = false
    private var receiverRegistered = false
    private var disposed = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!disposed && intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) pause()
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (!disposed) {
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> if (playing) {
                    playing = false
                    resumeOnFocusGain = true
                    onAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
                }
                AudioManager.AUDIOFOCUS_LOSS -> pause()
                AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnFocusGain) {
                    resumeOnFocusGain = false
                    onAction(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY)
                }
                // Android handles ducking and restores the original volume.
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> Unit
            }
        }
    }

    fun setPlaying(isPlaying: Boolean) {
        if (disposed) return
        playing = isPlaying
        if (isPlaying) {
            resumeOnFocusGain = false
            if (!hasFocus) {
                hasFocus = requestFocus()
                if (!hasFocus) {
                    playing = false
                    onAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
                    return
                }
            }
            setNoisyReceiverEnabled(true)
        } else if (!resumeOnFocusGain) {
            releaseFocus()
            setNoisyReceiverEnabled(false)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        playing = false
        resumeOnFocusGain = false
        releaseFocus()
        setNoisyReceiverEnabled(false)
    }

    private fun pause() {
        val shouldPause = playing || resumeOnFocusGain
        playing = false
        resumeOnFocusGain = false
        releaseFocus()
        setNoisyReceiverEnabled(false)
        if (shouldPause) onAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
    }

    private fun requestFocus(): Boolean {
        val manager = audioManager ?: return false
        return try {
            val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener(focusListener, handler)
                    .build().also { focusRequest = it }
                manager.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                manager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (error: Exception) {
            Log.w("DMusicAudio", "Audio focus request failed", error)
            false
        }
    }

    private fun releaseFocus() {
        if (!hasFocus) return
        hasFocus = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { audioManager?.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                audioManager?.abandonAudioFocus(focusListener)
            }
        } catch (error: Exception) {
            Log.w("DMusicAudio", "Audio focus could not be released", error)
        }
    }

    private fun setNoisyReceiverEnabled(enabled: Boolean) {
        if (receiverRegistered == enabled) return
        if (enabled) {
            ContextCompat.registerReceiver(context, noisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
        } else {
            context.unregisterReceiver(noisyReceiver)
        }
        receiverRegistered = enabled
    }
}
