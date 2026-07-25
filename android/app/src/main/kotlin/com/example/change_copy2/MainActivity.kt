package com.example.change_copy2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.ActivityManager
import android.content.Context
import android.os.Build
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
    }

    private fun persistWebCookies() {
        val manager = CookieManager.getInstance()
        manager.setAcceptCookie(true)
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
        val buffer = ByteBuffer.allocateDirect(16 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        var firstPresentationTimeUs = -1L
        var lastPresentationTimeUs = -1L
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
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
