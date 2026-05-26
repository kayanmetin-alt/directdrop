import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/device_presence.dart';
import 'device_registry_service.dart';
import 'paired_devices_service.dart';

class PairedPresenceService extends ChangeNotifier {
  PairedPresenceService._();

  static final PairedPresenceService instance = PairedPresenceService._();

  final DeviceRegistryService _registry = DeviceRegistryService();
  final Map<String, DevicePresence> _presenceByDeviceId = {};
  final Map<String, StreamSubscription<DevicePresence>> _subscriptions = {};
  Timer? _staleCheckTimer;
  bool _started = false;

  bool isOnline(String deviceId) =>
      _presenceByDeviceId[deviceId]?.isActive ?? false;

  /// Uygulama açık ve heartbeat taze mi?
  bool isStrictlyOnline(String deviceId) =>
      _presenceByDeviceId[deviceId]?.isOnlineNow ?? false;

  DevicePresence? presenceFor(String deviceId) => _presenceByDeviceId[deviceId];

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await PairedDevicesService.instance.load();
    PairedDevicesService.instance.addListener(_onPairsChanged);
    await _refreshSubscriptions();
    _startStaleCheck();
  }

  /// Uygulama ön plana döndüğünde abonelikleri yenile.
  Future<void> ensureRunning() async {
    if (!_started) {
      await start();
      return;
    }
    await _refreshSubscriptions();
    _startStaleCheck();
  }

  void _startStaleCheck() {
    _staleCheckTimer?.cancel();
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      notifyListeners();
    });
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    PairedDevicesService.instance.removeListener(_onPairsChanged);
    _staleCheckTimer?.cancel();
    _staleCheckTimer = null;
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _presenceByDeviceId.clear();
  }

  void _onPairsChanged() {
    unawaited(_refreshSubscriptions());
  }

  Future<void> _refreshSubscriptions() async {
    final pairedIds =
        PairedDevicesService.instance.devices.map((d) => d.deviceId).toSet();

    for (final id in _subscriptions.keys.toList()) {
      if (!pairedIds.contains(id)) {
        await _subscriptions.remove(id)?.cancel();
        _presenceByDeviceId.remove(id);
      }
    }

    for (final id in pairedIds) {
      if (_subscriptions.containsKey(id)) continue;
      _subscriptions[id] = _registry.watchPresence(id).listen((presence) {
        _presenceByDeviceId[id] = presence;
        notifyListeners();
      });
    }

    notifyListeners();
  }
}
