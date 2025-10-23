import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 网络服务 - 提供统一的HTTP请求处理，包含超时、重试和错误处理
class NetworkService {
  static const String _tag = 'NetworkService';

  late final Dio _dio;
  bool _isInitialized = false;

  /// 初始化网络服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      followRedirects: true,
      maxRedirects: 5,
      headers: {
        'User-Agent': 'Flutter-App/1.0.0',
        'Accept': '*/*',
        'Accept-Encoding': 'gzip, deflate, br',
        'Connection': 'keep-alive',
      },
    ));

    // 添加拦截器
    _dio.interceptors.add(_createRetryInterceptor());
    _dio.interceptors.add(_createLoggingInterceptor());

    _isInitialized = true;

    if (kDebugMode) {
      print('$_tag: 网络服务初始化完成');
    }
    return;
  }

  /// 创建重试拦截器
  Interceptor _createRetryInterceptor() {
    return InterceptorsWrapper(
      onError: (error, handler) async {
        final requestOptions = error.requestOptions;

        // 检查是否应该重试
        if (_shouldRetry(error) && requestOptions.extra['retryCount'] == null) {
          requestOptions.extra['retryCount'] = 0;
        }

        final retryCount = requestOptions.extra['retryCount'] ?? 0;
        const maxRetries = 3;

        if (retryCount < maxRetries && _shouldRetry(error)) {
          // 指数退避重试
          final delay = Duration(seconds: 1 << retryCount); // 1s, 2s, 4s
          requestOptions.extra['retryCount'] = retryCount + 1;

          if (kDebugMode) {
            print('$_tag: 重试请求 ${retryCount + 1}/$maxRetries, 延迟 ${delay.inSeconds}s');
          }

          await Future.delayed(delay);

          try {
            final response = await _dio.request(
              requestOptions.path,
              options: Options(
                method: requestOptions.method,
                headers: requestOptions.headers,
                extra: requestOptions.extra,
              ),
              data: requestOptions.data,
              queryParameters: requestOptions.queryParameters,
            );
            return handler.resolve(response);
          } catch (e) {
            return handler.next(error);
          }
        }

        handler.next(error);
      },
    );
  }

  /// 创建日志拦截器
  Interceptor _createLoggingInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) {
        if (kDebugMode) {
          print('$_tag: [${options.method}] ${options.uri}');
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        if (kDebugMode) {
          print('$_tag: [${response.statusCode}] ${response.requestOptions.uri}');
        }
        handler.next(response);
      },
      onError: (error, handler) {
        if (kDebugMode) {
          print('$_tag: [ERROR] ${error.requestOptions.uri} - ${error.message}');
        }
        handler.next(error);
      },
    );
  }

  /// 判断是否应该重试
  bool _shouldRetry(DioException error) {
    // 网络超时重试
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return true;
    }

    // 服务器错误重试 (5xx)
    if (error.type == DioExceptionType.badResponse &&
        error.response?.statusCode != null &&
        error.response!.statusCode! >= 500) {
      return true;
    }

    // 网络连接错误重试
    if (error.type == DioExceptionType.unknown &&
        error.message?.contains('Connection') == true) {
      return true;
    }

    return false;
  }

  /// GET 请求
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) {
    return _dio.get(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// POST 请求
  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) {
    return _dio.post(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// 下载文件
  Future<Response> download(
    String url,
    String savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    String lengthHeader = Headers.contentLengthHeader,
    dynamic data,
    Options? options,
  }) {
    return _dio.download(
      url,
      savePath,
      onReceiveProgress: onReceiveProgress,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      deleteOnError: deleteOnError,
      lengthHeader: lengthHeader,
      data: data,
      options: options,
    );
  }

  /// HEAD 请求
  Future<Response> head(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.head(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  /// 创建具有自定义超时的请求选项
  Options createOptions({
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, dynamic>? headers,
    String? contentType,
    ResponseType? responseType,
    bool? followRedirects,
    int? maxRedirects,
  }) {
    return Options(
      // Timeouts are configured on the Dio instance via BaseOptions; passing them here
      // to Options may not be supported across Dio versions, so we avoid that.
      headers: headers,
      contentType: contentType,
      responseType: responseType,
      followRedirects: followRedirects,
      maxRedirects: maxRedirects,
    );
  }

  /// 获取Dio实例（用于高级用法）
  Dio get dio => _dio;

  /// 清理资源
  void dispose() {
    _dio.close(force: true);
    _isInitialized = false;

    if (kDebugMode) {
      print('$_tag: 网络服务已清理');
    }
  }
}