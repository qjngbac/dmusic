package com.dmusic.app.dmusic_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import java.io.File

class DMusicAppWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_WIDGET_PLAY_PAUSE = "com.dmusic.app.ACTION_TOGGLE_PLAY"
        const val ACTION_WIDGET_PAUSE = "com.dmusic.app.ACTION_PAUSE"
        const val ACTION_WIDGET_PLAY = "com.dmusic.app.ACTION_PLAY"
        const val ACTION_WIDGET_PREV = "com.dmusic.app.ACTION_PREV"
        const val ACTION_WIDGET_NEXT = "com.dmusic.app.ACTION_NEXT"
        const val ACTION_WIDGET_FAVORITE = "com.dmusic.app.ACTION_TOGGLE_FAVORITE"
        const val ACTION_WIDGET_MODE = "com.dmusic.app.ACTION_TOGGLE_MODE"
        const val ACTION_WIDGET_SEEK = "com.dmusic.app.ACTION_SEEK"
        const val EXTRA_SEEK_POSITION_MS = "seek_position_ms"
        const val PLAYBACK_INDICATOR_RENEW_MS = 1_000L
        private const val PLAYBACK_INDICATOR_THROTTLE_MS = 700L

        private var firstPlaybackIndicator = true
        private var lastIndicatorRenewalElapsed = -PLAYBACK_INDICATOR_THROTTLE_MS

        fun dispatchAction(context: Context, action: String) {
            if (DMusicEngineBridge.dispatchAction(action)) return
            if (action == ACTION_WIDGET_PAUSE) return
            launchPlayer(context)
        }

        private fun launchPlayer(context: Context) {
            try {
                context.startActivity(Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                })
            } catch (_: Exception) {
                // The queued control remains available if Android blocks a background launch.
            }
        }

        const val PREF_NAME = "dmusic_widget_pref"
        const val KEY_TITLE = "title"
        const val KEY_ARTIST = "artist"
        const val KEY_PROGRESS = "progress"
        const val KEY_IS_PLAYING = "is_playing"
        const val KEY_IS_FAVORITE = "is_favorite"
        const val KEY_PLAY_MODE = "play_mode"
        const val KEY_QUALITY = "quality"
        const val KEY_COVER_PATH = "cover_path"

        private var cachedCoverPath: String? = null
        private var cachedCoverBitmap: Bitmap? = null

        private fun toCircularBitmap(src: Bitmap): Bitmap {
            val size = minOf(src.width, src.height)
            val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val radius = size / 2f
            canvas.drawCircle(radius, radius, radius, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            val left = (src.width - size) / 2
            val top = (src.height - size) / 2
            val srcRect = Rect(left, top, left + size, top + size)
            val dstRect = Rect(0, 0, size, size)
            canvas.drawBitmap(src, srcRect, dstRect, paint)
            return output
        }

        fun getSampledCoverBitmap(coverPath: String?, targetSize: Int): Bitmap? {
            if (coverPath.isNullOrEmpty()) return null
            val cached = cachedCoverBitmap
            if (coverPath == cachedCoverPath && cached != null && !cached.isRecycled) {
                return cached
            }
            val file = File(coverPath)
            if (!file.exists()) return null
            return try {
                val boundsOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.absolutePath, boundsOptions)
                val maxDim = maxOf(boundsOptions.outWidth, boundsOptions.outHeight)
                var sampleSize = 1
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
                val circular = toCircularBitmap(scaled)
                cachedCoverPath = coverPath
                cachedCoverBitmap = circular
                circular
            } catch (_: Exception) {
                null
            }
        }

        fun updateAllWidgets(
            context: Context,
            title: String? = null,
            artist: String? = null,
            progress: String? = null,
            isPlaying: Boolean? = null,
            isFavorite: Boolean? = null,
            playMode: String? = null,
            quality: String? = null,
            coverPath: String? = null
        ) {
            val appContext = context.applicationContext ?: context
            val prefs = appContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val editor = prefs.edit()
            val oldTitle = prefs.getString(KEY_TITLE, null)
            val isSongChanged = (title != null && title != oldTitle)

            title?.let { editor.putString(KEY_TITLE, it) }
            artist?.let { editor.putString(KEY_ARTIST, it) }
            progress?.let { editor.putString(KEY_PROGRESS, it) }
            isPlaying?.let { DMusicWidgetPlaybackState.record(editor, it) }
            isFavorite?.let { editor.putBoolean(KEY_IS_FAVORITE, it) }
            playMode?.let { editor.putString(KEY_PLAY_MODE, it) }
            quality?.let { editor.putString(KEY_QUALITY, it) }

            if (!coverPath.isNullOrEmpty()) {
                editor.putString(KEY_COVER_PATH, coverPath)
            } else if (isSongChanged || (isPlaying == false && title == "DMusic 发烧播放器")) {
                // 切歌且新歌无封面路径，或者播放器重置时，彻底移除旧封面路径并清空内存缓存
                editor.remove(KEY_COVER_PATH)
                cachedCoverPath = null
                cachedCoverBitmap = null
            }
            editor.commit()
            DMusicWidgetPlaybackState.afterPublish(appContext, prefs)

            val appWidgetManager = AppWidgetManager.getInstance(appContext)
            val thisWidget = ComponentName(appContext, DMusicAppWidgetProvider::class.java)
            val allWidgetIds = appWidgetManager.getAppWidgetIds(thisWidget)
            if (allWidgetIds.isEmpty()) return

            for (widgetId in allWidgetIds) {
                val views = RemoteViews(appContext.packageName, R.layout.widget_vinyl_card)
                buildViews(appContext, views, prefs)
                appWidgetManager.updateAppWidget(widgetId, views)
            }
        }

        fun renewPlaybackIndicator(context: Context) {
            if (!DMusicWidgetPlaybackState.accepts(DMusicWidgetPlaybackState.generation)) return
            val now = SystemClock.elapsedRealtime()
            if (now - lastIndicatorRenewalElapsed < PLAYBACK_INDICATOR_THROTTLE_MS) return
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, DMusicAppWidgetProvider::class.java))
            if (ids.isEmpty()) return
            lastIndicatorRenewalElapsed = now
            firstPlaybackIndicator = !firstPlaybackIndicator
            val views = RemoteViews(context.packageName, R.layout.widget_vinyl_card)
            setPlaybackIndicator(views, true)
            manager.partiallyUpdateAppWidget(ids, views)
        }

        private fun setPlaybackIndicator(views: RemoteViews, isPlaying: Boolean) {
            views.setViewVisibility(R.id.widget_playback_indicator_a,
                if (isPlaying && firstPlaybackIndicator) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.widget_playback_indicator_b,
                if (isPlaying && !firstPlaybackIndicator) View.VISIBLE else View.GONE)
        }

        fun buildViews(context: Context, views: RemoteViews, prefs: SharedPreferences) {
            val title = prefs.getString(KEY_TITLE, "DMusic 发烧播放器") ?: "DMusic 发烧播放器"
            val artist = prefs.getString(KEY_ARTIST, "点击开启好音乐") ?: "点击开启好音乐"
            val progress = prefs.getString(KEY_PROGRESS, "00:00 / 00:00") ?: "00:00 / 00:00"
            val isPlaying = DMusicWidgetPlaybackState.isPlaying(prefs)
            val isFavorite = prefs.getBoolean(KEY_IS_FAVORITE, false)
            val playMode = prefs.getString(KEY_PLAY_MODE, "listLoop") ?: "listLoop"
            val quality = prefs.getString(KEY_QUALITY, "FLAC 无损") ?: "FLAC 无损"
            val coverPath = prefs.getString(KEY_COVER_PATH, null)

            views.setTextViewText(R.id.widget_song_name, title)
            views.setTextViewText(R.id.widget_artist_name, artist)
            views.setTextViewText(R.id.widget_progress_text, progress)
            views.setTextViewText(R.id.widget_quality_badge, quality)

            views.setImageViewResource(R.id.widget_btn_play_pause, R.drawable.ic_widget_play)
            setPlaybackIndicator(views, isPlaying)

            // 红心收藏状态图标
            val favRes = if (isFavorite) R.drawable.ic_widget_heart_filled else R.drawable.ic_widget_heart_empty
            views.setImageViewResource(R.id.widget_btn_favorite, favRes)

            // 循环模式图标 (列表循环 / 单曲循环 / 随机播放)
            val modeRes = when (playMode) {
                "singleLoop" -> R.drawable.ic_widget_loop_single
                "shuffle" -> R.drawable.ic_widget_loop_shuffle
                else -> R.drawable.ic_widget_loop_list
            }
            views.setImageViewResource(R.id.widget_btn_mode, modeRes)

            // 封面图片加载（缩放下采样与安全缓存，防止大图引发 TransactionTooLargeException）
            val bmp = getSampledCoverBitmap(coverPath, 160)
            if (bmp != null) {
                views.setImageViewBitmap(R.id.widget_cover_image, bmp)
            } else {
                views.setImageViewResource(R.id.widget_cover_image, R.mipmap.ic_launcher)
            }

            // 点击大卡片或唱片打开主应用
            val appIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val pAppIntent = PendingIntent.getActivity(
                context, 0, appIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pAppIntent)
            views.setOnClickPendingIntent(R.id.widget_vinyl_container, pAppIntent)

            // 按钮事件广播
            val playIntent = Intent(context, DMusicAppWidgetProvider::class.java).apply {
                action = ACTION_WIDGET_PLAY_PAUSE
            }
            val pPlayIntent = PendingIntent.getBroadcast(
                context, 1, playIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_play_pause, pPlayIntent)

            val prevIntent = Intent(context, DMusicAppWidgetProvider::class.java).apply {
                action = ACTION_WIDGET_PREV
            }
            val pPrevIntent = PendingIntent.getBroadcast(
                context, 2, prevIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_prev, pPrevIntent)

            val nextIntent = Intent(context, DMusicAppWidgetProvider::class.java).apply {
                action = ACTION_WIDGET_NEXT
            }
            val pNextIntent = PendingIntent.getBroadcast(
                context, 3, nextIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_next, pNextIntent)

            val favIntent = Intent(context, DMusicAppWidgetProvider::class.java).apply {
                action = ACTION_WIDGET_FAVORITE
            }
            val pFavIntent = PendingIntent.getBroadcast(
                context, 4, favIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_favorite, pFavIntent)

            val modeIntent = Intent(context, DMusicAppWidgetProvider::class.java).apply {
                action = ACTION_WIDGET_MODE
            }
            val pModeIntent = PendingIntent.getBroadcast(
                context, 5, modeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_btn_mode, pModeIntent)
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        DMusicWidgetPlaybackState.checkPlayback(context)
        val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_vinyl_card)
            buildViews(context, views, prefs)
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        onUpdate(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.action ?: return
        when (action) {
            ACTION_WIDGET_SEEK -> {
                val position = intent.getLongExtra(EXTRA_SEEK_POSITION_MS, -1L)
                if (position >= 0L) forwardAction(context, "$ACTION_WIDGET_SEEK:$position")
            }
            ACTION_WIDGET_PLAY_PAUSE,
            ACTION_WIDGET_PAUSE,
            ACTION_WIDGET_PLAY,
            ACTION_WIDGET_PREV,
            ACTION_WIDGET_NEXT,
            ACTION_WIDGET_FAVORITE,
            ACTION_WIDGET_MODE -> {
                forwardAction(context, action)
            }
        }
    }

    override fun onDisabled(context: Context) {
        DMusicWidgetPlaybackState.widgetRemoved(context)
        super.onDisabled(context)
    }

    private fun forwardAction(context: Context, action: String) {
        dispatchAction(context, action)
    }
}
