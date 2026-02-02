import 'dart:async';
import 'dart:io';

import 'cache_file_manager.dart';
import 'cache_metadata_store.dart';
import 'hls_parser.dart';
import 'progressive_downloader.dart';

/// Manages HLS/M3U8 video caching.
/// Downloads segments progressively and generates local playlists.
class HlsCacheManager {
  HlsCacheManager._();

  static final Map<String, _HlsDownloadState> _downloads = {};

  /// Get a playable path for an HLS URL.
  /// Returns a local playlist path that can be played.
  /// Downloads segments progressively in background.
  static Future<HlsCacheResult> getPlayablePath(
    String hlsUrl, {
    int prefetchSegments = 3,
    int? targetBandwidth,
    Map<String, String>? headers,
  }) async {
    // Check if we have a cached playlist
    final cachedPlaylist = await _getCachedPlaylist(hlsUrl);
    if (cachedPlaylist != null) {
      // Return cached playlist with local paths
      return HlsCacheResult(
        playlistPath: cachedPlaylist,
        isFullyCached: await _isFullyCached(hlsUrl),
      );
    }

    // Fetch and parse the playlist
    final playlist = await _fetchAndParsePlaylist(hlsUrl, headers);

    if (playlist is HlsMasterPlaylist) {
      // Get the appropriate variant
      final variant = targetBandwidth != null
          ? playlist.getVariantByBandwidth(targetBandwidth)
          : playlist.bestVariant;

      if (variant == null) {
        throw Exception('No variants found in master playlist');
      }

      // Fetch the media playlist
      final mediaPlaylist = await _fetchAndParsePlaylist(variant.url, headers);
      if (mediaPlaylist is! HlsMediaPlaylist) {
        throw Exception('Expected media playlist');
      }

      return _processMediaPlaylist(
        hlsUrl,
        mediaPlaylist,
        prefetchSegments,
        headers,
      );
    } else if (playlist is HlsMediaPlaylist) {
      return _processMediaPlaylist(
        hlsUrl,
        playlist,
        prefetchSegments,
        headers,
      );
    }

    throw Exception('Unknown playlist type');
  }

  /// Process media playlist - cache segments and generate local playlist.
  static Future<HlsCacheResult> _processMediaPlaylist(
    String originalUrl,
    HlsMediaPlaylist playlist,
    int prefetchSegments,
    Map<String, String>? headers,
  ) async {
    // Create HLS cache directory
    final hlsCacheDir = await _getHlsCacheDir(originalUrl);
    await Directory(hlsCacheDir).create(recursive: true);

    final initialState = await _computeInitialCacheState(
      hlsCacheDir,
      playlist,
    );

    // Save playlist metadata
    await _savePlaylistMetadata(
      originalUrl,
      playlist,
      cachedSegments: initialState.cachedSegments,
    );

    // Start downloading first N segments
    _startSegmentDownloads(
      originalUrl,
      playlist,
      initialState.nextIndex,
      initialState.cachedSegments,
      prefetchSegments,
      headers,
    );

    // Generate local playlist immediately (mix of cached and remote URLs)
    final localPlaylistPath = await _generateLocalPlaylist(
      originalUrl,
      playlist,
    );

    return HlsCacheResult(
      playlistPath: localPlaylistPath,
      isFullyCached: initialState.cachedSegments >= playlist.segments.length,
      totalSegments: playlist.segments.length,
      cachedSegments: initialState.cachedSegments,
    );
  }

  /// Generate a local playlist file that points to cached segments.
  /// Uncached segments point to remote URLs.
  static Future<String> _generateLocalPlaylist(
    String originalUrl,
    HlsMediaPlaylist playlist,
  ) async {
    final hlsCacheDir = await _getHlsCacheDir(originalUrl);
    final playlistPath = '$hlsCacheDir/playlist.m3u8';

    final buffer = StringBuffer();
    buffer.writeln('#EXTM3U');
    buffer.writeln('#EXT-X-VERSION:3');
    buffer.writeln('#EXT-X-TARGETDURATION:${playlist.targetDuration.ceil()}');
    buffer.writeln('#EXT-X-MEDIA-SEQUENCE:${playlist.mediaSequence}');

    for (final segment in playlist.segments) {
      final segmentPath = _getSegmentPath(hlsCacheDir, segment.index);
      final segmentFile = File(segmentPath);

      buffer.writeln('#EXTINF:${segment.duration},');

      if (await segmentFile.exists() && await segmentFile.length() > 0) {
        // Use local file path
        buffer.writeln(segmentPath);
      } else {
        // Use remote URL
        buffer.writeln(segment.url);
      }
    }

    if (!playlist.isLive) {
      buffer.writeln('#EXT-X-ENDLIST');
    }

    await File(playlistPath).writeAsString(buffer.toString());
    return playlistPath;
  }

