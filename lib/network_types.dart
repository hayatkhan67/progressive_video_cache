/// Network quality types for adaptive prefetching
enum NetworkType { wifi, fiveG, fourG, slow, offline }

/// Configuration for adaptive prefetching based on network conditions
class PrefetchConfig {
  final int prefetchAhead; // Videos to prefetch ahead
  final int prefetchBehind; // Videos to prefetch behind (for swipe-up)
  final int keepRange; // Videos to keep in cache
  final int maxConcurrent; // Maximum concurrent downloads

  const PrefetchConfig({
    this.prefetchAhead = 3,
    this.prefetchBehind = 1,
    this.keepRange = 5,
    this.maxConcurrent = 3,
  });

  /// Adaptive config based on network type
  factory PrefetchConfig.forNetwork(NetworkType type) {
    switch (type) {
      case NetworkType.wifi:
        return const PrefetchConfig(
          prefetchAhead: 4,
          prefetchBehind: 2,
          keepRange: 8,
          maxConcurrent: 4,
        );
      case NetworkType.fiveG:
        return const PrefetchConfig(
          prefetchAhead: 3,
          prefetchBehind: 1,
          keepRange: 6,
          maxConcurrent: 3,
        );
      case NetworkType.fourG:
        return const PrefetchConfig(
          prefetchAhead: 2,
          prefetchBehind: 1,
          keepRange: 4,
          maxConcurrent: 2,
        );
      case NetworkType.slow:
        return const PrefetchConfig(
          prefetchAhead: 1,
          prefetchBehind: 0,
          keepRange: 3,
          maxConcurrent: 1,
        );
      case NetworkType.offline:
        return const PrefetchConfig(
          prefetchAhead: 0,
          prefetchBehind: 0,
          keepRange: 2,
          maxConcurrent: 0,
        );
    }
  }
}
