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

    // Save playlist metadata
    await _savePlaylistMetadata(originalUrl, playlist);

    // Start downloading first N segments
    _startSegmentDownloads(
      originalUrl,
      playlist,
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
      isFullyCached: false,
      totalSegments: playlist.segments.length,
      cachedSegments: 0,
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
    int prefetchCount,
    Map<String, String>? headers,
  ) {
    if (_downloads.containsKey(originalUrl)) return;

    final state = _HlsDownloadState(
      originalUrl: originalUrl,
      playlist: playlist,
      headers: headers,
    );
    _downloads[originalUrl] = state;

    _downloadNextSegments(state, prefetchCount);
  }

  /// Download next N segments that aren't cached.
  static Future<void> _downloadNextSegments(
    _HlsDownloadState state,
    int count,
  ) async {
    if (state.cancelled) return;

    final hlsCacheDir = await _getHlsCacheDir(state.originalUrl);
    int downloaded = 0;

    for (final segment in state.playlist.segments) {
      if (state.cancelled) break;
      if (downloaded >= count) break;

      final segmentPath = _getSegmentPath(hlsCacheDir, segment.index);
      final segmentFile = File(segmentPath);

      // Skip if already cached
      if (await segmentFile.exists() && await segmentFile.length() > 0) {
        continue;
      }

      // Download segment
      try {
        await _downloadSegment(
          segment.url,
          segmentPath,
          state.headers,
        );
        downloaded++;

        // Update metadata
        await _updateCacheProgress(state.originalUrl, segment.index);

        // Regenerate local playlist with new cached segment
        await _generateLocalPlaylist(state.originalUrl, state.playlist);
      } catch (e) {
        // Continue with next segment on error
      }
    }

    // Continue downloading remaining segments
    if (!state.cancelled) {
      _downloadNextSegments(state, 2); // Download 2 more at a time
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
    HlsMediaPlaylist playlist,
  ) async {
    await CacheMetadataStore.updateProgress(
      url,
      downloadedBytes: 0,
      totalBytes: playlist.segments.length,
      isHls: true,
    );
  }

  /// Update cache progress for HLS.
  static Future<void> _updateCacheProgress(String url, int segmentIndex) async {
    final meta = await CacheMetadataStore.get(url);
    if (meta != null) {
      await CacheMetadataStore.updateProgress(
        url,
        downloadedBytes: segmentIndex + 1,
        totalBytes: meta.totalBytes,
        isHls: true,
      );
    }
  }

  /// Cancel HLS download.
  static void cancel(String url) {
    final state = _downloads[url];
    if (state != null) {
      state.cancelled = true;
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
  final HlsMediaPlaylist playlist;
  final Map<String, String>? headers;
  bool cancelled = false;

  _HlsDownloadState({
    required this.originalUrl,
    required this.playlist,
    this.headers,
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
