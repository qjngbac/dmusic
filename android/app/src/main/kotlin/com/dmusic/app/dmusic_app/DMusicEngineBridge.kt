package com.dmusic.app.dmusic_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.audiofx.AudioEffect
import android.media.audiofx.Equalizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.dmusic.runtimebridge.DMusicRuntimeDelegate
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToInt

/** Installed once per service-owned Flutter engine, including headless startup. */
class DMusicEngineBridge(context: Context, messenger: BinaryMessenger) : DMusicRuntimeDelegate {
    companion object {
        const val CHANNEL = "com.dmusic.app/widget"
        @Volatile
        private var currentBridge: DMusicEngineBridge? = null
        private data class PendingAction(val action: String, val generation: Long?)
        private val pendingActions = ConcurrentLinkedQueue<PendingAction>()
        private val mainHandler = Handler(Looper.getMainLooper())

        /** False asks the widget receiver to open the UI for a cold engine. */
        fun dispatchAction(action: String): Boolean {
            val bridge = currentBridge
            if (bridge == null || bridge.disposed) {
                if (action != DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE) {
                    pendingActions.offer(PendingAction(action, null))
                }
                return false
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                bridge.dispatchUserAction(action)
            } else {
                mainHandler.post { bridge.dispatchUserAction(action) }
            }
            return true
        }

        fun onActivityFinishing(activity: Activity) {
            val bridge = currentBridge ?: return
            if (!activity.isFinishing || activity.isChangingConfigurations ||
                bridge.weakActivity.get() !== activity || !bridge.accepts(bridge.sessionGeneration)) return
            val generation = bridge.sessionGeneration
            Log.i("DMusicWidget", "Activity exit received: generation=$generation")
            DMusicWidgetPlaybackState.endSession(bridge.appContext, generation)
            bridge.sessionObserver.setActive(false)
            Log.i("DMusicWidget", "Paused widget published: generation=$generation")
            if (bridge.dartReady) {
                bridge.channel.invokeMethod("onTaskDismissed", mapOf("generation" to generation))
            }
        }
    }

    private val appContext = context.applicationContext
    private var weakActivity = WeakReference<Activity>(null)
    private val channel = MethodChannel(messenger, CHANNEL)
    private var sessionGeneration = DMusicWidgetPlaybackState.openSession()
    private var dartReady = false
    private var controlsReady = false
    @Volatile
    private var disposed = false
    private var equalizer: Equalizer? = null
    private val sessionObserver = DMusicMediaSessionObserver(
        appContext,
        generation = { sessionGeneration },
        onPlayingChanged = { playing ->
            if (accepts(sessionGeneration)) {
                DMusicAppWidgetProvider.updateAllWidgets(appContext, isPlaying = playing)
            }
        },
        onAction = { action ->
            // Focus/noisy events never reopen an epoch closed by user exit.
            if (accepts(sessionGeneration)) enqueueOrDispatch(action)
        },
    )

    init {
        currentBridge = this
        channel.setMethodCallHandler(::onMethodCall)
    }

    private fun owns(generation: Long): Boolean = !disposed && currentBridge === this &&
        generation == sessionGeneration && generation == DMusicWidgetPlaybackState.generation

    private fun accepts(generation: Long): Boolean =
        owns(generation) && DMusicWidgetPlaybackState.accepts(generation)

    private fun reopenIfClosed() {
        if (disposed || currentBridge !== this || !DMusicWidgetPlaybackState.closed) return
        // Pending controls belong to the closed epoch, including cold-launch
        // controls queued before an engine could assign their generation.
        pendingActions.clear()
        sessionGeneration = DMusicWidgetPlaybackState.openSession()
        if (dartReady) {
            channel.invokeMethod("onPlaybackSessionOpened", mapOf("generation" to sessionGeneration))
        }
    }

    private fun dispatchUserAction(action: String) {
        if (disposed || currentBridge !== this) return
        if (action == DMusicAppWidgetProvider.ACTION_WIDGET_PAUSE &&
            !accepts(sessionGeneration)) return
        reopenIfClosed()
        if (accepts(sessionGeneration)) enqueueOrDispatch(action)
    }

    private fun enqueueOrDispatch(action: String) {
        if (dartReady && controlsReady) {
            channel.invokeMethod("onWidgetAction", mapOf(
                "action" to action, "generation" to sessionGeneration,
            ))
        } else {
            pendingActions.offer(PendingAction(action, sessionGeneration))
        }
    }

