class DevicePresence {
  const DevicePresence({
    required this.online,
    this.lastSeenMs,
  });

  final bool online;
  final int? lastSeenMs;

  /// Heartbeat 12 sn (masaüstü); bu süreden eskiyse çevrimdışı say.
  static const onlineFreshnessMs = 45000;
  static const _staleAfterMs = 70000;

  bool get isOnlineNow {
    if (!online) return false;
    if (lastSeenMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch - lastSeenMs! <
        onlineFreshnessMs;
  }

  bool get isActive {
    if (isOnlineNow) return true;
    if (lastSeenMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch - lastSeenMs! < _staleAfterMs;
  }
}
