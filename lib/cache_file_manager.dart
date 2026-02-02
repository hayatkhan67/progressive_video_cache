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

  /// Maximum cache size in bytes (default: 500MB)
  static int maxCacheSizeBytes = 500 * 1024 * 1024;

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

    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }

  /// Evict oldest files if cache exceeds maximum size.
  /// Uses LRU (Least Recently Used) strategy based on file access time.
  /// Evicts until cache is under 80% of max size.
  static Future<void> evictIfNeeded() async {
    final dir = Directory(await getCacheDir());
    if (!dir.existsSync()) return;

    // Collect all files with their stats
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        files.add(entity);
      }
    }

    // Calculate total size
    int totalSize = 0;
    final fileStats = <(File, FileStat)>[];

    for (final file in files) {
      try {
        final stat = await file.stat();
        totalSize += stat.size;
        fileStats.add((file, stat));
      } catch (_) {
        // Skip files that can't be stat'd
      }
    }

    // Check if eviction needed
    if (totalSize <= maxCacheSizeBytes) return;

    // Sort by last accessed time (oldest first)
    fileStats.sort((a, b) => a.$2.accessed.compareTo(b.$2.accessed));

    // Target 80% of max to avoid frequent evictions
    final targetSize = (maxCacheSizeBytes * 0.8).toInt();

    for (final (file, stat) in fileStats) {
      if (totalSize <= targetSize) break;

      try {
        totalSize -= stat.size;
        await file.delete();

        // Extract hash from filename (format: hash.mp4)
        final hash = file.path.split('/').last.replaceAll('.mp4', '');
        await CacheMetadataStore.removeByHash(hash);
      } catch (_) {
        // Ignore deletion failures
      }
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
