import 'package:flutter_test/flutter_test.dart';
import 'package:progressive_video_cache/progressive_video_cache.dart';

void main() {
  group('HlsParser', () {
    test('isHlsUrl returns true for .m3u8 URLs', () {
      expect(HlsParser.isHlsUrl('https://example.com/video.m3u8'), isTrue);
      expect(HlsParser.isHlsUrl('https://example.com/video.m3u8?token=123'),
          isTrue);
      expect(HlsParser.isHlsUrl('https://example.com/video.M3U8'), isTrue);
    });

    test('isHlsUrl returns false for non-HLS URLs', () {
      expect(HlsParser.isHlsUrl('https://example.com/video.mp4'), isFalse);
      expect(HlsParser.isHlsUrl('https://example.com/video.webm'), isFalse);
    });

    test('parse throws on invalid playlist', () {
      expect(
        () =>
            HlsParser.parse('invalid content', 'https://example.com/test.m3u8'),
        throwsFormatException,
      );
    });

    test('parse detects master playlist', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=720x480
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
1080p.m3u8
''';
      final playlist =
          HlsParser.parse(content, 'https://example.com/master.m3u8');

      expect(playlist.isMaster, isTrue);
      expect(playlist, isA<HlsMasterPlaylist>());

      final master = playlist as HlsMasterPlaylist;
      expect(master.variants.length, equals(2));
      expect(
          master.variants[0].bandwidth, equals(2560000)); // Sorted by bandwidth
      expect(master.variants[0].url, equals('https://example.com/1080p.m3u8'));
    });

    test('parse detects media playlist', () {
      const content = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:9.009,
segment0.ts
#EXTINF:9.009,
segment1.ts
#EXTINF:3.003,
segment2.ts
#EXT-X-ENDLIST
''';
      final playlist =
          HlsParser.parse(content, 'https://example.com/playlist.m3u8');

      expect(playlist.isMaster, isFalse);
      expect(playlist, isA<HlsMediaPlaylist>());

      final media = playlist as HlsMediaPlaylist;
      expect(media.segments.length, equals(3));
      expect(media.targetDuration, equals(10));
      expect(media.isLive, isFalse);
      expect(media.segments[0].url, equals('https://example.com/segment0.ts'));
      expect(media.segments[0].duration, equals(9.009));
    });

    test('resolves relative URLs correctly', () {
      const content = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
/absolute/path/segment.ts
#EXTINF:10,
relative/segment.ts
#EXTINF:10,
https://cdn.example.com/full/url/segment.ts
#EXT-X-ENDLIST
''';
      final playlist =
          HlsParser.parse(content, 'https://example.com/video/playlist.m3u8')
              as HlsMediaPlaylist;

      expect(playlist.segments[0].url,
          equals('https://example.com/absolute/path/segment.ts'));
      expect(playlist.segments[1].url,
          equals('https://example.com/video/relative/segment.ts'));
      expect(playlist.segments[2].url,
          equals('https://cdn.example.com/full/url/segment.ts'));
    });
  });

  group('CacheFileManager', () {
    test('getUrlHash returns consistent hash', () {
      const url = 'https://example.com/video.mp4';
      final hash1 = CacheFileManager.getUrlHash(url);
      final hash2 = CacheFileManager.getUrlHash(url);

      expect(hash1, equals(hash2));
      expect(hash1.length, equals(32)); // MD5 hex length
    });

    test('getUrlHash returns different hash for different URLs', () {
      final hash1 =
          CacheFileManager.getUrlHash('https://example.com/video1.mp4');
      final hash2 =
          CacheFileManager.getUrlHash('https://example.com/video2.mp4');

      expect(hash1, isNot(equals(hash2)));
    });
  });

  group('ReelPrefetchController', () {
    test('creates with default maxConcurrent', () {
      final controller = ReelPrefetchController();
      expect(controller.maxConcurrent, equals(3));
    });

    test('creates with custom maxConcurrent', () {
      final controller = ReelPrefetchController(maxConcurrent: 5);
      expect(controller.maxConcurrent, equals(5));
    });
  });

  group('NetworkQualityMonitor', () {
    test('updateFromConnectivity sets network type', () {
      final monitor = NetworkQualityMonitor.instance;
      monitor.reset();

      monitor.updateFromConnectivity(isWifi: true);
      expect(monitor.currentType, equals(NetworkType.wifi));

      monitor.updateFromConnectivity(isMobile: true);
      expect(monitor.currentType, equals(NetworkType.fourG));

      monitor.updateFromConnectivity(isWifi: null, isMobile: null);
      expect(monitor.currentType, equals(NetworkType.offline));
    });

    test('recordBandwidthSample updates network type on mobile', () {
      final monitor = NetworkQualityMonitor.instance;
      monitor.reset();
      monitor.updateFromConnectivity(isMobile: true);
      monitor.recordBandwidthSample(
          3 * 1024 * 1024, const Duration(seconds: 1));
      expect(monitor.currentType, equals(NetworkType.fiveG));

      monitor.reset();
      monitor.updateFromConnectivity(isMobile: true);
      monitor.recordBandwidthSample(700 * 1024, const Duration(seconds: 1));
      expect(monitor.currentType, equals(NetworkType.fourG));

      monitor.reset();
      monitor.updateFromConnectivity(isMobile: true);
      monitor.recordBandwidthSample(100 * 1024, const Duration(seconds: 1));
      expect(monitor.currentType, equals(NetworkType.slow));
    });
  });

  group('PrefetchConfig', () {
    test('forNetwork returns expected defaults', () {
      expect(
          PrefetchConfig.forNetwork(NetworkType.wifi).prefetchAhead, equals(4));
      expect(
        PrefetchConfig.forNetwork(NetworkType.fourG).maxConcurrent,
        equals(2),
      );
      expect(
        PrefetchConfig.forNetwork(NetworkType.offline).prefetchAhead,
        equals(0),
      );
    });
  });
}
