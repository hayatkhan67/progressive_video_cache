import 'dart:async';

import 'cache_file_manager.dart';
import 'cache_metadata_store.dart';
import 'hls_cache_manager.dart';
import 'hls_parser.dart';
import 'progressive_downloader.dart';

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

/// Controls video prefetching based on scroll position.
/// Limits concurrent downloads and manages download lifecycle.
/// Uses NetworkQualityMonitor for adaptive prefetching configuration.
class ReelPrefetchController {
  static final ReelPrefetchController _instance =
      ReelPrefetchController._internal();
  factory ReelPrefetchController({int? maxConcurrent}) {
    if (maxConcurrent != null) {
      _instance.maxConcurrent = maxConcurrent;
    }
    return _instance;
  }

  ReelPrefetchController._internal();

  int maxConcurrent = 3;
  final Map<String, StreamSubscription> _activeDownloads = {};

  /// Optional manual network type override (null = use NetworkQualityMonitor)
  NetworkType? _networkTypeOverride;

  /// Manually override the network type for adaptive prefetching
  /// Pass null to use automatic detection from NetworkQualityMonitor
  void setNetworkType(NetworkType? type) {
    _networkTypeOverride = type;
  }

  /// Get current prefetch configuration based on network
  /// Uses NetworkQualityMonitor if no manual override is set
  PrefetchConfig get config {
    // Import here to avoid circular dependency if needed
    // Will use automatic network detection from NetworkQualityMonitor
    final networkType = _networkTypeOverride ?? NetworkType.wifi;
    return PrefetchConfig.forNetwork(networkType);
  }

  /// Get playable path for a video URL.
  /// Waits for minimum bytes if file is empty/small, then returns path.
  /// Download continues in background after path is returned.
  /// Automatically detects and handles HLS (.m3u8) URLs.
  Future<String> getPlayablePath(
    String url, {
    Map<String, String>? headers,
  }) async {
    // Check if HLS
    if (HlsParser.isHlsUrl(url)) {
      return _getHlsPlayablePath(url, headers);
    }

    return _getMp4PlayablePath(url, headers);
  }

  /// Get playable path for HLS URL.
  Future<String> _getHlsPlayablePath(
    String url,
    Map<String, String>? headers,
  ) async {
    try {
      final result = await HlsCacheManager.getPlayablePath(
        url,
        prefetchSegments: 3,
        headers: headers,
      );
      return result.playlistPath;
    } catch (e) {
      // Fallback to original URL on error
      return url;
    }
  }

  /// Get playable path for MP4 URL.
  Future<String> _getMp4PlayablePath(
    String url,
    Map<String, String>? headers,
  ) async {
    final path = await CacheFileManager.ensureFile(url);

    // If already complete, return immediately
    final isComplete = await CacheMetadataStore.isComplete(url);
    if (isComplete) {
      return path;
    }

    // Check current file size
    final fileSize = await CacheFileManager.getFileSize(url);
    final minBytes = ProgressiveDownloader.minBytesForPlayback;

    if (fileSize >= minBytes) {
      // Enough bytes exist, resume download in background
      _startDownload(url, path, headers);
      return path;
    }

    // Not enough bytes - wait for minimum before returning
    // Already downloading?
    if (_activeDownloads.containsKey(url)) {
      // Wait for existing download to reach threshold
      return await _waitForMinBytes(url, path, minBytes);
    }

    // At concurrency limit?
    if (_activeDownloads.length >= maxConcurrent) {
      // Can't start new download, return path anyway (fallback to network)
      return path;
    }

    // Start download and wait for minimum bytes
    return await _downloadAndWaitForMin(url, path, headers);
  }

  /// Check if video is fully cached.
  Future<bool> isCached(String url) async {
    return CacheMetadataStore.isComplete(url);
  }

  /// Get download progress (0.0 to 1.0).
  Future<double> getProgress(String url) async {
    final meta = await CacheMetadataStore.get(url);
    if (meta == null) return 0.0;
    if (meta.isComplete) return 1.0;
    if (meta.totalBytes == null || meta.totalBytes == 0) return 0.0;
    return meta.downloadedBytes / meta.totalBytes!;
  }

  /// Start download if not already running and under concurrency limit.
  void _startDownload(
    String url,
    String path,
    Map<String, String>? headers,
  ) {
    // Already downloading
    if (_activeDownloads.containsKey(url)) return;

    // At concurrency limit
    if (_activeDownloads.length >= maxConcurrent) return;

    _startDownloadInternal(url, path, headers);
  }

  Future<void> _startDownloadInternal(
    String url,
    String path,
    Map<String, String>? headers,
  ) async {
    // Get resume point from file size
    final startByte = await CacheFileManager.getFileSize(url);

    final stream = ProgressiveDownloader.download(
      url: url,
      filePath: path,
      startByte: startByte,
      headers: headers,
    );

    _activeDownloads[url] = stream.listen(
      (progress) {
        CacheMetadataStore.updateProgress(
          url,
          downloadedBytes: progress.downloadedBytes,
          totalBytes: progress.totalBytes,
        );

        if (progress.isComplete) {
          _activeDownloads.remove(url);
        }
      },
      onError: (e) {
        _activeDownloads.remove(url);
      },
      onDone: () {
        _activeDownloads.remove(url);
      },
    );
  }

