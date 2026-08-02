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

    private fun writeTrack(
        extractor: MediaExtractor,
        sourceTrack: Int,
        muxer: MediaMuxer,
        targetTrack: Int
    ) {
        extractor.selectTrack(sourceTrack)
        var buffer = ByteBuffer.allocateDirect(4 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        var firstPresentationTimeUs = -1L
        var lastPresentationTimeUs = -1L
        while (true) {
            buffer.clear()
            var size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            if (size > buffer.capacity()) {
                buffer = ByteBuffer.allocateDirect(size + 1024)
                size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
            }
            info.offset = 0
            info.size = size
            val sampleTimeUs = extractor.sampleTime
            if (firstPresentationTimeUs < 0L) firstPresentationTimeUs = sampleTimeUs
            var normalizedTimeUs = (sampleTimeUs - firstPresentationTimeUs).coerceAtLeast(0L)
            if (normalizedTimeUs <= lastPresentationTimeUs) {
                normalizedTimeUs = lastPresentationTimeUs + 1L
            }
            info.presentationTimeUs = normalizedTimeUs
            lastPresentationTimeUs = normalizedTimeUs
            info.flags = extractor.sampleFlags
            muxer.writeSampleData(targetTrack, buffer, info)
            if (!extractor.advance()) break
        }
        extractor.unselectTrack(sourceTrack)
    }

    /** Turn concatenated fMP4/HLS track files into a seekable progressive MP4. */
    private fun remuxSingleTrackToMp4(inputPath: String, outputPath: String, trackPrefix: String) {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            extractor.setDataSource(inputPath)
            val sourceTrack = findTrack(extractor, trackPrefix)
            if (sourceTrack < 0) {
                throw IllegalStateException("No $trackPrefix track in $inputPath")
            }
            File(outputPath).delete()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val targetTrack = muxer.addTrack(extractor.getTrackFormat(sourceTrack))
            muxer.start()
            writeTrack(extractor, sourceTrack, muxer, targetTrack)
            muxer.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }

    private fun muxMp4Tracks(videoPath: String, audioPath: String, outputPath: String) {
        val videoExtractor = MediaExtractor()
        val audioExtractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            videoExtractor.setDataSource(videoPath)
            audioExtractor.setDataSource(audioPath)
            val videoSourceTrack = findTrack(videoExtractor, "video/")
            val audioSourceTrack = findTrack(audioExtractor, "audio/")
            if (videoSourceTrack < 0 || audioSourceTrack < 0) {
                throw IllegalStateException("DASH track is missing video or audio samples")
            }
            File(outputPath).delete()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val videoTargetTrack = muxer.addTrack(videoExtractor.getTrackFormat(videoSourceTrack))
            val audioTargetTrack = muxer.addTrack(audioExtractor.getTrackFormat(audioSourceTrack))
            muxer.start()
            writeTrack(videoExtractor, videoSourceTrack, muxer, videoTargetTrack)
            writeTrack(audioExtractor, audioSourceTrack, muxer, audioTargetTrack)
            muxer.stop()
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            videoExtractor.release()
            audioExtractor.release()
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
