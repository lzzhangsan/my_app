  Future<void> _returnFromSmartMediaCard(
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
        _visitNextSmartCandidate(task);
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
      _visitNextSmartCandidate(task);
      return;
    }
    _continueSmartFeed(task, madeProgress: madeProgress);
  }
