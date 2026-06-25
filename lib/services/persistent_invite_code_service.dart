import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/room_code_generator.dart';
import 'device_identity_service.dart';
import 'firebase_auth_service.dart';

/// Cihaza özel kalıcı davet kodu (QR). Yenilenene kadar aynı kalır.
class PersistentInviteCodeService {
  PersistentInviteCodeService._();

  static final PersistentInviteCodeService instance =
      PersistentInviteCodeService._();

  static const _prefKey = 'persistent_invite_code';

  final FirebaseDatabase _database = FirebaseDatabase.instance;
  String? _cachedCode;

  DatabaseReference get _inviteCodes => _database.ref('inviteCodes');

  Future<String> getOrCreate() async {
    if (_cachedCode != null) return _cachedCode!;
    final prefs = await SharedPreferences.getInstance();
    var code = prefs.getString(_prefKey);
    if (code == null || code.isEmpty) {
      code = RoomCodeGenerator.generate();
      await prefs.setString(_prefKey, code);
    }
    _cachedCode = code;
    await _syncToFirebase(code);
    return code;
  }

  Future<void> resyncCurrentMapping() async {
    if (_cachedCode != null) {
      await _syncToFirebase(_cachedCode!);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey);
    if (code == null || code.isEmpty) return;
    _cachedCode = code;
    await _syncToFirebase(code);
  }

  Future<String> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final oldCode = prefs.getString(_prefKey);
    final code = RoomCodeGenerator.generate();
    await prefs.setString(_prefKey, code);
    _cachedCode = code;

    if (oldCode != null && oldCode.isNotEmpty) {
      await _removeMapping(oldCode);
    }
    await _syncToFirebase(code);
    return code;
  }

  Future<void> _syncToFirebase(String code) async {
    try {
      final identity = DeviceIdentityService.instance;
      final deviceId = await identity.getDeviceId();
      final ownerUid = await FirebaseAuthService.instance.requireUid();
      final normalized = code.trim().toUpperCase();

      await _inviteCodes.child(normalized).set({
        'deviceId': deviceId,
        'ownerUid': ownerUid,
        'displayName': identity.displayName,
        'platform': identity.platformLabel,
        'updatedAt': ServerValue.timestamp,
        'clientUpdatedAt': DateTime.now().millisecondsSinceEpoch,
      });

      await _database.ref('devices').child(deviceId).update({
        'inviteCode': normalized,
      });
    } on FirebaseException catch (e) {
      debugPrint('Kalıcı davet kodu kaydı başarısız: ${e.code}');
    }
  }

  Future<void> _removeMapping(String code) async {
    try {
      final normalized = code.trim().toUpperCase();
      final snapshot = await _inviteCodes.child(normalized).get();
      if (!snapshot.exists) return;
      final deviceId = await DeviceIdentityService.instance.getDeviceId();
      final data = snapshot.value;
      if (data is Map && data['deviceId'] == deviceId) {
        await _inviteCodes.child(normalized).remove();
      }
    } catch (e) {
      debugPrint('Eski davet kodu silinemedi: $e');
    }
  }

  /// QR/kod ile cihaz arar. Ephemeral oda kodu değilse cihaz bilgisi döner.
  Future<DeviceInviteLookup?> lookup(String rawCode) async {
    final code = rawCode.trim().toUpperCase();
    if (code.length < 6) return null;

    try {
      final snapshot = await _inviteCodes.child(code).get();
      if (!snapshot.exists || snapshot.value is! Map) return null;
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      final deviceId = data['deviceId'] as String?;
      if (deviceId == null || deviceId.isEmpty) return null;

      final myId = await DeviceIdentityService.instance.getDeviceId();
      if (deviceId == myId) return null;

      return DeviceInviteLookup(
        inviteCode: code,
        deviceId: deviceId,
        displayName: data['displayName'] as String? ?? 'Cihaz',
        platform: data['platform'] as String? ?? 'unknown',
      );
    } on FirebaseException catch (e) {
      debugPrint('Davet kodu araması başarısız: ${e.code}');
      return null;
    }
  }
}

class DeviceInviteLookup {
  const DeviceInviteLookup({
    required this.inviteCode,
    required this.deviceId,
    required this.displayName,
    required this.platform,
  });

  final String inviteCode;
  final String deviceId;
  final String displayName;
  final String platform;
}
