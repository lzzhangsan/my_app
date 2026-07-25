  Future<void> _resolveAndDownloadSmartCandidateInBackground(
    Map<String, dynamic> task,
    Map<String, String> candidate,
  ) async {
    if (!identical(_smartDownloadTask, task)) return;
    final candidates = task['candidates'] as List<Map<String, String>>;
    final currentIndex = ((task['index'] as int) - 1).clamp(
      0,
      candidates.length - 1,
    );
    final probeWidth = min(12, 4 + ((task['searchCycle'] as int?) ?? 0) * 2);
    final probeEnd = min(currentIndex + probeWidth, candidates.length);
    final probes = <Map<String, dynamic>>[
      for (var i = currentIndex; i < probeEnd; i++)
        <String, dynamic>{'index': i, 'candidate': candidates[i]},
    ];
    final initialPageUrl = (candidate['url'] ?? '').trim();
    final candidateListUrl = (task['candidateListUrl'] ?? '').toString();
    final taskHost = (task['host'] ?? '').toString();
    final is91 = taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com');
    final currentlyOnCandidateList =
        candidateListUrl.isNotEmpty &&
        (is91
            ? _isSame91TaskPage(_currentUrl, candidateListUrl)
            : _currentUrl == candidateListUrl);
    if (is91 && currentlyOnCandidateList) {
      task['strict91ActiveCardUrl'] = initialPageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['cardListUrl'] = candidateListUrl;
      task['resumeCandidateQueueAfterCard'] = true;
      task['activeDiscoveryStrategy'] = 'click_media_card';
      task['cardEnteredAt'] = DateTime.now();
      task['nextMediaLabel'] =
          (candidate['title'] ?? '').trim().isEmpty
              ? '下一个关键词视频'
              : (candidate['title'] ?? '').trim();
      task['nextMediaStatus'] = '正在直接进入关键词视频详情';
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      if (!identical(_smartDownloadTask, task)) return;
      if (!clicked) {
        // Fall back only for this card when its DOM click handler is missing.
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
      } else {
        debugPrint(
          'Smart 91: clicked ordered card ${task['index']}/${candidates.length} $initialPageUrl',
        );
      }
      return;
    }
    if (currentlyOnCandidateList &&
        !_smartStrategyCircuitOpen(task, 'click_media_card')) {
      task['phase'] = 'visiting_clicked_card';
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      if (!identical(_smartDownloadTask, task)) return;
      if (clicked) {
        task['cardListUrl'] = candidateListUrl;
        task['resumeCandidateQueueAfterCard'] = true;
        task['activeDiscoveryStrategy'] = 'click_media_card';
        task['nextMediaLabel'] =
            (candidate['title'] ?? '').trim().isEmpty
                ? '下一个视频卡片'
                : (candidate['title'] ?? '').trim();
        task['nextMediaStatus'] = '正在进入卡片深挖地址';
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'visiting_clicked_card') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return;
      }
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: false,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      task['phase'] = 'resolving_candidate_background';
    }
    if (_smartStrategyCircuitOpen(task, 'source_parallel')) {
      task['phase'] = 'visiting_candidate';
      if (_smartStrategyCircuitOpen(task, 'click_media_card')) {
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
        return;
      }
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: clicked,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      if (clicked) {
        task['activeDiscoveryStrategy'] = 'click_media_card';
      } else {
        _loadUrl(initialPageUrl);
      }
      return;
    }
    final id = (task['discoveryTaskId'] ?? '').toString();
    if (id.isNotEmpty) {
      _updateDownloadTask(
        id,
        progressDetail:
            '正在并行解析候选 ${currentIndex + 1}-$probeEnd/${candidates.length} · 已保存 ${task['success']}/${task['target']}',
      );
    }
    final preheated =
        task['preheatedVideoCandidates'] as Map<String, List<String>>;
    final sourceWatch = Stopwatch()..start();
    final extractedBatch = await Future.wait(
      probes.map((probe) async {
        final row = probe['candidate'] as Map<String, String>;
        final url = (row['url'] ?? '').trim();
        final cached = preheated.remove(url);
        if (cached != null && cached.isNotEmpty) {
          return <String, dynamic>{...probe, 'urls': cached};
        }
        final extracted = await _resniffFavoriteCandidatesFromSourcePage(
          url,
        ).timeout(const Duration(seconds: 7), onTimeout: () => <String>[]);
        return <String, dynamic>{...probe, 'urls': extracted};
      }),
    );
    sourceWatch.stop();
    if (!identical(_smartDownloadTask, task)) return;
    final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
    Map<String, dynamic>? selected;
    List<String> urls = const <String>[];
    for (final probe in extractedBatch) {
      final probeCandidate = probe['candidate'] as Map<String, String>;
      final probePageUrl = (probeCandidate['url'] ?? '').trim();
      final resolved =
          (probe['urls'] as List<String>)
              .where((url) => !_isLikelyAdUrl(url))
              .where(
                (url) =>
                    !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
              )
              .toSet()
              .toList();
      if (resolved.isNotEmpty) preheated[probePageUrl] = resolved;
      if (resolved.isNotEmpty) {
        selected = probe;
        urls = resolved;
        break;
      }
    }
    if (selected == null) {
      _recordSmartStrategyOutcome(
        task,
        'source_parallel',
        success: false,
        elapsedMs: sourceWatch.elapsedMilliseconds,
      );
      // 动态播放器无法从 HTML 解析时，真实点击当前页的媒体卡片。
      task['phase'] = 'visiting_candidate';
      if (_smartStrategyCircuitOpen(task, 'click_media_card')) {
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
        return;
      }
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: clicked,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      if (!identical(_smartDownloadTask, task)) return;
      if (clicked) {
        task['activeDiscoveryStrategy'] = 'click_media_card';
      } else {
        _loadUrl(initialPageUrl);
      }
      return;
    }
    task['activeDiscoveryStrategy'] = 'source_parallel';

    final selectedIndex = selected['index'] as int;
    final selectedCandidate = selected['candidate'] as Map<String, String>;
    final pageUrl = (selectedCandidate['url'] ?? '').trim();
    final title = (selectedCandidate['title'] ?? pageUrl).trim();
    final visited = task['visitedPageUrls'] as Set<String>;
    for (var i = currentIndex; i <= selectedIndex; i++) {
      visited.add((candidates[i]['url'] ?? '').trim());
    }
    task['index'] = selectedIndex + 1;

    final nextReadyIndex = extractedBatch.indexWhere((probe) {
      final index = probe['index'] as int;
      final row = probe['candidate'] as Map<String, String>;
      return index > selectedIndex &&
          preheated.containsKey((row['url'] ?? '').trim());
    });
    if (nextReadyIndex >= 0) {
      final nextRow =
          extractedBatch[nextReadyIndex]['candidate'] as Map<String, String>;
      task['nextMediaPreheated'] = true;
      task['nextMediaLabel'] =
          (nextRow['title'] ?? '').trim().isEmpty
              ? '下一个站内视频'
              : (nextRow['title'] ?? '').trim();
      task['nextMediaStatus'] = '待下载（地址已解析）';
    } else {
      unawaited(_preheatSmartCandidateAddresses(task, probeEnd));
    }

    final contextKey = _normalizeVideoSourceUrl(urls.first);
    final attemptedContexts = task['attemptedVideoContexts'] as Set<String>;
    if (!attemptedContexts.add(contextKey)) {
      _recordSmartStrategyOutcome(
        task,
        'source_parallel',
        success: false,
        elapsedMs: sourceWatch.elapsedMilliseconds,
      );
      task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
      _visitNextSmartCandidate(task);
      return;
    }

    var ok = false;
    var failureType = '';
    if (await _smartVideoSizeAllowed(task, urls, pageUrl, 0)) {
      ok = await _downloadMediaRobustly(
        item: <String, dynamic>{
          'title': title,
          'pageUrl': pageUrl,
          'videoUrl': urls.first,
          'candidateUrls': urls,
          'downloadOrigin': 'smart_batch',
          'allowSourceUrlReuse': _isElementBoundFeedPage(pageUrl),
          'smartTask': task,
        },
        showModalDialog: false,
        showResultHint: false,
        onFailureType: (type) => failureType = type,
        minFileBytes: task['effectiveMinVideoBytes'] as int?,
        maxFileBytes: task['effectiveMaxVideoBytes'] as int?,
      );
    } else {
      failureType = 'outside_requested_size_range';
    }
    if (!identical(_smartDownloadTask, task)) return;
    _recordSmartStrategyOutcome(
      task,
      'source_parallel',
      success: ok,
      elapsedMs: sourceWatch.elapsedMilliseconds,
    );
    if (failureType == 'already_in_library' ||
        failureType == 'already_in_smart_task') {
      duplicateUrlKeys.add(contextKey);
      task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
    } else if (failureType == 'outside_requested_size_range') {
      task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
    } else if (failureType == 'invalid_smart_media_content') {
      task['invalidSkipped'] = ((task['invalidSkipped'] as int?) ?? 0) + 1;
    }
    task[ok ? 'success' : 'failed'] =
        (task[ok ? 'success' : 'failed'] as int) + 1;
    _updateSmartDiscoveryProgress(task, 'visiting_candidate');
    if ((task['success'] as int) >= (task['target'] as int)) {
      await _finishSmartDownload();
    } else {
      _visitNextSmartCandidate(task);
    }
  }
