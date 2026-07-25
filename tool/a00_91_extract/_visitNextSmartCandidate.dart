  void _visitNextSmartCandidate(Map<String, dynamic> task) {
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
      _resolveAndDownloadSmartCandidateInBackground(task, candidates[index]),
    );
  }