    private fun pollCurrentAction(): String? {
        while (true) {
            val next = pendingActions.poll() ?: return null
            if (next.generation == null || next.generation == sessionGeneration) return next.action
        }
    }

    override fun onActivityAttached(activity: Activity) {
        weakActivity = WeakReference(activity)
        reopenIfClosed()
    }

    override fun onActivityDetached() {
        weakActivity.get()?.let { onActivityFinishing(it) }
        weakActivity.clear()
    }

    override fun onEngineDetached() {
        if (disposed) return
        disposed = true
        weakActivity.clear()
        channel.setMethodCallHandler(null)
        sessionObserver.dispose()
        try {
            equalizer?.release()
        } catch (_: Exception) {}
        equalizer = null
        if (currentBridge === this) {
            currentBridge = null
            DMusicWidgetPlaybackState.endSession(appContext, sessionGeneration)
        }
        dartReady = false
        controlsReady = false
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val generation = call.argument<Number>("generation")?.toLong()
        when (call.method) {
            "openPlaybackSession" -> {
                reopenIfClosed()
                result.success(mapOf("generation" to sessionGeneration))
            }
            "connectPlaybackSession" -> {
                dartReady = true
                result.success(mapOf(
                    "generation" to sessionGeneration,
                    "closed" to DMusicWidgetPlaybackState.closed,
                ))
            }
            "checkPendingAction" -> {
                // Restoration completes even if an exit closed its epoch while
                // Dart was loading. A later explicit reopen needs no new handshake.
                controlsReady = true
                if (!accepts(sessionGeneration)) {
                    result.success(null)
                    return
                }
                // Dart installs callbacks before connect, then restores playback
                // before opening this control gate.
                result.success(pollCurrentAction())
                val expectedGeneration = sessionGeneration
                mainHandler.post {
                    if (!accepts(expectedGeneration)) return@post
                    while (true) {
                        val action = pollCurrentAction() ?: break
                        enqueueOrDispatch(action)
                    }
                }
            }
            "updateWidget" -> {
                if (generation == null || !accepts(generation)) {
                    result.success(false)
                    return
                }
                // The actual MediaSession exclusively publishes playing state.
                DMusicAppWidgetProvider.updateAllWidgets(
                    context = appContext,
                    title = call.argument<String>("title"),
                    artist = call.argument<String>("artist"),
                    progress = call.argument<String>("progress"),
                    isFavorite = call.argument<Boolean>("isFavorite"),
                    playMode = call.argument<String>("playMode"),
                    quality = call.argument<String>("quality"),
                    coverPath = call.argument<String>("coverPath"),
                )
                result.success(true)
            }
            "mediaSessionActive" -> {
                val active = call.argument<Boolean>("active") == true
                if (generation == null || !owns(generation) ||
                    (active && !accepts(generation))) {
                    result.success(false)
                    return
                }
                sessionObserver.setActive(active)
                result.success(true)
            }
            "beginPlaybackExit" -> {
                if (generation == null || !owns(generation)) {
                    result.success(false)
                    return
                }
                // Dart pauses/saves or stops the official AudioService. Native
                // teardown only closes its matching widget epoch and observer.
                val closed = DMusicWidgetPlaybackState.endSession(appContext, generation)
                sessionObserver.setActive(false)
                result.success(closed)
            }
            "stopPlaybackService" -> {
                if (generation == null || !owns(generation)) {
                    result.success(false)
                    return
                }
                // An ordinary stop is reusable by the attached UI. Explicit
                // exit already closed its epoch through beginPlaybackExit.
                DMusicAppWidgetProvider.updateAllWidgets(appContext, isPlaying = false)
                sessionObserver.setActive(false)
                result.success(true)
            }
            "widgetHeartbeat" -> result.success(generation != null && accepts(generation))
            "openFolder" -> result.success(openFolder(call.argument<String>("path") ?: ""))
            "setEqualizerBands" -> setEqualizerBands(call, result)
            "openSystemEqualizer" -> result.success(openSystemEqualizer())
            else -> result.notImplemented()
        }
    }

