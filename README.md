# progressive_video_cache

[![pub package](https://img.shields.io/pub/v/progressive_video_cache.svg)](https://pub.dev/packages/progressive_video_cache)

Progressive video caching for Flutter Reels/short-video apps.

## Features

- **Progressive playback**: Play videos before download completes
- **Offline-first**: Cached bytes play instantly without network
- **Resume downloads**: Continue from last downloaded byte
- **Scroll-aware prefetch**: Automatically cache upcoming videos
- **Simple API**: 4 classes, zero configuration

## Architecture

```
VideoPlayerController.file()
        ↓
Growing local file (append-only)
        ↑
ProgressiveDownloader (HTTP stream → file)
```

No proxy servers. No sockets. No complex state machines.

## Usage

```dart
import 'dart:io';
import 'package:progressive_video_cache/progressive_video_cache.dart';
import 'package:video_player/video_player.dart';

// Create prefetch controller
final prefetch = ReelPrefetchController(maxConcurrent: 2);

// Get playable path (starts download if needed)
final path = await prefetch.getPlayablePath(videoUrl);

// Play from file
final controller = VideoPlayerController.file(File(path));
await controller.initialize();
controller.play();

// On scroll, prefetch next videos
prefetch.onScrollUpdate(
  urls: allVideoUrls,
  currentIndex: currentIndex,
);

// Cleanup
prefetch.dispose();
```

## API

### ReelPrefetchController

Main entry point for video caching.

```dart
// Create controller
final prefetch = ReelPrefetchController(maxConcurrent: 2);

// Get path for playback (starts download if not cached)
Future<String> getPlayablePath(String url);

// Check if fully cached
Future<bool> isCached(String url);

// Cancel active download
void cancelDownload(String url);

// Update prefetch on scroll
void onScrollUpdate({
  required List<String> urls,
  required int currentIndex,
  int prefetchCount = 2,
  int keepRange = 3,
});

// Cleanup
void dispose();
```

### CacheFileManager

Direct file operations.

```dart
// Get cache path for URL
Future<String> getFilePath(String url);

// Check if file exists
Future<bool> exists(String url);

// Get current file size
Future<int> getFileSize(String url);

// Delete cached file
Future<void> delete(String url);

// Clear all cache
Future<void> clearAll();
```

### CacheMetadataStore

Download progress tracking.

```dart
// Check if complete
Future<bool> isComplete(String url);

// Get downloaded bytes
Future<int> getDownloadedBytes(String url);

// Get metadata
Future<CacheMetadata?> get(String url);
```

### ProgressiveDownloader

Low-level download API (usually not needed directly).

```dart
// Start download, returns progress stream
static Stream<DownloadProgress> download({
  required String url,
  required String filePath,
  int startByte = 0,
});

// Cancel download
static void cancel(String url);
```

## Platform Notes

- **Android**: ExoPlayer supports growing files
- **iOS**: AVPlayer supports growing files
- **Format**: MP4 only (no HLS parsing)

## Installation

```yaml
dependencies:
  progressive_video_cache: ^1.0.0
```

## License

MIT
