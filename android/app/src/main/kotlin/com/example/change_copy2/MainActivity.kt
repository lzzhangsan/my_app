package com.example.change_copy2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "media_auto_import"
    private val ZIP_CHANNEL = "native_zip"

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

        // 原生流式Zip/Unzip能力
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ZIP_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "zipDirectory" -> {
                        val sourceDir = call.argument<String>("sourceDir") ?: return@setMethodCallHandler result.error("ARG", "sourceDir is required", null)
                        val zipPath = call.argument<String>("zipPath") ?: return@setMethodCallHandler result.error("ARG", "zipPath is required", null)
                        zipDirectoryStreaming(File(sourceDir), File(zipPath))
                        result.success(zipPath)
                    }
                    "unzipToDirectory" -> {
                        val zipPath = call.argument<String>("zipPath") ?: return@setMethodCallHandler result.error("ARG", "zipPath is required", null)
                        val targetDir = call.argument<String>("targetDir") ?: return@setMethodCallHandler result.error("ARG", "targetDir is required", null)
                        unzipStreaming(File(zipPath), File(targetDir))
                        result.success(targetDir)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("ZIP_ERR", e.message, null)
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

    private fun zipDirectoryStreaming(sourceDir: File, zipFile: File) {
        if (!sourceDir.exists()) throw IllegalArgumentException("sourceDir not exists: ${sourceDir.path}")
        zipFile.parentFile?.mkdirs()
        ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
            val basePath = sourceDir.canonicalPath
            sourceDir.walkTopDown().forEach { file ->
                val abs = file.canonicalPath
                if (abs == basePath) return@forEach // 跳过根目录本身，避免越界

                // 安全计算相对路径
                var name = if (abs.startsWith(basePath)) abs.substring(basePath.length) else abs
                if (name.startsWith(File.separator)) name = name.substring(1)
                name = name.replace("\\", "/")
                if (name.isEmpty()) return@forEach

                if (file.isDirectory) {
                    val entryName = if (name.endsWith('/')) name else "$name/"
                    val entry = ZipEntry(entryName)
                    zos.putNextEntry(entry)
                    zos.closeEntry()
                } else {
                    val entry = ZipEntry(name)
                    zos.putNextEntry(entry)
                    BufferedInputStream(FileInputStream(file)).use { input ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            zos.write(buffer, 0, read)
                        }
                    }
                    zos.closeEntry()
                }
            }
        }
    }

    private fun unzipStreaming(zipFile: File, targetDir: File) {
        targetDir.mkdirs()
        ZipInputStream(BufferedInputStream(FileInputStream(zipFile))).use { zis ->
            var entry: ZipEntry? = zis.nextEntry
            val buffer = ByteArray(64 * 1024)
            while (entry != null) {
                val outFile = File(targetDir, entry.name)
                if (entry.isDirectory || entry.name.endsWith("/")) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    BufferedOutputStream(FileOutputStream(outFile)).use { bos ->
                        while (true) {
                            val read = zis.read(buffer)
                            if (read <= 0) break
                            bos.write(buffer, 0, read)
                        }
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }
} 