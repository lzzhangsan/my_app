package com.example.change_copy2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager
import android.webkit.WebView
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.ReturnCode

class MainActivity: FlutterActivity() {
    private val CHANNEL = "media_auto_import"
    private val PERF_CHANNEL = "performance_service"
    private var lastCpuTime: Long = 0
    private var lastCpuSampleTime: Long = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        persistWebCookies()

        // 性能监控：真实内存与 CPU 数据
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERF_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMemoryInfo" -> {
                    try {
                        val runtime = Runtime.getRuntime()
                        val used = runtime.totalMemory() - runtime.freeMemory()
                        val maxHeap = runtime.maxMemory()
                        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val memInfo = ActivityManager.MemoryInfo()
                        activityManager.getMemoryInfo(memInfo)
                        val totalDevice = memInfo.totalMem
                        val availDevice = memInfo.availMem
                        val usedDevice = totalDevice - availDevice
                        val pss = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                            val pid = android.os.Process.myPid()
                            val pids = intArrayOf(pid)
                            val memoryInfo = activityManager.getProcessMemoryInfo(pids)
                            if (memoryInfo != null && memoryInfo.isNotEmpty()) {
                                memoryInfo[0].totalPss * 1024L
                            } else used
                        } else used
                        val percentage = if (totalDevice > 0) (pss.toDouble() / totalDevice).coerceIn(0.0, 1.0) else 0.1
                        result.success(mapOf(
                            "used" to pss,
                            "total" to totalDevice,
                            "percentage" to percentage,
                            "heapUsed" to used,
                            "heapMax" to maxHeap
                        ))
                    } catch (e: Exception) {
                        result.error("MEMORY_ERROR", e.message, null)
                    }
                }
                "getCpuUsage" -> {
                    try {
                        val reader = RandomAccessFile("/proc/self/stat", "r")
                        val stat = reader.readLine()
                        reader.close()
                        val endOfComm = stat.lastIndexOf(')')
                        val afterComm = stat.substring(endOfComm + 1).trim().split(Regex("\\s+"))
                        val utime = afterComm.getOrNull(11)?.toLongOrNull() ?: 0L
                        val stime = afterComm.getOrNull(12)?.toLongOrNull() ?: 0L
                        val cpuTime = utime + stime
                        val now = System.currentTimeMillis()
                        val elapsedMs = now - lastCpuSampleTime
                        val usage = if (lastCpuSampleTime > 0 && elapsedMs > 300) {
                            val jiffiesPerSec = 100.0
                            val cpuDeltaSec = (cpuTime - lastCpuTime) / jiffiesPerSec
                            val elapsedSec = elapsedMs / 1000.0
                            if (elapsedSec > 0) (cpuDeltaSec / elapsedSec).coerceIn(0.0, 1.0) else 0.1
                        } else 0.1
                        lastCpuTime = cpuTime
                        lastCpuSampleTime = now
                        result.success(usage)
                    } catch (e: Exception) {
                        result.success(0.1)
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        // 创建通知渠道
        createNotificationChannel()
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "createNotificationChannel" -> {
                    createNotificationChannel()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Expose cookies from WebView via platform channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "browser_cookies").setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url")
                    if (url == null || url.isEmpty()) {
                        result.success("")
                    } else {
                        try {
                            val cookie = CookieManager.getInstance().getCookie(url)
                            result.success(cookie ?: "")
                        } catch (e: Exception) {
                            result.success("")
                        }
                    }
                }
                "flushCookies" -> {
                    try {
                        persistWebCookies()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("COOKIE_FLUSH_ERROR", e.toString(), null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "media_muxer").setMethodCallHandler { call, result ->
            if (call.method == "probeDurationMs") {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.success(0L)
                    return@setMethodCallHandler
                }
                Thread {
                    val retriever = MediaMetadataRetriever()
                    val duration = try {
                        retriever.setDataSource(path)
                        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                    } catch (_: Exception) {
                        0L
                    } finally {
                        retriever.release()
                    }
                    runOnUiThread { result.success(duration) }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "remuxMp4") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Missing remux path", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        remuxToMp4(inputPath, outputPath)
                        runOnUiThread { result.success(true) }
                    } catch (e: Exception) {
                        File(outputPath).delete()
                        runOnUiThread { result.error("REMUX_FAILED", e.message, null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "remuxSingleTrackMp4") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val trackType = call.argument<String>("trackType") ?: "video"
                if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Missing remux path", null)
                    return@setMethodCallHandler
                }
                val prefix = if (trackType == "audio") "audio/" else "video/"
                Thread {
                    try {
                        remuxSingleTrackToMp4(inputPath, outputPath, prefix)
                        runOnUiThread { result.success(true) }
                    } catch (e: Exception) {
                        File(outputPath).delete()
                        runOnUiThread { result.error("REMUX_FAILED", e.toString(), null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "ffmpegRemuxCopy") {
                val videoPath = call.argument<String>("videoPath")
                val audioPath = call.argument<String>("audioPath")
                val outputPath = call.argument<String>("outputPath")
                val videoOnly = call.argument<Boolean>("videoOnly") ?: false
                if (videoPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Missing ffmpeg remux path", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        ffmpegRemuxCopy(
                            videoPath = videoPath,
                            audioPath = audioPath,
                            outputPath = outputPath,
                            videoOnly = videoOnly,
                        )
                        runOnUiThread { result.success(true) }
                    } catch (t: Throwable) {
                        // Must catch Error too (e.g. NoClassDefFoundError); Exception-only
                        // lets linkage failures kill the whole process.
                        File(outputPath).delete()
                        android.util.Log.e(
                            "X_HLS_MUX_NATIVE",
                            "ffmpegRemuxCopy failed: ${t.message}",
                            t,
                        )
                        runOnUiThread {
                            result.error("FFMPEG_REMUX_FAILED", t.message, null)
                        }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method != "muxMp4") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val videoPath = call.argument<String>("videoPath")
            val audioPath = call.argument<String>("audioPath")
            val outputPath = call.argument<String>("outputPath")
            if (videoPath.isNullOrBlank() || audioPath.isNullOrBlank() || outputPath.isNullOrBlank()) {
                result.error("INVALID_ARGUMENT", "Missing DASH track path", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    muxMp4Tracks(videoPath, audioPath, outputPath)
                    runOnUiThread { result.success(true) }
                } catch (e: Exception) {
                    File(outputPath).delete()
                        runOnUiThread { result.error("MUX_FAILED", e.toString(), null) }
                }
            }.start()
        }

        // 向 WebView 注入真实 MotionEvent（JS 合成触摸 isTrusted=false，多数信息流会忽略）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "webview_touch")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "flick" -> {
                        val axisHint = call.argument<String>("axisHint") ?: "up"
                        val distanceFraction =
                            (call.argument<Number>("distanceFraction")?.toDouble() ?: 0.32)
                                .coerceIn(0.12, 0.85)
                        val durationMs =
                            (call.argument<Number>("durationMs")?.toInt() ?: 260)
                                .coerceIn(120, 900)
                        val fromXArg = call.argument<Number>("fromX")?.toDouble()
                        val fromYArg = call.argument<Number>("fromY")?.toDouble()
                        val toXArg = call.argument<Number>("toX")?.toDouble()
                        val toYArg = call.argument<Number>("toY")?.toDouble()
                        runOnUiThread {
                            try {
                                val webView = findWebView(window.decorView)
                                if (webView == null || webView.width <= 0 || webView.height <= 0) {
                                    result.error("NO_WEBVIEW", "WebView not found or not laid out", null)
                                    return@runOnUiThread
                                }
                                val w = webView.width.toFloat()
                                val h = webView.height.toFloat()
                                val norms = computeFlickNorms(
                                    axisHint,
                                    distanceFraction,
                                    fromXArg,
                                    fromYArg,
                                    toXArg,
                                    toYArg,
                                )
                                fun px(norm: Double, size: Float): Float =
                                    (norm.toFloat() * size).coerceIn(2f, size - 2f)
                                injectFlick(
                                    target = webView,
                                    fromX = px(norms.a, w),
                                    fromY = px(norms.b, h),
                                    toX = px(norms.c, w),
                                    toY = px(norms.d, h),
                                    durationMs = durationMs.toLong(),
                                    linear = false,
                                ) { ok ->
                                    result.success(ok)
                                }
                            } catch (e: Exception) {
                                result.error("FLICK_FAILED", e.message, null)
                            }
                        }
                    }
                    // 整屏高度 fling：用 Display/Window 屏高算起止点，再经 locationOnScreen
                    // 换算成 WebView 局部坐标注入（避免仅按 WebView 高度比例导致 dy/速度不够被 Reels 弹回）
                    "fullScreenVerticalFling" -> {
                        val direction = call.argument<String>("direction") ?: "up"
                        val xNorm =
                            (call.argument<Number>("xNorm")?.toDouble() ?: 0.5)
                                .coerceIn(0.22, 0.78)
                        val durationMs =
                            (call.argument<Number>("durationMs")?.toInt() ?: 180)
                                .coerceIn(140, 240)
                        val fromScreenY =
                            (call.argument<Number>("fromScreenY")?.toDouble() ?: 0.90)
                                .coerceIn(0.78, 0.96)
                        val toScreenY =
                            (call.argument<Number>("toScreenY")?.toDouble() ?: 0.08)
                                .coerceIn(0.04, 0.18)
                        runOnUiThread {
                            try {
                                val webView = findWebView(window.decorView)
                                if (webView == null || webView.width <= 0 || webView.height <= 0) {
                                    result.error("NO_WEBVIEW", "WebView not found or not laid out", null)
                                    return@runOnUiThread
                                }
                                val (screenW, screenH) = displaySizePx()
                                if (screenW <= 0 || screenH <= 0) {
                                    result.error("NO_DISPLAY", "Display metrics unavailable", null)
                                    return@runOnUiThread
                                }
                                val loc = IntArray(2)
                                webView.getLocationOnScreen(loc)
                                val up = direction != "down"
                                val screenFromY =
                                    ((if (up) fromScreenY else toScreenY) * screenH).toFloat()
                                val screenToY =
                                    ((if (up) toScreenY else fromScreenY) * screenH).toFloat()
                                val screenX = (xNorm * screenW).toFloat()

                                var fromX = screenX - loc[0]
                                var fromY = screenFromY - loc[1]
                                var toX = screenX - loc[0]
                                var toY = screenToY - loc[1]

                                val w = webView.width.toFloat()
                                val h = webView.height.toFloat()
                                fromX = fromX.coerceIn(2f, w - 2f)
                                toX = toX.coerceIn(2f, w - 2f)
                                fromY = fromY.coerceIn(2f, h - 2f)
                                toY = toY.coerceIn(2f, h - 2f)

                                // clamp 后若 dy 仍远小于屏高，强制吃满 WebView 竖向（等价整屏翻页）
                                val minDy = screenH * 0.55f
                                if (kotlin.math.abs(toY - fromY) < minDy) {
                                    if (up) {
                                        fromY = h - 2f
                                        toY = 2f
                                    } else {
                                        fromY = 2f
                                        toY = h - 2f
                                    }
                                }

                                android.util.Log.i(
                                    "webview_touch",
                                    "fullScreenVerticalFling dir=$direction " +
                                        "screen=${screenW}x$screenH loc=${loc[0]},${loc[1]} " +
                                        "wv=${w.toInt()}x${h.toInt()} " +
                                        "from=($fromX,$fromY) to=($toX,$toY) " +
                                        "dy=${kotlin.math.abs(toY - fromY)} dur=${durationMs}ms",
                                )

                                injectFlick(
                                    target = webView,
                                    fromX = fromX,
                                    fromY = fromY,
                                    toX = toX,
                                    toY = toY,
                                    durationMs = durationMs.toLong(),
                                    linear = true,
                                ) { ok ->
                                    result.success(
                                        mapOf(
                                            "ok" to ok,
                                            "screenH" to screenH,
                                            "webViewH" to webView.height,
                                            "dy" to kotlin.math.abs(toY - fromY).toDouble(),
                                            "fromY" to fromY.toDouble(),
                                            "toY" to toY.toDouble(),
                                            "locY" to loc[1],
                                        ),
                                    )
                                }
                            } catch (e: Exception) {
                                result.error("FULLSCREEN_FLING_FAILED", e.message, null)
                            }
                        }
                    }
                    "tap" -> {
                        val xNorm = (call.argument<Number>("x")?.toDouble() ?: 0.5)
                            .coerceIn(0.02, 0.98)
                        val yNorm = (call.argument<Number>("y")?.toDouble() ?: 0.5)
                            .coerceIn(0.02, 0.98)
                        val holdMs = (call.argument<Number>("holdMs")?.toInt() ?: 70)
                            .coerceIn(40, 400)
                        runOnUiThread {
                            try {
                                val webView = findWebView(window.decorView)
                                if (webView == null || webView.width <= 0 || webView.height <= 0) {
                                    result.error("NO_WEBVIEW", "WebView not found or not laid out", null)
                                    return@runOnUiThread
                                }
                                val x = (xNorm * webView.width).toFloat()
                                    .coerceIn(2f, webView.width - 2f)
                                val y = (yNorm * webView.height).toFloat()
                                    .coerceIn(2f, webView.height - 2f)
                                injectTap(
                                    target = webView,
                                    x = x,
                                    y = y,
                                    holdMs = holdMs.toLong(),
                                ) { ok -> result.success(ok) }
                            } catch (e: Exception) {
                                result.error("TAP_FAILED", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun computeFlickNorms(
        axisHint: String,
        distanceFraction: Double,
        fromXArg: Double?,
        fromYArg: Double?,
        toXArg: Double?,
        toYArg: Double?,
    ): Quadruple {
        if (fromXArg != null && fromYArg != null && toXArg != null && toYArg != null) {
            return Quadruple(fromXArg, fromYArg, toXArg, toYArg)
        }
        val f = distanceFraction
        return when (axisHint) {
            "down" -> Quadruple(0.5, 0.38, 0.5, (0.38 + f).coerceAtMost(0.92))
            "left" -> Quadruple(0.72, 0.5, (0.72 - f).coerceAtLeast(0.06), 0.5)
            "right" -> Quadruple(0.28, 0.5, (0.28 + f).coerceAtMost(0.94), 0.5)
            else -> Quadruple(0.5, 0.62, 0.5, (0.62 - f).coerceAtLeast(0.08)) // up
        }
    }

    private data class Quadruple(
        val a: Double,
        val b: Double,
        val c: Double,
        val d: Double,
    )

    private fun findWebView(root: View?): WebView? {
        if (root == null) return null
        val found = ArrayList<WebView>()
        fun walk(view: View?) {
            if (view == null) return
            if (view is WebView) {
                found.add(view)
                return
            }
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) {
                    walk(view.getChildAt(i))
                }
            }
        }
        walk(root)
        // 优先可见且面积最大的 WebView（避免点到隐藏/预加载实例）
        return found
            .filter { it.isShown && it.width > 0 && it.height > 0 }
            .maxByOrNull { it.width * it.height }
            ?: found.maxByOrNull { it.width * it.height }
    }

    /** 物理屏（或当前窗口）宽高，用于整屏 fling 的屏坐标基准。 */
    private fun displaySizePx(): Pair<Int, Int> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            @Suppress("DEPRECATION")
            val metrics = resources.displayMetrics
            Pair(metrics.widthPixels, metrics.heightPixels)
        }
    }

    private fun obtainTouch(
        downTime: Long,
        eventTime: Long,
        action: Int,
        x: Float,
        y: Float,
    ): MotionEvent {
        val props = arrayOf(
            MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_FINGER
            },
        )
        val coords = arrayOf(
            MotionEvent.PointerCoords().apply {
                this.x = x
                this.y = y
                pressure = 1f
                size = 1f
            },
        )
        return MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            1,
            props,
            coords,
            0,
            0,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0,
        )
    }

    private fun injectTap(
        target: View,
        x: Float,
        y: Float,
        holdMs: Long,
        onDone: (Boolean) -> Unit,
    ) {
        val handler = Handler(Looper.getMainLooper())
        val downTime = SystemClock.uptimeMillis()
        var finished = false
        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            onDone(ok)
        }
        try {
            val down = obtainTouch(downTime, downTime, MotionEvent.ACTION_DOWN, x, y)
            try {
                target.dispatchTouchEvent(down)
            } finally {
                down.recycle()
            }
            handler.postDelayed({
                if (finished) return@postDelayed
                val upTime = SystemClock.uptimeMillis()
                val up = obtainTouch(downTime, upTime, MotionEvent.ACTION_UP, x, y)
                try {
                    target.dispatchTouchEvent(up)
                } finally {
                    up.recycle()
                }
                finish(true)
            }, holdMs)
            handler.postDelayed({ finish(true) }, holdMs + 120L)
        } catch (e: Exception) {
            finish(false)
        }
    }

    private fun injectFlick(
        target: View,
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        durationMs: Long,
        linear: Boolean = false,
        onDone: (Boolean) -> Unit,
    ) {
        val handler = Handler(Looper.getMainLooper())
        val downTime = SystemClock.uptimeMillis()
        // 线性整屏甩：更密 MOVE，给 VelocityTracker 稳定高速度；普通 flick 仍用原节奏
        val steps = if (linear) {
            maxOf(12, minOf(24, (durationMs / 12L).toInt()))
        } else {
            maxOf(8, minOf(20, (durationMs / 16L).toInt()))
        }
        var finished = false

        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            onDone(ok)
        }

        fun dispatch(action: Int, x: Float, y: Float, eventTime: Long) {
            val ev = obtainTouch(downTime, eventTime, action, x, y)
            try {
                target.dispatchTouchEvent(ev)
            } finally {
                ev.recycle()
            }
        }

        try {
            dispatch(MotionEvent.ACTION_DOWN, fromX, fromY, downTime)
            for (i in 1..steps) {
                val step = i
                handler.postDelayed({
                    if (finished) return@postDelayed
                    val t = step.toFloat() / steps
                    // linear：恒速高 velocity（Reels fling 判定）；否则 ease-out 贴近轻扫
                    val progress = if (linear) {
                        t
                    } else {
                        1f - (1f - t) * (1f - t) * (1f - t)
                    }
                    val x = fromX + (toX - fromX) * progress
                    val y = fromY + (toY - fromY) * progress
                    val eventTime = downTime + durationMs * step / steps
                    if (step < steps) {
                        dispatch(MotionEvent.ACTION_MOVE, x, y, eventTime)
                    } else {
                        dispatch(MotionEvent.ACTION_MOVE, toX, toY, eventTime)
                        handler.postDelayed({
                            if (finished) return@postDelayed
                            dispatch(
                                MotionEvent.ACTION_UP,
                                toX,
                                toY,
                                eventTime + 12,
                            )
                            finish(true)
                        }, 12L)
                    }
                }, durationMs * step / steps)
            }
            // 兜底：避免 MethodChannel 永久挂起
            handler.postDelayed({ finish(true) }, durationMs + 160L)
        } catch (e: Exception) {
            finish(false)
        }
    }

    private fun persistWebCookies() {
        val manager = CookieManager.getInstance()
        manager.setAcceptCookie(true)
        // 确保当前 WebView 实例接受第三方 cookie（Google 登录常跨 accounts.google.com）
        try {
            val decor = window?.decorView
            if (decor != null) {
                findWebView(decor)?.let { webView ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        manager.setAcceptThirdPartyCookies(webView, true)
                    }
                }
            }
        } catch (_: Exception) {
            // WebView 尚未挂载时忽略
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            manager.flush()
        }
    }

    override fun onPause() {
        persistWebCookies()
        super.onPause()
    }

    override fun onStop() {
        persistWebCookies()
        super.onStop()
    }

    override fun onDestroy() {
        persistWebCookies()
        super.onDestroy()
    }

    private fun findTrack(extractor: MediaExtractor, prefix: String): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith(prefix)) return index
        }
        return -1
    }

    /** Copy only MediaMuxer-safe keys; fMP4 HLS formats often carry keys that break addTrack. */
    private fun muxerSafeFormat(source: MediaFormat): MediaFormat {
        val mime = source.getString(MediaFormat.KEY_MIME)
            ?: throw IllegalStateException("Track missing KEY_MIME")
        val out = MediaFormat()
        out.setString(MediaFormat.KEY_MIME, mime)
        val intKeys = arrayOf(
            MediaFormat.KEY_WIDTH,
            MediaFormat.KEY_HEIGHT,
            MediaFormat.KEY_BIT_RATE,
            MediaFormat.KEY_FRAME_RATE,
            MediaFormat.KEY_I_FRAME_INTERVAL,
            MediaFormat.KEY_CHANNEL_COUNT,
            MediaFormat.KEY_SAMPLE_RATE,
            MediaFormat.KEY_MAX_INPUT_SIZE,
            MediaFormat.KEY_AAC_PROFILE,
            MediaFormat.KEY_PROFILE,
            MediaFormat.KEY_LEVEL,
            MediaFormat.KEY_ROTATION,
        )
        for (key in intKeys) {
            if (source.containsKey(key)) {
                try {
                    out.setInteger(key, source.getInteger(key))
                } catch (_: Exception) {
                    try {
                        out.setLong(key, source.getLong(key))
                    } catch (_: Exception) {
                    }
                }
            }
        }
        if (source.containsKey(MediaFormat.KEY_DURATION)) {
            try {
                out.setLong(MediaFormat.KEY_DURATION, source.getLong(MediaFormat.KEY_DURATION))
            } catch (_: Exception) {
                try {
                    out.setInteger(
                        MediaFormat.KEY_DURATION,
                        source.getInteger(MediaFormat.KEY_DURATION),
                    )
                } catch (_: Exception) {
                }
            }
        }
        // CSD buffers are required for H.264/AAC progressive MP4.
        for (csd in arrayOf("csd-0", "csd-1", "csd-2")) {
            if (!source.containsKey(csd)) continue
            val buf = source.getByteBuffer(csd) ?: continue
            val copy = ByteBuffer.allocate(buf.remaining())
            copy.put(buf.duplicate())
            copy.flip()
            out.setByteBuffer(csd, copy)
        }
        return out
    }

    private fun allocateSampleBuffer(extractor: MediaExtractor, sourceTrack: Int): ByteBuffer {
        val format = extractor.getTrackFormat(sourceTrack)
        var maxInput = 2 * 1024 * 1024
        if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            try {
                maxInput = format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE).coerceAtLeast(maxInput)
            } catch (_: Exception) {
            }
        }
        // High-bitrate X long-form I-frames can exceed the advertised max; pad generously.
        return ByteBuffer.allocateDirect((maxInput + 256 * 1024).coerceAtMost(16 * 1024 * 1024))
    }

    private data class WriteTrackResult(
        val wrote: Int,
        val lastPtsUs: Long,
        val ptsForcedMono: Int,
        val resumePasses: Int = 1,
        val payloadBytes: Long = 0L,
    )

    /**
     * Probe container duration (µs). For long X fMP4 concat, MediaExtractor often EOS
     * early while MetadataRetriever / mehd still reports the full length.
     */
    private fun probeContainerDurationUs(path: String): Long {
        val fromRetriever =
            try {
                val retriever = android.media.MediaMetadataRetriever()
                try {
                    retriever.setDataSource(path)
                    val ms =
                        retriever
                            .extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_DURATION,
                            )
                            ?.toLongOrNull()
                    if (ms != null && ms > 0L) ms * 1000L else -1L
                } finally {
                    try {
                        retriever.release()
                    } catch (_: Exception) {
                    }
                }
            } catch (_: Exception) {
                -1L
            }
        val fromMehd = probeMehdDurationUs(path)
        return when {
            fromRetriever > 0L && fromMehd > 0L -> maxOf(fromRetriever, fromMehd)
            fromRetriever > 0L -> fromRetriever
            else -> fromMehd
        }
    }

    /** Read mvhd.timescale + mehd.fragment_duration from a CMAF/fMP4 init segment. */
    private fun probeMehdDurationUs(path: String): Long {
        return try {
            java.io.RandomAccessFile(path, "r").use { raf ->
                val fileSize = raf.length()
                var offset = 0L
                var mvhdTimescale = -1L
                var mehdFragmentDuration = -1L
                while (offset + 8 <= fileSize) {
                    raf.seek(offset)
                    val size32 = raf.readInt().toLong() and 0xffffffffL
                    val typeBytes = ByteArray(4)
                    if (raf.read(typeBytes) != 4) break
                    val type = String(typeBytes, Charsets.US_ASCII)
                    var boxSize = size32
                    var header = 8L
                    if (size32 == 1L) {
                        boxSize = raf.readLong()
                        header = 16L
                    } else if (size32 == 0L) {
                        boxSize = fileSize - offset
                    }
                    if (boxSize < header) break
                    if (type == "moov") {
                        var inner = offset + header
                        val moovEnd = offset + boxSize
                        while (inner + 8 <= moovEnd) {
                            raf.seek(inner)
                            val iSize32 = raf.readInt().toLong() and 0xffffffffL
                            val iTypeBytes = ByteArray(4)
                            if (raf.read(iTypeBytes) != 4) break
                            val iType = String(iTypeBytes, Charsets.US_ASCII)
                            var iSize = iSize32
                            var iHeader = 8L
                            if (iSize32 == 1L) {
                                iSize = raf.readLong()
                                iHeader = 16L
                            } else if (iSize32 == 0L) {
                                iSize = moovEnd - inner
                            }
                            if (iSize < iHeader) break
                            if (iType == "mvhd" || iType == "mehd") {
                                raf.seek(inner + iHeader)
                                val version = raf.read()
                                raf.skipBytes(3)
                                if (iType == "mvhd") {
                                    if (version == 1) {
                                        raf.skipBytes(16) // ctime+mtime
                                        mvhdTimescale = raf.readInt().toLong() and 0xffffffffL
                                    } else {
                                        raf.skipBytes(8)
                                        mvhdTimescale = raf.readInt().toLong() and 0xffffffffL
                                    }
                                } else {
                                    mehdFragmentDuration =
                                        if (version == 1) {
                                            raf.readLong()
                                        } else {
                                            raf.readInt().toLong() and 0xffffffffL
                                        }
                                }
                            } else if (iType == "trak" || iType == "mvex") {
                                // Descend one level for mehd (mvex/mehd) — handled by scanning
                                // all direct moov children; mehd is under mvex.
                                var nested = inner + iHeader
                                val nestEnd = inner + iSize
                                while (nested + 8 <= nestEnd) {
                                    raf.seek(nested)
                                    val nSize32 = raf.readInt().toLong() and 0xffffffffL
                                    val nTypeBytes = ByteArray(4)
                                    if (raf.read(nTypeBytes) != 4) break
                                    val nType = String(nTypeBytes, Charsets.US_ASCII)
                                    var nSize = nSize32
                                    var nHeader = 8L
                                    if (nSize32 == 1L) {
                                        nSize = raf.readLong()
                                        nHeader = 16L
                                    } else if (nSize32 == 0L) {
                                        nSize = nestEnd - nested
                                    }
                                    if (nSize < nHeader) break
                                    if (nType == "mehd") {
                                        raf.seek(nested + nHeader)
                                        val version = raf.read()
                                        raf.skipBytes(3)
                                        mehdFragmentDuration =
                                            if (version == 1) {
                                                raf.readLong()
                                            } else {
                                                raf.readInt().toLong() and 0xffffffffL
                                            }
                                    }
                                    nested += nSize
                                }
                            }
                            inner += iSize
                        }
                        break
                    }
                    if (type == "mdat" || type == "moof") {
                        // Past init; no need to scan media for duration probe.
                        if (mvhdTimescale > 0L && mehdFragmentDuration >= 0L) break
                    }
                    offset += boxSize
                }
                if (mvhdTimescale > 0L && mehdFragmentDuration > 0L) {
                    (mehdFragmentDuration * 1_000_000L) / mvhdTimescale
                } else {
                    -1L
                }
            }
        } catch (_: Exception) {
            -1L
        }
    }

    /**
     * Copy one track into [muxer]. Owns MediaExtractor lifecycle.
     *
     * Android MediaExtractor frequently stops early on long CMAF/fMP4 (init + many
     * moof/mdat) even when the file is complete (ffprobe shows full duration). We
     * reopen + seek past the last raw PTS and continue until a pass writes nothing.
     */
    private fun writeTrackFromPath(
        inputPath: String,
        trackPrefix: String,
        muxer: MediaMuxer,
        targetTrack: Int,
        longFmp4Mode: String = "moof",
    ): WriteTrackResult {
        val targetDurationUs = probeContainerDurationUs(inputPath)
        val fragCount =
            try {
                scanFmp4Layout(inputPath).second.size
            } catch (_: Exception) {
                0
            }
        // Long CMAF: MediaExtractor one-shot EOS near ~8min. Prefer moof-walk with
        // explicit sample payloads (GPT: wrote=N ≠ bytes actually muxed). Never chain
        // fragment-window then moof-walk into the same MediaMuxer — that appends a second
        // timeline onto a partial first write.
        val longFmp4 =
            fragCount >= 40 &&
                (targetDurationUs >= 180_000_000L || fragCount >= 80)
        if (longFmp4 && longFmp4Mode == "fragment") {
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "writeTrack long-fMP4 fragment-window frags=$fragCount " +
                    "targetDurUs=$targetDurationUs in=$inputPath",
            )
            return writeTrackByFragmentWindows(
                inputPath = inputPath,
                trackPrefix = trackPrefix,
                muxer = muxer,
                targetTrack = targetTrack,
                firstPresentationTimeUs = -1L,
                lastPresentationTimeUs = -1L,
                lastRawSampleTimeUs = -1L,
                wrote = 0,
                ptsForcedMono = 0,
                priorPasses = 0,
            )
        }
        if (longFmp4) {
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "writeTrack long-fMP4 primary moof-walk frags=$fragCount " +
                    "targetDurUs=$targetDurationUs in=$inputPath",
            )
            val walked =
                writeTrackByMoofSampleWalk(
                    inputPath = inputPath,
                    trackPrefix = trackPrefix,
                    muxer = muxer,
                    targetTrack = targetTrack,
                )
            if (targetDurationUs <= 0L ||
                walked.lastPtsUs >= (targetDurationUs * 4L) / 5L
            ) {
                return walked
            }
            android.util.Log.w(
                "X_HLS_MUX_NATIVE",
                "moof-walk short wrotePtsUs=${walked.lastPtsUs} " +
                    "targetDurUs=$targetDurationUs payloadBytes=${walked.payloadBytes}; " +
                    "fail closed (do not append fragment-window to same muxer)",
            )
            throw IllegalStateException(
                "moof-walk short wrotePtsUs=${walked.lastPtsUs} " +
                    "targetDurUs=$targetDurationUs payloadBytes=${walked.payloadBytes}",
            )
        }

        val info = MediaCodec.BufferInfo()
        var firstPresentationTimeUs = -1L
        var lastPresentationTimeUs = -1L
        var lastRawSampleTimeUs = -1L
        var wrote = 0
        var ptsForcedMono = 0
        var resumeFromUs = 0L
        var pass = 0
        val maxPasses = 64

        while (pass < maxPasses) {
            pass++
            val extractor = MediaExtractor()
            var passWrote = 0
            var passLastRaw = lastRawSampleTimeUs
            try {
                extractor.setDataSource(inputPath)
                val sourceTrack = findTrack(extractor, trackPrefix)
                if (sourceTrack < 0) {
                    throw IllegalStateException("No $trackPrefix track in $inputPath")
                }
                extractor.selectTrack(sourceTrack)
                if (resumeFromUs > 0L) {
                    extractor.seekTo(resumeFromUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    android.util.Log.i(
                        "X_HLS_MUX_NATIVE",
                        "writeTrack resume pass=$pass seekUs=$resumeFromUs " +
                            "lastRawPtsUs=$lastRawSampleTimeUs wrote=$wrote " +
                            "targetDurUs=$targetDurationUs",
                    )
                }
                var buffer = allocateSampleBuffer(extractor, sourceTrack)
                while (true) {
                    buffer.clear()
                    var size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    if (size > buffer.capacity()) {
                        val growTo = (size + 256 * 1024).coerceAtMost(32 * 1024 * 1024)
                        if (growTo < size) {
                            throw IllegalArgumentException(
                                "Sample too large for remux buffer size=$size " +
                                    "capacity=${buffer.capacity()}",
                            )
                        }
                        buffer = ByteBuffer.allocateDirect(growTo)
                        size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                    }
                    val rawFlags = extractor.sampleFlags
                    if ((rawFlags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        if (!extractor.advance()) break
                        continue
                    }
                    if (size == 0) {
                        if (!extractor.advance()) break
                        continue
                    }
                    val sampleTimeUs = extractor.sampleTime
                    // Skip samples already committed in a previous resume pass.
                    if (sampleTimeUs >= 0L &&
                        lastRawSampleTimeUs >= 0L &&
                        sampleTimeUs <= lastRawSampleTimeUs
                    ) {
                        if (!extractor.advance()) break
                        continue
                    }
                    buffer.position(0)
                    buffer.limit(size)
                    info.offset = 0
                    info.size = size
                    if (sampleTimeUs >= 0L) {
                        if (firstPresentationTimeUs < 0L) {
                            firstPresentationTimeUs = sampleTimeUs
                            android.util.Log.i(
                                "X_HLS_MUX_NATIVE",
                                "writeTrack firstSample size=$size flags=$rawFlags " +
                                    "pts=$sampleTimeUs " +
                                    "key=${(rawFlags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0} " +
                                    "targetDurUs=$targetDurationUs",
                            )
                        }
                        var normalizedTimeUs =
                            (sampleTimeUs - firstPresentationTimeUs).coerceAtLeast(0L)
                        if (lastPresentationTimeUs >= 0L &&
                            normalizedTimeUs <= lastPresentationTimeUs
                        ) {
                            normalizedTimeUs = lastPresentationTimeUs + 1L
                            ptsForcedMono++
                        }
                        info.presentationTimeUs = normalizedTimeUs
                        lastPresentationTimeUs = normalizedTimeUs
                        lastRawSampleTimeUs = sampleTimeUs
                        passLastRaw = sampleTimeUs
                    } else {
                        val fallback =
                            if (lastPresentationTimeUs < 0L) {
                                0L
                            } else {
                                lastPresentationTimeUs + 33_333L
                            }
                        info.presentationTimeUs = fallback
                        lastPresentationTimeUs = fallback
                        if (firstPresentationTimeUs < 0L) firstPresentationTimeUs = 0L
                    }
                    info.flags = rawFlags
                    try {
                        muxer.writeSampleData(targetTrack, buffer, info)
                    } catch (e: IllegalArgumentException) {
                        throw IllegalArgumentException(
                            "writeSampleData failed wrote=$wrote size=$size " +
                                "pts=${info.presentationTimeUs} flags=${info.flags} " +
                                "cap=${buffer.capacity()}: ${e.message}",
                            e,
                        )
                    }
                    wrote++
                    passWrote++
                    if (!extractor.advance()) break
                }
            } finally {
                try {
                    extractor.release()
                } catch (_: Exception) {
                }
            }

            if (passWrote == 0) {
                // +1µs seek often clamps back onto the last consumed keyframe. If we are
                // still short of the probed duration, jump ~1s ahead and keep going.
                if (targetDurationUs > 0L &&
                    lastPresentationTimeUs >= 0L &&
                    lastPresentationTimeUs < targetDurationUs - 2_000_000L &&
                    lastRawSampleTimeUs >= 0L
                ) {
                    val farSeek = lastRawSampleTimeUs + 1_000_000L
                    if (farSeek > resumeFromUs) {
                        android.util.Log.w(
                            "X_HLS_MUX_NATIVE",
                            "writeTrack resume empty; far-seek from=$resumeFromUs to=$farSeek " +
                                "lastPtsUs=$lastPresentationTimeUs targetDurUs=$targetDurationUs",
                        )
                        resumeFromUs = farSeek
                        continue
                    }
                }
                android.util.Log.i(
                    "X_HLS_MUX_NATIVE",
                    "writeTrack resume stop pass=$pass noNewSamples wrote=$wrote " +
                        "lastPtsUs=$lastPresentationTimeUs lastRawPtsUs=$lastRawSampleTimeUs",
                )
                break
            }
            // Next pass starts just after the last raw PTS we actually wrote.
            val nextResume = passLastRaw + 1L
            if (nextResume <= resumeFromUs) {
                break
            }
            resumeFromUs = nextResume
            // If we already reached (or passed) the probed duration, stop.
            if (targetDurationUs > 0L &&
                lastPresentationTimeUs >= targetDurationUs - 1_000_000L
            ) {
                break
            }
        }

        android.util.Log.i(
            "X_HLS_MUX_NATIVE",
            "writeTrack seek-resume wrote=$wrote lastPtsUs=$lastPresentationTimeUs " +
                "lastRawPtsUs=$lastRawSampleTimeUs ptsForcedMono=$ptsForcedMono " +
                "passes=$pass targetDurUs=$targetDurationUs",
        )

        // If seek-resume still falls far short of the real CMAF duration, slice the
        // file into init+moof windows. Each short window stays within MediaExtractor's
        // reliable range (observed: full file is 1485s but one-shot EOS near ~8min).
        val needFragmentFallback =
            targetDurationUs > 0L &&
                lastPresentationTimeUs >= 0L &&
                lastPresentationTimeUs < (targetDurationUs * 4L) / 5L &&
                targetDurationUs - lastPresentationTimeUs > 5_000_000L
        if (needFragmentFallback || wrote == 0) {
            android.util.Log.w(
                "X_HLS_MUX_NATIVE",
                "writeTrack fragment-window fallback wrote=$wrote lastPtsUs=$lastPresentationTimeUs " +
                    "targetDurUs=$targetDurationUs",
            )
            return writeTrackByFragmentWindows(
                inputPath = inputPath,
                trackPrefix = trackPrefix,
                muxer = muxer,
                targetTrack = targetTrack,
                firstPresentationTimeUs = firstPresentationTimeUs,
                lastPresentationTimeUs = lastPresentationTimeUs,
                lastRawSampleTimeUs = lastRawSampleTimeUs,
                wrote = wrote,
                ptsForcedMono = ptsForcedMono,
                priorPasses = pass,
            )
        }
        if (wrote == 0) {
            throw IllegalStateException("No samples written for $trackPrefix in $inputPath")
        }
        return WriteTrackResult(
            wrote = wrote,
            lastPtsUs = lastPresentationTimeUs.coerceAtLeast(0L),
            ptsForcedMono = ptsForcedMono,
            resumePasses = pass,
        )
    }

    private data class Fmp4FragmentSpan(val start: Long, val end: Long)

    /** initEnd = byte offset after moov; fragments = each styp?/moof/mdat group. */
    private fun scanFmp4Layout(path: String): Pair<Long, List<Fmp4FragmentSpan>> {
        RandomAccessFile(path, "r").use { raf ->
            val fileSize = raf.length()
            var offset = 0L
            var initEnd = -1L
            val fragments = ArrayList<Fmp4FragmentSpan>()
            var fragStart = -1L
            while (offset + 8 <= fileSize) {
                raf.seek(offset)
                val size32 = raf.readInt().toLong() and 0xffffffffL
                val typeBytes = ByteArray(4)
                if (raf.read(typeBytes) != 4) break
                val type = String(typeBytes, Charsets.US_ASCII)
                var boxSize = size32
                var header = 8L
                if (size32 == 1L) {
                    boxSize = raf.readLong()
                    header = 16L
                } else if (size32 == 0L) {
                    boxSize = fileSize - offset
                }
                if (boxSize < header) break
                when (type) {
                    "ftyp", "free", "skip", "wide", "pdin" -> {}
                    "moov" -> initEnd = offset + boxSize
                    "styp", "sidx", "ssix" -> {
                        if (fragStart < 0L) fragStart = offset
                    }
                    "moof" -> {
                        if (fragStart < 0L) fragStart = offset
                    }
                    "mdat" -> {
                        if (fragStart < 0L) fragStart = offset
                        fragments.add(Fmp4FragmentSpan(fragStart, offset + boxSize))
                        fragStart = -1L
                    }
                }
                offset += boxSize
            }
            if (initEnd < 0L) {
                throw IllegalStateException("fMP4 missing moov init in $path")
            }
            return initEnd to fragments
        }
    }

    private fun copyFileRange(
        src: RandomAccessFile,
        out: java.io.FileOutputStream,
        start: Long,
        end: Long,
        buffer: ByteArray,
    ) {
        src.seek(start)
        var remaining = end - start
        while (remaining > 0L) {
            val n = src.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (n <= 0) throw IllegalStateException("Short read copying fMP4 window")
            out.write(buffer, 0, n)
            remaining -= n.toLong()
        }
    }

    private data class TrexDefaults(
        val duration: Long,
        val size: Long,
        val flags: Int,
    )

    /**
     * Walk every moof/trun/mdat and write samples without MediaExtractor.
     * Reliable for long X CMAF where MediaExtractor EOS near ~8 minutes.
     */
    private fun writeTrackByMoofSampleWalk(
        inputPath: String,
        trackPrefix: String,
        muxer: MediaMuxer,
        targetTrack: Int,
    ): WriteTrackResult {
        RandomAccessFile(inputPath, "r").use { raf ->
            val fileSize = raf.length()
            var timescale = 0L
            var trex = TrexDefaults(duration = 0L, size = 0L, flags = 0)
            var offset = 0L
            // First pass: moov defaults
            while (offset + 8 <= fileSize) {
                val (boxType, boxSize, header) = readBoxHeader(raf, offset, fileSize) ?: break
                if (boxType == "moov") {
                    val moovEnd = offset + boxSize
                    var inner = offset + header
                    while (inner + 8 <= moovEnd) {
                        val (iType, iSize, iHeader) = readBoxHeader(raf, inner, moovEnd) ?: break
                        when (iType) {
                            "mvex" -> {
                                var n = inner + iHeader
                                val nEnd = inner + iSize
                                while (n + 8 <= nEnd) {
                                    val (t, s, h) = readBoxHeader(raf, n, nEnd) ?: break
                                    if (t == "trex" && s >= h + 24) {
                                        raf.seek(n + h)
                                        raf.skipBytes(4) // version + flags
                                        raf.skipBytes(4) // track_ID
                                        raf.skipBytes(4) // default_sample_description_index
                                        val defDur = raf.readInt().toLong() and 0xffffffffL
                                        val defSize = raf.readInt().toLong() and 0xffffffffL
                                        val defFlags = raf.readInt()
                                        trex = TrexDefaults(defDur, defSize, defFlags)
                                        android.util.Log.i(
                                            "X_HLS_MUX_NATIVE",
                                            "moof-walk trex dur=$defDur size=$defSize flags=$defFlags",
                                        )
                                    }
                                    n += s
                                }
                            }
                            "trak" -> {
                                var n = inner + iHeader
                                val nEnd = inner + iSize
                                while (n + 8 <= nEnd) {
                                    val (t, s, h) = readBoxHeader(raf, n, nEnd) ?: break
                                    if (t == "mdia") {
                                        var m = n + h
                                        val mEnd = n + s
                                        while (m + 8 <= mEnd) {
                                            val (mt, ms, mh) = readBoxHeader(raf, m, mEnd) ?: break
                                            if (mt == "mdhd" && timescale <= 0L) {
                                                raf.seek(m + mh)
                                                val ver = raf.read()
                                                raf.skipBytes(3)
                                                if (ver == 1) {
                                                    raf.skipBytes(16)
                                                    timescale = raf.readInt().toLong() and 0xffffffffL
                                                } else {
                                                    raf.skipBytes(8)
                                                    timescale = raf.readInt().toLong() and 0xffffffffL
                                                }
                                            }
                                            m += ms
                                        }
                                    }
                                    n += s
                                }
                            }
                        }
                        inner += iSize
                    }
                    break
                }
                offset += boxSize
            }
            if (timescale <= 0L) timescale = 90_000L

            val info = MediaCodec.BufferInfo()
            var wrote = 0
            var firstPtsUs = -1L
            var lastPtsUs = -1L
            var ptsForced = 0
            var payloadBytes = 0L
            var keyframeCount = 0
            // Tombstone 17:21: MPEG4Writer thread aborted with
            //   FORTIFY: write: count 18446744073709551615 > SSIZE_MAX
            // in addLengthPrefixedSample_l — NAL length read as -1 from a DirectByteBuffer
            // that our moof-walk pool had already overwritten (writer is async).
            // Fix: never reuse the buffer passed to writeSampleData; throttle so the
            // writer can drain. Unique heap wrap pins each sample's byte[].
            var readBuf = ByteArray(256 * 1024)
            offset = 0L
            while (offset + 8 <= fileSize) {
                val (boxType, boxSize, header) = readBoxHeader(raf, offset, fileSize) ?: break
                if (boxType == "moof") {
                    val moofStart = offset
                    val moofEnd = offset + boxSize
                    var baseDecode = 0L
                    var defaultDuration = trex.duration
                    var defaultSize = trex.size
                    var defaultFlags = trex.flags
                    var dataOffset = 0L
                    var haveDataOffset = false
                    val sampleDurations = ArrayList<Long>()
                    val sampleSizes = ArrayList<Long>()
                    val sampleFlags = ArrayList<Int>()
                    val sampleCts = ArrayList<Long>()

                    var inner = offset + header
                    while (inner + 8 <= moofEnd) {
                        val (iType, iSize, iHeader) = readBoxHeader(raf, inner, moofEnd) ?: break
                        if (iType == "traf") {
                            var t = inner + iHeader
                            val tEnd = inner + iSize
                            while (t + 8 <= tEnd) {
                                val (tt, ts, th) = readBoxHeader(raf, t, tEnd) ?: break
                                when (tt) {
                                    "tfhd" -> {
                                        raf.seek(t + th)
                                        raf.skipBytes(1) // version
                                        val flags =
                                            ((raf.read() and 0xff) shl 16) or
                                                ((raf.read() and 0xff) shl 8) or
                                                (raf.read() and 0xff)
                                        raf.skipBytes(4) // track_ID
                                        if ((flags and 0x1) != 0) raf.skipBytes(8) // base_data_offset
                                        if ((flags and 0x2) != 0) raf.skipBytes(4) // sample_description_index
                                        if ((flags and 0x8) != 0) {
                                            defaultDuration = raf.readInt().toLong() and 0xffffffffL
                                        }
                                        if ((flags and 0x10) != 0) {
                                            defaultSize = raf.readInt().toLong() and 0xffffffffL
                                        }
                                        if ((flags and 0x20) != 0) {
                                            defaultFlags = raf.readInt()
                                        }
                                    }
                                    "tfdt" -> {
                                        raf.seek(t + th)
                                        val ver = raf.read()
                                        raf.skipBytes(3)
                                        baseDecode =
                                            if (ver == 1) raf.readLong()
                                            else raf.readInt().toLong() and 0xffffffffL
                                    }
                                    "trun" -> {
                                        raf.seek(t + th)
                                        val ver = raf.read()
                                        val flags =
                                            ((raf.read() and 0xff) shl 16) or
                                                ((raf.read() and 0xff) shl 8) or
                                                (raf.read() and 0xff)
                                        val sampleCount = raf.readInt()
                                        if ((flags and 0x1) != 0) {
                                            dataOffset = raf.readInt().toLong()
                                            haveDataOffset = true
                                        }
                                        if ((flags and 0x4) != 0) raf.skipBytes(4) // first_sample_flags
                                        repeat(sampleCount) {
                                            var dur = defaultDuration
                                            var size = defaultSize
                                            var sFlags = defaultFlags
                                            var cts = 0L
                                            if ((flags and 0x100) != 0) {
                                                dur = raf.readInt().toLong() and 0xffffffffL
                                            }
                                            if ((flags and 0x200) != 0) {
                                                size = raf.readInt().toLong() and 0xffffffffL
                                            }
                                            if ((flags and 0x400) != 0) {
                                                sFlags = raf.readInt()
                                            }
                                            if ((flags and 0x800) != 0) {
                                                cts = raf.readInt().toLong()
                                            }
                                            sampleDurations.add(dur)
                                            sampleSizes.add(size)
                                            sampleFlags.add(sFlags)
                                            sampleCts.add(cts)
                                        }
                                    }
                                }
                                t += ts
                            }
                        }
                        inner += iSize
                    }

                    // Locate mdat: usually the next top-level box after moof.
                    var mdatPayload = -1L
                    var look = moofEnd
                    while (look + 8 <= fileSize) {
                        val (nType, nSize, nHeader) = readBoxHeader(raf, look, fileSize) ?: break
                        if (nType == "mdat") {
                            mdatPayload = look + nHeader
                            break
                        }
                        if (nType == "moof") break
                        look += nSize
                    }
                    if (mdatPayload < 0L || sampleSizes.isEmpty()) {
                        offset += boxSize
                        continue
                    }

                    var dataPtr =
                        if (haveDataOffset) {
                            // data_offset is relative to the start of the moof box
                            moofStart + dataOffset
                        } else {
                            mdatPayload
                        }
                    var decodeTime = baseDecode
                    for (i in sampleSizes.indices) {
                        val size = sampleSizes[i].toInt()
                        if (size <= 0 || dataPtr + size > fileSize) {
                            throw IllegalStateException(
                                "moof-walk bad sample size=$size at dataPtr=$dataPtr",
                            )
                        }
                        if (readBuf.size < size) {
                            readBuf = ByteArray((size + 64 * 1024).coerceAtMost(16 * 1024 * 1024))
                        }
                        raf.seek(dataPtr)
                        raf.readFully(readBuf, 0, size)
                        dataPtr += size.toLong()
                        // Defensive copy: readBuf is reused; muxer/MPEG4Writer must not
                        // see memory that the next sample overwrites.
                        val bytes = readBuf.copyOf(size)

                        val composition = decodeTime + sampleCts[i]
                        val ptsUs = (composition * 1_000_000L) / timescale
                        if (firstPtsUs < 0L) firstPtsUs = ptsUs
                        var outPts = (ptsUs - firstPtsUs).coerceAtLeast(0L)
                        if (lastPtsUs >= 0L && outPts <= lastPtsUs) {
                            outPts = lastPtsUs + 1L
                            ptsForced++
                        }
                        val sFlags = sampleFlags[i]
                        var codecFlags = 0
                        // sample_is_non_sync_sample lives in bit 16 of sample_flags.
                        // X trex often sets this default (flags=65536) for every sample even
                        // when mdat contains IDR (NAL type 5). MediaMuxer then keeps ~1.6MB.
                        val nonSync = ((sFlags ushr 16) and 0x1) != 0
                        val idr = avcSampleHasIdr(bytes)
                        if (!nonSync || idr) {
                            codecFlags = codecFlags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                        }

                        info.offset = 0
                        info.size = size
                        info.presentationTimeUs = outPts
                        info.flags = codecFlags
                        if ((codecFlags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0) keyframeCount++
                        val wrapped = ByteBuffer.wrap(bytes)
                        val remaining = wrapped.remaining()
                        if (remaining != size) {
                            throw IllegalStateException(
                                "moof-walk buffer remaining=$remaining size=$size wrote=$wrote",
                            )
                        }
                        if (wrote < 5 || wrote % 2000 == 0) {
                            val hex =
                                bytes.take(minOf(8, bytes.size)).joinToString("") {
                                    String.format("%02x", it)
                                }
                            android.util.Log.i(
                                "X_HLS_MUX_NATIVE",
                                "moof-walk sample[$wrote] size=$size remaining=$remaining " +
                                    "ptsUs=$outPts key=${(codecFlags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0} " +
                                    "idr=$idr hex=$hex",
                            )
                        }
                        muxer.writeSampleData(targetTrack, wrapped, info)
                        wrote++
                        payloadBytes += size.toLong()
                        lastPtsUs = outPts
                        decodeTime += sampleDurations[i]
                        // Let async MPEG4Writer drain; unrestricted moof-walk was ~5k
                        // samples/s and raced the writer into SIGABRT.
                        if (wrote % 40 == 0) {
                            try {
                                Thread.sleep(4L)
                            } catch (_: InterruptedException) {
                            }
                        }
                    }
                }
                offset += boxSize
            }

            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "moof-walk done wrote=$wrote lastPtsUs=$lastPtsUs timescale=$timescale " +
                    "ptsForced=$ptsForced payloadBytes=$payloadBytes keyframes=$keyframeCount " +
                    "trackPrefix=$trackPrefix",
            )
            if (wrote == 0) {
                throw IllegalStateException("moof-walk wrote 0 samples for $inputPath")
            }
            if (trackPrefix.startsWith("video/") && keyframeCount == 0) {
                throw IllegalStateException(
                    "moof-walk wrote $wrote video samples but 0 keyframes for $inputPath",
                )
            }
            return WriteTrackResult(
                wrote = wrote,
                lastPtsUs = lastPtsUs.coerceAtLeast(0L),
                ptsForcedMono = ptsForced,
                resumePasses = 1,
                payloadBytes = payloadBytes,
            )
        }
    }

    /**
     * Length-prefixed AVC access unit → true if any NAL type 5 (IDR) is present.
     * X trex defaults often mark every sample non-sync even when IDRs exist in mdat.
     */
    private fun avcSampleHasIdr(sample: ByteArray): Boolean {
        var i = 0
        while (i + 5 <= sample.size) {
            val nalLen =
                ((sample[i].toInt() and 0xff) shl 24) or
                    ((sample[i + 1].toInt() and 0xff) shl 16) or
                    ((sample[i + 2].toInt() and 0xff) shl 8) or
                    (sample[i + 3].toInt() and 0xff)
            i += 4
            if (nalLen <= 0 || i + nalLen > sample.size) return false
            val nalType = sample[i].toInt() and 0x1f
            if (nalType == 5) return true
            i += nalLen
        }
        return false
    }

    private fun readBoxHeader(
        raf: RandomAccessFile,
        offset: Long,
        end: Long,
    ): Triple<String, Long, Long>? {
        if (offset + 8 > end) return null
        raf.seek(offset)
        val size32 = raf.readInt().toLong() and 0xffffffffL
        val typeBytes = ByteArray(4)
        if (raf.read(typeBytes) != 4) return null
        val type = String(typeBytes, Charsets.US_ASCII)
        var boxSize = size32
        var header = 8L
        if (size32 == 1L) {
            if (offset + 16 > end) return null
            boxSize = raf.readLong()
            header = 16L
        } else if (size32 == 0L) {
            boxSize = end - offset
        }
        if (boxSize < header) return null
        return Triple(type, boxSize, header)
    }

    /**
     * Remux by feeding MediaExtractor short windows: [init][moof…mdat]×N.
     * Mid-stream windows often restart PTS near 0 — apply [ptsShift] so we do not
     * skip the rest of the timeline after a prior window.
     */
    private fun writeTrackByFragmentWindows(
        inputPath: String,
        trackPrefix: String,
        muxer: MediaMuxer,
        targetTrack: Int,
        firstPresentationTimeUs: Long,
        lastPresentationTimeUs: Long,
        lastRawSampleTimeUs: Long,
        wrote: Int,
        ptsForcedMono: Int,
        priorPasses: Int,
    ): WriteTrackResult {
        val (initEnd, fragments) = scanFmp4Layout(inputPath)
        if (fragments.isEmpty()) {
            if (wrote == 0) {
                throw IllegalStateException("No fMP4 fragments in $inputPath")
            }
            return WriteTrackResult(wrote, lastPresentationTimeUs.coerceAtLeast(0L), ptsForcedMono, priorPasses)
        }
        android.util.Log.i(
            "X_HLS_MUX_NATIVE",
            "fragment-window begin initEnd=$initEnd fragments=${fragments.size} " +
                "priorWrote=$wrote priorPtsUs=$lastPresentationTimeUs",
        )
        var firstPts = firstPresentationTimeUs
        var lastPts = lastPresentationTimeUs
        var lastRaw = lastRawSampleTimeUs
        var totalWrote = wrote
        var forced = ptsForcedMono
        val info = MediaCodec.BufferInfo()
        val windowFrags = 3
        val copyBuf = ByteArray(1024 * 1024)
        // Per-sample owned buffers — do not reuse one DirectByteBuffer across
        // writeSampleData calls (MPEG4Writer is async; see moof-walk tombstone).
        val cacheDir = cacheDir ?: filesDir
        var windowIndex = 0
        var fragIndex = 0
        var payloadBytes = 0L
        val probedDurUs = probeContainerDurationUs(inputPath)
        // Prefer constant frame step from container duration once we know fragment count;
        // ME sampleTime deltas per short window inflate PTS (24min → 45min).
        var fixedStepUs = 40_000L
        if (probedDurUs > 0L && fragments.isNotEmpty()) {
            // Rough: ~75 samples / fragment on this X long clip (37143/495).
            val approxSamples = (fragments.size * 75L).coerceAtLeast(1L)
            fixedStepUs = (probedDurUs / approxSamples).coerceIn(8_000L, 100_000L)
        }
        while (fragIndex < fragments.size) {
            val endFrag = minOf(fragIndex + windowFrags, fragments.size)
            // No prior-fragment overlap: overlapping + cumulative ptsShift inflated
            // timeline (~1485s → ~1977s) and skipped ~40% of frames (22146 vs 37143),
            // producing choppy/corrupt seekable files. Init+current window is enough
            // for MediaExtractor sample delivery on X CMAF (fragments usually start IDR).
            val mediaStart = fragments[fragIndex].start
            val mediaEnd = fragments[endFrag - 1].end
            val tmp = File(cacheDir, "x_fmp4_win_${System.nanoTime()}.mp4")
            try {
                RandomAccessFile(inputPath, "r").use { src ->
                    java.io.FileOutputStream(tmp).use { out ->
                        copyFileRange(src, out, 0L, initEnd, copyBuf)
                        copyFileRange(src, out, mediaStart, mediaEnd, copyBuf)
                    }
                }
                val extractor = MediaExtractor()
                try {
                    extractor.setDataSource(tmp.absolutePath)
                    val sourceTrack = findTrack(extractor, trackPrefix)
                    if (sourceTrack < 0) {
                        android.util.Log.w(
                            "X_HLS_MUX_NATIVE",
                            "fragment-window[$windowIndex] no $trackPrefix track",
                        )
                        fragIndex = endFrag
                        windowIndex++
                        continue
                    }
                    extractor.selectTrack(sourceTrack)
                    var buffer = allocateSampleBuffer(extractor, sourceTrack)
                    var windowWrote = 0
                    var windowRead = 0
                    var windowSkip = 0
                    var prevRawInWindow = -1L
                    while (true) {
                        buffer.clear()
                        var size = extractor.readSampleData(buffer, 0)
                        if (size < 0) break
                        if (size > buffer.capacity()) {
                            val growTo = (size + 256 * 1024).coerceAtMost(32 * 1024 * 1024)
                            if (growTo < size) {
                                throw IllegalArgumentException("Sample too large size=$size")
                            }
                            buffer = ByteBuffer.allocateDirect(growTo)
                            size = extractor.readSampleData(buffer, 0)
                            if (size < 0) break
                        }
                        val rawFlags = extractor.sampleFlags
                        if ((rawFlags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 || size == 0) {
                            if (!extractor.advance()) break
                            continue
                        }
                        windowRead++
                        val sampleTimeUs = extractor.sampleTime
                        // Wall-clock from fixed step (not ME deltas) — see fixedStepUs.
                        val stepUs = fixedStepUs
                        if (sampleTimeUs >= 0L) prevRawInWindow = sampleTimeUs

                        val owned = ByteArray(size)
                        val src = buffer.duplicate()
                        src.position(0)
                        src.limit(size)
                        src.get(owned)
                        val writeBuf = ByteBuffer.wrap(owned)
                        info.offset = 0
                        info.size = size
                        val outPts =
                            if (lastPts < 0L) {
                                0L
                            } else {
                                lastPts + stepUs
                            }
                        if (firstPts < 0L) firstPts = outPts
                        info.presentationTimeUs = outPts
                        lastPts = outPts
                        if (sampleTimeUs >= 0L) lastRaw = sampleTimeUs
                        info.flags = rawFlags
                        if (writeBuf.remaining() != size) {
                            throw IllegalStateException(
                                "fragment-window buffer remaining=${writeBuf.remaining()} size=$size",
                            )
                        }
                        muxer.writeSampleData(targetTrack, writeBuf, info)
                        totalWrote++
                        windowWrote++
                        payloadBytes += size.toLong()
                        if (totalWrote % 40 == 0) {
                            try {
                                Thread.sleep(4L)
                            } catch (_: InterruptedException) {
                            }
                        }
                        if (!extractor.advance()) break
                    }
                    android.util.Log.i(
                        "X_HLS_MUX_NATIVE",
                        "fragment-window[$windowIndex] frags=$fragIndex..${endFrag - 1} " +
                            "read=$windowRead skip=$windowSkip wrote=$windowWrote " +
                            "total=$totalWrote lastPtsUs=$lastPts payloadBytes=$payloadBytes",
                    )
                } finally {
                    try {
                        extractor.release()
                    } catch (_: Exception) {
                    }
                }
            } finally {
                try {
                    tmp.delete()
                } catch (_: Exception) {
                }
            }
            fragIndex = endFrag
            windowIndex++
        }
        android.util.Log.i(
            "X_HLS_MUX_NATIVE",
            "writeTrack fragment-window done wrote=$totalWrote lastPtsUs=$lastPts " +
                "lastRawPtsUs=$lastRaw windows=$windowIndex",
        )
        if (totalWrote == 0) {
            throw IllegalStateException("No samples written via fragment windows for $inputPath")
        }
        return WriteTrackResult(
            wrote = totalWrote,
            lastPtsUs = lastPts.coerceAtLeast(0L),
            ptsForcedMono = forced,
            resumePasses = priorPasses + windowIndex,
            payloadBytes = payloadBytes,
        )
    }

    /** Legacy single-extractor path (TS remux). Prefer [writeTrackFromPath] for fMP4. */
    private fun writeTrack(
        extractor: MediaExtractor,
        sourceTrack: Int,
        muxer: MediaMuxer,
        targetTrack: Int
    ): WriteTrackResult {
        extractor.selectTrack(sourceTrack)
        var buffer = allocateSampleBuffer(extractor, sourceTrack)
        val info = MediaCodec.BufferInfo()
        var firstPresentationTimeUs = -1L
        var lastPresentationTimeUs = -1L
        var wrote = 0
        var ptsForcedMono = 0
        while (true) {
            buffer.clear()
            var size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            if (size > buffer.capacity()) {
                val growTo = (size + 256 * 1024).coerceAtMost(32 * 1024 * 1024)
                if (growTo < size) {
                    throw IllegalArgumentException(
                        "Sample too large for remux buffer size=$size capacity=${buffer.capacity()}",
                    )
                }
                buffer = ByteBuffer.allocateDirect(growTo)
                size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
            }
            val rawFlags = extractor.sampleFlags
            if ((rawFlags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                if (!extractor.advance()) break
                continue
            }
            if (size == 0) {
                if (!extractor.advance()) break
                continue
            }
            buffer.position(0)
            buffer.limit(size)
            info.offset = 0
            info.size = size
            val sampleTimeUs = extractor.sampleTime
            if (sampleTimeUs >= 0L) {
                if (firstPresentationTimeUs < 0L) firstPresentationTimeUs = sampleTimeUs
                var normalizedTimeUs = (sampleTimeUs - firstPresentationTimeUs).coerceAtLeast(0L)
                if (lastPresentationTimeUs >= 0L && normalizedTimeUs <= lastPresentationTimeUs) {
                    normalizedTimeUs = lastPresentationTimeUs + 1L
                    ptsForcedMono++
                }
                info.presentationTimeUs = normalizedTimeUs
                lastPresentationTimeUs = normalizedTimeUs
            } else {
                val fallback =
                    if (lastPresentationTimeUs < 0L) 0L else lastPresentationTimeUs + 33_333L
                info.presentationTimeUs = fallback
                lastPresentationTimeUs = fallback
                if (firstPresentationTimeUs < 0L) firstPresentationTimeUs = 0L
            }
            info.flags = rawFlags
            muxer.writeSampleData(targetTrack, buffer, info)
            wrote++
            if (!extractor.advance()) break
        }
        try {
            extractor.unselectTrack(sourceTrack)
        } catch (_: Exception) {
        }
        if (wrote == 0) {
            throw IllegalStateException("No samples written for track $sourceTrack")
        }
        return WriteTrackResult(
            wrote = wrote,
            lastPtsUs = lastPresentationTimeUs.coerceAtLeast(0L),
            ptsForcedMono = ptsForcedMono,
        )
    }

    /** Turn concatenated fMP4/HLS track files into a seekable progressive MP4. */
    /**
     * Lossless remux via FFmpeg (-c copy). Used for X long CMAF/fMP4 where Android
     * MediaMuxer/MPEG4Writer aborts in addLengthPrefixedSample_l (NAL length = -1).
     */
    private fun ffmpegRemuxCopy(
        videoPath: String,
        audioPath: String?,
        outputPath: String,
        videoOnly: Boolean,
    ) {
        val inVideo = File(videoPath)
        if (!inVideo.exists() || inVideo.length() <= 0L) {
            throw IllegalStateException("ffmpeg input missing: $videoPath")
        }
        File(outputPath).delete()
        val args =
            if (videoOnly || audioPath.isNullOrBlank()) {
                arrayOf(
                    "-y",
                    "-i",
                    videoPath,
                    "-map",
                    "0:v:0",
                    "-c:v",
                    "copy",
                    "-an",
                    "-movflags",
                    "+faststart",
                    outputPath,
                )
            } else {
                arrayOf(
                    "-y",
                    "-i",
                    videoPath,
                    "-i",
                    audioPath!!,
                    "-map",
                    "0:v:0",
                    "-map",
                    "1:a:0",
                    "-c",
                    "copy",
                    "-movflags",
                    "+faststart",
                    outputPath,
                )
            }
        android.util.Log.i(
            "X_HLS_MUX_NATIVE",
            "ffmpeg begin videoOnly=$videoOnly inBytes=${inVideo.length()} " +
                "audio=${!audioPath.isNullOrBlank()} out=$outputPath",
        )
        val session = FFmpegKit.executeWithArguments(args)
        val code = session.returnCode
        val outFile = File(outputPath)
        val outBytes = if (outFile.exists()) outFile.length() else 0L
        val ok = ReturnCode.isSuccess(code)
        android.util.Log.i(
            "X_HLS_MUX_NATIVE",
            "ffmpeg done ok=$ok rc=$code outBytes=$outBytes inBytes=${inVideo.length()} " +
                "failStack=${session.failStackTrace?.take(400)}",
        )
        if (!ok) {
            throw IllegalStateException(
                "ffmpeg rc=$code state=${session.state} " +
                    "output=${session.output?.takeLast(500)}",
            )
        }
        if (outBytes <= 0L) {
            throw IllegalStateException("ffmpeg produced empty output")
        }
        // Fail-closed: copy remux should stay near input size for video-bearing outputs.
        if (inVideo.length() > 5_000_000L && outBytes < inVideo.length() / 3L) {
            throw IllegalStateException(
                "ffmpeg output too small outBytes=$outBytes inBytes=${inVideo.length()}",
            )
        }
    }

    private fun remuxSingleTrackToMp4(inputPath: String, outputPath: String, trackPrefix: String) {
        val attempts =
            listOf(
                false to "moof",
                true to "moof",
                false to "fragment",
                true to "fragment",
            )
        var last: Exception? = null
        for ((safe, mode) in attempts) {
            try {
                File(outputPath).delete()
                remuxSingleTrackInternal(
                    inputPath,
                    outputPath,
                    trackPrefix,
                    useSafeFormat = safe,
                    longFmp4Mode = mode,
                )
                return
            } catch (e: Exception) {
                last = e
                android.util.Log.w(
                    "X_HLS_MUX_NATIVE",
                    "remux attempt safe=$safe mode=$mode failed: ${e.message}",
                )
            }
        }
        throw last ?: IllegalStateException("remuxSingleTrackToMp4 failed")
    }

    private fun remuxSingleTrackInternal(
        inputPath: String,
        outputPath: String,
        trackPrefix: String,
        useSafeFormat: Boolean,
        longFmp4Mode: String = "moof",
    ) {
        var extractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        var step = "init"
        try {
            step = "setDataSource"
            extractor = MediaExtractor()
            extractor.setDataSource(inputPath)
            step = "findTrack"
            val sourceTrack = findTrack(extractor, trackPrefix)
            if (sourceTrack < 0) {
                throw IllegalStateException("No $trackPrefix track in $inputPath")
            }
            val format = extractor.getTrackFormat(sourceTrack)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: "?"
            val hasCsd0 = format.containsKey("csd-0")
            val hasCsd1 = format.containsKey("csd-1")
            val maxInput =
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    try { format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) } catch (_: Exception) { -1 }
                } else -1
            val declaredDurationUs =
                if (format.containsKey(MediaFormat.KEY_DURATION)) {
                    try { format.getLong(MediaFormat.KEY_DURATION) } catch (_: Exception) { -1L }
                } else -1L
            val probedDurationUs = probeContainerDurationUs(inputPath)
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "remux begin safe=$useSafeFormat mode=$longFmp4Mode tracks=${extractor.trackCount} " +
                    "src=$sourceTrack mime=$mime csd0=$hasCsd0 csd1=$hasCsd1 maxInput=$maxInput " +
                    "declaredDurUs=$declaredDurationUs probedDurUs=$probedDurationUs in=$inputPath",
            )
            // Release probe extractor before writing — writeTrackFromPath opens its own.
            extractor.release()
            extractor = null
            File(outputPath).delete()
            step = "createMuxer"
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            step = "addTrack"
            val targetTrack =
                muxer.addTrack(if (useSafeFormat) muxerSafeFormat(format) else format)
            step = "start"
            muxer.start()
            step = "writeTrack"
            val written = writeTrackFromPath(
                inputPath,
                trackPrefix,
                muxer,
                targetTrack,
                longFmp4Mode = longFmp4Mode,
            )
            val expectUs =
                when {
                    probedDurationUs > 0L -> probedDurationUs
                    declaredDurationUs > 0L -> declaredDurationUs
                    else -> -1L
                }
            if (expectUs > 0L &&
                written.lastPtsUs > 0L &&
                expectUs > written.lastPtsUs * 5L / 4L &&
                expectUs - written.lastPtsUs > 5_000_000L
            ) {
                throw IllegalStateException(
                    "remux truncated wrotePtsUs=${written.lastPtsUs} " +
                        "expectDurUs=$expectUs samples=${written.wrote} passes=${written.resumePasses}",
                )
            }
            // Reject PTS-inflated remux (fragment ptsShift bug → 24min content shown as 33min,
            // choppy/corrupt frames). Prefer fail → next attempt / raw keep over bad library file.
            if (expectUs > 0L &&
                written.lastPtsUs > expectUs * 5L / 4L &&
                written.lastPtsUs - expectUs > 5_000_000L
            ) {
                throw IllegalStateException(
                    "remux pts inflated wrotePtsUs=${written.lastPtsUs} " +
                        "expectDurUs=$expectUs samples=${written.wrote} " +
                        "payloadBytes=${written.payloadBytes}",
                )
            }
            step = "stop"
            muxer.stop()
            val outBytes = File(outputPath).length()
            val inBytes = File(inputPath).length()
            if (inBytes > 5_000_000L && outBytes > 0L && outBytes < inBytes / 3L) {
                throw IllegalStateException(
                    "remux output too small outBytes=$outBytes inBytes=$inBytes " +
                        "samples=${written.wrote} wrotePtsUs=${written.lastPtsUs} " +
                        "payloadBytes=${written.payloadBytes}",
                )
            }
            // Moof-walk can report large payloadBytes while MediaMuxer drops video; also
            // require outBytes to track claimed payload when payload is huge.
            if (written.payloadBytes > 50_000_000L &&
                outBytes > 0L &&
                outBytes < written.payloadBytes / 2L
            ) {
                throw IllegalStateException(
                    "remux muxer dropped payload outBytes=$outBytes " +
                        "payloadBytes=${written.payloadBytes} samples=${written.wrote}",
                )
            }
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "remux ok safe=$useSafeFormat out=$outputPath " +
                    "wrotePtsUs=${written.lastPtsUs} samples=${written.wrote} " +
                    "passes=${written.resumePasses} expectDurUs=$expectUs " +
                    "payloadBytes=${written.payloadBytes} outBytes=$outBytes",
            )
        } catch (e: Exception) {
            android.util.Log.e(
                "X_HLS_MUX_NATIVE",
                "remux fail step=$step safe=$useSafeFormat err=${e.javaClass.simpleName}: ${e.message}",
                e,
            )
            throw IllegalStateException("remux fail step=$step safe=$useSafeFormat: ${e.message}", e)
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            try { extractor?.release() } catch (_: Exception) {}
        }
    }

    private fun muxMp4Tracks(videoPath: String, audioPath: String, outputPath: String) {
        try {
            muxMp4TracksInternal(videoPath, audioPath, outputPath, useSafeFormat = false)
        } catch (first: Exception) {
            File(outputPath).delete()
            muxMp4TracksInternal(videoPath, audioPath, outputPath, useSafeFormat = true)
        }
    }

    private fun muxMp4TracksInternal(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        useSafeFormat: Boolean,
    ) {
        var videoFormatExtractor: MediaExtractor? = null
        var audioFormatExtractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        var step = "init"
        try {
            step = "setDataSource"
            videoFormatExtractor = MediaExtractor().also { it.setDataSource(videoPath) }
            audioFormatExtractor = MediaExtractor().also { it.setDataSource(audioPath) }
            step = "findTrack"
            val videoSourceTrack = findTrack(videoFormatExtractor, "video/")
            val audioSourceTrack = findTrack(audioFormatExtractor, "audio/")
            if (videoSourceTrack < 0 || audioSourceTrack < 0) {
                throw IllegalStateException("DASH track is missing video or audio samples")
            }
            val videoFormat = videoFormatExtractor.getTrackFormat(videoSourceTrack)
            val audioFormat = audioFormatExtractor.getTrackFormat(audioSourceTrack)
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "mux begin safe=$useSafeFormat " +
                    "vMime=${videoFormat.getString(MediaFormat.KEY_MIME)} " +
                    "aMime=${audioFormat.getString(MediaFormat.KEY_MIME)} " +
                    "vCsd0=${videoFormat.containsKey("csd-0")} aCsd0=${audioFormat.containsKey("csd-0")} " +
                    "vProbeUs=${probeContainerDurationUs(videoPath)} " +
                    "aProbeUs=${probeContainerDurationUs(audioPath)}",
            )
            File(outputPath).delete()
            step = "createMuxer"
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            step = "addTrack"
            val videoTargetTrack =
                muxer.addTrack(if (useSafeFormat) muxerSafeFormat(videoFormat) else videoFormat)
            val audioTargetTrack =
                muxer.addTrack(if (useSafeFormat) muxerSafeFormat(audioFormat) else audioFormat)
            step = "start"
            muxer.start()
            // Release format extractors before writeTrackFromPath opens its own.
            // Holding an exhausted extractor can block selectTrack on some OEMs.
            try {
                videoFormatExtractor.release()
            } catch (_: Exception) {
            }
            videoFormatExtractor = null
            try {
                audioFormatExtractor.release()
            } catch (_: Exception) {
            }
            audioFormatExtractor = null
            step = "writeVideo"
            val videoWritten =
                writeTrackFromPath(videoPath, "video/", muxer, videoTargetTrack)
            step = "writeAudio"
            val audioWritten =
                writeTrackFromPath(audioPath, "audio/", muxer, audioTargetTrack)
            // Fail-closed: progress bar follows the longer track. If video is much shorter
            // than audio, seeking near the end freezes with no picture.
            if (videoWritten.lastPtsUs > 0L && audioWritten.lastPtsUs > 0L) {
                val shorter = minOf(videoWritten.lastPtsUs, audioWritten.lastPtsUs)
                val longer = maxOf(videoWritten.lastPtsUs, audioWritten.lastPtsUs)
                if (longer > shorter * 5L / 4L && longer - shorter > 5_000_000L) {
                    throw IllegalStateException(
                        "A/V duration skew vPtsUs=${videoWritten.lastPtsUs} " +
                            "aPtsUs=${audioWritten.lastPtsUs} vSamples=${videoWritten.wrote} " +
                            "aSamples=${audioWritten.wrote} " +
                            "vPasses=${videoWritten.resumePasses} aPasses=${audioWritten.resumePasses}",
                    )
                }
            }
            step = "stop"
            muxer.stop()
            val outBytes = File(outputPath).length()
            val videoInBytes = File(videoPath).length()
            // Fail-closed: moof-walk once "wrote" 37k samples but heap ByteBuffer caused
            // MediaMuxer to keep ~90 video frames; output shrank to ~audio size.
            if (videoInBytes > 5_000_000L && outBytes > 0L && outBytes < videoInBytes / 3L) {
                throw IllegalStateException(
                    "mux output too small outBytes=$outBytes videoInBytes=$videoInBytes " +
                        "vSamples=${videoWritten.wrote} aSamples=${audioWritten.wrote}",
                )
            }
            android.util.Log.i(
                "X_HLS_MUX_NATIVE",
                "mux ok safe=$useSafeFormat out=$outputPath " +
                    "vPtsUs=${videoWritten.lastPtsUs} aPtsUs=${audioWritten.lastPtsUs} " +
                    "vSamples=${videoWritten.wrote} aSamples=${audioWritten.wrote} " +
                    "vPasses=${videoWritten.resumePasses} aPasses=${audioWritten.resumePasses} " +
                    "outBytes=$outBytes",
            )
        } catch (e: Exception) {
            android.util.Log.e(
                "X_HLS_MUX_NATIVE",
                "mux fail step=$step safe=$useSafeFormat err=${e.javaClass.simpleName}: ${e.message}",
                e,
            )
            throw IllegalStateException("mux fail step=$step safe=$useSafeFormat: ${e.message}", e)
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            try { videoFormatExtractor?.release() } catch (_: Exception) {}
            try { audioFormatExtractor?.release() } catch (_: Exception) {}
        }
    }

    /**
     * Legacy TS→MP4 helper. Unsafe for H.264 with B-frames: MediaExtractor delivers
     * decode order while [writeTrack] forces monotonic PTS, collapsing several frames
     * onto one presentationTime (first-frame freeze in ExoPlayer). HLS downloads now
     * keep MPEG-TS instead; X still uses [muxMp4Tracks] only.
     */
    private fun remuxToMp4(inputPath: String, outputPath: String) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(inputPath)
            File(outputPath).delete()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val trackPairs = mutableListOf<Pair<Int, Int>>()
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                trackPairs.add(index to muxer.addTrack(format))
            }
            if (trackPairs.isEmpty()) throw IllegalStateException("No media track to remux")
            muxer.start()
            for ((sourceTrack, targetTrack) in trackPairs) {
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                writeTrack(extractor, sourceTrack, muxer, targetTrack)
            }
            muxer.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "media_auto_import",
                "媒体自动导入",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "监听媒体库变化并自动导入新媒体"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }
} 
