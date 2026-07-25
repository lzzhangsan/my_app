  Future<void> _startSmartDownload({
    required Map<String, dynamic> website,
    required String keyword,
    required int targetCount,
    required MediaType mediaType,
    bool startFromCurrentPage = false,
    int? minVideoBytes,
    int? maxVideoBytes,
    bool autoVideoSizeRange = false,
  }) async {
    final rawUrl = (website['url'] ?? '').toString().trim();
    final normalized =
        rawUrl.startsWith('http://') || rawUrl.startsWith('https://')
            ? rawUrl
            : 'https://$rawUrl';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return;
    final normalizedHost = uri.host.toLowerCase().replaceFirst(
      RegExp(r'^www\.'),
      '',
    );
    final keywordFirstOn91 =
        startFromCurrentPage &&
        keyword.trim().isNotEmpty &&
        (normalizedHost == '91cg1.com' ||
            normalizedHost.endsWith('.91cg1.com'));
    final strictXFeedMode =
        startFromCurrentPage &&
        (normalizedHost == 'x.com' ||
            normalizedHost.endsWith('.x.com') ||
            normalizedHost == 'twitter.com' ||
            normalizedHost.endsWith('.twitter.com'));
    final keywordFirstOnX = strictXFeedMode && keyword.trim().isNotEmpty;
    await _loadSmartDownload24hRegistry();
    await _loadSmartStrategyProfiles();
    final startedAt = DateTime.now();
    final deadlineAt = startedAt.add(const Duration(hours: 5));
    final strict91SearchUrl =
        keywordFirstOn91
            ? '${uri.origin}/search/${Uri.encodeComponent(keyword.trim())}/'
            : '';
    final strictXSearchUrl =
        keywordFirstOnX
            ? '${uri.origin}/search?q=${Uri.encodeQueryComponent(keyword.trim())}&src=typed_query&f=media'
            : '';
    if (startFromCurrentPage && keyword.trim().isEmpty) {
      await _anchorSmartSeedForType(mediaType);
    }
    _smartDownloadTask = <String, dynamic>{
      'phase':
          keywordFirstOn91
              ? 'collecting_search_results'
              : keywordFirstOnX
              ? 'x_search_loading'
              : startFromCurrentPage
              ? 'visiting_seed'
              : 'opening_site',
      'siteUrl': normalized,
      'host': normalizedHost,
      'keyword': keyword,
      'mediaType': mediaType,
      'target': targetCount,
      'minVideoBytes': minVideoBytes,
      'maxVideoBytes': maxVideoBytes,
      'autoVideoSizeRange': autoVideoSizeRange,
      'effectiveMinVideoBytes': minVideoBytes,
      'effectiveMaxVideoBytes': maxVideoBytes,
      'matchStage':
          keywordFirstOn91
              ? '关键词优先 · 站内搜索'
              : keyword.isEmpty
              ? '无关键词 · 邻近媒体优先'
              : '精确匹配',
      'success': 0,
      'failed': 0,
      'index': 0,
      'candidates': <Map<String, String>>[],
      'seenMediaUrls': <String>{},
      'attemptedVideoContexts': <String>{},
      'duplicateVideoUrlKeys': <String>{},
      'videoMediaStates': <String, String>{},
      'reservedMediaNameKeys': <String>{},
      'reservedMediaTitleKeys': <String>{},
      'clickedSmartCardKeys': <String>{},
      'exploratoryClickedKeys': <String>{},
      'feedScans': 0,
      'feedNoNew': 0,
      'feedDirection': 1,
      'discoveryRound': 0,
      'searchCycle': 0,
      'strategyStats': <String, dynamic>{},
      'startedAt': startedAt,
      'deadlineAt': deadlineAt,
      'lastAdvanceAt': startedAt,
      'visitedPageUrls': <String>{},
      'discoveryPageQueue': <String>[],
      'queuedDiscoveryUrls': <String>{},
      'visitedDiscoveryUrls': <String>{},
      'syntheticRouteFailures': 0,
      'disableSyntheticRoutes': false,
      'preheatedVideoCandidates': <String, List<String>>{},
      'startedFromCurrentPage': startFromCurrentPage,
      'originUrl': _currentUrl,
      'strict91KeywordMode': keywordFirstOn91,
      'strict91SearchUrl': strict91SearchUrl,
      'strict91QueueReady': false,
      'strict91ActiveCardUrl': '',
      'strict91ReturnAttempts': 0,
      'strictXFeedMode': strictXFeedMode,
      'strictXSearchUrl': strictXSearchUrl,
      'xVisitedStatusIds': <String>{},
    };
    final activeTask = _smartDownloadTask!;
    activeTask['deadlineTimer'] = Timer(
      deadlineAt.difference(DateTime.now()),
      () {
        if (identical(_smartDownloadTask, activeTask)) {
          unawaited(_finishSmartDownload('已达到单次任务 5 小时时间上限'));
        }
      },
    );
    activeTask['watchdogTimer'] = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) {
      if (!identical(_smartDownloadTask, activeTask)) return;
      if (!DateTime.now().isBefore(deadlineAt)) {
        unawaited(_finishSmartDownload('已达到单次任务 5 小时时间上限'));
        return;
      }
      final hasActiveMediaDownload = _downloadTasks.any(
        (row) =>
            row['isSmartBatchMedia'] == true && row['status'] == 'downloading',
      );
      if (hasActiveMediaDownload || _smartDownloadAdvancing) return;
      final lastAdvance = activeTask['lastAdvanceAt'] as DateTime? ?? startedAt;
      if (DateTime.now().difference(lastAdvance) <
          const Duration(seconds: 60)) {
        return;
      }
      activeTask['lastAdvanceAt'] = DateTime.now();
      if (activeTask['phase'] == 'resolving_candidate_background') {
        _visitNextSmartCandidate(activeTask);
      } else {
        unawaited(_advanceSmartDownload(_currentUrl));
      }
    });
    final discoveryQueue =
        _smartDownloadTask!['discoveryPageQueue'] as List<String>;
    final queuedDiscoveryUrls =
        _smartDownloadTask!['queuedDiscoveryUrls'] as Set<String>;
    void enqueueDiscoveryPage(String value) {
      final candidateUri = Uri.tryParse(value);
      if (candidateUri == null ||
          candidateUri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') !=
              uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ||
          value == _currentUrl ||
          !queuedDiscoveryUrls.add(value)) {
        return;
      }
      discoveryQueue.add(value);
    }

    final seedUri = Uri.tryParse(
      startFromCurrentPage ? _currentUrl : normalized,
    );
    if (!keywordFirstOn91 && seedUri != null && seedUri.host.isNotEmpty) {
      final segments =
          seedUri.pathSegments.where((part) => part.isNotEmpty).toList();
      while (segments.isNotEmpty) {
        segments.removeLast();
        enqueueDiscoveryPage(
          seedUri
              .replace(pathSegments: segments, query: '', fragment: '')
              .toString(),
        );
      }
    }
    final discoveryTaskId = const Uuid().v4();
    final discoveryCancelToken = CancelToken();
    _smartDownloadTask!['discoveryTaskId'] = discoveryTaskId;
    _smartDownloadTask!['discoveryCancelToken'] = discoveryCancelToken;
    if (mounted) {
      _addDownloadTask(
        discoveryTaskId,
        'smart://${keyword.isEmpty ? 'nearby-media' : keyword}',
        mediaType,
        discoveryCancelToken,
        displayName: '智能采集：${keyword.isEmpty ? '当前媒体附近' : keyword}',
        isSmartDiscovery: true,
      );
      _updateDownloadTask(
        discoveryTaskId,
        progress: 0.02,
        progressDetail: '正在解析当前页面媒体地址...',
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '智能下载已开始：${mediaType == MediaType.image ? '图片' : '视频'} · ${keyword.isEmpty ? '按当前媒体从近到远' : keyword} · $targetCount 个',
        ),
      ),
    );
    if (keywordFirstOn91) {
      _smartDownloadTask!['activeDiscoveryStrategy'] = 'site_search';
      _loadUrl(strict91SearchUrl);
    } else if (keywordFirstOnX) {
      _smartDownloadTask!['activeDiscoveryStrategy'] = 'x_media_search';
      _loadUrl(strictXSearchUrl);
    } else if (startFromCurrentPage) {
      unawaited(_advanceSmartDownload(_currentUrl));
    } else {
      _loadUrl(normalized);
    }
  }
