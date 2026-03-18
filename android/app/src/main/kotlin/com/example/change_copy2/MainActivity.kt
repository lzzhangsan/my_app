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
import java.io.RandomAccessFile

class MainActivity: FlutterActivity() {
    private val CHANNEL = "media_auto_import"
    private val PERF_CHANNEL = "performance_service"
    private var lastCpuTime: Long = 0
    private var lastCpuSampleTime: Long = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                else -> result.notImplemented()
            }
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
