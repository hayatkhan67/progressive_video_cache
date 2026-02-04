import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'cache_metadata_store.dart';

/// Manages cache file paths and file operations.
/// Includes LRU (Least Recently Used) cache eviction to prevent unbounded growth.
class CacheFileManager {
  CacheFileManager._();

  static String? _cacheDir;
  static DateTime _lastEviction = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _evictionInProgress = false;
  static const Duration _minEvictionInterval = Duration(seconds: 30);

  /// Maximum cache size in bytes (default: 500MB)
  static int maxCacheSizeBytes = 200 * 1024 * 1024;

  /// Get the cache directory, creating if needed.
  static Future<String> getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;

    final tempDir = await getTemporaryDirectory();
    _cacheDir = '${tempDir.path}/video_cache';

    final dir = Directory(_cacheDir!);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    return _cacheDir!;
  }

  /// Get file path for a URL. Does not create the file.
  static Future<String> getFilePath(String url) async {
    final dir = await getCacheDir();
    final hash = _urlToHash(url);
    return '$dir/$hash.mp4';
  }

  /// Check if file exists for URL.
  static Future<bool> exists(String url) async {
    final path = await getFilePath(url);
    return File(path).existsSync();
  }

  /// Get current file size. Returns 0 if file doesn't exist.
  static Future<int> getFileSize(String url) async {
    final path = await getFilePath(url);
    final file = File(path);
    if (!file.existsSync()) return 0;
    return file.lengthSync();
  }

  /// Create empty file if it doesn't exist.
  static Future<String> ensureFile(String url) async {
    final path = await getFilePath(url);
    final file = File(path);
    if (!file.existsSync()) {
      await file.create(recursive: true);
    }
    return path;
  }

  /// Delete cached file for URL.
  static Future<void> delete(String url) async {
    final path = await getFilePath(url);
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
    // Also clean metadata
    await CacheMetadataStore.remove(url);
  }

  /// Delete all cached files.
  static Future<void> clearAll() async {
    final dir = Directory(await getCacheDir());
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    // Also clear metadata
    await CacheMetadataStore.clearAll();
  }

  /// Get total cache size in bytes.
  static Future<int> getTotalCacheSize() async {
    final dir = Directory(await getCacheDir());
    if (!dir.existsSync()) return 0;

    return _computeDirectorySize(dir);
  }

  /// Evict oldest files if cache exceeds maximum size.
  /// Uses LRU (Least Recently Used) strategy based on file access time.
  /// Evicts until cache is under 80% of max size.
  static Future<void> evictIfNeeded() async {
    final dir = Directory(await getCacheDir());
    if (!dir.existsSync()) return;

    // Collect cache entries (mp4 files + HLS directories)
    final entries = await _collectCacheEntries(dir);

    // Calculate total size
    int totalSize = 0;
    for (final entry in entries) {
      totalSize += entry.size;
    }

    // Check if eviction needed
    if (totalSize <= maxCacheSizeBytes) return;

    // Sort by last accessed time (oldest first)
    entries.sort((a, b) => a.accessed.compareTo(b.accessed));

    // Target 80% of max to avoid frequent evictions
    final targetSize = (maxCacheSizeBytes * 0.8).toInt();

    for (final entry in entries) {
      if (totalSize <= targetSize) break;

      try {
        totalSize -= entry.size;
        if (entry.isDirectory) {
          await entry.directory!.delete(recursive: true);
        } else {
          await entry.file!.delete();
        }

        await CacheMetadataStore.removeByHash(entry.hash);
      } catch (_) {
        // Ignore deletion failures
      }
    }
  }

  /// Throttled eviction to avoid scanning too often.
  static Future<void> evictIfNeededThrottled() async {
    if (_evictionInProgress) return;
    final now = DateTime.now();
    if (now.difference(_lastEviction) < _minEvictionInterval) return;
    _evictionInProgress = true;
    try {
      await evictIfNeeded();
    } finally {
      _lastEviction = DateTime.now();
      _evictionInProgress = false;
    }
  }

  /// Update access time for a file (marks it as recently used).
  /// Call this when a video is played to keep it in cache longer.
  static Future<void> updateAccessTime(String url) async {
    final path = await getFilePath(url);
    final file = File(path);
    if (file.existsSync()) {
      // Touch the file to update access time
      try {
        final now = DateTime.now();
        await file.setLastAccessed(now);
      } catch (_) {
        // Ignore if can't update access time
      }
    }
  }

  /// MD5 hash of URL for filename.
  static String _urlToHash(String url) => getUrlHash(url);

  /// Get MD5 hash of URL. Public for use by HLS cache.
  static String getUrlHash(String url) {
    return md5.convert(utf8.encode(url)).toString();
  }
}

class _CacheEntry {
  final int size;
  final DateTime accessed;
  final String hash;
  final File? file;
  final Directory? directory;

  _CacheEntry({
    required this.size,
    required this.accessed,
    required this.hash,
    this.file,
    this.directory,
  });

  bool get isDirectory => directory != null;
}

Future<int> _computeDirectorySize(Directory dir) async {
  int total = 0;
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      try {
        total += entity.lengthSync();
      } catch (_) {}
    }
  }
  return total;
}

Future<List<_CacheEntry>> _collectCacheEntries(Directory rootDir) async {
  final entries = <_CacheEntry>[];
  await for (final entity in rootDir.list()) {
    if (entity is File) {
      try {
        final stat = await entity.stat();
        final hash = _basename(entity.path).replaceAll('.mp4', '');
        entries.add(_CacheEntry(
          size: stat.size,
          accessed: stat.accessed,
          hash: hash,
          file: entity,
        ));
      } catch (_) {}
      continue;
    }

    if (entity is Directory && _isHlsRoot(entity)) {
      await for (final sub in entity.list()) {
        if (sub is! Directory) continue;
        final size = await _computeDirectorySize(sub);
        final accessed = await _getDirectoryAccessed(sub);
        final hash = _basename(sub.path);
        entries.add(_CacheEntry(
          size: size,
          accessed: accessed,
          hash: hash,
          directory: sub,
        ));
      }
    }
  }
  return entries;
}

String _basename(String path) =>
    path.split(Platform.pathSeparator).where((p) => p.isNotEmpty).last;

bool _isHlsRoot(Directory dir) {
  final parts = dir.path
      .split(Platform.pathSeparator)
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isNotEmpty && parts.last == 'hls';
}

Future<DateTime> _getDirectoryAccessed(Directory dir) async {
  DateTime? latest;
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      try {
        final stat = await entity.stat();
        final accessed = stat.accessed;
        if (latest == null || accessed.isAfter(latest)) {
          latest = accessed;
        }
      } catch (_) {}
    }
  }
  if (latest != null) return latest;
  try {
    return (await dir.stat()).accessed;
  } catch (_) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
