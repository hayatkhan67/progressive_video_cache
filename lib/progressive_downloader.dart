import 'dart:async';
import 'dart:io';

/// Progressive HTTP downloader that streams bytes to a growing file.
/// Supports resume, cancellation, progress reporting, and waiting for minimum bytes.
/// Uses HTTP client pooling for connection reuse.
class ProgressiveDownloader {
  ProgressiveDownloader._();

  /// Download state for cancellation and byte threshold signaling
  static final Map<String, _DownloadState> _downloads = {};

  /// Minimum bytes needed for ExoPlayer/AVPlayer to start playback
  /// Increased from 64KB to 128KB for smoother playback start
  static const int minBytesForPlayback = 131072; // 128KB

  /// Chunk size for progress reporting (64KB)
  static const int chunkSize = 65536;

  /// Maximum HTTP connections for pooling
  static const int maxConnections = 4;

  /// HTTP client pool for connection reuse
  static final List<HttpClient> _clientPool = List.generate(
    maxConnections,
    (_) => HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 30),
  );

  static int _clientIndex = 0;

  /// Get next available HTTP client from pool (round-robin)
  static HttpClient get _nextClient {
    final client = _clientPool[_clientIndex];
    _clientIndex = (_clientIndex + 1) % maxConnections;
    return client;
  }

  /// Start downloading and wait until minimum bytes are available.
  /// Returns a Future that completes when [minBytes] are downloaded.
  /// Download continues in background after Future completes.
  static Future<DownloadResult> downloadAndWaitForBytes({
    required String url,
    required String filePath,
    int startByte = 0,
    int minBytes = minBytesForPlayback,
    Map<String, String>? headers,
  }) async {
    final completer = Completer<DownloadResult>();
    bool thresholdReached = false;

    final stream = download(
      url: url,
      filePath: filePath,
      startByte: startByte,
      headers: headers,
    );

    late StreamSubscription<DownloadProgress> subscription;
    subscription = stream.listen(
      (progress) {
        if (!thresholdReached) {
          if (progress.downloadedBytes >= minBytes || progress.isComplete) {
            thresholdReached = true;
            completer.complete(DownloadResult(
              downloadedBytes: progress.downloadedBytes,
              isComplete: progress.isComplete,
              subscription: subscription,
            ));
          }
        }
      },
      onError: (e) {
        if (!thresholdReached) {
          thresholdReached = true;
          completer.completeError(e);
        }
      },
      onDone: () {
        if (!thresholdReached) {
          thresholdReached = true;
          completer.complete(DownloadResult(
            downloadedBytes: 0,
            isComplete: true,
            subscription: subscription,
          ));
        }
      },
    );

    return completer.future;
  }

  /// Start downloading [url] to [filePath], resuming from [startByte].
  /// Returns a stream of progress updates.
  static Stream<DownloadProgress> download({
    required String url,
    required String filePath,
    int startByte = 0,
    Map<String, String>? headers,
  }) {
    late StreamController<DownloadProgress> controller;
    controller = StreamController<DownloadProgress>(
      onCancel: () {
        cancel(url);
        if (!controller.isClosed) {
          controller.close();
        }
      },
    );

    _startDownload(
      url: url,
      filePath: filePath,
      startByte: startByte,
      headers: headers,
      controller: controller,
      onProgress: (downloaded, total) {
        if (controller.isClosed) return;
        controller.add(DownloadProgress(
          url: url,
          downloadedBytes: downloaded,
          totalBytes: total,
          isComplete: total != null && downloaded >= total,
        ));
      },
      onComplete: (downloaded, total) {
        _downloads.remove(url);
        if (controller.isClosed) return;
        controller.add(DownloadProgress(
          url: url,
          downloadedBytes: downloaded,
          totalBytes: total,
          isComplete: true,
        ));
        controller.close();
      },
      onError: (error) {
        _downloads.remove(url);
        if (controller.isClosed) return;
        controller.addError(error);
        controller.close();
      },
    );

    return controller.stream;
  }

  /// Cancel an active download.
  static void cancel(String url) {
    final state = _downloads[url];
    if (state != null) {
      state.cancelled = true;
      state.request?.abort();
      try {
        if (state.controller != null && !state.controller!.isClosed) {
          state.controller!.close();
        }
      } catch (_) {}
      _downloads.remove(url);
    }
  }

  /// Cancel all active downloads.
  static void cancelAll() {
    for (final url in _downloads.keys.toList()) {
      cancel(url);
    }
  }

  static Future<void> _startDownload({
    required String url,
    required String filePath,
    required int startByte,
    Map<String, String>? headers,
    required StreamController<DownloadProgress> controller,
    required void Function(int downloaded, int? total) onProgress,
    required void Function(int downloaded, int? total) onComplete,
    required void Function(Object error) onError,
  }) async {
    final existing = _downloads[url];
    if (existing != null) {
      cancel(url);
    }
    final state = _DownloadState();
    state.controller = controller;
    _downloads[url] = state;

    try {
      // Use pooled client for connection reuse
      final client = _nextClient;
      final uri = Uri.parse(url);

      Future<HttpClientResponse> sendRequest(int rangeStart) async {
        final request = await client.getUrl(uri);
        state.request = request;

        // Add range header for resume
        if (rangeStart > 0) {
          request.headers.set('Range', 'bytes=$rangeStart-');
        }

        // Add custom headers
        headers?.forEach((key, value) {
          request.headers.set(key, value);
        });

        return request.close();
      }

      var effectiveStart = startByte;
      var response = await sendRequest(effectiveStart);
      state.response = response;

      // If server ignored Range, restart from 0 to avoid corruption
      if (effectiveStart > 0 && response.statusCode == 200) {
        await response.drain();
        await _truncateFile(filePath);
        effectiveStart = 0;
        response = await sendRequest(effectiveStart);
        state.response = response;
      }

      // Check for valid response
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      // Determine total size
      int? totalBytes;
      if (response.contentLength > 0) {
        totalBytes = effectiveStart + response.contentLength;
      }

      // Open file for append
      final file = File(filePath);
      final mode =
          effectiveStart > 0 ? FileMode.writeOnlyAppend : FileMode.write;
      final raf = await file.open(mode: mode);
      state.raf = raf;

      int downloadedBytes = effectiveStart;
      int lastReportedBytes = effectiveStart;

      await for (final chunk in response) {
        if (state.cancelled) break;
        await raf.writeFrom(chunk);
        downloadedBytes += chunk.length;

        // Throttle progress updates using chunkSize
        if (downloadedBytes - lastReportedBytes >= chunkSize) {
          onProgress(downloadedBytes, totalBytes);
          lastReportedBytes = downloadedBytes;
        }
      }

      if (state.cancelled) {
        try {
          await raf.close();
        } catch (_) {}
        return;
      }

      await raf.flush();
      await raf.close();
      // Don't close pooled client - let it be reused

      onProgress(downloadedBytes, totalBytes);
      onComplete(downloadedBytes, totalBytes);
    } catch (e) {
      if (!state.cancelled) {
        onError(e);
      }
    }
  }
}

class _DownloadState {
  bool cancelled = false;
  HttpClientRequest? request;
  HttpClientResponse? response;
  RandomAccessFile? raf;
  StreamController<DownloadProgress>? controller;
}

/// Progress update from downloader.
class DownloadProgress {
  final String url;
  final int downloadedBytes;
  final int? totalBytes;
  final bool isComplete;

  DownloadProgress({
    required this.url,
    required this.downloadedBytes,
    this.totalBytes,
    required this.isComplete,
  });

  double get progress {
    if (totalBytes == null || totalBytes == 0) return 0.0;
    return downloadedBytes / totalBytes!;
  }
}

/// Result of downloading until minimum bytes threshold.
class DownloadResult {
  final int downloadedBytes;
  final bool isComplete;
  final StreamSubscription<DownloadProgress>? subscription;

  DownloadResult({
    required this.downloadedBytes,
    required this.isComplete,
    this.subscription,
  });
}

Future<void> _truncateFile(String filePath) async {
  final file = File(filePath);
  if (await file.exists()) {
    await file.writeAsBytes(const [], mode: FileMode.write);
  } else {
    await file.create(recursive: true);
  }
}
