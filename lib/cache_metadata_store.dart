import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Tracks download progress and completion status.
/// Persists metadata to survive app restarts.
class CacheMetadataStore {
  CacheMetadataStore._();

  static final Map<String, CacheMetadata> _cache = {};
  static bool _loaded = false;
  static String? _metadataPath;
  static final Map<String, DateTime> _lastPersisted = {};
  static const Duration _persistInterval = Duration(seconds: 5);

  /// Load metadata from disk.
  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final path = await _getMetadataPath();
      final file = File(path);
      if (file.existsSync()) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in json.entries) {
          _cache[entry.key] = CacheMetadata.fromJson(entry.value);
        }
      }
    } catch (_) {
      // Ignore corrupt metadata
    }

    await _reconcileWithFiles();
  }

  static Future<String> _getMetadataPath() async {
    if (_metadataPath != null) return _metadataPath!;
    final tempDir = await getTemporaryDirectory();
    _metadataPath = '${tempDir.path}/video_cache/metadata.json';
    return _metadataPath!;
  }

  /// Save metadata to disk.
  static Future<void> _persist() async {
    try {
      final path = await _getMetadataPath();
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) {
        await parent.create(recursive: true);
      }

      final json = <String, dynamic>{};
      for (final entry in _cache.entries) {
        json[entry.key] = entry.value.toJson();
      }
      await file.writeAsString(jsonEncode(json));
    } catch (_) {
      // Ignore write errors
    }
  }

  /// Update progress for a URL.
  static Future<void> updateProgress(
    String url, {
    required int downloadedBytes,
    int? totalBytes,
    bool isHls = false,
  }) async {
    await _ensureLoaded();

    final isComplete = totalBytes != null && downloadedBytes >= totalBytes;

    _cache[url] = CacheMetadata(
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      isComplete: isComplete,
      lastUpdated: DateTime.now(),
      isHls: isHls,
    );

    // Persist on completion or periodically to reduce I/O
    final now = DateTime.now();
    final lastPersisted = _lastPersisted[url];
    if (isComplete ||
        lastPersisted == null ||
        now.difference(lastPersisted) >= _persistInterval) {
      _lastPersisted[url] = now;
      await _persist();
    }
  }

  /// Mark download as complete.
  static Future<void> markComplete(String url, int totalBytes) async {
    await _ensureLoaded();

    final existing = _cache[url];
    _cache[url] = CacheMetadata(
      downloadedBytes: totalBytes,
      totalBytes: totalBytes,
      isComplete: true,
      lastUpdated: DateTime.now(),
      isHls: existing?.isHls ?? false,
    );

    await _persist();
  }

  /// Get metadata for URL.
  static Future<CacheMetadata?> get(String url) async {
    await _ensureLoaded();
    return _cache[url];
  }

  /// Check if URL is fully cached.
  static Future<bool> isComplete(String url) async {
    await _ensureLoaded();
    return _cache[url]?.isComplete ?? false;
  }

  /// Get downloaded bytes for URL.
  static Future<int> getDownloadedBytes(String url) async {
    await _ensureLoaded();
    return _cache[url]?.downloadedBytes ?? 0;
  }

  /// Remove metadata for URL.
  static Future<void> remove(String url) async {
    await _ensureLoaded();
    _cache.remove(url);
    await _persist();
  }

  /// Remove metadata by URL hash.
  /// Used by LRU cache eviction when the original URL is not known.
  static Future<void> removeByHash(String hash) async {
    await _ensureLoaded();

    // Find and remove entries whose URL hashes to the given hash
    final urlsToRemove = <String>[];
    for (final url in _cache.keys) {
      // Simple check - if the URL hash matches, remove it
      // We import differently to avoid circular dependency
      if (_hashesMatch(url, hash)) {
        urlsToRemove.add(url);
      }
    }

    for (final url in urlsToRemove) {
      _cache.remove(url);
    }

    if (urlsToRemove.isNotEmpty) {
      await _persist();
    }
  }

  /// Check if a URL's hash matches the given hash.
  static bool _hashesMatch(String url, String hash) {
    // Use same hashing as CacheFileManager
    return _urlToHash(url) == hash;
  }

  /// MD5 hash of URL (same algorithm as CacheFileManager).
  static String _urlToHash(String url) {
    // Using crypto package for proper MD5 hashing
    return md5.convert(utf8.encode(url)).toString();
  }

  /// Clear all metadata.
  static Future<void> clearAll() async {
    _cache.clear();
    _lastPersisted.clear();
    final path = await _getMetadataPath();
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  static Future<void> _reconcileWithFiles() async {
    if (_cache.isEmpty) return;

    final tempDir = await getTemporaryDirectory();
    final cacheDir = '${tempDir.path}/video_cache';

    final urlsToRemove = <String>[];
    for (final entry in _cache.entries) {
      final url = entry.key;
      final meta = entry.value;

      if (meta.isHls) {
        continue;
      }

      final hash = _urlToHash(url);
      final filePath = '$cacheDir/$hash.mp4';
      final file = File(filePath);

      if (!file.existsSync()) {
        urlsToRemove.add(url);
        continue;
      }

      final size = file.lengthSync();
      final totalBytes = meta.totalBytes;
      final isComplete =
          totalBytes != null ? size >= totalBytes : meta.isComplete;

      if (size != meta.downloadedBytes || isComplete != meta.isComplete) {
        _cache[url] = CacheMetadata(
          downloadedBytes: size,
          totalBytes: totalBytes,
          isComplete: isComplete,
          lastUpdated: DateTime.now(),
          isHls: meta.isHls,
        );
      }
    }

    if (urlsToRemove.isNotEmpty) {
      for (final url in urlsToRemove) {
        _cache.remove(url);
      }
    }
  }
}

/// Metadata for a single cached video.
class CacheMetadata {
  final int downloadedBytes;
  final int? totalBytes;
  final bool isComplete;
  final DateTime lastUpdated;
  final bool isHls;

  CacheMetadata({
    required this.downloadedBytes,
    this.totalBytes,
    required this.isComplete,
    required this.lastUpdated,
    this.isHls = false,
  });

  factory CacheMetadata.fromJson(Map<String, dynamic> json) {
    return CacheMetadata(
      downloadedBytes: json['downloadedBytes'] as int,
      totalBytes: json['totalBytes'] as int?,
      isComplete: json['isComplete'] as bool,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
      isHls: json['isHls'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'isComplete': isComplete,
        'lastUpdated': lastUpdated.toIso8601String(),
        'isHls': isHls,
      };
}