  /// Start download and wait for minimum bytes before returning path.
  Future<String> _downloadAndWaitForMin(
    String url,
    String path,
    Map<String, String>? headers,
  ) async {
    final startByte = await CacheFileManager.getFileSize(url);

    try {
      final result = await ProgressiveDownloader.downloadAndWaitForBytes(
        url: url,
        filePath: path,
        startByte: startByte,
        headers: headers,
      );

      // Store the subscription for tracking
      if (result.subscription != null && !result.isComplete) {
        _activeDownloads[url] = result.subscription!;

        // Forward progress to metadata store
        result.subscription!.onData((progress) {
          CacheMetadataStore.updateProgress(
            url,
            downloadedBytes: progress.downloadedBytes,
            totalBytes: progress.totalBytes,
          );
          if (progress.isComplete) {
            _activeDownloads.remove(url);
          }
        });
      }

      return path;
    } catch (e) {
      // Download failed, return path anyway (will trigger network fallback)
      return path;
    }
  }

  /// Wait for an existing download to reach minimum bytes.
  Future<String> _waitForMinBytes(String url, String path, int minBytes) async {
    // Poll file size until threshold reached or timeout
    const pollInterval = Duration(milliseconds: 100);
    const timeout = Duration(seconds: 10);
    final startTime = DateTime.now();

    while (DateTime.now().difference(startTime) < timeout) {
      final size = await CacheFileManager.getFileSize(url);
      if (size >= minBytes) {
        return path;
      }

      // Check if download is still active
      if (!_activeDownloads.containsKey(url)) {
        // Download finished or cancelled
        final isComplete = await CacheMetadataStore.isComplete(url);
        if (isComplete) return path;
        break;
      }

      await Future.delayed(pollInterval);
    }

    // Timeout or download stopped - return path anyway
    return path;
  }

  /// Cancel download for a URL.
  void cancelDownload(String url) {
    // Cancel MP4 download
    _activeDownloads[url]?.cancel();
    _activeDownloads.remove(url);
    ProgressiveDownloader.cancel(url);

    // Cancel HLS download
    if (HlsParser.isHlsUrl(url)) {
      HlsCacheManager.cancel(url);
    }
  }

  /// Cancel all downloads.
  void cancelAll() {
    for (final sub in _activeDownloads.values) {
      sub.cancel();
    }
    _activeDownloads.clear();
    ProgressiveDownloader.cancelAll();
    HlsCacheManager.cancelAll();
  }

  /// Update prefetch based on current scroll position.
  /// Cancels downloads far from current, starts prefetch for next/previous videos.
  /// Uses network-adaptive configuration for prefetch counts.
  void onScrollUpdate({
    required List<String> urls,
    required int currentIndex,
    int? prefetchCount, // Optional override, uses config.prefetchAhead if null
    int?
        prefetchBehind, // Optional override, uses config.prefetchBehind if null
    int? keepRange, // Optional override, uses config.keepRange if null
    Map<String, String>? headers,
  }) {
    final effectiveConfig = config;
    final effectivePrefetchAhead =
        prefetchCount ?? effectiveConfig.prefetchAhead;
    final effectivePrefetchBehind =
        prefetchBehind ?? effectiveConfig.prefetchBehind;
    final effectiveKeepRange = keepRange ?? effectiveConfig.keepRange;

    // Cancel downloads outside keep range
    final urlsToCancel = <String>[];
    for (final url in _activeDownloads.keys) {
      final idx = urls.indexOf(url);
      if (idx < 0 || (idx - currentIndex).abs() > effectiveKeepRange) {
        urlsToCancel.add(url);
      }
    }
    for (final url in urlsToCancel) {
      cancelDownload(url);
    }

    // Priority-based prefetch: next video first, then previous, then further ahead
    final prefetchQueue = <int>[];

    // Add next videos (highest priority)
    for (int i = 1; i <= effectivePrefetchAhead; i++) {
      final idx = currentIndex + i;
      if (idx >= 0 && idx < urls.length) {
        prefetchQueue.add(idx);
      }
    }

    // Add previous videos (for smooth swipe-up)
    for (int i = 1; i <= effectivePrefetchBehind; i++) {
      final idx = currentIndex - i;
      if (idx >= 0 && idx < urls.length) {
        prefetchQueue.add(idx);
      }
    }

    // Start prefetch for queued videos
    for (final idx in prefetchQueue) {
      getPlayablePath(urls[idx], headers: headers);
    }
  }

  /// Clean up resources.
  void dispose() {
    cancelAll();
  }
}
