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

    test('all network types return correct values', () {
      for (final type in NetworkType.values) {
        final config = PrefetchConfig.forNetwork(type);
        expect(config.maxConcurrent, isNonNegative);
        expect(config.prefetchAhead, isNonNegative);
        expect(config.prefetchBehind, isNonNegative);
        expect(config.keepRange, isNonNegative);
      }
    });
  });

  group('HlsParser Additional Tests', () {
    test('master playlist with codecs', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=720x480,CODECS="avc1.4d401f,mp4a.40.2"
720p.m3u8
''';
      final playlist = HlsParser.parse(content, 'https://example.com/master.m3u8') as HlsMasterPlaylist;
      expect(playlist.variants.length, equals(1));
      expect(playlist.variants[0].codecs, equals('avc1.4d401f,mp4a.40.2'));
    });

    test('live playlist has no EXT-X-ENDLIST', () {
      const content = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
segment0.ts
''';
      final playlist = HlsParser.parse(content, 'https://example.com/playlist.m3u8') as HlsMediaPlaylist;
      expect(playlist.isLive, isTrue);
    });

    test('empty playlist content throws FormatException', () {
      expect(() => HlsParser.parse('', 'https://example.com/empty.m3u8'), throwsFormatException);
    });

    test('resolves relative URLs with ports correctly', () {
      const content = '''
#EXTM3U
#EXTINF:10,
/absolute/path/segment.ts
''';
      final playlist = HlsParser.parse(content, 'http://example.com:8080/video/playlist.m3u8') as HlsMediaPlaylist;
      expect(playlist.segments[0].url, equals('http://example.com:8080/absolute/path/segment.ts'));
    });
  });

  group('CacheMetadata Tests', () {
    test('JSON round-trip serialization', () {
      final now = DateTime.now();
      final original = CacheMetadata(
        downloadedBytes: 500,
        totalBytes: 1000,
        isComplete: false,
        lastUpdated: now,
        isHls: true,
      );

      final json = original.toJson();
      final restored = CacheMetadata.fromJson(json);

      expect(restored.downloadedBytes, equals(500));
      expect(restored.totalBytes, equals(1000));
      expect(restored.isComplete, isFalse);
      expect(restored.lastUpdated.toIso8601String(), equals(now.toIso8601String()));
      expect(restored.isHls, isTrue);
    });

    test('fromJson with missing optional fields', () {
      final json = {
        'downloadedBytes': 300,
        'isComplete': true,
        'lastUpdated': DateTime.now().toIso8601String(),
      };
      final metadata = CacheMetadata.fromJson(json);
      expect(metadata.totalBytes, isNull);
      expect(metadata.isHls, isFalse);
    });
  });

  group('NetworkQualityMonitor Additional Tests', () {
    test('bandwidth sample does not update WiFi type', () {
      final monitor = NetworkQualityMonitor.instance;
      monitor.reset();
      monitor.updateFromConnectivity(isWifi: true);
      monitor.recordBandwidthSample(100, const Duration(milliseconds: 200));
      // Should remain WiFi despite the low bandwidth sample
      expect(monitor.currentType, equals(NetworkType.wifi));
    });

    test('reset() restores defaults', () {
      final monitor = NetworkQualityMonitor.instance;
      monitor.updateFromConnectivity(isWifi: null, isMobile: null); // offline
      monitor.reset();
      expect(monitor.currentType, equals(NetworkType.wifi));
    });

    test('short sample (<100ms) is ignored', () {
      final monitor = NetworkQualityMonitor.instance;
      monitor.reset();
      monitor.updateFromConnectivity(isMobile: true);
      monitor.recordBandwidthSample(5000000, const Duration(milliseconds: 50));
      // High bandwidth but duration is < 100ms, so ignored and stays fourG (default mobile)
      expect(monitor.currentType, equals(NetworkType.fourG));
    });
  });

  group('DownloadProgress Tests', () {
    test('progress calculation normal case', () {
      final progress = DownloadProgress(
        url: 'https://example.com/video.mp4',
        downloadedBytes: 250,
        totalBytes: 1000,
        isComplete: false,
      );
      expect(progress.progress, equals(0.25));
    });

    test('progress calculation with 0 total', () {
      final progress = DownloadProgress(
        url: 'https://example.com/video.mp4',
        downloadedBytes: 250,
        totalBytes: 0,
        isComplete: false,
      );
      expect(progress.progress, equals(0.0));
    });

    test('progress calculation with null total', () {
      final progress = DownloadProgress(
        url: 'https://example.com/video.mp4',
        downloadedBytes: 250,
        totalBytes: null,
        isComplete: false,
      );
      expect(progress.progress, equals(0.0));
    });
  });

  group('HlsCacheResult Tests', () {
    test('progress calculation normal case', () {
      final result = HlsCacheResult(
        playlistPath: 'path/to/playlist.m3u8',
        isFullyCached: false,
        totalSegments: 10,
        cachedSegments: 4,
      );
      expect(result.progress, equals(0.4));
    });

    test('progress calculation edge cases', () {
      final result1 = HlsCacheResult(
        playlistPath: 'path/to/playlist.m3u8',
        isFullyCached: false,
        totalSegments: 0,
        cachedSegments: 0,
      );
      expect(result1.progress, equals(0.0));

      final result2 = HlsCacheResult(
        playlistPath: 'path/to/playlist.m3u8',
        isFullyCached: false,
        totalSegments: null,
        cachedSegments: 4,
      );
      expect(result2.progress, equals(0.0));
    });
  });

  group('HlsVariant and HlsSegment Tests', () {
    test('construction and field access', () {
      final variant = HlsVariant(
        url: 'https://example.com/v.m3u8',
        bandwidth: 800000,
        resolution: '640x360',
        codecs: 'mp4a.40.2',
      );
      expect(variant.url, equals('https://example.com/v.m3u8'));
      expect(variant.bandwidth, equals(800000));
      expect(variant.resolution, equals('640x360'));
      expect(variant.codecs, equals('mp4a.40.2'));

      final segment = HlsSegment(
        url: 'https://example.com/s1.ts',
        duration: 9.5,
        index: 2,
      );
      expect(segment.url, equals('https://example.com/s1.ts'));
      expect(segment.duration, equals(9.5));
      expect(segment.index, equals(2));
    });
  });

  group('HlsMasterPlaylist Tests', () {
    test('getVariantByBandwidth closest match and empty variants', () {
      final v1 = HlsVariant(url: 'v1.m3u8', bandwidth: 500000);
      final v2 = HlsVariant(url: 'v2.m3u8', bandwidth: 1500000);
      final master = HlsMasterPlaylist(url: 'master.m3u8', variants: [v1, v2]);

      expect(master.getVariantByBandwidth(900000), equals(v1));
      expect(master.getVariantByBandwidth(1100000), equals(v2));

      final emptyMaster = HlsMasterPlaylist(url: 'master.m3u8', variants: []);
      expect(emptyMaster.getVariantByBandwidth(1000000), isNull);
    });
  });

  group('HlsMediaPlaylist Tests', () {
    test('totalDuration calculation', () {
      final s1 = HlsSegment(url: 's1.ts', duration: 10.0, index: 0);
      final s2 = HlsSegment(url: 's2.ts', duration: 8.5, index: 1);
      final playlist = HlsMediaPlaylist(
        url: 'playlist.m3u8',
        segments: [s1, s2],
        targetDuration: 10.0,
        mediaSequence: 0,
        isLive: false,
      );
      expect(playlist.totalDuration, equals(18.5));
    });
  });
}
