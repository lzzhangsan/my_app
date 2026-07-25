  Future<void> _advanceSmartDownload(String loadedUrl) async {
    final task = _smartDownloadTask;
    final controller = _controller;
    if (task == null || controller == null) return;
    if (_smartDownloadAdvancing) {
      if (task['advanceRetryScheduled'] != true) {
        task['advanceRetryScheduled'] = true;
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          if (!identical(_smartDownloadTask, task)) return;
          task['advanceRetryScheduled'] = false;
          unawaited(_advanceSmartDownload(_currentUrl));
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
          _visitNextSmartCandidate(task);
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
        _visitNextSmartCandidate(task);
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
            () => unawaited(_advanceSmartDownload(_currentUrl)),
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
            () => unawaited(_advanceSmartDownload(_currentUrl)),
          );
        } else {
          Future<void>.delayed(
            const Duration(seconds: 3),
            () => unawaited(_advanceSmartDownload(_currentUrl)),
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
            _visitNextSmartCandidate(task);
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
        _visitNextSmartCandidate(task);
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
            _visitNextSmartCandidate(task);
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
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
            return;
          }
          task.remove('adWaitStartedAt');
          task['adSkipped'] = ((task['adSkipped'] as int?) ?? 0) + 1;
          if (phase == 'visiting_clicked_card') {
            await _returnFromSmartMediaCard(task, madeProgress: false);
          } else if (phase == 'visiting_candidate') {
            _visitNextSmartCandidate(task);
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
              () => unawaited(_advanceSmartDownload(_currentUrl)),
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
              () => unawaited(_advanceSmartDownload(_currentUrl)),
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
              () => unawaited(_advanceSmartDownload(_currentUrl)),
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
            await _returnFromSmartMediaCard(task, madeProgress: false);
          } else if (phase == 'scanning_feed') {
            if (!strictXFeedMode &&
                await _openNearestSmartMediaCard(task, pageUrl)) {
              return;
            }
            _continueSmartFeed(task, madeProgress: false);
          } else {
            _visitNextSmartCandidate(task);
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
              await _returnFromSmartMediaCard(task, madeProgress: false);
            } else {
              _visitNextSmartCandidate(task);
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
          await _returnFromSmartMediaCard(
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
          _visitNextSmartCandidate(task);
        }
      }
    } catch (e, st) {
      debugPrint('智能下载步骤失败: $e\n$st');
      if (_smartDownloadTask != null) {
        task['failed'] = (task['failed'] as int) + 1;
        final phase = task['phase']?.toString();
        if (phase == 'visiting_clicked_card') {
          await _returnFromSmartMediaCard(task, madeProgress: false);
        } else if (phase == 'x_viewing_search_card') {
          await _returnFromXSmartCard(task);
        } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
          _continueSmartFeed(task, madeProgress: false);
        } else {
          _visitNextSmartCandidate(task);
        }
      }
    } finally {
      _smartDownloadAdvancing = false;
    }
  }
