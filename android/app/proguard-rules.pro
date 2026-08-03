# =============================================================================
# Release 混淆与压缩（R8）：减小 APK、移除未使用的 Android res 资源。
# Dart 业务代码由 Flutter 引擎加载，不由 R8 混淆；此处主要保护 Java/Kotlin 插件与引擎桥接。
# =============================================================================

# 崩溃栈可读性（可选，便于从 logcat 对照源码行号）
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 注解与泛型（反射、JSON、Kotlin 常用）
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# JNI
-keepclasseswithmembernames class * {
    native <methods>;
}

# Kotlin
-dontwarn kotlin.**
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# ------------------------------------------------------------------------------
# Flutter 引擎与插件注册（必须）
# ------------------------------------------------------------------------------
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-dontwarn io.flutter.embedding.**

# 各 Flutter 插件 Java/Kotlin 实现（平台通道、WebView、ExoPlayer 等）
-keep class xyz.luan.audioplayers.** { *; }
-keep class dev.fluttercommunity.plus.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class id.flutter.flutter_background_service.** { *; }
-keep class vn.hunghd.flutterdownloader.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keep class com.jrai.flutter_keyboard_visibility_temp_fork.** { *; }
-keep class com.aubergine.open_file_manager.** { *; }
-keep class com.crazecoder.openfile.** { *; }
-keep class com.fluttercandies.photo_manager.** { *; }
-keep class dev.flutterquill.quill_native_bridge.** { *; }
-keep class com.llfbandit.record.** { *; }
-keep class com.tekartik.sqflite.** { *; }
-keep class xyz.justsoft.video_thumbnail.** { *; }
-keep class dev.flutter.plugins.integration_test.** { *; }

# WebView / JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class androidx.webkit.** { *; }
-dontwarn androidx.webkit.**

# ExoPlayer / Media3（video_player、chewie 等）
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# Glide（app/build.gradle 中显式依赖）
-keep public class * implements com.bumptech.glide.module.GlideModule
-keep class * extends com.bumptech.glide.module.AppGlideModule { <init>(...); }
-keep public enum com.bumptech.glide.load.ImageHeaderParser$** {
    **[] $VALUES;
    public *;
}
-keep class com.bumptech.glide.** { *; }

# FFmpegKit（X HLS fMP4 -c copy remux）
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**
-keep class com.arthenica.smartexception.** { *; }
-dontwarn com.arthenica.smartexception.**

# OkHttp / Okio（下载、网络库传递依赖）
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# Parcelable
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}
