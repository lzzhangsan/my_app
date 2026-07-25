  bool _isSame91TaskPage(String left, String right) {
    final leftKey = _smartStablePageKey(left);
    final rightKey = _smartStablePageKey(right);
    if (leftKey.isNotEmpty || rightKey.isNotEmpty) {
      return leftKey.isNotEmpty && leftKey == rightKey;
    }
    return _isSameLoadedDocument(left, right);
  }
