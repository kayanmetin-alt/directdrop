import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/paired_device.dart';
import 'firebase_auth_service.dart';

/// Eşleştirilmiş cihazları Firebase'de `pairings/{ownerUid}/{peerDeviceId}` altında
/// tutar. RTDB kuralları bu kayıt üzerinden eş cihazların presence / pairConnect
/// okumasını ve wake isteği gönderimini doğrular.
class PairingsRegistryService {
  PairingsRegistryService._();

  static final PairingsRegistryService instance = PairingsRegistryService._();

  final FirebaseDatabase _database = FirebaseDatabase.instance;

  DatabaseReference get _pairings => _database.ref('pairings');

  Future<void> syncAll(List<PairedDevice> devices) async {
    try {
      final ownerUid = await FirebaseAuthService.instance.requireUid();
      final ref = _pairings.child(ownerUid);

      final snapshot = await ref.get();
      final existing = <String>{};
      if (snapshot.exists && snapshot.value is Map) {
        existing.addAll(
          (snapshot.value as Map).keys.cast<String>(),
        );
      }

      final desired = devices.map((d) => d.deviceId).toSet();

      final updates = <String, dynamic>{};
      for (final peerId in desired) {
        updates[peerId] = true;
      }
      for (final stale in existing.difference(desired)) {
        updates[stale] = null;
      }

      if (updates.isEmpty) return;
      await ref.update(updates);
    } catch (e, stack) {
      debugPrint('Eşleşme kaydı senkronu başarısız: $e\n$stack');
    }
  }

  Future<void> addPeer(String peerDeviceId) async {
    if (peerDeviceId.isEmpty) return;
    try {
      final ownerUid = await FirebaseAuthService.instance.requireUid();
      await _pairings.child(ownerUid).child(peerDeviceId).set(true);
    } catch (e, stack) {
      debugPrint('Eşleşme eklenemedi: $e\n$stack');
    }
  }

  Future<void> removePeer(String peerDeviceId) async {
    if (peerDeviceId.isEmpty) return;
    try {
      final ownerUid = await FirebaseAuthService.instance.requireUid();
      await _pairings.child(ownerUid).child(peerDeviceId).remove();
    } catch (e, stack) {
      debugPrint('Eşleşme kaldırılamadı: $e\n$stack');
    }
  }
}
