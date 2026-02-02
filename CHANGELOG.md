# Changelog

## 1.0.0

**Package renamed from `flutter_video_caching` to `progressive_video_cache`**

**Breaking Change: Complete Architecture Refactor**

Removed proxy-based streaming. Now uses progressive file-based caching.

### Added
- `ReelPrefetchController` - Scroll-aware prefetch with concurrency control
- `ProgressiveDownloader` - HTTP stream → growing file
- `CacheFileManager` - Path resolution and file operations
- `CacheMetadataStore` - Download progress tracking with persistence
- `HlsCacheManager` - HLS/M3U8 caching with segment-based progressive download
- `HlsParser` - Parse master and media playlists

### Removed
- Local HTTP proxy server (`LocalProxyServer`)
- Socket-based streaming
- URL parsing/rewriting system
- Over-engineered isolate pool
- Complex download task system

### Changed
- Videos now play from local files via `VideoPlayerController.file()`
- Offline playback works with cached bytes
- Downloads resume from last byte
- Dependencies reduced from 7 to 2 (crypto, path_provider)

## 0.4.6

Legacy proxy-based version (deprecated).
