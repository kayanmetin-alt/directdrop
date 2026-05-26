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
  }) async {
    await load();
    final now = DateTime.now();
    final index = _devices.indexWhere((d) => d.deviceId == deviceId);
    if (index >= 0) {
      _devices[index] = _devices[index].copyWith(
        displayName: displayName,
        lastConnectedAt: now,
      );
    } else {
      _devices.insert(
        0,
        PairedDevice(
          deviceId: deviceId,
          displayName: displayName,
          platform: platform,
          lastConnectedAt: now,
        ),
      );
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

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}
