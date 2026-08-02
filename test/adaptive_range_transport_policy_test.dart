import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/media_download/adaptive_range_transport_policy.dart';

void main() {
  final now = DateTime(2026, 8, 2, 12);

  test('starts from the proven baseline and climbs after a clean sample', () {
    final policy = AdaptiveRangeTransportPolicy();
    expect(
      policy.choose(host: 'cdn.xfree.com', baseline: 6, maxConcurrency: 12),
      6,
    );
    final decision = policy.record(
      host: 'cdn.xfree.com',
      concurrency: 6,
      maxConcurrency: 12,
      totalBytes: 60 * 1024 * 1024,
      elapsed: const Duration(seconds: 10),
      firstRoundFailures: 0,
      completed: true,
      now: now,
    );
    expect(decision.nextConcurrency, 7);
  });

  test('keeps a completed route when transient connections recover', () {
    final policy = AdaptiveRangeTransportPolicy();
    final decision = policy.record(
      host: 'cdn.xfree.com',
      concurrency: 8,
      maxConcurrency: 12,
      totalBytes: 60 * 1024 * 1024,
      elapsed: const Duration(seconds: 25),
      firstRoundFailures: 3,
      completed: true,
      now: now,
    );
    expect(decision.nextConcurrency, 8);
    expect(
      policy.choose(
        host: 'cdn.xfree.com',
        baseline: 6,
        maxConcurrency: 12,
        now: now,
      ),
      8,
    );
  });

  test(
    'keeps exploring when recovered failures still produce a clear gain',
    () {
      final policy = AdaptiveRangeTransportPolicy();
      policy.record(
        host: 'cdn.xfree.com',
        concurrency: 6,
        maxConcurrency: 12,
        totalBytes: 60 * 1024 * 1024,
        elapsed: const Duration(seconds: 60),
        firstRoundFailures: 0,
        completed: true,
        now: now,
      );
      final faster = policy.record(
        host: 'cdn.xfree.com',
        concurrency: 7,
        maxConcurrency: 12,
        totalBytes: 60 * 1024 * 1024,
        elapsed: const Duration(seconds: 36),
        firstRoundFailures: 2,
        completed: true,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(faster.nextConcurrency, 8);
      expect(faster.bestConcurrency, 7);
    },
  );

  test('backs off only one level after a route-level failure', () {
    final policy = AdaptiveRangeTransportPolicy();
    final decision = policy.record(
      host: 'cdn.xfree.com',
      concurrency: 8,
      maxConcurrency: 12,
      totalBytes: 60 * 1024 * 1024,
      elapsed: const Duration(seconds: 20),
      firstRoundFailures: 3,
      completed: false,
      now: now,
    );
    expect(decision.nextConcurrency, 7);
  });

  test('returns to the measured best when a higher level is slower', () {
    final policy = AdaptiveRangeTransportPolicy();
    policy.record(
      host: 'cdn.xfree.com',
      concurrency: 6,
      maxConcurrency: 12,
      totalBytes: 60 * 1024 * 1024,
      elapsed: const Duration(seconds: 10),
      firstRoundFailures: 0,
      completed: true,
      now: now,
    );
    final slower = policy.record(
      host: 'cdn.xfree.com',
      concurrency: 7,
      maxConcurrency: 12,
      totalBytes: 60 * 1024 * 1024,
      elapsed: const Duration(seconds: 15),
      firstRoundFailures: 0,
      completed: true,
      now: now.add(const Duration(minutes: 1)),
    );
    expect(slower.nextConcurrency, 6);
    expect(slower.bestConcurrency, 6);
  });

  test('serializes profiles and expires stale network knowledge', () {
    final policy = AdaptiveRangeTransportPolicy();
    policy.record(
      host: 'cdn.xfree.com',
      concurrency: 6,
      maxConcurrency: 12,
      totalBytes: 30 * 1024 * 1024,
      elapsed: const Duration(seconds: 8),
      firstRoundFailures: 0,
      completed: true,
      now: now,
    );
    final restored = AdaptiveRangeTransportPolicy();
    restored.restore(policy.encode(), now: now.add(const Duration(hours: 1)));
    expect(
      restored.choose(
        host: 'cdn.xfree.com',
        baseline: 4,
        maxConcurrency: 10,
        now: now.add(const Duration(hours: 1)),
      ),
      7,
    );
    expect(
      restored.choose(
        host: 'cdn.xfree.com',
        baseline: 4,
        maxConcurrency: 10,
        now: now.add(const Duration(hours: 7)),
      ),
      4,
    );
  });
}
