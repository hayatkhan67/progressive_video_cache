# Changelog

## 1.0.0

**`progressive_video_cache`**

**Breaking Change: Complete Architecture Refactor**

Now uses progressive file-based caching.

### Added
- `ReelPrefetchController` - Scroll-aware prefetch with concurrency control
- `ProgressiveDownloader` - HTTP stream → growing file
- `CacheFileManager` - Path resolution and file operations
- `CacheMetadataStore` - Download progress tracking with persistence
- `HlsCacheManager` - HLS/M3U8 caching with segment-based progressive download
- `HlsParser` - Parse master and media playlists
- `NetworkQualityMonitor` - Bandwidth estimation and network type detection
- Adaptive prefetching configuration based on network quality

### Changed
- Videos now play from local files via `VideoPlayerController.file()`
- Offline playback works with cached bytes
- Downloads resume from last byte
- Dependencies reduced from 7 to 2 (crypto, path_provider)
