import 'dart:async';

import 'dart:collection';

import 'cache_file_manager.dart';
import 'cache_metadata_store.dart';
import 'hls_cache_manager.dart';
import 'hls_parser.dart';
import 'network_quality_monitor.dart';
import 'network_types.dart';
import 'progressive_downloader.dart';

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
  final Queue<_DownloadRequest> _highPriorityQueue = Queue<_DownloadRequest>();
  final Queue<_DownloadRequest> _lowPriorityQueue = Queue<_DownloadRequest>();
  final Set<String> _inFlight = {};
  final Set<String> _queuedUrls = {};

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
    final networkType = _networkTypeOverride ??
        NetworkQualityMonitor.instance.currentType;
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
    if (_inFlight.length >= _currentMaxConcurrent) {
      // Can't start new download, return path anyway (fallback to network)
      _enqueueDownload(
        _DownloadRequest(
          url: url,
          path: path,
          headers: headers,
          priority: _DownloadPriority.high,
        ),
      );
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
    _enqueueDownload(
      _DownloadRequest(
        url: url,
        path: path,
        headers: headers,
        priority: _DownloadPriority.low,
      ),
    );
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
          _finishDownload(url);
        }
      },
      onError: (e) {
        _finishDownload(url);
      },
      onDone: () {
        _finishDownload(url);
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
      if (!_tryReserveSlot(url)) {
        // No slot available, return path and enqueue background download
        _enqueueDownload(
          _DownloadRequest(
            url: url,
            path: path,
            headers: headers,
            priority: _DownloadPriority.high,
          ),
        );
        return path;
      }

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
            _finishDownload(url);
          }
        });
        result.subscription!.onDone(() {
          _finishDownload(url);
        });
        result.subscription!.onError((_) {
          _finishDownload(url);
        });
      } else {
        _finishDownload(url);
      }

      return path;
    } catch (e) {
      _finishDownload(url);
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

  int get _currentMaxConcurrent {
    final configMax = config.maxConcurrent;
    return maxConcurrent < configMax ? maxConcurrent : configMax;
  }

  bool _tryReserveSlot(String url) {
    if (_inFlight.contains(url)) return false;
    if (_inFlight.length >= _currentMaxConcurrent) return false;
    _inFlight.add(url);
    return true;
  }

  void _finishDownload(String url) {
    _activeDownloads.remove(url);
    if (_inFlight.remove(url)) {
      _processQueue();
    }
  }

  void _enqueueDownload(_DownloadRequest request) {
    if (_activeDownloads.containsKey(request.url) ||
        _inFlight.contains(request.url) ||
        _queuedUrls.contains(request.url)) {
      return;
    }

    if (_tryReserveSlot(request.url)) {
      _startDownloadInternal(request.url, request.path, request.headers);
      return;
    }

    _queuedUrls.add(request.url);
    if (request.priority == _DownloadPriority.high) {
      _highPriorityQueue.add(request);
    } else {
      _lowPriorityQueue.add(request);
    }
  }

  void _processQueue() {
    while (_inFlight.length < _currentMaxConcurrent) {
      _DownloadRequest? next;
      if (_highPriorityQueue.isNotEmpty) {
        next = _highPriorityQueue.removeFirst();
      } else if (_lowPriorityQueue.isNotEmpty) {
        next = _lowPriorityQueue.removeFirst();
      } else {
        return;
      }

      _queuedUrls.remove(next.url);
      if (_tryReserveSlot(next.url)) {
        _startDownloadInternal(next.url, next.path, next.headers);
      }
    }
  }

  void _removeQueued(String url) {
    if (_queuedUrls.remove(url)) {
      _highPriorityQueue.removeWhere((r) => r.url == url);
      _lowPriorityQueue.removeWhere((r) => r.url == url);
    }
  }

  void _clearQueue() {
    _queuedUrls.clear();
    _highPriorityQueue.clear();
    _lowPriorityQueue.clear();
  }

  /// Cancel download for a URL.
  void cancelDownload(String url) {
    // Cancel MP4 download
    _activeDownloads[url]?.cancel();
    _activeDownloads.remove(url);
    _inFlight.remove(url);
    _removeQueued(url);
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
    _inFlight.clear();
    _clearQueue();
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

enum _DownloadPriority { high, low }

class _DownloadRequest {
  final String url;
  final String path;
  final Map<String, String>? headers;
  final _DownloadPriority priority;

  _DownloadRequest({
    required this.url,
    required this.path,
    required this.headers,
    required this.priority,
  });
}
