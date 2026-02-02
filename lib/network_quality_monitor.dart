import 'package:flutter/foundation.dart';

import 'reel_prefetch_controller.dart';

/// Monitors network quality and estimates bandwidth.
/// Provides adaptive prefetch configuration based on detected network conditions.
class NetworkQualityMonitor {
  NetworkQualityMonitor._();
  static final instance = NetworkQualityMonitor._();

  /// Current network type (defaults to WiFi)
  final _networkType = ValueNotifier<NetworkType>(NetworkType.wifi);

  /// Estimated bandwidth in KB/s (updated from download speed samples)
  double _estimatedBandwidth = 1000; // Default 1MB/s

  /// Bandwidth samples for rolling average
  final List<double> _bandwidthSamples = [];
  static const int maxSamples = 10;

  /// Listen to network type changes
  ValueListenable<NetworkType> get networkType => _networkType;

  /// Get current estimated bandwidth in KB/s
  double get estimatedBandwidth => _estimatedBandwidth;

  /// Get current network type value
  NetworkType get currentType => _networkType.value;

  /// Manually set network type (useful when connectivity_plus is not available)
  void setNetworkType(NetworkType type) {
    _networkType.value = type;
  }

  /// Record a bandwidth sample from a download
  /// Call this after each download completes with bytes downloaded and duration
  void recordBandwidthSample(int bytes, Duration duration) {
    if (duration.inMilliseconds < 100) return; // Ignore too-short samples

    final kbps = (bytes / 1024) / (duration.inMilliseconds / 1000);
    _bandwidthSamples.add(kbps);

    if (_bandwidthSamples.length > maxSamples) {
      _bandwidthSamples.removeAt(0);
    }

    // Calculate rolling average
    _estimatedBandwidth =
        _bandwidthSamples.reduce((a, b) => a + b) / _bandwidthSamples.length;

    // Update network type based on measured bandwidth (only for mobile)
    if (_networkType.value != NetworkType.wifi) {
      if (_estimatedBandwidth > 2000) {
        // > 2MB/s = 5G
        _networkType.value = NetworkType.fiveG;
      } else if (_estimatedBandwidth > 500) {
        // > 500KB/s = 4G
        _networkType.value = NetworkType.fourG;
      } else {
        // < 500KB/s = Slow
        _networkType.value = NetworkType.slow;
      }
    }
  }

  /// Update network type from connectivity status
  /// Pass true if connected via WiFi, false if mobile, null if offline
  void updateFromConnectivity({bool? isWifi, bool? isMobile}) {
    if (isWifi == true) {
      _networkType.value = NetworkType.wifi;
    } else if (isMobile == true) {
      // Start with 4G, will be refined by bandwidth samples
      _networkType.value = NetworkType.fourG;
    } else {
      _networkType.value = NetworkType.offline;
    }

    // Clear samples when connectivity changes
    _bandwidthSamples.clear();
  }

  /// Reset to default state
  void reset() {
    _networkType.value = NetworkType.wifi;
    _estimatedBandwidth = 1000;
    _bandwidthSamples.clear();
  }

  /// Get current prefetch config based on network conditions
  PrefetchConfig get prefetchConfig =>
      PrefetchConfig.forNetwork(_networkType.value);
}