  /// Start downloading segments in order.
  static void _startSegmentDownloads(
    String originalUrl,
    HlsMediaPlaylist playlist,
    int nextIndex,
    int cachedSegments,
    int prefetchCount,
    Map<String, String>? headers,
  ) {
    if (_downloads.containsKey(originalUrl)) return;

    final state = _HlsDownloadState(
      originalUrl: originalUrl,
      playlist: playlist,
      headers: headers,
      nextIndex: nextIndex,
      cachedSegments: cachedSegments,
    );
    _downloads[originalUrl] = state;

    _downloadNextSegments(state, prefetchCount);
  }

  /// Download next N segments that aren't cached.
  static Future<void> _downloadNextSegments(
    _HlsDownloadState state,
    int count,
  ) async {
    if (state.cancelled || state.isDownloading) return;

    state.isDownloading = true;
    try {
      final hlsCacheDir = await _getHlsCacheDir(state.originalUrl);
      var requested = count;

      while (!state.cancelled) {
        int downloaded = 0;

        while (state.nextIndex < state.playlist.segments.length &&
            downloaded < requested &&
            !state.cancelled) {
          final segment = state.playlist.segments[state.nextIndex];
          final segmentPath = _getSegmentPath(hlsCacheDir, segment.index);
          final segmentFile = File(segmentPath);

          // Skip if already cached
          if (await segmentFile.exists() && await segmentFile.length() > 0) {
            state.nextIndex++;
            continue;
          }

          try {
            await _downloadSegment(
              segment.url,
              segmentPath,
              state.headers,
            );
            downloaded++;
            state.cachedSegments++;

            await _updateCacheProgress(
              state.originalUrl,
              state.cachedSegments,
              state.playlist.segments.length,
            );

            await _generateLocalPlaylist(state.originalUrl, state.playlist);
          } catch (e) {
            // Continue with next segment on error
          }

          state.nextIndex++;
        }

        if (state.nextIndex >= state.playlist.segments.length) {
          if (!state.playlist.isLive) {
            await _markHlsComplete(state);
            _downloads.remove(state.originalUrl);
            return;
          }

          _scheduleLiveRefresh(state);
          return;
        }

        requested = 2;
      }
    } finally {
      state.isDownloading = false;
    }
  }

