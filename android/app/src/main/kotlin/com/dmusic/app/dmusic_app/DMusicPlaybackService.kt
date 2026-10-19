package com.dmusic.app.dmusic_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.media.app.NotificationCompat.MediaStyle
import java.io.File

class DMusicPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "dmusic_playback_channel"
        const val CHANNEL_NAME = "DMusic 音乐后台播放"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "com.dmusic.app.ACTION_SERVICE_START"
        const val ACTION_UPDATE = "com.dmusic.app.ACTION_SERVICE_UPDATE"
        const val ACTION_STOP = "com.dmusic.app.ACTION_SERVICE_STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_QUALITY = "quality"
        const val EXTRA_COVER_PATH = "coverPath"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_DURATION_MS = "durationMs"

        @Volatile
        var isServiceRunning = false

        fun startOrUpdateService(
            context: Context,
            title: String?,
            artist: String?,
            isPlaying: Boolean,
            quality: String?,
            coverPath: String?,
            positionMs: Long = 0L,
            durationMs: Long = 0L
        ) {
            // AUD-03: 未播放且服务未处于运行状态时直接忽略，避免后台冷态无故拉起前台服务
            if (!isPlaying && !isServiceRunning) {
                return
            }

            val intent = Intent(context, DMusicPlaybackService::class.java).apply {
                action = if (isServiceRunning) ACTION_UPDATE else ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_IS_PLAYING, isPlaying)
                putExtra(EXTRA_QUALITY, quality)
                putExtra(EXTRA_COVER_PATH, coverPath)
                putExtra(EXTRA_POSITION_MS, positionMs)
                putExtra(EXTRA_DURATION_MS, durationMs)
            }
            try {
                // AUD-03: 服务已在前台运行时，直接使用普通 startService 投递更新，彻底避开 Android 12+ 后台严格限制
                if (isServiceRunning) {
                    context.startService(intent)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        fun stopService(context: Context) {
            if (!isServiceRunning) return
            try {
                context.stopService(Intent(context, DMusicPlaybackService::class.java))
            } catch (e: Exception) {
                e.printStackTrace()
            }
            isServiceRunning = false
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var mediaSession: MediaSessionCompat? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val wakeLockReleaseRunnable = Runnable {
        releaseWakeLockNow()
    }

    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var noisyReceiverRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                handleAudioFocusLoss()
            }
        }
    }

    private var lastTitle: String = "DMusic 发烧音乐"
    private var lastArtist: String = "DMusic 正在播放"
    private var lastQuality: String = "发烧无损"
    private var lastCoverPath: String? = null
    private var lastCoverBitmap: Bitmap? = null
    private var lastIsPlaying: Boolean = false
    private var lastPositionMs: Long = 0L
    private var lastDurationMs: Long = 0L
    private var resumeOnFocusGain: Boolean = false

    private fun getSampledNotificationBitmap(coverPath: String?): Bitmap? {
        if (coverPath.isNullOrEmpty()) return null
        if (coverPath == lastCoverPath && lastCoverBitmap != null && !lastCoverBitmap!!.isRecycled) {
            return lastCoverBitmap
        }
        val file = File(coverPath)
        if (!file.exists()) return null
        return try {
            val boundsOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, boundsOptions)
            val maxDim = maxOf(boundsOptions.outWidth, boundsOptions.outHeight)
            var sampleSize = 1
            val targetSize = 256
            while (maxDim / (sampleSize * 2) >= targetSize) {
                sampleSize *= 2
            }
            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            val rawBmp = BitmapFactory.decodeFile(file.absolutePath, decodeOptions) ?: return null
            val scaled = if (rawBmp.width > targetSize || rawBmp.height > targetSize) {
                Bitmap.createScaledBitmap(rawBmp, targetSize, targetSize, true)
            } else {
                rawBmp
            }
            lastCoverPath = coverPath
            lastCoverBitmap = scaled
            scaled
        } catch (_: Exception) {
            null
        }
    }

    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 收到微信提示音或导航通知短暂打断：
                // 保持播放，不触发暂停（系统音频框架会自动执行 ducking 降低当前音量，提示音完毕后恢复原音量）
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 短暂失去焦点（如语音通话或第三方独占音频开始）：
                // 暂停音乐，但不注销焦点（不调用 abandonAudioFocus），记录恢复标记
                if (lastIsPlaying) {
                    resumeOnFocusGain = true
                    DMusicAppWidgetProvider.dispatchAction(this, DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久失去焦点（如其他音乐播放器启动）：
                resumeOnFocusGain = false
                handleAudioFocusLoss()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 恢复获得焦点：若之前因短暂打断暂停，自动恢复播放
                if (resumeOnFocusGain) {
                    resumeOnFocusGain = false
                    DMusicAppWidgetProvider.dispatchAction(this, DMusicAppWidgetProvider.ACTION_WIDGET_PLAY_PAUSE)
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        } catch (e: Exception) {
            e.printStackTrace()
        }
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DMusic:PlaybackWakeLock")
            wakeLock?.setReferenceCounted(false)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        // 初始化 MediaSessionCompat，全面适配车载大屏、锁屏媒体控件及蓝牙耳机线控
        try {
            mediaSession = MediaSessionCompat(this, "DMusicMediaSession").apply {
                setFlags(
                    MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
                )
                setCallback(object : MediaSessionCompat.Callback() {
                    private var lastActionTime = 0L
                    private var lastAction = ""

                    private fun dispatchAction(action: String) {
                        val now = System.currentTimeMillis()
                        if (action == lastAction && now - lastActionTime < 350L) {
                            return
                        }
                        lastAction = action
                        lastActionTime = now

                        DMusicAppWidgetProvider.dispatchAction(this@DMusicPlaybackService, action)
                    }

                    override fun onPlay() {
                        dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY)
                    }
                    override fun onPause() {
                        dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
                    }
                    override fun onSkipToNext() {
                        dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT)
                    }
                    override fun onSkipToPrevious() {
                        dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PREV)
                    }
                    override fun onSeekTo(pos: Long) {
                        dispatchAction("com.dmusic.app.ACTION_SEEK:$pos")
                    }
                    override fun onStop() {
                        dispatchAction(DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
                    }
                })
                isActive = true
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        if (action == ACTION_STOP) {
            // AUD-03: 如果尚未成为前台服务就收到 ACTION_STOP，先补齐最小前台通知避免 Android 8.0+ 报未调用 startForeground 超时崩溃
            if (!isServiceRunning && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    val minimalNotification = NotificationCompat.Builder(this, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("DMusic")
                        .setPriority(NotificationCompat.PRIORITY_MIN)
                        .build()
                    startForeground(NOTIFICATION_ID, minimalNotification)
                } catch (_: Exception) {}
            }
            abandonAudioFocus()
            releaseWakeLockNow()
            DMusicAppWidgetProvider.updateAllWidgets(this, isPlaying = false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.cancel(NOTIFICATION_ID)
            stopSelf()
            isServiceRunning = false
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "DMusic 发烧音乐"
        val artist = intent?.getStringExtra(EXTRA_ARTIST) ?: "DMusic 正在播放"
        var isPlaying = intent?.getBooleanExtra(EXTRA_IS_PLAYING, false) ?: false
        val quality = intent?.getStringExtra(EXTRA_QUALITY) ?: "发烧无损"
        val coverPath = intent?.getStringExtra(EXTRA_COVER_PATH)
        val positionMs = intent?.getLongExtra(EXTRA_POSITION_MS, 0L) ?: 0L
        val durationMs = intent?.getLongExtra(EXTRA_DURATION_MS, 0L) ?: 0L

        val isSongChanged = (title != lastTitle || artist != lastArtist)

        if (isSongChanged) {
            // 切歌时：彻底清空上一首歌曲的封面缓存与位图，严禁将上一首的图挪给新歌
            lastCoverPath = null
            lastCoverBitmap = null
        }

        // AUD-01: 脏数据比对（Diff Check）：比对核心元数据或播放状态是否改变
        val metadataChanged = (!isServiceRunning ||
            isSongChanged ||
            isPlaying != lastIsPlaying ||
            quality != lastQuality ||
            coverPath != lastCoverPath)

        val isSeek = java.lang.Math.abs(positionMs - lastPositionMs) > 2000L

        // 解析封面 Bitmap (采用采样下采样与复用缓存，杜绝主线程大图解码耗时与 Binder 溢出)
        val coverBitmap = getSampledNotificationBitmap(coverPath)

        if (coverBitmap != null) {
            lastCoverBitmap = coverBitmap
            lastCoverPath = coverPath
        } else if (isSongChanged) {
            lastCoverBitmap = null
            lastCoverPath = null
        }

        if (durationMs > 0L) {
            lastDurationMs = durationMs
        }
        lastTitle = title
        lastArtist = artist
        lastQuality = quality
        lastIsPlaying = isPlaying
        lastPositionMs = positionMs

        val effectiveCoverBitmap = if (isSongChanged) coverBitmap else (coverBitmap ?: lastCoverBitmap)
        val effectiveDurationMs = if (durationMs > 0L) durationMs else lastDurationMs

        // 仅在元数据变动或进度发生拖拽跳变时，才同步 MediaSession
        if (metadataChanged || isSeek) {
            updateMediaSession(title, artist, isPlaying, effectiveCoverBitmap, positionMs, effectiveDurationMs)
        }

        // AUD-01: 仅在元数据/状态变更时才重构 Notification 并调用 startForeground，避免每秒重复写盘重绘通知栏
        if (metadataChanged) {
            val notification = buildNotification(title, artist, isPlaying, quality, effectiveCoverBitmap)

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                // Android 15+ 后台请求焦点要求前台服务先就绪。
                if (isPlaying) {
                    resumeOnFocusGain = false
                    if (!requestAudioFocus()) {
                        handleAudioFocusLoss()
                        isPlaying = false
                    }
                } else if (!resumeOnFocusGain) {
                    abandonAudioFocus()
                }
                setNoisyReceiverEnabled(isPlaying)
                if (isPlaying) {
                    acquireWakeLock()
                } else {
                    // 暂停或切歌换源间隙：保持前台服务并延时3分钟释放唤醒锁，彻底杜绝灭屏时系统断网冻结
                    scheduleWakeLockRelease(180_000L)
                }
                isServiceRunning = true
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        return START_STICKY
    }

    private fun updateMediaSession(
        title: String,
        artist: String,
        isPlaying: Boolean,
        coverBitmap: Bitmap?,
        positionMs: Long = 0L,
        durationMs: Long = 0L
    ) {
        try {
            val metadataBuilder = MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, "DMusic 发烧音乐")
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, artist)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_DESCRIPTION, "DMusic 发烧音乐")
            if (durationMs > 0L) {
                metadataBuilder.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
            }
            if (coverBitmap != null) {
                metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, coverBitmap)
                metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, coverBitmap)
            } else {
                metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, null)
                metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, null)
            }
            mediaSession?.setMetadata(metadataBuilder.build())

            val state = if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
            val playbackSpeed = if (isPlaying) 1.0f else 0.0f
            val playbackState = PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                    PlaybackStateCompat.ACTION_PAUSE or
                    PlaybackStateCompat.ACTION_PLAY_PAUSE or
                    PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                    PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackStateCompat.ACTION_SEEK_TO or
                    PlaybackStateCompat.ACTION_STOP
                )
                .setState(
                    state,
                    positionMs.coerceAtLeast(0L),
                    playbackSpeed,
                    SystemClock.elapsedRealtime()
                )
                .build()
            mediaSession?.setPlaybackState(playbackState)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun acquireWakeLock() {
        mainHandler.removeCallbacks(wakeLockReleaseRunnable)
        try {
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(24 * 60 * 60 * 1000L) // 最大持有24小时
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun scheduleWakeLockRelease(delayMs: Long = 180_000L) {
        // 延时3分钟释放唤醒锁，防止切歌网络解析、换源或短暂暂停时立即灭屏断网
        mainHandler.removeCallbacks(wakeLockReleaseRunnable)
        mainHandler.postDelayed(wakeLockReleaseRunnable, delayMs)
    }

    private fun releaseWakeLockNow() {
        mainHandler.removeCallbacks(wakeLockReleaseRunnable)
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "用于保证 DMusic 后台切歌、息屏不间断播放及锁屏媒体控制"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(
        title: String,
        artist: String,
        isPlaying: Boolean,
        quality: String,
        coverBitmap: Bitmap?
    ): Notification {
        val appIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pAppIntent = PendingIntent.getActivity(
            this,
            0,
            appIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 上一首
        val prevIntent = Intent(DMusicAppWidgetProvider.ACTION_WIDGET_PREV).apply {
            setPackage(packageName)
        }
        val pPrev = PendingIntent.getBroadcast(
            this,
            101,
            prevIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 播放 / 暂停
        val playIntent = Intent(DMusicAppWidgetProvider.ACTION_WIDGET_PLAY_PAUSE).apply {
            setPackage(packageName)
        }
        val pPlay = PendingIntent.getBroadcast(
            this,
            102,
            playIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 下一首
        val nextIntent = Intent(DMusicAppWidgetProvider.ACTION_WIDGET_NEXT).apply {
            setPackage(packageName)
        }
        val pNext = PendingIntent.getBroadcast(
            this,
            103,
            nextIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val mediaStyle = MediaStyle()
            .setShowActionsInCompactView(0, 1, 2)
        mediaSession?.sessionToken?.let {
            mediaStyle.setMediaSession(it)
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(artist)
            .setSubText(quality)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pAppIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(isPlaying)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setStyle(mediaStyle)
            .addAction(android.R.drawable.ic_media_previous, "上一首", pPrev)
            .addAction(
                if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (isPlaying) "暂停" else "播放",
                pPlay
            )
            .addAction(android.R.drawable.ic_media_next, "下一首", pNext)

        if (coverBitmap != null) {
            builder.setLargeIcon(coverBitmap)
        } else {
            builder.setLargeIcon(null as Bitmap?)
        }

        return builder.build()
    }

    private fun requestAudioFocus(): Boolean {
        val am = audioManager ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (audioFocusRequest == null) {
                    val attributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                    audioFocusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(attributes)
                        .setAcceptsDelayedFocusGain(false)
                        .setOnAudioFocusChangeListener(audioFocusChangeListener, mainHandler)
                        .build()
                }
                val res = am.requestAudioFocus(audioFocusRequest!!)
                res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                @Suppress("DEPRECATION")
                val res = am.requestAudioFocus(
                    audioFocusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN
                )
                res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun setNoisyReceiverEnabled(enabled: Boolean) {
        if (enabled == noisyReceiverRegistered) return
        try {
            if (enabled) {
                ContextCompat.registerReceiver(
                    this,
                    noisyReceiver,
                    IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                    ContextCompat.RECEIVER_NOT_EXPORTED
                )
            } else {
                unregisterReceiver(noisyReceiver)
            }
            noisyReceiverRegistered = enabled
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(audioFocusChangeListener)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun handleAudioFocusLoss() {
        if (!lastIsPlaying) return
        lastIsPlaying = false
        resumeOnFocusGain = false
        abandonAudioFocus()
        setNoisyReceiverEnabled(false)

        try {
            updateMediaSession(lastTitle, lastArtist, isPlaying = false, lastCoverBitmap, lastPositionMs, lastDurationMs)
            val notification = buildNotification(lastTitle, lastArtist, isPlaying = false, lastQuality, lastCoverBitmap)
            val manager = getSystemService(NotificationManager::class.java)
            manager?.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        DMusicAppWidgetProvider.updateAllWidgets(this, isPlaying = false)
        DMusicAppWidgetProvider.dispatchAction(this, DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE)
        releaseWakeLockNow()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        resumeOnFocusGain = false
        abandonAudioFocus()
        setNoisyReceiverEnabled(false)
        releaseWakeLockNow()
        DMusicAppWidgetProvider.updateAllWidgets(this, isPlaying = false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
        mediaSession?.apply {
            isActive = false
            release()
        }
        mediaSession = null
        isServiceRunning = false
        stopSelf()
    }

    override fun onDestroy() {
        abandonAudioFocus()
        setNoisyReceiverEnabled(false)
        releaseWakeLockNow()
        DMusicAppWidgetProvider.updateAllWidgets(this, isPlaying = false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
        mediaSession?.apply {
            isActive = false
            release()
        }
        mediaSession = null
        isServiceRunning = false
        super.onDestroy()
    }
}
