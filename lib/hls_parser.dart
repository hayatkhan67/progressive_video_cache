import 'dart:convert';

/// HLS/M3U8 playlist parser.
/// Parses master playlists (variant streams) and media playlists (segments).
class HlsParser {
  HlsParser._();

  /// Parse an M3U8 playlist content.
  /// Returns [HlsMasterPlaylist] if master, [HlsMediaPlaylist] if media.
  static HlsPlaylist parse(String content, String playlistUrl) {
    final lines = LineSplitter.split(content).toList();

    if (lines.isEmpty || !lines[0].startsWith('#EXTM3U')) {
      throw FormatException('Invalid M3U8: missing #EXTM3U header');
    }

    // Check if master playlist (contains #EXT-X-STREAM-INF)
    final isMaster = lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'));

    if (isMaster) {
      return _parseMasterPlaylist(lines, playlistUrl);
    } else {
      return _parseMediaPlaylist(lines, playlistUrl);
    }
  }

  /// Check if URL is HLS.
  static bool isHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.m3u8') || lower.contains('.m3u8?');
  }

  /// Parse master playlist with variant streams.
  static HlsMasterPlaylist _parseMasterPlaylist(
      List<String> lines, String playlistUrl) {
    final variants = <HlsVariant>[];
    final baseUrl = _getBaseUrl(playlistUrl);

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        // Parse attributes
        final attrs = _parseAttributes(line.substring(18));
        final bandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '0') ?? 0;
        final resolution = attrs['RESOLUTION'];
        final codecs = attrs['CODECS'];

        // Next non-comment line is the URI
        String? uri;
        for (int j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
            uri = _resolveUrl(nextLine, baseUrl);
            break;
          }
        }

        if (uri != null) {
          variants.add(HlsVariant(
            url: uri,
            bandwidth: bandwidth,
            resolution: resolution,
            codecs: codecs,
          ));
        }
      }
    }

    // Sort by bandwidth (highest first)
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    return HlsMasterPlaylist(
      url: playlistUrl,
      variants: variants,
    );
  }

  /// Parse media playlist with segments.
  static HlsMediaPlaylist _parseMediaPlaylist(
      List<String> lines, String playlistUrl) {
    final segments = <HlsSegment>[];
    final baseUrl = _getBaseUrl(playlistUrl);

    double targetDuration = 0;
    double currentDuration = 0;
    int mediaSequence = 0;
    bool isLive = true;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.tryParse(line.substring(22)) ?? targetDuration;
      } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(line.substring(22)) ?? mediaSequence;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        isLive = false;
      } else if (line.startsWith('#EXTINF:')) {
        // Parse duration
        final durationStr = line.substring(8).split(',')[0];
        currentDuration = double.tryParse(durationStr) ?? 0;

        // Next non-comment line is the segment URI
        for (int j = i + 1; j < lines.length; j++) {
          final nextLine = lines[j].trim();
          if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
            final segmentUrl = _resolveUrl(nextLine, baseUrl);
            segments.add(HlsSegment(
              url: segmentUrl,
              duration: currentDuration,
              index: segments.length,
            ));
            break;
          }
        }
      }
    }

    return HlsMediaPlaylist(
      url: playlistUrl,
      segments: segments,
      targetDuration: targetDuration,
      mediaSequence: mediaSequence,
      isLive: isLive,
    );
  }

  /// Parse key=value,key="value" attributes.
  static Map<String, String> _parseAttributes(String attrString) {
    final attrs = <String, String>{};
    final regex = RegExp(r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))');

    for (final match in regex.allMatches(attrString)) {
      final key = match.group(1)!;
      final value = match.group(2) ?? match.group(3) ?? '';
      attrs[key] = value;
    }

    return attrs;
  }

  /// Get base URL for resolving relative URLs.
  static String _getBaseUrl(String url) {
    final lastSlash = url.lastIndexOf('/');
    if (lastSlash > 0) {
      return url.substring(0, lastSlash + 1);
    }
    return url;
  }

  /// Resolve relative URL against base URL.
  static String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    if (url.startsWith('/')) {
      // Absolute path - need to get scheme and host from base
      final uri = Uri.parse(baseUrl);
      return '${uri.scheme}://${uri.host}$url';
    }
    return baseUrl + url;
  }
}

/// Base class for HLS playlists.
abstract class HlsPlaylist {
  final String url;
  HlsPlaylist({required this.url});

  bool get isMaster;
}

/// Master playlist containing variant streams.
class HlsMasterPlaylist extends HlsPlaylist {
  final List<HlsVariant> variants;

  HlsMasterPlaylist({
    required super.url,
    required this.variants,
  });

  @override
  bool get isMaster => true;

  /// Get best variant (highest bandwidth).
  HlsVariant? get bestVariant => variants.isNotEmpty ? variants.first : null;

  /// Get variant by target bandwidth.
  HlsVariant? getVariantByBandwidth(int targetBandwidth) {
    if (variants.isEmpty) return null;

    // Find closest to target
    HlsVariant? best;
    int bestDiff = double.maxFinite.toInt();

    for (final v in variants) {
      final diff = (v.bandwidth - targetBandwidth).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = v;
      }
    }

    return best;
  }
}

/// Media playlist containing segments.
class HlsMediaPlaylist extends HlsPlaylist {
  final List<HlsSegment> segments;
  final double targetDuration;
  final int mediaSequence;
  final bool isLive;

  HlsMediaPlaylist({
    required super.url,
    required this.segments,
    required this.targetDuration,
    required this.mediaSequence,
    required this.isLive,
  });

  @override
  bool get isMaster => false;

  /// Total duration in seconds.
  double get totalDuration => segments.fold(0, (sum, s) => sum + s.duration);
}

/// Variant stream in master playlist.
class HlsVariant {
  final String url;
  final int bandwidth;
  final String? resolution;
  final String? codecs;

  HlsVariant({
    required this.url,
    required this.bandwidth,
    this.resolution,
    this.codecs,
  });
}

/// Segment in media playlist.
class HlsSegment {
  final String url;
  final double duration;
  final int index;

  HlsSegment({
    required this.url,
    required this.duration,
    required this.index,
  });
}
