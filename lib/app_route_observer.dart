import 'package:flutter/material.dart';

/// 全局路由观察，用于目录页等在「上层 push 新页面」时暂停背景视频等。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
