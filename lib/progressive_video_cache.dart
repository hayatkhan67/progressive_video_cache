/// Progressive Video Cache - File-Based Progressive Caching
///
/// This package provides progressive video caching for Reels/short-video apps.
/// Videos are played directly from growing local files, enabling:
/// - Instant playback without full download
/// - Offline playback of cached bytes
/// - Resume from last downloaded byte
/// - Network-adaptive prefetching (WiFi/5G/4G/Slow)
/// - Bi-directional prefetching (next AND previous videos)
///
/// Usage:
/// ```dart
/// final controller = ReelPrefetchController(maxConcurrent: 3);
///
/// // Get playable path (starts download if needed)
/// final path = await controller.getPlayablePath(videoUrl);
///
/// // Play from file
/// final player = VideoPlayerController.file(File(path));
/// await player.initialize();
/// player.play();
///
/// // On scroll, update prefetch (now bi-directional)
/// controller.onScrollUpdate(urls: allUrls, currentIndex: index);
///
/// // Optionally set network type for adaptive prefetching
/// controller.setNetworkType(NetworkType.fourG);
///
/// // Cleanup
/// controller.dispose();
/// ```
library;

export 'cache_file_manager.dart';
export 'cache_metadata_store.dart';
export 'hls_cache_manager.dart';
export 'hls_parser.dart';
export 'network_quality_monitor.dart';
export 'progressive_downloader.dart';
export 'reel_prefetch_controller.dart';
