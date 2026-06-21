import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/paired_device.dart';

class PairedDevicesService extends ChangeNotifier {
  PairedDevicesService._();

  static final PairedDevicesService instance = PairedDevicesService._();

  static const _storageKey = 'directdrop_paired_devices';

  List<PairedDevice> _devices = [];
  bool _loaded = false;

  List<PairedDevice> get devices => List.unmodifiable(_devices);

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _devices = list
            .map((e) => PairedDevice.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList()
          ..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
      } catch (e) {
        debugPrint('Eşleşmiş cihaz listesi okunamadı: $e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> savePair({
    required String deviceId,
    required String displayName,
    required String platform,
    String? inviteCode,
  }) async {
    await load();
    final now = DateTime.now();
    final index = _devices.indexWhere((d) => d.deviceId == deviceId);
    if (index >= 0) {
      _devices[index] = _devices[index].copyWith(
        displayName: displayName,
        lastConnectedAt: now,
        inviteCode: inviteCode ?? _devices[index].inviteCode,
      );
    } else {
      final byInviteIndex = inviteCode == null
          ? -1
          : _devices.indexWhere((d) => d.inviteCode == inviteCode);
      if (byInviteIndex >= 0) {
        _devices[byInviteIndex] = _devices[byInviteIndex].copyWith(
          deviceId: deviceId,
          displayName: displayName,
          lastConnectedAt: now,
          inviteCode: inviteCode,
        );
      } else {
        _devices.insert(
          0,
          PairedDevice(
            deviceId: deviceId,
            displayName: displayName,
            platform: platform,
            lastConnectedAt: now,
            inviteCode: inviteCode,
          ),
        );
      }
    }
    _devices.sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String deviceId) async {
    await load();
    _devices.removeWhere((d) => d.deviceId == deviceId);
    await _persist();
    notifyListeners();
  }

  PairedDevice? findByDeviceId(String deviceId) {
    for (final device in _devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  PairedDevice? findByDisplayName(String displayName) {
    if (displayName.isEmpty) return null;
    for (final device in _devices) {
      if (device.displayName == displayName) return device;
    }
    return null;
  }

  bool isKnownPeer({String? deviceId, String? displayName}) {
    if (deviceId != null &&
        deviceId.isNotEmpty &&
        findByDeviceId(deviceId) != null) {
      return true;
    }
    if (displayName != null &&
        displayName.isNotEmpty &&
        findByDisplayName(displayName) != null) {
      return true;
    }
    return false;
  }

  /// Firebase Auth sonrası cihaz kimliği değişmişse eşleşmeyi günceller.
  Future<void> reconcileDeviceId({
    required String oldDeviceId,
    required String newDeviceId,
  }) async {
    if (oldDeviceId == newDeviceId) return;
    await load();

    final oldIndex = _devices.indexWhere((d) => d.deviceId == oldDeviceId);
    if (oldIndex < 0) return;

    final newIndex = _devices.indexWhere((d) => d.deviceId == newDeviceId);
    if (newIndex >= 0 && newIndex != oldIndex) {
      _devices.removeAt(oldIndex);
    } else {
      _devices[oldIndex] = _devices[oldIndex].copyWith(deviceId: newDeviceId);
    }

    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}
