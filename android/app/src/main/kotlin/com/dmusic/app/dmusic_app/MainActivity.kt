package com.dmusic.app.dmusic_app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.media.audiofx.AudioEffect
import android.media.audiofx.Equalizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.dmusic.app/widget"
        @Volatile
        var methodChannel: MethodChannel? = null
        @Volatile
        private var dartReady = false
        private val pendingWidgetActions = ConcurrentLinkedQueue<String>()

        fun sendWidgetAction(action: String) {
            val channel = methodChannel
            if (channel != null && dartReady) {
                channel.invokeMethod("onWidgetAction", mapOf("action" to action))
            } else {
                pendingWidgetActions.offer(action)
            }
        }
    }

    private var localMethodChannel: MethodChannel? = null
    private var equalizer: Equalizer? = null

    private fun getOrCreateEqualizer(): Equalizer? {
        if (equalizer == null) {
            try {
                equalizer = Equalizer(0, 0).apply {
                    enabled = true
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return equalizer
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val action = intent?.getStringExtra("widget_action")
        if (!action.isNullOrEmpty()) {
            sendWidgetAction(action)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        localMethodChannel = channel
        methodChannel = channel
        dartReady = false
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    val progress = call.argument<String>("progress")
                    val isPlaying = call.argument<Boolean>("isPlaying")
                    val isFavorite = call.argument<Boolean>("isFavorite")
                    val playMode = call.argument<String>("playMode")
                    val quality = call.argument<String>("quality")
                    val coverPath = call.argument<String>("coverPath")
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    val durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L

                    DMusicAppWidgetProvider.updateAllWidgets(
                        context = this,
                        title = title,
                        artist = artist,
                        progress = progress,
                        isPlaying = isPlaying,
                        isFavorite = isFavorite,
                        playMode = playMode,
                        quality = quality,
                        coverPath = coverPath
                    )

                    // AUD-03: 仅当真正播放或前台服务已在运行时才更新服务，杜绝无播放时后台冷态盲目拉起前台服务
                    if (isPlaying == true || (DMusicPlaybackService.isServiceRunning && title != "DMusic 发烧播放器")) {
                        DMusicPlaybackService.startOrUpdateService(
                            context = this,
                            title = title,
                            artist = artist,
                            isPlaying = isPlaying ?: false,
                            quality = quality,
                            coverPath = coverPath,
                            positionMs = positionMs,
                            durationMs = durationMs
                        )
                    } else if (isPlaying == false && title == "DMusic 发烧播放器" && DMusicPlaybackService.isServiceRunning) {
                        DMusicPlaybackService.stopService(this)
                    }

                    result.success(true)
                }
                "stopPlaybackService" -> {
                    DMusicPlaybackService.stopService(this)
                    DMusicAppWidgetProvider.updateAllWidgets(this, isPlaying = false)
                    result.success(true)
                }
                "checkPendingAction" -> {
                    // Flutter 调用前已安装回调，之后才可直接投递控制命令。
                    dartReady = true
                    val firstAction = pendingWidgetActions.poll()
                    // AUD-06: 队列中若存在多条冷启动指令，首条返回，其余逐条通过通道分发，杜绝指令丢失
                    while (true) {
                        val next = pendingWidgetActions.poll() ?: break
                        methodChannel?.invokeMethod("onWidgetAction", mapOf("action" to next))
                    }
                    result.success(firstAction)
                }
                "openFolder" -> {
                    val folderPath = call.argument<String>("path") ?: ""
                    val success = openFolder(folderPath)
                    result.success(success)
                }
                "setEqualizerBands" -> {
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
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "openSystemEqualizer" -> {
                    try {
                        val intent = Intent(AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL).apply {
                            putExtra(AudioEffect.EXTRA_PACKAGE_NAME, packageName)
                            putExtra(AudioEffect.EXTRA_CONTENT_TYPE, AudioEffect.CONTENT_TYPE_MUSIC)
                            putExtra(AudioEffect.EXTRA_AUDIO_SESSION, 0)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        if (intent.resolveActivity(packageManager) != null) {
                            startActivity(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

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
                    if (intent.resolveActivity(packageManager) != null) {
                        startActivity(intent)
                        return true
                    }
                } catch (_: Exception) {}

                // 2. 尝试通用 ACTION_VIEW 针对文件夹
                try {
                    val intent = Intent("android.provider.action.BROWSE").apply {
                        data = android.provider.DocumentsContract.buildRootUri("com.android.externalstorage.documents", "primary")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    if (intent.resolveActivity(packageManager) != null) {
                        startActivity(intent)
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
                val launchIntent = packageManager.getLaunchIntentForPackage(pkg)
                if (launchIntent != null) {
                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(launchIntent)
                    return true
                }
            } catch (_: Exception) {}
        }
        return false
    }

    override fun onDestroy() {
        // 允许后台音乐在退出界面时持续播放，不强杀后台服务
        if (methodChannel === localMethodChannel) {
            methodChannel = null
            dartReady = false
        }
        localMethodChannel = null
        try {
            equalizer?.release()
            equalizer = null
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
