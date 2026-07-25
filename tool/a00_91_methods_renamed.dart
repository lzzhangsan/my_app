  // ========== a00c4bd 91 pipeline (absolute copy, do not remix) ==========

  Future<void> _startSmartDownload91A00({
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
      'a00_91_pipeline': true,
      'siteProfile': '91',
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
        _visitNextSmartCandidate91A00(activeTask);
      } else {
        unawaited(_advanceSmartDownload91A00(_currentUrl));
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
      unawaited(_advanceSmartDownload91A00(_currentUrl));
    } else {
      _loadUrl(normalized);
    }
  }


  Future<void> _advanceSmartDownload91A00(String loadedUrl) async {
    final task = _smartDownloadTask;
    final controller = _controller;
    if (task == null || controller == null) return;
    if (_smartDownloadAdvancing) {
      if (task['advanceRetryScheduled'] != true) {
        task['advanceRetryScheduled'] = true;
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          if (!identical(_smartDownloadTask, task)) return;
          task['advanceRetryScheduled'] = false;
          unawaited(_advanceSmartDownload91A00(_currentUrl));
        });
      }
      return;
    }
    task['advanceRetryScheduled'] = false;
    final discoveryToken = task['discoveryCancelToken'] as CancelToken?;
    if (discoveryToken?.isCancelled == true) {
      await _finishSmartDownload('用户已停止任务');
      return;
    }
    final deadlineAt = task['deadlineAt'] as DateTime?;
    if (deadlineAt != null && !DateTime.now().isBefore(deadlineAt)) {
      await _finishSmartDownload('已达到单次任务 5 小时时间上限');
      return;
    }
    _smartDownloadAdvancing = true;
    task['lastAdvanceAt'] = DateTime.now();
    try {
      final phase = task['phase']?.toString() ?? '';
      final taskHost = (task['host'] ?? '').toString();
      final is91KeywordTask =
          (taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com')) &&
          (task['keyword'] ?? '').toString().trim().isNotEmpty;
      final strict91Mode = task['strict91KeywordMode'] == true;
      final strictXFeedMode = task['strictXFeedMode'] == true;
      final strictXSearchUrl = (task['strictXSearchUrl'] ?? '').toString();
      final strict91SearchUrl = (task['strict91SearchUrl'] ?? '').toString();
      final actualLoadedUrl =
          (await controller.getUrl())?.toString() ?? loadedUrl;

      if (strictXFeedMode && phase == 'x_search_loading') {
        final actualUri = Uri.tryParse(actualLoadedUrl);
        final onSearchPage =
            actualUri != null &&
            actualUri.pathSegments.isNotEmpty &&
            actualUri.pathSegments.first == 'search';
        if (!onSearchPage) {
          _loadUrl(strictXSearchUrl);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        task['phase'] = 'scanning_feed';
        _continueSmartFeed(task, madeProgress: false);
        return;
      }

      if (strictXFeedMode && phase == 'x_search_returning') {
        if (strictXSearchUrl.isEmpty) {
          final returnUrl = (task['xReturnUrl'] ?? '').toString().trim();
          if (_isBlankHistoryUrl(actualLoadedUrl) ||
              !_isXPlatformPage(actualLoadedUrl) ||
              (returnUrl.startsWith('http') &&
                  !_isSameLoadedDocument(returnUrl, actualLoadedUrl))) {
            if (returnUrl.startsWith('http')) {
              _loadUrl(returnUrl);
            } else {
              _loadUrl((task['siteUrl'] ?? '').toString());
            }
            return;
          }
          task['phase'] = 'scanning_feed';
          _continueSmartFeed(task, madeProgress: false);
          return;
        }
        final actualUri = Uri.tryParse(actualLoadedUrl);
        final onSearchPage =
            actualUri != null &&
            actualUri.pathSegments.isNotEmpty &&
            actualUri.pathSegments.first == 'search';
        if (!onSearchPage) {
          if (await controller.canGoBack()) {
            await controller.goBack();
          } else {
            _loadUrl(strictXSearchUrl);
          }
          return;
        }
        task['phase'] = 'scanning_feed';
        _continueSmartFeed(task, madeProgress: false);
        return;
      }

      if (strict91Mode && phase == 'strict91_returning') {
        if (_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
          task['strict91ReturnAttempts'] = 0;
          task['strict91ActiveCardUrl'] = '';
          task.remove('cardEnteredAt');
          task['phase'] = 'visiting_candidate';
          debugPrint('Smart 91 strict: restored remembered search page');
          _visitNextSmartCandidate91A00(task);
          return;
        }
        final attempts = (task['strict91ReturnAttempts'] as int?) ?? 0;
        task['strict91ReturnAttempts'] = attempts + 1;
        if (attempts < 3 && await controller.canGoBack()) {
          debugPrint(
            'Smart 91 strict: backing through intermediate page $actualLoadedUrl',
          );
          await controller.goBack();
        } else {
          debugPrint('Smart 91 strict: restoring $strict91SearchUrl');
          _loadUrl(strict91SearchUrl);
        }
        return;
      }

      if (strict91Mode && phase == 'visiting_clicked_card') {
        final activeCardUrl = (task['strict91ActiveCardUrl'] ?? '').toString();
        if (activeCardUrl.isNotEmpty &&
            !_isSame91TaskPage(activeCardUrl, actualLoadedUrl)) {
          if (_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
            final clicked = await _clickSmartCandidateLink(activeCardUrl);
            if (!clicked) _loadUrl(activeCardUrl);
          } else {
            _loadUrl(activeCardUrl);
          }
          debugPrint(
            'Smart 91 strict: rejected unrelated page $actualLoadedUrl; expected $activeCardUrl',
          );
          return;
        }
      }
      if (phase == 'returning_candidate_list') {
        task['phase'] = 'visiting_candidate';
        _visitNextSmartCandidate91A00(task);
        return;
      }
      if ((phase == 'scanning_feed' ||
              phase == 'collecting_site_results' ||
              phase == 'collecting_search_results' ||
              phase == 'visiting_candidate') &&
          await _recoverSmartDownloadErrorPage(task, loadedUrl)) {
        return;
      }
      _updateSmartDiscoveryProgress(task, phase);
      if (phase == 'opening_site') {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if ((task['keyword'] ?? '').toString().trim().isEmpty) {
          task['phase'] = 'scanning_feed';
          Future<void>.delayed(
            const Duration(milliseconds: 120),
            () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
          );
          return;
        }
        task['phase'] = 'collecting_site_results';
        final keywordJson = jsonEncode(task['keyword']);
        final submitted = await controller.evaluateJavascript(
          source: '''
            (() => {
              const keyword = $keywordJson;
              const inputs = Array.from(document.querySelectorAll(
                'input[type="search"], input[name="q"], input[name*="search" i], input[placeholder*="search" i], input[placeholder*="搜索"]'
              ));
              const input = inputs.find(e => e.offsetParent !== null) || inputs[0];
              if (!input) return false;
              input.focus();
              input.value = keyword;
              input.dispatchEvent(new Event('input', {bubbles:true}));
              input.dispatchEvent(new Event('change', {bubbles:true}));
              const form = input.form || input.closest('form');
              if (form) {
                if (form.requestSubmit) form.requestSubmit(); else form.submit();
              } else {
                input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, bubbles:true}));
              }
              return true;
            })()
          ''',
        );
        final didSubmit = submitted == true || submitted.toString() == 'true';
        if (!didSubmit) {
          Future<void>.delayed(
            const Duration(milliseconds: 200),
            () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
          );
        } else {
          Future<void>.delayed(
            const Duration(seconds: 3),
            () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
          );
        }
        return;
      }

      if (phase == 'collecting_site_results' ||
          phase == 'collecting_search_results') {
        if (strict91Mode) {
          if (!_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
            _loadUrl(strict91SearchUrl);
            return;
          }
          if (task['strict91QueueReady'] == true &&
              (task['candidates'] as List).isNotEmpty) {
            task['phase'] = 'visiting_candidate';
            _visitNextSmartCandidate91A00(task);
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final hostJson = jsonEncode(task['host']);
        final keywordJson = jsonEncode(task['keyword']);
        final searchCycleDepth = (task['searchCycle'] as int?) ?? 0;
        final exhaustive = searchCycleDepth > 0;
        final limit = ((task['target'] as int) * 30 + searchCycleDepth * 80)
            .clamp(60, 1000);
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const targetHost = $hostJson;
              const keyword = $keywordJson.toLowerCase();
              const exhaustive = $exhaustive;
              // Avoid backslash escapes in injected regular expressions.
              // Dart string processing can otherwise corrupt the JS source.
              const tokens = keyword.split(' ')
                .map(v => v.trim()).filter(v => v.length >= 2).slice(0, 16);
              const seen = new Set();
              return Array.from(document.querySelectorAll('a[href]')).map((a, order) => {
                try {
                  const u = new URL(a.href, location.href);
                  const host = u.hostname.toLowerCase();
                  const normalizedHost = host.replace(/^www\./, '');
                  if (!(normalizedHost === targetHost || normalizedHost.endsWith('.' + targetHost))) return null;
                  u.hash = '';
                  const url = u.href;
                  if (seen.has(url) || u.pathname === '/' || url === location.href) return null;
                  if (!exhaustive && a.closest('header, nav, footer, aside, [role="navigation"]')) return null;
                  const path = u.pathname.toLowerCase();
                  const directMedia = /[.](m3u8|mp4|webm|mov)(?:\$|[?])/i.test(url);
                  const detailPath = /[/](archives?|posts?|videos?|watch|view|detail|movies?)[/]/i.test(path);
                  const taxonomyPath = /[/](category|categories|tags?|authors?|search|feed|page)[/]/i.test(path);
                  const blockedPath = /[/](login|register|account|logout|cart|checkout|user)[/]/i.test(path);
                  const mediaCard = !!a.querySelector('img, video, picture') ||
                    !!a.closest('article, figure, [class*="card"], [class*="post"], [class*="item"]');
                  if (blockedPath) return null;
                  if (!directMedia && !detailPath && !mediaCard && !taxonomyPath && !exhaustive) return null;
                  seen.add(url);
                  const title = (a.innerText || a.title || a.getAttribute('aria-label') ||
                    (a.querySelector('img') && a.querySelector('img').alt) || '').trim();
                  const haystack = (title + ' ' + url).toLowerCase();
                  const tokenHits = tokens.reduce((sum, token) =>
                    sum + (haystack.includes(token) ? 1 : 0), 0);
                  const exact = keyword.length > 0 && haystack.includes(keyword);
                  const tier = exact ? 2 : (tokenHits > 0 ? 1 : 0);
                  const score = (exact ? 100000 : 0) +
                    tokenHits * 5000 +
                    (directMedia ? 80000 : 0) +
                    (detailPath ? 50000 : 0) +
                    (mediaCard ? 20000 : 0) +
                    Math.max(0, 2000 - order);
                  return {url, title: title || document.title || url, score, tier, order,
                    scopeOnly: !directMedia && !detailPath &&
                      (taxonomyPath || (exhaustive && !mediaCard))};
                } catch (_) { return null; }
              }).filter(Boolean).sort((a,b) => b.score - a.score).slice(0, $limit);
            })()
          ''',
        );
        final candidates = <Map<String, String>>[];
        final discoveryQueue = task['discoveryPageQueue'] as List<String>;
        final queuedDiscoveryUrls = task['queuedDiscoveryUrls'] as Set<String>;
        final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
        final hasKeyword = (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final loadedUri = Uri.tryParse(loadedUrl);
        final isSearchResultsPage =
            loadedUri != null &&
            (loadedUri.pathSegments.contains('search') ||
                loadedUri.queryParameters.containsKey('s') ||
                loadedUri.queryParameters.containsKey('q'));
        final taskHost = (task['host'] ?? '').toString();
        final isKeywordFirst91 =
            taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com');
        final requiredTier =
            !hasKeyword || (isSearchResultsPage && !isKeywordFirst91)
                ? 0
                : exhaustiveCycle
                ? 0
                : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
        if (result is List) {
          for (final row in result) {
            if (row is Map && row['url'] != null) {
              final rowUrl = row['url'].toString();
              if (isKeywordFirst91 && !_is91ContentPage(rowUrl)) continue;
              if (row['scopeOnly'] == true) {
                if (isKeywordFirst91) {
                  final rowUri = Uri.tryParse(rowUrl);
                  final segments = rowUri?.pathSegments ?? const <String>[];
                  final isSameKeywordSearch =
                      segments.length >= 2 &&
                      segments.first.toLowerCase() == 'search' &&
                      segments[1].trim().toLowerCase() ==
                          (task['keyword'] ?? '')
                              .toString()
                              .trim()
                              .toLowerCase();
                  if (!isSameKeywordSearch) continue;
                }
                if (discoveryQueue.length < 300 &&
                    queuedDiscoveryUrls.add(rowUrl)) {
                  discoveryQueue.add(rowUrl);
                }
                continue;
              }
              final tier = int.tryParse((row['tier'] ?? '0').toString()) ?? 0;
              if (tier < requiredTier) continue;
              candidates.add({
                'url': rowUrl,
                'title': (row['title'] ?? '').toString(),
                'tier': '$tier',
                'order': (row['order'] ?? '0').toString(),
              });
            }
          }
        }
        if (isKeywordFirst91) {
          // Preserve the visible search-result order. The first 91 result is
          // commonly stale or promoted, so begin with the second card.
          candidates.sort((left, right) {
            final leftOrder = int.tryParse(left['order'] ?? '') ?? 0;
            final rightOrder = int.tryParse(right['order'] ?? '') ?? 0;
            return leftOrder.compareTo(rightOrder);
          });
          if (candidates.isNotEmpty) {
            final skipped = candidates.removeAt(0);
            (task['visitedPageUrls'] as Set<String>).add(skipped['url'] ?? '');
            debugPrint('Smart 91: skipped first search card ${skipped['url']}');
          }
          int searchPageNumber(String value) {
            final segments = Uri.tryParse(value)?.pathSegments ?? const [];
            for (final segment in segments.reversed) {
              final number = int.tryParse(segment);
              if (number != null) return number;
            }
            return 1;
          }

          discoveryQueue.sort(
            (left, right) =>
                searchPageNumber(left).compareTo(searchPageNumber(right)),
          );
        }
        final activeStrategy =
            (task['activeDiscoveryStrategy'] ?? '').toString();
        if (<String>{
          'actual_scope_link',
          'site_search',
          'synthetic_route',
        }.contains(activeStrategy)) {
          _recordSmartStrategyOutcome(
            task,
            activeStrategy,
            success: candidates.isNotEmpty,
          );
        }
        if (candidates.isEmpty) {
          // Some sites render playable cards through CSS/JavaScript and expose
          // no useful detail links to the source scanner. Exhaust real cards
          // on the current productive page before guessing another route.
          if (await _openNearestSmartMediaCard(task, loadedUrl)) return;
          if (_allowSmartExploratoryClick(task) &&
              await _openExploratorySmartTarget(task, loadedUrl)) {
            return;
          }
          _broadenSmartDiscovery(task, '当前搜索路径没有候选');
          return;
        }
        task['candidates'] = candidates;
        task['candidateListUrl'] = strict91Mode ? strict91SearchUrl : loadedUrl;
        if (strict91Mode) task['strict91QueueReady'] = true;
        task['index'] = 0;
        task['phase'] = 'visiting_candidate';
        _visitNextSmartCandidate91A00(task);
        return;
      }

      if (phase == 'visiting_candidate' ||
          phase == 'visiting_seed' ||
          phase == 'visiting_clicked_card' ||
          phase == 'x_viewing_search_card' ||
          phase == 'scanning_feed') {
        final candidatePreheated =
            phase == 'visiting_candidate' &&
            task.remove('nextMediaPreheated') == true;
        if (candidatePreheated) task['nextMediaStatus'] = '马上下载';
        await Future<void>.delayed(
          Duration(
            milliseconds:
                phase == 'visiting_seed'
                    ? 250
                    : phase == 'scanning_feed'
                    ? 400
                    : phase == 'visiting_clicked_card' && is91KeywordTask
                    ? 1200
                    : (candidatePreheated ? 180 : 450),
          ),
        );
        final successBefore = task['success'] as int;
        if (!strict91Mode) {
          unawaited(_preheatNextSmartMedia(task, phase));
        }
        if (task['mediaType'] == MediaType.image) {
          await _downloadSmartImagesFromCurrentPage(task);
          if (phase == 'visiting_clicked_card') {
            final strategy = (task['activeDiscoveryStrategy'] ?? '').toString();
            if (strategy == 'click_media_card' ||
                strategy == 'exploratory_click') {
              _recordSmartStrategyOutcome(
                task,
                strategy,
                success: (task['success'] as int) > successBefore,
              );
            }
          }
          if (_smartDownloadTask == null) return;
          if (strictXFeedMode &&
              phase == 'scanning_feed' &&
              (task['strictXSearchUrl'] ?? '').toString().isNotEmpty &&
              (task['success'] as int) == successBefore &&
              await _openActiveXSmartCard(task)) {
            return;
          }
          if ((task['success'] as int) >= (task['target'] as int)) {
            await _finishSmartDownload();
          } else if (phase == 'x_viewing_search_card') {
            await _returnFromXSmartCard(task);
          } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
            _continueSmartFeed(
              task,
              madeProgress: (task['success'] as int) > successBefore,
            );
          } else {
            _visitNextSmartCandidate91A00(task);
          }
          return;
        }
        final scopeDiscoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final scopeHasKeyword =
            (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final preferSeedScope =
            !scopeHasKeyword &&
            task['startedFromCurrentPage'] == true &&
            scopeDiscoveryRound == 0;
        final preferSeedMedia =
            phase == 'visiting_seed' ||
            (strictXFeedMode && phase == 'scanning_feed');
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const preferSeedScope = $preferSeedScope;
              const preferSeedMedia = $preferSeedMedia;
              const allVideos = Array.from(document.querySelectorAll('video'));
              const activeXScope = $strictXFeedMode
                ? document.querySelector('[data-app-smart-x-active="1"]')
                : null;
              const scope = activeXScope || (preferSeedScope
                ? document.querySelector('[data-smart-seed-scope="1"]')
                : null);
              const scopedVideos = scope
                ? Array.from(scope.querySelectorAll('video'))
                : [];
              // In X's immersive viewer adjacent posts are preloaded. Once an
              // active scope exists, never fall back to those page-wide nodes.
              const videos = scope ? scopedVideos : allVideos;
              const visible = videos.filter(v => {
                const r = v.getBoundingClientRect();
                return r.width > 80 && r.height > 60 && r.bottom > 0 && r.top < innerHeight;
              });
              const seed = preferSeedMedia
                ? (scope?.querySelector('video[data-smart-seed-media="1"]') ||
                    document.querySelector('video[data-smart-seed-media="1"]'))
                : null;
              const video = seed || (visible.length ? visible : videos).sort((a,b) => {
                const ar = a.getBoundingClientRect();
                const br = b.getBoundingClientRect();
                const ad = Math.abs(ar.top + ar.height / 2 - innerHeight / 2);
                const bd = Math.abs(br.top + br.height / 2 - innerHeight / 2);
                return ad - bd || (b.clientWidth*b.clientHeight) - (a.clientWidth*a.clientHeight);
              })[0];
              if (!video) return {hasVideo:false, candidates:[]};
              try { video.muted = true; video.play().catch(() => {}); } catch (_) {}
              const urls = [video.currentSrc, video.src,
                ...Array.from(video.querySelectorAll('source')).map(s => s.src)]
                .filter(Boolean);
              const currentTweet = (() => {
                try { return new URL(location.href).searchParams.get('currentTweet') || ''; }
                catch (_) { return ''; }
              })();
              let nearby = video.closest(
                'article, figure, [class*="card"], [class*="item"], [class*="post"], [role="dialog"]'
              );
              if ($strictXFeedMode && currentTweet && !activeXScope) {
                const currentLink = Array.from(document.querySelectorAll('a[href*="/status/"]'))
                  .find(link => String(link.href || '').includes('/status/' + currentTweet));
                nearby = (currentLink && currentLink.closest(
                  'article[data-testid="tweet"], article, [role="dialog"], main'
                )) || nearby;
              }
              const xMediaIdFromScope = scope => {
                if (!scope) return '';
                const values = [];
                const add = value => { if (value) values.push(String(value)); };
                Array.from(scope.querySelectorAll('video, img')).forEach(media => {
                  add(media.poster); add(media.getAttribute && media.getAttribute('poster'));
                  if (String(media.tagName || '').toLowerCase() === 'img') {
                    add(media.currentSrc); add(media.src);
                    add(media.getAttribute && media.getAttribute('src'));
                    add(media.getAttribute && media.getAttribute('srcset'));
                  }
                });
                for (const value of values) {
                  const lower = value.toLowerCase();
                  for (const marker of ['/amplify_video_thumb/', '/ext_tw_video_thumb/',
                    '/tweet_video_thumb/', '/amplify_video/', '/ext_tw_video/', '/tweet_video/']) {
                    const index = lower.indexOf(marker);
                    if (index < 0) continue;
                    const id = value.substring(index + marker.length).split('/')[0];
                    if (id && Array.from(id).every(ch => ch >= '0' && ch <= '9')) return id;
                  }
                }
                return '';
              };
              const expectedXMediaId = $strictXFeedMode
                ? (xMediaIdFromScope(video) || xMediaIdFromScope(scope) ||
                    xMediaIdFromScope(nearby || video.parentElement))
                : '';
              const contextText = [video.title, video.getAttribute('aria-label'),
                nearby && nearby.innerText, document.title].filter(Boolean).join(' ');
              const elementIdentity = [
                video.getAttribute('data-id'), video.getAttribute('data-video-id'),
                video.getAttribute('data-post-id'), nearby && nearby.id,
                nearby && nearby.getAttribute('data-id'),
                nearby && nearby.getAttribute('data-post-id'),
                nearby && nearby.querySelector('a[href]')?.href
              ].filter(Boolean).join('|');
              const adContainers = Array.from(document.querySelectorAll(
                '[class*="video-ad" i], [class*="ad-container" i], [class*="ad-overlay" i], '
                + '[class*="preroll" i], [class*="pre-roll" i], [class*="vast" i], '
                + '[id*="video-ad" i], [id*="ad-container" i], [id*="preroll" i]'
              )).filter(el => {
                const r = el.getBoundingClientRect();
                return r.width > 20 && r.height > 10 && r.bottom > 0 && r.top < innerHeight;
              });
              const skipButton = Array.from(document.querySelectorAll(
                'button, [role="button"], a'
              )).find(el => {
                const r = el.getBoundingClientRect();
                if (r.width < 20 || r.height < 10 || r.bottom <= 0 || r.top >= innerHeight) return false;
                const label = (el.innerText || el.getAttribute('aria-label') || el.title || '').trim();
                return /^(skip|skip ad|跳过|跳过广告|关闭广告)/i.test(label);
              });
              if (skipButton) { try { skipButton.click(); } catch (_) {} }
              const adText = adContainers.map(el =>
                [el.id, el.className, el.innerText].join(' ')).join(' ').toLowerCase();
              const adLikely = adContainers.length > 0 &&
                /(video.?ad|ad.?container|ad.?overlay|preroll|pre.?roll|vast|广告|advertisement)/i.test(adText);
              return {hasVideo:true, url: urls[0] || '', candidates: Array.from(new Set(urls)),
                duration: Number.isFinite(video.duration) ? video.duration : 0,
                currentTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                title: document.title || location.href, contextText, elementIdentity,
                expectedXMediaId,
                adLikely, skipClicked: !!skipButton};
            })()
          ''',
        );
        var ok = false;
        final pageUrl = loadedUrl.isNotEmpty ? loadedUrl : _currentUrl;
        final urls = <String>[];
        var title = pageUrl;
        var contextText = '';
        var elementIdentity = '';
        var durationSec = 0.0;
        var currentTimeSec = 0.0;
        var adLikely = false;
        var expectedXMediaId = '';
        if (result is Map) {
          final rawCandidates = result['candidates'];
          if (rawCandidates is List) {
            urls.addAll(rawCandidates.map((e) => e.toString()));
          }
          final primary = (result['url'] ?? '').toString();
          if (primary.isNotEmpty) urls.insert(0, primary);
          title = (result['title'] ?? pageUrl).toString();
          contextText = (result['contextText'] ?? '').toString();
          elementIdentity = (result['elementIdentity'] ?? '').toString();
          durationSec = (result['duration'] as num?)?.toDouble() ?? 0.0;
          currentTimeSec = (result['currentTime'] as num?)?.toDouble() ?? 0.0;
          adLikely = result['adLikely'] == true;
          expectedXMediaId =
              (result['expectedXMediaId'] ?? '').toString().trim();
        }
        if (adLikely) {
          final now = DateTime.now();
          final waitStarted = task['adWaitStartedAt'] as DateTime? ?? now;
          task['adWaitStartedAt'] = waitStarted;
          final waited = now.difference(waitStarted);
          if (waited < const Duration(seconds: 60)) {
            final remaining =
                durationSec > currentTimeSec
                    ? max(0, (durationSec - currentTimeSec).ceil())
                    : 0;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '已识别前贴片广告，等待主视频${remaining > 0 ? '（约 $remaining 秒）' : ''}...',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 1500),
              () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
            );
            return;
          }
          task.remove('adWaitStartedAt');
          task['adSkipped'] = ((task['adSkipped'] as int?) ?? 0) + 1;
          if (phase == 'visiting_clicked_card') {
            await _returnFromSmartMediaCard91A00(task, madeProgress: false);
          } else if (phase == 'visiting_candidate') {
            _visitNextSmartCandidate91A00(task);
          } else {
            _continueSmartFeed(task, madeProgress: false);
          }
          return;
        }
        task.remove('adWaitStartedAt');
        final lastFeedMoveAt = task['lastFeedMoveAt'] as DateTime?;
        final freshCaptured =
            lastFeedMoveAt == null
                ? const <String>[]
                : _recentCapturedMediaCandidates(
                  MediaType.video,
                  pageUrl: pageUrl,
                  notBefore: lastFeedMoveAt,
                );
        final captured = <String>[
          ...(strict91Mode
              ? freshCaptured
              : freshCaptured.isNotEmpty
              ? freshCaptured
              : _recentCapturedMediaCandidates(
                MediaType.video,
                pageUrl: pageUrl,
              )),
        ];
        if (_isXPlatformPage(pageUrl)) {
          var boundMediaIds =
              expectedXMediaId.isNotEmpty
                  ? <String>{expectedXMediaId}
                  : urls
                      .map(_xMediaIdentity)
                      .where((id) => id.isNotEmpty)
                      .toSet();
          if (boundMediaIds.isEmpty && strictXFeedMode) {
            final grouped = <String, List<String>>{};
            for (final url in freshCaptured) {
              final id = _xMediaIdentity(url);
              if (id.isNotEmpty) (grouped[id] ??= <String>[]).add(url);
            }
            if (grouped.isNotEmpty) {
              final ranked =
                  grouped.entries.toList()..sort((left, right) {
                    int score(MapEntry<String, List<String>> entry) {
                      final rows = entry.value;
                      final hasMaster = rows.any(
                        (url) => RegExp(
                          r'/pl/[^/]+\.m3u8(?:\?|$)',
                        ).hasMatch(url.toLowerCase()),
                      );
                      final hasVideo = rows.any(
                        (url) =>
                            url.contains('/avc1/') || url.contains('/vid/'),
                      );
                      final hasAudio = rows.any(
                        (url) =>
                            url.contains('/mp4a/') || url.contains('/aud/'),
                      );
                      return (hasMaster ? 10000 : 0) +
                          (hasVideo ? 3000 : 0) +
                          (hasAudio ? 1000 : 0) +
                          rows.length * 10;
                    }

                    return score(right).compareTo(score(left));
                  });
              boundMediaIds = <String>{ranked.first.key};
            }
          }
          if (expectedXMediaId.isNotEmpty) {
            urls.removeWhere((url) {
              final id = _xMediaIdentity(url);
              return id.isNotEmpty && id != expectedXMediaId;
            });
          }
          if (boundMediaIds.isNotEmpty) {
            captured.retainWhere(
              (url) => boundMediaIds.contains(_xMediaIdentity(url)),
            );
          } else {
            // X preloads adjacent posts. Without an element-bound media ID,
            // page-wide traffic is not safe enough to select a download.
            captured.clear();
          }
          if (strictXFeedMode && expectedXMediaId.isNotEmpty) {
            final resolved = await _resolveXLongPressVideoCandidates(
              primaryUrl: urls.isEmpty ? '' : urls.first,
              candidates: <String>[...urls, ...captured],
              pageUrl: pageUrl,
              expectedMediaId: expectedXMediaId,
              notBefore: lastFeedMoveAt,
            );
            if (resolved.isNotEmpty) {
              urls
                ..clear()
                ..addAll(resolved);
              captured.clear();
            }
          }
        }
        if ((strict91Mode || _isElementBoundFeedPage(pageUrl)) &&
            captured.isNotEmpty) {
          urls.insertAll(0, captured);
        } else {
          urls.addAll(captured);
        }
        urls.removeWhere((url) => url.trim().isEmpty);
        urls.removeWhere(_isLikelyAdUrl);
        final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
        final uniqueUrls =
            urls
                .toSet()
                .where(
                  (url) =>
                      !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
                )
                .toList();
        if (_isXPlatformPage(pageUrl)) {
          uniqueUrls.sort(
            (left, right) => _scoreXVideoCandidate(
              right,
            ).compareTo(_scoreXVideoCandidate(left)),
          );
        }
        if (uniqueUrls.isEmpty &&
            phase == 'visiting_clicked_card' &&
            is91KeywordTask &&
            _is91ContentPage(pageUrl)) {
          final retries = (task['candidateResolveRetries'] as int?) ?? 0;
          final enteredAt =
              task['cardEnteredAt'] as DateTime? ?? DateTime.now();
          task['cardEnteredAt'] = enteredAt;

          // Some 91 players expose the real address only after play/visibility.
          await controller.evaluateJavascript(
            source: '''
              (() => {
                const videos = Array.from(document.querySelectorAll('video'));
                const video = videos.find(v => {
                  const r = v.getBoundingClientRect();
                  return r.width > 80 && r.height > 60;
                }) || videos[0];
                if (video) {
                  video.scrollIntoView({behavior:'auto', block:'center'});
                  video.muted = true;
                  try { video.load(); } catch (_) {}
                  try { video.play().catch(() => {}); } catch (_) {}
                }
                const play = Array.from(document.querySelectorAll(
                  'button, [role="button"], .play, [class*="play"]'
                )).find(el => {
                  const r = el.getBoundingClientRect();
                  const text = (el.innerText || el.title || el.getAttribute('aria-label') || '').trim();
                  return r.width > 20 && r.height > 20 &&
                    /(play|播放|开始)/i.test([text, el.className].join(' '));
                });
                if (play) { try { play.click(); } catch (_) {} }
                return {videos: videos.length, clickedPlay: !!play};
              })()
            ''',
          );

          if (retries == 2 || retries == 6) {
            final sourceUrls = await _resniffFavoriteCandidatesFromSourcePage(
              pageUrl,
            ).timeout(const Duration(seconds: 7), onTimeout: () => <String>[]);
            uniqueUrls.addAll(
              sourceUrls.where(
                (url) =>
                    !_isLikelyAdUrl(url) &&
                    !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
              ),
            );
          }

          final elapsed = DateTime.now().difference(enteredAt);
          if (uniqueUrls.isEmpty &&
              retries < 15 &&
              elapsed < const Duration(seconds: 25)) {
            task['candidateResolveRetries'] = retries + 1;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '正在深入解析当前关键词卡片 ${retries + 1}/15 · 已停留 ${elapsed.inSeconds} 秒',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 1000),
              () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
            );
            return;
          }
        }
        if (uniqueUrls.isEmpty &&
            strictXFeedMode &&
            (phase == 'visiting_seed' ||
                phase == 'scanning_feed' ||
                phase == 'x_viewing_search_card')) {
          final retries = (task['xCurrentPostResolveRetries'] as int?) ?? 0;
          final retryLimit =
              phase == 'scanning_feed' &&
                      (task['strictXSearchUrl'] ?? '').toString().isNotEmpty
                  ? 3
                  : 12;
          if (retries < retryLimit) {
            task['xCurrentPostResolveRetries'] = retries + 1;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '正在当前 X 帖子内等待真实视频地址 ${retries + 1}/$retryLimit，不会继续下滑...',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 800),
              () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
            );
            return;
          }
          task['xCurrentPostResolveRetries'] = 0;
          if (phase == 'scanning_feed' &&
              (task['strictXSearchUrl'] ?? '').toString().isNotEmpty &&
              await _openActiveXSmartCard(task)) {
            return;
          }
          if (phase == 'x_viewing_search_card') {
            await _returnFromXSmartCard(task);
            return;
          }
          _continueSmartFeed(task, madeProgress: false);
          return;
        }
        task['xCurrentPostResolveRetries'] = 0;
        if (uniqueUrls.isEmpty &&
            (phase == 'visiting_seed' || phase == 'scanning_feed')) {
          if (await _openNearestSmartMediaCard(task, pageUrl)) return;
        }
        if (uniqueUrls.isEmpty && phase == 'visiting_candidate') {
          final retries = (task['candidateResolveRetries'] as int?) ?? 0;
          final retryLimit = min(5, 2 + ((task['searchCycle'] as int?) ?? 0));
          if (retries < retryLimit) {
            task['candidateResolveRetries'] = retries + 1;
            Future<void>.delayed(
              const Duration(milliseconds: 650),
              () => unawaited(_advanceSmartDownload91A00(_currentUrl)),
            );
            return;
          }
        }
        task['candidateResolveRetries'] = 0;
        task.remove('cardEnteredAt');
        final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
        final hasKeyword = (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final trustedXKeywordResult =
            strictXFeedMode &&
            hasKeyword &&
            strictXSearchUrl.isNotEmpty &&
            (phase == 'scanning_feed' || phase == 'x_viewing_search_card');
        final requiredTier =
            !hasKeyword || trustedXKeywordResult
                ? 0
                : exhaustiveCycle
                ? 0
                : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
        final contextTier = _smartKeywordMatchTier(
          (task['keyword'] ?? '').toString(),
          '$title $contextText $pageUrl',
        );
        if (phase != 'visiting_seed' && contextTier < requiredTier) {
          task['relevanceSkipped'] =
              ((task['relevanceSkipped'] as int?) ?? 0) + 1;
          _updateSmartDiscoveryProgress(task, phase);
          if (phase == 'visiting_clicked_card') {
            await _returnFromSmartMediaCard91A00(task, madeProgress: false);
          } else if (phase == 'scanning_feed') {
            if (!strictXFeedMode &&
                await _openNearestSmartMediaCard(task, pageUrl)) {
              return;
            }
            _continueSmartFeed(task, madeProgress: false);
          } else {
            _visitNextSmartCandidate91A00(task);
          }
          return;
        }
        if (uniqueUrls.isNotEmpty) {
          final chosen = uniqueUrls.first;
          final normalizedChosen = _normalizeVideoSourceUrl(chosen);
          final normalizedContext =
              contextText.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
          final normalizedTitle = title.trim().toLowerCase();
          final meaningfulContext =
              normalizedContext.length >= 8 &&
              normalizedContext != normalizedTitle;
          final pagePath = Uri.tryParse(pageUrl)?.path ?? pageUrl;
          final stableElementIdentity = elementIdentity.trim();
          final contextPart =
              meaningfulContext
                  ? normalizedContext.substring(
                    0,
                    min(180, normalizedContext.length),
                  )
                  : normalizedChosen;
          final mediaContextKey =
              _isElementBoundFeedPage(pageUrl)
                  ? '$pagePath|$stableElementIdentity|${durationSec.round()}|$contextPart'
                  : normalizedChosen;
          final attemptedContexts =
              task['attemptedVideoContexts'] as Set<String>;
          if (!attemptedContexts.add(mediaContextKey)) {
            task['duplicateSkipped'] =
                ((task['duplicateSkipped'] as int?) ?? 0) + 1;
            _updateSmartDiscoveryProgress(task, phase);
            if (phase == 'visiting_seed' || phase == 'scanning_feed') {
              if (!strictXFeedMode &&
                  await _openNearestSmartMediaCard(task, pageUrl)) {
                return;
              }
              _continueSmartFeed(task, madeProgress: false);
            } else if (phase == 'visiting_clicked_card') {
              await _returnFromSmartMediaCard91A00(task, madeProgress: false);
            } else {
              _visitNextSmartCandidate91A00(task);
            }
            return;
          }
          final sizeAllowed = await _smartVideoSizeAllowed(
            task,
            uniqueUrls,
            pageUrl,
            durationSec,
          );
          if (sizeAllowed) {
            final seen = task['seenMediaUrls'] as Set<String>;
            final canTrustUrlIdentity =
                chosen.startsWith('http') && !_isElementBoundFeedPage(pageUrl);
            if (!canTrustUrlIdentity || seen.add(chosen)) {
              var smartFailureType = '';
              ok = await _downloadMediaRobustly(
                item: <String, dynamic>{
                  'title': title,
                  'pageUrl': pageUrl,
                  'videoUrl': chosen,
                  'candidateUrls': uniqueUrls,
                  'durationSec': durationSec,
                  'downloadOrigin': 'smart_batch',
                  'allowSourceUrlReuse': _isElementBoundFeedPage(pageUrl),
                  'smartTask': task,
                },
                showModalDialog: false,
                showResultHint: false,
                onFailureType: (type) => smartFailureType = type,
                minFileBytes: task['effectiveMinVideoBytes'] as int?,
                maxFileBytes: task['effectiveMaxVideoBytes'] as int?,
              );
              if (smartFailureType == 'outside_requested_size_range') {
                task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
              } else if (smartFailureType == 'invalid_smart_media_content') {
                task['invalidSkipped'] =
                    ((task['invalidSkipped'] as int?) ?? 0) + 1;
              } else if (smartFailureType == 'already_in_library' ||
                  smartFailureType == 'already_in_smart_task') {
                duplicateUrlKeys.add(normalizedChosen);
                task['duplicateSkipped'] =
                    ((task['duplicateSkipped'] as int?) ?? 0) + 1;
              }
            }
          } else {
            task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
          }
        }
        task[ok ? 'success' : 'failed'] =
            (task[ok ? 'success' : 'failed'] as int) + 1;
        if (phase == 'visiting_clicked_card') {
          final strategy = (task['activeDiscoveryStrategy'] ?? '').toString();
          if (strategy == 'click_media_card' ||
              strategy == 'exploratory_click') {
            _recordSmartStrategyOutcome(task, strategy, success: ok);
          }
        }
        _updateSmartDiscoveryProgress(task, phase);
        if ((task['success'] as int) >= (task['target'] as int)) {
          await _finishSmartDownload();
        } else if (phase == 'x_viewing_search_card') {
          await _returnFromXSmartCard(task);
        } else if (phase == 'visiting_clicked_card') {
          await _returnFromSmartMediaCard91A00(
            task,
            madeProgress: (task['success'] as int) > successBefore,
          );
        } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
          if (!ok &&
              !strictXFeedMode &&
              await _openNearestSmartMediaCard(task, pageUrl)) {
            return;
          }
          _continueSmartFeed(
            task,
            madeProgress: (task['success'] as int) > successBefore,
          );
        } else {
          _visitNextSmartCandidate91A00(task);
        }
      }
    } catch (e, st) {
      debugPrint('智能下载步骤失败: $e\n$st');
      if (_smartDownloadTask != null) {
        task['failed'] = (task['failed'] as int) + 1;
        final phase = task['phase']?.toString();
        if (phase == 'visiting_clicked_card') {
          await _returnFromSmartMediaCard91A00(task, madeProgress: false);
        } else if (phase == 'x_viewing_search_card') {
          await _returnFromXSmartCard(task);
        } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
          _continueSmartFeed(task, madeProgress: false);
        } else {
          _visitNextSmartCandidate91A00(task);
        }
      }
    } finally {
      _smartDownloadAdvancing = false;
    }
  }


  void _visitNextSmartCandidate91A00(Map<String, dynamic> task) {
    final candidates = task['candidates'] as List<Map<String, String>>;
    if (task['strict91KeywordMode'] == true) {
      final listUrl = (task['strict91SearchUrl'] ?? '').toString();
      if (listUrl.isNotEmpty && !_isSame91TaskPage(listUrl, _currentUrl)) {
        task['phase'] = 'strict91_returning';
        _loadUrl(listUrl);
        return;
      }
    }
    var index = task['index'] as int;
    final visited = task['visitedPageUrls'] as Set<String>;
    while (index < candidates.length &&
        !visited.add(candidates[index]['url'] ?? '')) {
      index++;
    }
    if (index >= candidates.length) {
      unawaited(() async {
        final listUrl = (task['candidateListUrl'] ?? _currentUrl).toString();
        if (await _openNearestSmartMediaCard(task, listUrl)) return;
        if (_allowSmartExploratoryClick(task) &&
            await _openExploratorySmartTarget(task, listUrl)) {
          return;
        }
        _broadenSmartDiscovery(task, '当前列表的卡片和候选已全部尝试');
      }());
      return;
    }
    task['candidateResolveRetries'] = 0;
    task['index'] = index + 1;
    if (task['mediaType'] != MediaType.video) {
      task['phase'] = 'visiting_candidate';
      _loadUrl(candidates[index]['url']!);
      return;
    }
    task['phase'] = 'resolving_candidate_background';
    unawaited(
      _resolveAndDownloadSmartCandidate91A00(task, candidates[index]),
    );
  }


  Future<void> _resolveAndDownloadSmartCandidate91A00(
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
            unawaited(_advanceSmartDownload91A00(_currentUrl));
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
      _visitNextSmartCandidate91A00(task);
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
      _visitNextSmartCandidate91A00(task);
    }
  }


  Future<void> _returnFromSmartMediaCard91A00(
    Map<String, dynamic> task, {
    required bool madeProgress,
  }) async {
    if (!identical(_smartDownloadTask, task)) return;
    if (task['strict91KeywordMode'] == true) {
      final listUrl = (task['strict91SearchUrl'] ?? '').toString();
      task['phase'] = 'strict91_returning';
      task['strict91ReturnAttempts'] = 0;
      task.remove('nextMediaLabel');
      task.remove('nextMediaStatus');
      final controller = _controller;
      if (controller == null || listUrl.isEmpty) return;
      final actualUrl = (await controller.getUrl())?.toString() ?? _currentUrl;
      if (_isSame91TaskPage(listUrl, actualUrl)) {
        task['phase'] = 'visiting_candidate';
        task['strict91ActiveCardUrl'] = '';
        _visitNextSmartCandidate91A00(task);
      } else if (await controller.canGoBack()) {
        await controller.goBack();
      } else {
        _loadUrl(listUrl);
      }
      return;
    }
    final listUrl = (task.remove('cardListUrl') ?? '').toString();
    final resumeCandidateQueue =
        task.remove('resumeCandidateQueueAfterCard') == true;
    task['phase'] =
        resumeCandidateQueue ? 'returning_candidate_list' : 'scanning_feed';
    task.remove('nextMediaLabel');
    task.remove('nextMediaStatus');
    final controller = _controller;
    if (controller == null) return;
    if (listUrl.isNotEmpty && _currentUrl != listUrl) {
      if (await controller.canGoBack()) {
        await controller.goBack();
      } else {
        _loadUrl(listUrl);
      }
      return;
    }
    if (resumeCandidateQueue) {
      task['phase'] = 'visiting_candidate';
      _visitNextSmartCandidate91A00(task);
      return;
    }
    _continueSmartFeed(task, madeProgress: madeProgress);
  }