  /// Download a single segment.
  static Future<void> _downloadSegment(
    String url,
    String path,
    Map<String, String>? headers,
  ) async {
    final completer = Completer<void>();

    ProgressiveDownloader.download(
      url: url,
      filePath: path,
      headers: headers,
    ).listen(
      (progress) {
        if (progress.isComplete && !completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
    );

    return completer.future;
  }

  /// Fetch and parse a playlist from URL.
  static Future<HlsPlaylist> _fetchAndParsePlaylist(
    String url,
    Map<String, String>? headers,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach((key, value) {
        request.headers.set(key, value);
      });

      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final content = await response.transform(SystemEncoding().decoder).join();
      return HlsParser.parse(content, url);
    } finally {
      client.close();
    }
  }

  /// Get HLS cache directory for a URL.
  static Future<String> _getHlsCacheDir(String url) async {
    final cacheDir = await CacheFileManager.getCacheDir();
    final hash = CacheFileManager.getUrlHash(url);
    return '$cacheDir/hls/$hash';
  }

  /// Get segment file path.
  static String _getSegmentPath(String hlsCacheDir, int index) {
    return '$hlsCacheDir/segment_$index.ts';
  }

  /// Get cached playlist path if exists.
  static Future<String?> _getCachedPlaylist(String url) async {
    final hlsCacheDir = await _getHlsCacheDir(url);
    final playlistPath = '$hlsCacheDir/playlist.m3u8';
    final file = File(playlistPath);

    if (await file.exists()) {
      return playlistPath;
    }
    return null;
  }

  /// Check if all segments are cached.
  static Future<bool> _isFullyCached(String url) async {
    final meta = await CacheMetadataStore.get(url);
    return meta?.isComplete ?? false;
  }

  /// Save playlist metadata.
  static Future<void> _savePlaylistMetadata(
    String url,
    HlsMediaPlaylist playlist, {
    required int cachedSegments,
  }) async {
    await CacheMetadataStore.updateProgress(
      url,
      downloadedBytes: cachedSegments,
      totalBytes: playlist.segments.length,
      isHls: true,
    );
  }

  /// Update cache progress for HLS.
  static Future<void> _updateCacheProgress(
    String url,
    int cachedSegments,
    int totalSegments,
  ) async {
    final meta = await CacheMetadataStore.get(url);
    if (meta != null) {
      await CacheMetadataStore.updateProgress(
        url,
        downloadedBytes: cachedSegments,
        totalBytes: totalSegments,
        isHls: true,
      );
    }
  }

  static Future<void> _markHlsComplete(_HlsDownloadState state) async {
    await CacheMetadataStore.updateProgress(
      state.originalUrl,
      downloadedBytes: state.playlist.segments.length,
      totalBytes: state.playlist.segments.length,
      isHls: true,
    );
    state.refreshTimer?.cancel();
  }

  static void _scheduleLiveRefresh(_HlsDownloadState state) {
    if (state.cancelled) return;
    if (state.refreshTimer?.isActive ?? false) return;

    final baseDelay = state.playlist.targetDuration.ceil().clamp(3, 30);
    final delaySeconds =
        state.refreshBackoffSeconds > 0 ? state.refreshBackoffSeconds : baseDelay;

    state.refreshTimer = Timer(Duration(seconds: delaySeconds), () async {
      await _refreshLivePlaylist(state);
    });
  }

  static Future<void> _refreshLivePlaylist(_HlsDownloadState state) async {
    if (state.cancelled) return;

    try {
      final refreshed =
          await _fetchAndParsePlaylist(state.playlist.url, state.headers);
      if (refreshed is! HlsMediaPlaylist) return;

      state.playlist = refreshed;
      state.refreshBackoffSeconds = 0;

      final hlsCacheDir = await _getHlsCacheDir(state.originalUrl);
      final initialState = await _computeInitialCacheState(
        hlsCacheDir,
        refreshed,
      );
      state.nextIndex = initialState.nextIndex;
      state.cachedSegments = initialState.cachedSegments;

      await _savePlaylistMetadata(
        state.originalUrl,
        refreshed,
        cachedSegments: state.cachedSegments,
      );

      _downloadNextSegments(state, 2);
    } catch (_) {
      final nextBackoff = state.refreshBackoffSeconds == 0
          ? state.playlist.targetDuration.ceil().clamp(3, 30)
          : (state.refreshBackoffSeconds * 2).clamp(3, 60);
      state.refreshBackoffSeconds = nextBackoff;
      _scheduleLiveRefresh(state);
    }
  }

  static Future<_InitialCacheState> _computeInitialCacheState(
    String hlsCacheDir,
    HlsMediaPlaylist playlist,
  ) async {
    int cachedSegments = 0;
    int? firstMissingIndex;

    for (int i = 0; i < playlist.segments.length; i++) {
      final segment = playlist.segments[i];
      final segmentPath = _getSegmentPath(hlsCacheDir, segment.index);
      final segmentFile = File(segmentPath);

      if (await segmentFile.exists() && await segmentFile.length() > 0) {
        cachedSegments++;
      } else {
        firstMissingIndex ??= i;
      }
    }

    return _InitialCacheState(
      nextIndex: firstMissingIndex ?? playlist.segments.length,
      cachedSegments: cachedSegments,
    );
  }

  /// Cancel HLS download.
  static void cancel(String url) {
    final state = _downloads[url];
    if (state != null) {
      state.cancelled = true;
      state.refreshTimer?.cancel();
      _downloads.remove(url);
    }
  }

  /// Cancel all HLS downloads.
  static void cancelAll() {
    for (final url in _downloads.keys.toList()) {
      cancel(url);
    }
  }

  /// Clear HLS cache for a URL.
  static Future<void> clearCache(String url) async {
    cancel(url);
    final hlsCacheDir = await _getHlsCacheDir(url);
    final dir = Directory(hlsCacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await CacheMetadataStore.remove(url);
  }
}

/// State for tracking HLS downloads.
class _HlsDownloadState {
  final String originalUrl;
  HlsMediaPlaylist playlist;
  final Map<String, String>? headers;
  int nextIndex;
  int cachedSegments;
  bool isDownloading;
  Timer? refreshTimer;
  int refreshBackoffSeconds;
  bool cancelled = false;

  _HlsDownloadState({
    required this.originalUrl,
    required this.playlist,
    this.headers,
    this.nextIndex = 0,
    this.cachedSegments = 0,
    this.isDownloading = false,
    this.refreshBackoffSeconds = 0,
  });
}

/// Result of getting playable HLS path.
class HlsCacheResult {
  final String playlistPath;
  final bool isFullyCached;
  final int? totalSegments;
  final int? cachedSegments;

  HlsCacheResult({
    required this.playlistPath,
    required this.isFullyCached,
    this.totalSegments,
    this.cachedSegments,
  });

  double get progress {
    if (totalSegments == null || totalSegments == 0) return 0.0;
    return (cachedSegments ?? 0) / totalSegments!;
  }
}

class _InitialCacheState {
  final int nextIndex;
  final int cachedSegments;

  _InitialCacheState({
    required this.nextIndex,
    required this.cachedSegments,
  });
}
