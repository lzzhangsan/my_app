/// 文档等媒体栏：在选定目录/整个媒体库后，再限定「全部 / 仅已收藏 / 仅未收藏」。
enum MediaSourceFavoriteFilter {
  all,
  favoriteOnly,
  notFavoriteOnly,
}

const String kMediaSourceFavoriteFilterPrefsKey = 'media_source_favorite_filter';

extension MediaSourceFavoriteFilterStorage on MediaSourceFavoriteFilter {
  /// 写入 SharedPreferences 的值。
  String get storageValue => switch (this) {
    MediaSourceFavoriteFilter.all => 'all',
    MediaSourceFavoriteFilter.favoriteOnly => 'favorite',
    MediaSourceFavoriteFilter.notFavoriteOnly => 'not_favorite',
  };

  String get displayLabel => switch (this) {
    MediaSourceFavoriteFilter.all => '全部媒体',
    MediaSourceFavoriteFilter.favoriteOnly => '已收藏媒体',
    MediaSourceFavoriteFilter.notFavoriteOnly => '未收藏媒体',
  };
}

MediaSourceFavoriteFilter parseMediaSourceFavoriteFilter(String? raw) {
  switch (raw) {
    case 'favorite':
      return MediaSourceFavoriteFilter.favoriteOnly;
    case 'not_favorite':
      return MediaSourceFavoriteFilter.notFavoriteOnly;
    default:
      return MediaSourceFavoriteFilter.all;
  }
}

bool mediaRowIsFavorite(Map<String, dynamic> row) {
  final fav = row['is_favorite'];
  return fav == true ||
      fav == 1 ||
      (fav is num && fav != 0);
}