    private fun getOrCreateEqualizer(): Equalizer? {
        if (equalizer == null) {
            try {
                equalizer = Equalizer(0, 0).apply { enabled = true }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return equalizer
    }

    private fun setEqualizerBands(call: MethodCall, result: MethodChannel.Result) {
        val rawGains = call.argument<List<*>>("gains") ?: emptyList<Any>()
        val gains = rawGains.mapNotNull { (it as? Number)?.toDouble() }
        val eq = getOrCreateEqualizer()
        if (eq != null && gains.isNotEmpty()) {
            try {
                val numBands = eq.numberOfBands.toInt()
                val range = eq.bandLevelRange
                val minLevel = range[0]
                val maxLevel = range[1]
                val maxGainIndex = (gains.size - 1).coerceAtLeast(1).toDouble()
                for (i in 0 until numBands) {
                    val uiIndex = (i * maxGainIndex / (numBands - 1).coerceAtLeast(1)).roundToInt().coerceIn(0, gains.size - 1)
                    val gainDb = gains[uiIndex]
                    val millibels = (gainDb * 100).toInt().coerceIn(minLevel.toInt(), maxLevel.toInt()).toShort()
                    eq.setBandLevel(i.toShort(), millibels)
                }
                result.success(true)
            } catch (_: Exception) {
                result.success(false)
            }
        } else {
            result.success(false)
        }
    }

    private fun openSystemEqualizer(): Boolean = try {
        val intent = Intent(AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL).apply {
            putExtra(AudioEffect.EXTRA_PACKAGE_NAME, appContext.packageName)
            putExtra(AudioEffect.EXTRA_CONTENT_TYPE, AudioEffect.CONTENT_TYPE_MUSIC)
            putExtra(AudioEffect.EXTRA_AUDIO_SESSION, 0)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        if (intent.resolveActivity(appContext.packageManager) != null) {
            (weakActivity.get() ?: appContext).startActivity(intent)
            true
        } else {
            false
        }
    } catch (_: Exception) {
        false
    }
    private fun openFolder(folderPath: String): Boolean {
        val cleanPath = folderPath.trim()
        if (cleanPath.isNotEmpty()) {
            val file = File(cleanPath)
            val dir = if (file.isDirectory) file else file.parentFile
            if (dir != null && dir.exists()) {
                // 1. 优先尝试系统 DocumentsUI 准确定位到目标文件夹
                try {
                    val relativePath = dir.absolutePath
                        .replace(Regex("^/storage/emulated/0/"), "")
                        .replace(Regex("^/sdcard/"), "")
                    val documentUri = android.provider.DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents",
                        "primary:$relativePath"
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(documentUri, "vnd.android.document/directory")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                        putExtra(android.provider.DocumentsContract.EXTRA_INITIAL_URI, documentUri)
                    }
                    if (intent.resolveActivity(appContext.packageManager) != null) {
                        (weakActivity.get() ?: appContext).startActivity(intent)
                        return true
                    }
                } catch (_: Exception) {}

                // 2. 尝试通用 ACTION_VIEW 针对文件夹
                try {
                    val intent = Intent("android.provider.action.BROWSE").apply {
                        data = android.provider.DocumentsContract.buildRootUri("com.android.externalstorage.documents", "primary")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    if (intent.resolveActivity(appContext.packageManager) != null) {
                        (weakActivity.get() ?: appContext).startActivity(intent)
                        return true
                    }
                } catch (_: Exception) {}
            }
        }

        // 3. 回退：定向唤起手机官方系统自带的文件管理应用
        val systemFileManagerPackages = listOf(
            "com.android.fileexplorer",            // 小米 / Redmi (MIUI & HyperOS)
            "com.mi.android.globalFileexplorer",   // 小米国际版
            "com.huawei.hidisk",                   // 华为 (HarmonyOS & EMUI)
            "com.hihonor.filemanager",             // 荣耀 (MagicOS)
            "com.coloros.filemanager",             // OPPO / 一加 / 真我 (ColorOS)
            "com.oplus.filemanager",               // OPPO 新版
            "com.vivo.filemanager",                // vivo / iQOO (OriginOS)
            "com.sec.android.app.myfiles",         // 三星 (One UI)
            "com.google.android.apps.nbu.files",   // Google Files (原生)
            "com.google.android.documentsui",      // 原生系统文件
            "com.android.documentsui"              // AOSP 系统文件
        )
        for (pkg in systemFileManagerPackages) {
            try {
                val launchIntent = appContext.packageManager.getLaunchIntentForPackage(pkg)
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    (weakActivity.get() ?: appContext).startActivity(launchIntent)
                    return true
                }
            } catch (_: Exception) {}
        }
        return false
    }

}
