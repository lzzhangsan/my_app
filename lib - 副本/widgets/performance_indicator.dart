import 'dart:async';
import 'package:flutter/material.dart';
import '../services/performance_service.dart';
import '../performance_monitor_page.dart';

/// 性能指示器小部件 - 显示简化的性能状态
class PerformanceIndicator extends StatefulWidget {
  final bool showDetails;
  final EdgeInsets? padding;
  final double? size;

  const PerformanceIndicator({
    Key? key,
    this.showDetails = false,
    this.padding,
    this.size,
  }) : super(key: key);

  @override
  State<PerformanceIndicator> createState() => _PerformanceIndicatorState();
}

class _PerformanceIndicatorState extends State<PerformanceIndicator>
    with TickerProviderStateMixin {
  final PerformanceService _performanceService = PerformanceService();
  StreamSubscription<PerformanceMetric>? _metricsSubscription;
  PerformanceMetric? _currentMetric;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isHealthy = true;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializePerformanceService();
  }

  void _initializeAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));
  }

  Future<void> _initializePerformanceService() async {
    try {
      if (!_performanceService.isInitialized) {
        await _performanceService.initialize();
      }
      
      _metricsSubscription = _performanceService.metricsStream.listen((metric) {
        if (mounted) {
          setState(() {
            _currentMetric = metric;
            _isHealthy = _checkSystemHealth(metric);
          });
          
          if (!_isHealthy && !_pulseController.isAnimating) {
            _pulseController.repeat(reverse: true);
          } else if (_isHealthy && _pulseController.isAnimating) {
            _pulseController.stop();
            _pulseController.reset();
          }
        }
      });
      
      // 立即获取一次数据
      final metric = await _performanceService.collectMetricsOnce();
      if (mounted) {
        setState(() {
          _currentMetric = metric;
          _isHealthy = _checkSystemHealth(metric);
        });
      }
    } catch (e) {
      // 静默处理错误，不影响主应用
      print('性能指示器初始化失败: $e');
    }
  }

  bool _checkSystemHealth(PerformanceMetric metric) {
    return metric.memoryPercentage < 0.8 &&
           metric.cpuUsage < 0.7 &&
           metric.frameRate >= 30;
  }

  @override
  void dispose() {
    _metricsSubscription?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentMetric == null) {
      return _buildLoadingIndicator();
    }

    return GestureDetector(
      onTap: _openPerformanceMonitor,
      child: Container(
        padding: widget.padding ?? const EdgeInsets.all(8),
        child: widget.showDetails ? _buildDetailedView() : _buildSimpleView(),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      width: widget.size ?? 24,
      height: widget.size ?? 24,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade400),
      ),
    );
  }

  Widget _buildSimpleView() {
    final color = _isHealthy ? Colors.green : Colors.orange;
    final icon = _isHealthy ? Icons.check_circle : Icons.warning;
    
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _isHealthy ? 1.0 : _pulseAnimation.value,
          child: Icon(
            icon,
            color: color,
            size: widget.size ?? 24,
          ),
        );
      },
    );
  }

  Widget _buildDetailedView() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _isHealthy ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isHealthy ? Colors.green : Colors.orange,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _isHealthy ? 1.0 : _pulseAnimation.value,
                child: Icon(
                  _isHealthy ? Icons.speed : Icons.warning,
                  color: _isHealthy ? Colors.green : Colors.orange,
                  size: 16,
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isHealthy ? '性能良好' : '需要关注',
                style: TextStyle(
                  color: _isHealthy ? Colors.green.shade700 : Colors.orange.shade700,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '内存: ${(_currentMetric!.memoryPercentage * 100).toStringAsFixed(0)}% | '
                'CPU: ${(_currentMetric!.cpuUsage * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openPerformanceMonitor() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const PerformanceMonitorPage(),
      ),
    );
  }
}

/// 浮动性能指示器 - 可以覆盖在其他内容上
class FloatingPerformanceIndicator extends StatelessWidget {
  final Alignment alignment;
  final EdgeInsets margin;
  final bool showDetails;
  final VoidCallback? onTap;

  const FloatingPerformanceIndicator({
    Key? key,
    this.alignment = Alignment.topRight,
    this.margin = const EdgeInsets.all(16),
    this.showDetails = false,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: Container(
          margin: margin,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: onTap,
              child: PerformanceIndicator(
                showDetails: showDetails,
                padding: const EdgeInsets.all(8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}