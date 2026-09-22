import 'dart:io';

import 'package:flutter/material.dart';
import 'package:progressive_video_cache/progressive_video_cache.dart';
import 'package:video_player/video_player.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Caching Example',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.amberAccent,
        ),
      ),
      home: const ReelDemoPage(),
    );
  }
}

/// Demo page showing progressive video caching
class ReelDemoPage extends StatefulWidget {
  const ReelDemoPage({super.key});

  @override
  State<ReelDemoPage> createState() => _ReelDemoPageState();
}

class _ReelDemoPageState extends State<ReelDemoPage> {
  // Sample video URLs (mix of MP4 and HLS)
  final List<String> videoUrls = [
    "https://playertest.longtailvideo.com/adaptive/oceans/oceans.m3u8", // HLS
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackOnStreetAndDirt.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4"
  ];

  late final PageController _pageController;
  late final ReelPrefetchController _prefetch;

  VideoPlayerController? _currentPlayer;
  int _currentIndex = 0;
  bool _isLoading = true;
  int _cacheSize = 0;
  double _currentProgress = 0.0;
  String _networkStatus = "WiFi";

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _prefetch = ReelPrefetchController(maxConcurrent: 2);
    _updateCacheSize();
    _loadVideo(0);
  }

  Future<void> _updateCacheSize() async {
    final size = await CacheFileManager.getTotalCacheSize();
    if (mounted) {
      setState(() {
        _cacheSize = size;
      });
    }
  }

  Future<void> _loadVideo(int index) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _currentProgress = 0.0;
    });

    // Capture the current target index to prevent race conditions on rapid swipes
    final targetIndex = index;

    // Dispose old player
    final oldPlayer = _currentPlayer;
    _currentPlayer = null;
    if (oldPlayer != null) {
      await oldPlayer.dispose();
    }

    try {
      // Get playable path (starts download if needed)
      final path = await _prefetch.getPlayablePath(videoUrls[index]);

      // Check if the user has already scrolled away while we were loading
      if (_currentIndex != targetIndex) {
        return;
      }

      // Check download progress to display in UI
      final progress = await _prefetch.getProgress(videoUrls[index]);
      if (mounted) {
        setState(() {
          _currentProgress = progress;
        });
      }

      // Create player from file
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      await controller.setLooping(true);

      if (_currentIndex == targetIndex && mounted) {
        _currentPlayer = controller;
        await _currentPlayer!.play();
        setState(() {
          _isLoading = false;
        });
        _updateCacheSize();
      } else {
        await controller.dispose();
      }
    } catch (e) {
      debugPrint('Error loading video: $e');
      if (mounted && _currentIndex == targetIndex) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onPageChanged(int index) {
    _currentIndex = index;

    // Update prefetch for upcoming videos
    _prefetch.onScrollUpdate(
      urls: videoUrls,
      currentIndex: index,
      prefetchCount: 2,
    );

    _loadVideo(index);
  }

  Future<void> _clearCache() async {
    await CacheFileManager.clearAll();
    await _updateCacheSize();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared successfully!')),
      );
    }
    _loadVideo(_currentIndex);
  }

  void _setNetworkOverride(NetworkType type) {
    _prefetch.setNetworkType(type);
    setState(() {
      _networkStatus = type.name.toUpperCase();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _prefetch.dispose();
    _currentPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mbSize = (_cacheSize / (1024 * 1024)).toStringAsFixed(2);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Progressive Video Caching'),
        backgroundColor: Colors.black87,
        actions: [
          PopupMenuButton<NetworkType>(
            icon: const Icon(Icons.signal_cellular_alt),
            tooltip: 'Override Network Quality',
            onSelected: _setNetworkOverride,
            itemBuilder: (context) => NetworkType.values
                .map((type) => PopupMenuItem(
                      value: type,
                      child: Text(type.name.toUpperCase()),
                    ))
                .toList(),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear Cache ($mbSize MB)',
            onPressed: _clearCache,
          ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            onPageChanged: _onPageChanged,
            itemCount: videoUrls.length,
            itemBuilder: (context, index) {
              if (index != _currentIndex) {
                return Container(
                  color: Colors.grey[900],
                  child: Center(
                    child: Text(
                      'Video ${index + 1}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                );
              }

              if (_isLoading) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                );
              }

              if (_currentPlayer == null ||
                  !_currentPlayer!.value.isInitialized) {
                return const Center(
                  child: Text('Failed to load video',
                      style: TextStyle(color: Colors.red)),
                );
              }

              return GestureDetector(
                onTap: () {
                  if (_currentPlayer!.value.isPlaying) {
                    _currentPlayer!.pause();
                  } else {
                    _currentPlayer!.play();
                  }
                  setState(() {});
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: _currentPlayer!.value.aspectRatio,
                        child: VideoPlayer(_currentPlayer!),
                      ),
                    ),
                    if (!_currentPlayer!.value.isPlaying)
                      const Icon(
                        Icons.play_arrow,
                        size: 80,
                        color: Colors.white54,
                      ),
                  ],
                ),
              );
            },
          ),
          // Info overlay at the top left of the video screen
          Positioned(
            left: 16,
            top: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Net Status: $_networkStatus',
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Cache: $mbSize MB',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_currentProgress > 0 && _currentProgress < 1.0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Buffered: ${(_currentProgress * 100).toInt()}%',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
