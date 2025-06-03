import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/performance_service.dart';

/// 性能监控面板页面
class PerformanceMonitorPage extends StatefulWidget {
  const PerformanceMonitorPage({super.key});

  @override
  State<PerformanceMonitorPage> createState() => _PerformanceMonitorPageState();
}

class _PerformanceMonitorPageState extends State<PerformanceMonitorPage>
    with TickerProviderStateMixin {
  final PerformanceService _performanceService = PerformanceService();
  StreamSubscription<PerformanceMetric>? _metricsSubscription;
  PerformanceMetric? _currentMetric;
  PerformanceMetric? _averageMetric;
  bool _isMonitoring = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

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
    _pulseController.repeat(reverse: true);
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
            _averageMetric = _performanceService.getAverageMetrics(
              period: const Duration(minutes: 5),
            );
            _isMonitoring = true;
          });
        }
      });
      
      // 立即获取一次数据
      final metric = await _performanceService.collectMetricsOnce();
      if (mounted) {
        setState(() {
          _currentMetric = metric;
          _isMonitoring = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('性能监控初始化失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _metricsSubscription?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('性能监控'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_isMonitoring ? Icons.pause : Icons.play_arrow),
            onPressed: _toggleMonitoring,
            tooltip: _isMonitoring ? '暂停监控' : '开始监控',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshMetrics,
            tooltip: '刷新数据',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.blue.shade700,
              Colors.blue.shade50,
            ],
          ),
        ),
        child: _currentMetric == null
            ? _buildLoadingView()
            : _buildMetricsView(),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  strokeWidth: 3,
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text(
            '正在初始化性能监控...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusCard(),
          const SizedBox(height: 16),
          _buildMetricsGrid(),
          const SizedBox(height: 16),
          _buildDetailedInfo(),
          const SizedBox(height: 16),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final isHealthy = _isSystemHealthy();
    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: isHealthy
                ? [Colors.green.shade400, Colors.green.shade600]
                : [Colors.orange.shade400, Colors.red.shade600],
          ),
        ),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _isMonitoring ? _pulseAnimation.value : 1.0,
                  child: Icon(
                    isHealthy ? Icons.check_circle : Icons.warning,
                    color: Colors.white,
                    size: 40,
                  ),
                );
              },
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isHealthy ? '系统运行良好' : '性能需要关注',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _getStatusDescription(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _isMonitoring ? '监控中' : '已暂停',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.2,
      children: [
        _buildMetricCard(
          title: '内存使用',
          value: '${(_currentMetric!.memoryPercentage * 100).toStringAsFixed(1)}%',
          subtitle: '${(_currentMetric!.memoryUsage / (1024 * 1024)).toStringAsFixed(0)}/${(_currentMetric!.memoryTotal / (1024 * 1024)).toStringAsFixed(0)}MB',
          icon: Icons.memory,
          color: _getMemoryColor(),
          progress: _currentMetric!.memoryPercentage,
        ),
        _buildMetricCard(
          title: 'CPU使用',
          value: '${(_currentMetric!.cpuUsage * 100).toStringAsFixed(1)}%',
          subtitle: '空闲状态',
          icon: Icons.speed,
          color: _getCpuColor(),
          progress: _currentMetric!.cpuUsage,
        ),
        _buildMetricCard(
          title: '帧率',
          value: '${_currentMetric!.frameRate.toStringAsFixed(0)} FPS',
          subtitle: '流畅状态',
          icon: Icons.videocam,
          color: _getFrameRateColor(),
          progress: _currentMetric!.frameRate / 60.0,
        ),
        _buildMetricCard(
          title: '电池电量',
          value: '${(_currentMetric!.batteryLevel * 100).toStringAsFixed(0)}%',
          subtitle: '电量充足',
          icon: Icons.battery_full,
          color: _getBatteryColor(),
          progress: _currentMetric!.batteryLevel,
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required double progress,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), // 减小内边距
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, color.withOpacity(0.1)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // 确保卡片高度适应内容
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20), // 减小图标大小
                const SizedBox(width: 6), // 减小间距
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontSize: 13, // 减小字体大小
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6), // 减小间距
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 18, // 减小字体大小
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2), // 减小间距
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 11, // 减小字体大小
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6), // 减小间距
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 3, // 减小进度条高度
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailedInfo() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics, color: Colors.blue.shade600),
                const SizedBox(width: 8),
                Text(
                  '详细信息',
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInfoRow('监控时长', _getMonitoringDuration()),
            _buildInfoRow('数据点数', '${_performanceService.metrics.length}'),
            _buildInfoRow('更新时间', _formatTime(_currentMetric!.timestamp)),
            if (_averageMetric != null) ...[
              const Divider(height: 20),
              Text(
                '5分钟平均值',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              _buildInfoRow('平均内存', '${(_averageMetric!.memoryPercentage * 100).toStringAsFixed(1)}%'),
              _buildInfoRow('平均CPU', '${(_averageMetric!.cpuUsage * 100).toStringAsFixed(1)}%'),
              _buildInfoRow('平均帧率', '${_averageMetric!.frameRate.toStringAsFixed(1)} FPS'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: Colors.grey.shade800,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _clearMetrics,
            icon: const Icon(Icons.clear_all),
            label: const Text('清空历史'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _exportReport,
            icon: const Icon(Icons.file_download),
            label: const Text('导出报告'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // 辅助方法
  bool _isSystemHealthy() {
    if (_currentMetric == null) return true;
    return _currentMetric!.memoryPercentage < 0.8 &&
           _currentMetric!.cpuUsage < 0.7 &&
           _currentMetric!.frameRate >= 30;
  }

  String _getStatusDescription() {
    if (_currentMetric == null) return '正在获取数据...';
    
    final issues = <String>[];
    if (_currentMetric!.memoryPercentage >= 0.8) issues.add('内存使用过高');
    if (_currentMetric!.cpuUsage >= 0.7) issues.add('CPU负载过高');
    if (_currentMetric!.frameRate < 30) issues.add('帧率偏低');
    
    return issues.isEmpty ? '所有指标正常' : issues.join('、');
  }

  Color _getMemoryColor() {
    final usage = _currentMetric!.memoryPercentage;
    if (usage >= 0.9) return Colors.red;
    if (usage >= 0.8) return Colors.orange;
    return Colors.green;
  }

  Color _getCpuColor() {
    final usage = _currentMetric!.cpuUsage;
    if (usage >= 0.8) return Colors.red;
    if (usage >= 0.6) return Colors.orange;
    return Colors.green;
  }

  Color _getFrameRateColor() {
    final fps = _currentMetric!.frameRate;
    if (fps < 30) return Colors.red;
    if (fps < 45) return Colors.orange;
    return Colors.green;
  }

  Color _getBatteryColor() {
    final level = _currentMetric!.batteryLevel;
    if (level < 0.2) return Colors.red;
    if (level < 0.5) return Colors.orange;
    return Colors.green;
  }

  String _getCpuDescription() {
    final usage = _currentMetric!.cpuUsage;
    if (usage >= 0.8) return '负载过高';
    if (usage >= 0.6) return '负载较高';
    if (usage >= 0.3) return '正常使用';
    return '空闲状态';
  }

  String _getFrameRateDescription() {
    final fps = _currentMetric!.frameRate;
    if (fps >= 55) return '非常流畅';
    if (fps >= 45) return '流畅';
    if (fps >= 30) return '基本流畅';
    return '可能卡顿';
  }

  String _getBatteryDescription() {
    final level = _currentMetric!.batteryLevel;
    if (level >= 0.8) return '电量充足';
    if (level >= 0.5) return '电量正常';
    if (level >= 0.2) return '电量偏低';
    return '电量不足';
  }

  String _getMonitoringDuration() {
    final metrics = _performanceService.metrics;
    if (metrics.isEmpty) return '0分钟';
    
    final duration = DateTime.now().difference(metrics.first.timestamp);
    if (duration.inHours > 0) {
      return '${duration.inHours}小时${duration.inMinutes % 60}分钟';
    }
    return '${duration.inMinutes}分钟';
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  // 事件处理
  void _toggleMonitoring() {
    if (_isMonitoring) {
      _performanceService.pauseMonitoring();
    } else {
      _performanceService.resumeMonitoring();
    }
    setState(() {
      _isMonitoring = !_isMonitoring;
    });
  }

  Future<void> _refreshMetrics() async {
    try {
      final metric = await _performanceService.collectMetricsOnce();
      setState(() {
        _currentMetric = metric;
        _averageMetric = _performanceService.getAverageMetrics(
          period: const Duration(minutes: 5),
        );
      });
      
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('数据已刷新'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('刷新失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _clearMetrics() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有性能监控历史数据吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _performanceService.clearMetrics();
              setState(() {
                _averageMetric = null;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('历史数据已清空')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _exportReport() {
    final report = _performanceService.getPerformanceReport();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('性能报告'),
        content: SingleChildScrollView(
          child: Text(
            '监控状态: ${report['status']}\n'
            '数据点数: ${report['metrics_count']}\n'
            '监控时长: ${report['monitoring_duration']}分钟\n'
            '生成时间: ${DateTime.now().toString().substring(0, 19)}\n\n'
            '当前指标:\n'
            '${_currentMetric?.toString() ?? "无数据"}\n\n'
            '${_averageMetric != null ? "平均指标:\n${_averageMetric.toString()}" : ""}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              // 这里可以实现实际的导出功能
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('报告已生成（演示功能）')),
              );
            },
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }
}