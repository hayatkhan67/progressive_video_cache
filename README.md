# progressive_video_cache

[![pub package](https://img.shields.io/pub/v/progressive_video_cache.svg)](https://pub.dev/packages/progressive_video_cache)

Progressive video caching for Flutter Reels/short-video apps. Supports both MP4 and HLS (.m3u8) streams with adaptive network-aware prefetching.

## Features

- **Progressive playback**: Play videos before download completes.
- **HLS Support**: Automatic parsing and segment-based caching of M3U8 playlists.
- **Adaptive Prefetching**: Automatically adjusts prefetch counts based on network quality (WiFi, 5G, 4G, Slow).
- **Offline-first**: Cached bytes/segments play instantly without network.
- **Resume downloads**: Continue from last downloaded byte.
- **Scroll-aware prefetch**: Automatically manage download lifecycle during scrolling.
- **Network Monitoring**: Built-in bandwidth estimation for intelligent caching decisions.

## Architecture

### MP4 Caching
```
VideoPlayerController.file()
        ↓
Growing local file (append-only)
        ↑
ProgressiveDownloader (HTTP range request → file)
```

### HLS Caching
```
VideoPlayerController.file()
        ↓
Local .m3u8 playlist (points to local .ts files)
        ↑
HlsCacheManager (Downloads segments progressively)
```

## Usage

### Simple Usage

```dart
import 'dart:io';
import 'package:progressive_video_cache/progressive_video_cache.dart';
import 'package:video_player/video_player.dart';

// Create prefetch controller
final prefetch = ReelPrefetchController();

// Get playable path (works for both MP4 and HLS)
final path = await prefetch.getPlayablePath(videoUrl);

// Play from path
final controller = VideoPlayerController.file(File(path));
await controller.initialize();
controller.play();
```

### Adaptive Scrolling

Pass your list of URLs and current index to `onScrollUpdate`. The controller will use the `NetworkQualityMonitor` to decide how many videos to prefetch ahead and behind.

```dart
prefetch.onScrollUpdate(
  urls: allVideoUrls,
  currentIndex: currentIndex,
);
```

### Network Quality Monitoring

The package automatically monitors network quality. You can manually hint at connectivity changes:

```dart
final monitor = NetworkQualityMonitor.instance;

// Update from connectivity_plus or similar
monitor.updateFromConnectivity(isWifi: true);

// Record custom bandwidth sample if needed
monitor.recordBandwidthSample(bytesDownloaded, duration);
```

## API

### ReelPrefetchController

Main entry point.

- `Future<String> getPlayablePath(String url)`: Gets path for playback. Detects HLS automatically.
- `void onScrollUpdate({required List<String> urls, required int currentIndex})`: Manages prefetch based on scroll position.
- `void setNetworkType(NetworkType? type)`: Manually override the network type (e.g., force 'Slow' mode).

### NetworkQualityMonitor

Singleton for bandwidth estimation.

- `double get estimatedBandwidth`: Get current estimation in KB/s.
- `NetworkType get currentType`: Get detected network type (wifi, fiveG, fourG, slow).
- `PrefetchConfig get prefetchConfig`: Get recommended config for current network.

### PrefetchConfig

Immutable configuration for prefetching behavior.

```dart
final config = PrefetchConfig(
  prefetchAhead: 3,
  prefetchBehind: 1,
  keepRange: 5,
  maxConcurrent: 3,
);
```

## Platform Notes

- **MP4**: Works on Android and iOS using standard file-based playback for growing files.
- **HLS**: Works by generating a local `.m3u8` playlist that points to cached `.ts` segments.
- **Storage**: Files are stored in the application cache directory by default.

## Installation

```yaml
dependencies:
  progressive_video_cache: ">=1.0.0 <2.0.0"
```

## License

MIT
