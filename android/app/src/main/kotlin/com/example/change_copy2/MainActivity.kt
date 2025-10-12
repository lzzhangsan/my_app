package com.example.change_copy2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

class MainActivity: FlutterActivity() {
    private val CHANNEL = "media_auto_import"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
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
