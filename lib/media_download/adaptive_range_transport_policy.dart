import 'dart:convert';
import 'dart:math' as math;

class RangeTransportDecision {
  const RangeTransportDecision({
    required this.nextConcurrency,
    required this.bytesPerSecond,
    required this.bestConcurrency,
    required this.bestBytesPerSecond,
  });

  final int nextConcurrency;
  final double bytesPerSecond;
  final int bestConcurrency;
  final double bestBytesPerSecond;
}

class AdaptiveRangeTransportPolicy {
  AdaptiveRangeTransportPolicy({this.profileTtl = const Duration(hours: 6)});

  static const int schemaVersion = 2;
  final Duration profileTtl;
  final Map<String, _RangeTransportProfile> _profiles = {};

  int choose({
    required String host,
    required int baseline,
    required int maxConcurrency,
    DateTime? now,
  }) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return baseline.clamp(2, maxConcurrency);
    final profile = _freshProfile(normalized, now ?? DateTime.now());
    return (profile?.recommendedConcurrency ?? baseline).clamp(
      2,
      maxConcurrency,
    );
  }

  RangeTransportDecision record({
    required String host,
    required int concurrency,
    required int maxConcurrency,
    required int totalBytes,
    required Duration elapsed,
    required int firstRoundFailures,
    required bool completed,
    DateTime? now,
  }) {
    final normalized = host.trim().toLowerCase();
    final timestamp = now ?? DateTime.now();
    final seconds = math.max(0.001, elapsed.inMicroseconds / 1000000.0);
    final bytesPerSecond = completed ? totalBytes / seconds : 0.0;
    final previous = _freshProfile(normalized, timestamp);
    var bestConcurrency = previous?.bestConcurrency ?? concurrency;
    var bestBytesPerSecond = previous?.bestBytesPerSecond ?? 0.0;
    var next = concurrency;

    if (!completed) {
      // A route-level failure deserves one bounded step down. Larger jumps
      // caused the controller to collapse from 6 to 2 after transient TLS
      // failures even though the recovered transfers were still fast.
      next = math.max(2, concurrency - 1);
    } else {
      final previousBestBytesPerSecond = bestBytesPerSecond;
      final previousBestConcurrency = bestConcurrency;
      final materiallyFasterThanPreviousBest =
          previousBestBytesPerSecond > 0 &&
          bytesPerSecond > previousBestBytesPerSecond * 1.08;
      final materiallySlowerThanPreviousBest =
          previousBestBytesPerSecond > 0 &&
          bytesPerSecond < previousBestBytesPerSecond * 0.92;
      if (bytesPerSecond >= bestBytesPerSecond) {
        bestBytesPerSecond = bytesPerSecond;
        bestConcurrency = concurrency;
      }
      if (materiallySlowerThanPreviousBest &&
          previousBestConcurrency != concurrency) {
        next = previousBestConcurrency;
      } else if (firstRoundFailures * 2 >= concurrency) {
        // Only a majority-level connection failure reduces a completed route.
        next = math.max(2, concurrency - 1);
      } else if (firstRoundFailures > 0) {
        // Minority failures that recovered are not a reason to stop exploring
        // when this level is measurably faster. This lets a 6 -> 7 gain keep
        // probing 8, while a flat/noisy sample remains at the proven level.
        next =
            materiallyFasterThanPreviousBest
                ? math.min(maxConcurrency, concurrency + 1)
                : concurrency;
      } else {
        next = math.min(maxConcurrency, concurrency + 1);
      }
    }

    final oldEwma = previous?.ewmaBytesPerSecond ?? 0.0;
    final ewma =
        bytesPerSecond <= 0
            ? oldEwma
            : oldEwma <= 0
            ? bytesPerSecond
            : oldEwma * 0.65 + bytesPerSecond * 0.35;
    final profile = _RangeTransportProfile(
      recommendedConcurrency: next.clamp(2, maxConcurrency),
      bestConcurrency: bestConcurrency.clamp(2, maxConcurrency),
      bestBytesPerSecond: bestBytesPerSecond,
      ewmaBytesPerSecond: ewma,
      samples: (previous?.samples ?? 0) + 1,
      updatedAtMs: timestamp.millisecondsSinceEpoch,
    );
    if (normalized.isNotEmpty) _profiles[normalized] = profile;
    return RangeTransportDecision(
      nextConcurrency: profile.recommendedConcurrency,
      bytesPerSecond: bytesPerSecond,
      bestConcurrency: profile.bestConcurrency,
      bestBytesPerSecond: profile.bestBytesPerSecond,
    );
  }

  String encode() => jsonEncode({
    'version': schemaVersion,
    'profiles': _profiles.map(
      (host, profile) => MapEntry(host, profile.toJson()),
    ),
  });

  void restore(String? raw, {DateTime? now}) {
    _profiles.clear();
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != schemaVersion) return;
      final profiles = decoded['profiles'];
      if (profiles is! Map) return;
      profiles.forEach((host, value) {
        if (host is! String || value is! Map) return;
        final profile = _RangeTransportProfile.fromJson(value);
        if (profile != null) _profiles[host.toLowerCase()] = profile;
      });
      final timestamp = now ?? DateTime.now();
      _profiles.removeWhere((_, profile) {
        final age = timestamp.difference(
          DateTime.fromMillisecondsSinceEpoch(profile.updatedAtMs),
        );
        return age.isNegative || age > profileTtl;
      });
    } catch (_) {
      _profiles.clear();
    }
  }

  _RangeTransportProfile? _freshProfile(String host, DateTime now) {
    final profile = _profiles[host];
    if (profile == null) return null;
    final age = now.difference(
      DateTime.fromMillisecondsSinceEpoch(profile.updatedAtMs),
    );
    if (age.isNegative || age > profileTtl) {
      _profiles.remove(host);
      return null;
    }
    return profile;
  }
}

class _RangeTransportProfile {
  const _RangeTransportProfile({
    required this.recommendedConcurrency,
    required this.bestConcurrency,
    required this.bestBytesPerSecond,
    required this.ewmaBytesPerSecond,
    required this.samples,
    required this.updatedAtMs,
  });

  final int recommendedConcurrency;
  final int bestConcurrency;
  final double bestBytesPerSecond;
  final double ewmaBytesPerSecond;
  final int samples;
  final int updatedAtMs;

  Map<String, Object> toJson() => {
    'recommended': recommendedConcurrency,
    'bestConcurrency': bestConcurrency,
    'bestBps': bestBytesPerSecond,
    'ewmaBps': ewmaBytesPerSecond,
    'samples': samples,
    'updatedAtMs': updatedAtMs,
  };

  static _RangeTransportProfile? fromJson(Map value) {
    final recommended = value['recommended'];
    final bestConcurrency = value['bestConcurrency'];
    final bestBps = value['bestBps'];
    final ewmaBps = value['ewmaBps'];
    final samples = value['samples'];
    final updatedAtMs = value['updatedAtMs'];
    if (recommended is! num ||
        bestConcurrency is! num ||
        bestBps is! num ||
        ewmaBps is! num ||
        samples is! num ||
        updatedAtMs is! num) {
      return null;
    }
    return _RangeTransportProfile(
      recommendedConcurrency: recommended.toInt(),
      bestConcurrency: bestConcurrency.toInt(),
      bestBytesPerSecond: bestBps.toDouble(),
      ewmaBytesPerSecond: ewmaBps.toDouble(),
      samples: samples.toInt(),
      updatedAtMs: updatedAtMs.toInt(),
    );
  }
}
