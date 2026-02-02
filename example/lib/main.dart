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
      theme: ThemeData.dark(),
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
  // Sample video URLs
  final List<String> videoUrls = [
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

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _prefetch = ReelPrefetchController(maxConcurrent: 2);
    _loadVideo(0);
  }

  Future<void> _loadVideo(int index) async {
    setState(() => _isLoading = true);

    // Dispose old player
    await _currentPlayer?.dispose();

    try {
      // Get playable path (starts download if needed)
      final path = await _prefetch.getPlayablePath(videoUrls[index]);

      // Create player from file
      _currentPlayer = VideoPlayerController.file(File(path));
      await _currentPlayer!.initialize();
      await _currentPlayer!.setLooping(true);
      await _currentPlayer!.play();

      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Error loading video: $e');
      setState(() => _isLoading = false);
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

  @override
  void dispose() {
    _pageController.dispose();
    _prefetch.dispose();
    _currentPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Progressive Video Caching'),
        backgroundColor: Colors.black,
      ),
      body: PageView.builder(
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

          if (_currentPlayer == null || !_currentPlayer!.value.isInitialized) {
            return const Center(
              child:
                  Text('Failed to load', style: TextStyle(color: Colors.red)),
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
    );
  }
}
