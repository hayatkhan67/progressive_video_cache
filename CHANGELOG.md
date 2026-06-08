# Changelog

## 1.0.1

### Added
- `network_types.dart` for shared `NetworkType` and `PrefetchConfig`
- Live HLS playlist refresh with backoff
- Download scheduling queue to enforce concurrency limits

### Changed
- Prefetch configuration now uses `NetworkQualityMonitor` by default
- Cache eviction and size accounting now include HLS segment directories
- Cache metadata persistence now happens periodically, not only on completion

### Fixed
- Resume download corruption when servers ignore `Range` requests
- Cancellation now aborts network streams to reduce wasted bandwidth
- HLS segment downloader no longer loops indefinitely after completion
- MP4 metadata reconciles with on-disk file sizes at startup

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
