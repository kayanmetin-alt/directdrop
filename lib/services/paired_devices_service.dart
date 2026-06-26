import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/paired_device.dart';
import 'pairings_registry_service.dart';

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
        _dedupe();
      } catch (e) {
        debugPrint('Eşleşmiş cihaz listesi okunamadı: $e');
      }
    }
    _loaded = true;
    notifyListeners();
    unawaited(PairingsRegistryService.instance.syncAll(_devices));
  }

  /// Aynı cihaz için birden fazla satır oluşmasını engeller. Aynı `deviceId`
  /// ya da (aynı ad + aynı platform) olan kayıtlar tek satırda birleştirilir;
  /// en güncel bağlantı zamanı korunur, eksik davet kodu tamamlanır.
  void _dedupe() {
    bool sameDevice(PairedDevice a, PairedDevice b) {
      if (a.deviceId == b.deviceId) return true;
      if (a.displayName.isNotEmpty &&
          a.displayName == b.displayName &&
          a.platform == b.platform) {
        return true;
      }
      return false;
    }

    final sorted = [..._devices]
      ..sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    final result = <PairedDevice>[];
    for (final device in sorted) {
      final existingIndex = result.indexWhere((r) => sameDevice(r, device));
      if (existingIndex >= 0) {
        final existing = result[existingIndex];
        result[existingIndex] = existing.copyWith(
          inviteCode: existing.inviteCode ?? device.inviteCode,
        );
      } else {
        result.add(device);
      }
    }
    _devices = result;
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
      // deviceId ve davet kodu eşleşmezse, kullanıcı aynı cihazla sıfırdan
      // yeniden eşleştiğinde yeni satır açmak yerine aynı ada + platforma sahip
      // mevcut kaydı güncelle (her cihaz için tek satır).
      final byNameIndex = byInviteIndex >= 0 || displayName.isEmpty
          ? -1
          : _devices.indexWhere(
              (d) => d.displayName == displayName && d.platform == platform,
            );
      if (byInviteIndex >= 0) {
        _devices[byInviteIndex] = _devices[byInviteIndex].copyWith(
          deviceId: deviceId,
          displayName: displayName,
          lastConnectedAt: now,
          inviteCode: inviteCode,
        );
      } else if (byNameIndex >= 0) {
        _devices[byNameIndex] = _devices[byNameIndex].copyWith(
          deviceId: deviceId,
          displayName: displayName,
          lastConnectedAt: now,
          inviteCode: inviteCode ?? _devices[byNameIndex].inviteCode,
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
    _dedupe();
    _devices.sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    await _persist();
    notifyListeners();
    await PairingsRegistryService.instance.syncAll(_devices);
  }

  Future<void> remove(String deviceId) async {
    await load();
    _devices.removeWhere((d) => d.deviceId == deviceId);
    await _persist();
    notifyListeners();
    unawaited(PairingsRegistryService.instance.removePeer(deviceId));
    unawaited(PairingsRegistryService.instance.syncAll(_devices));
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

  /// Güven kararı YALNIZCA daha önce eşleştirilmiş deviceId ile verilir.
  /// Görünen ad istemciden gelir ve taklit edilebilir; bu yüzden güvende
  /// kullanılmaz (yalnızca görüntüleme amaçlıdır).
  bool isKnownPeer({String? deviceId}) {
    return deviceId != null &&
        deviceId.isNotEmpty &&
        findByDeviceId(deviceId) != null;
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
    await PairingsRegistryService.instance.removePeer(oldDeviceId);
    await PairingsRegistryService.instance.addPeer(newDeviceId);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}
