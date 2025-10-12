package com.example.change_copy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.webkit.CookieManager

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
