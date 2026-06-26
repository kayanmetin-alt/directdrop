import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/room_code_generator.dart';
import 'app_check_service.dart';
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
    if (_cachedCode != null) {
      return _syncToFirebaseEnsuringPublished(_cachedCode!);
    }
    final prefs = await SharedPreferences.getInstance();
    var code = prefs.getString(_prefKey);
    if (code == null || code.isEmpty) {
      code = RoomCodeGenerator.generate();
      await prefs.setString(_prefKey, code);
    }
    _cachedCode = code;
    final published = await _syncToFirebaseEnsuringPublished(code);
    _cachedCode = published;
    return published;
  }

  Future<void> resyncCurrentMapping() async {
    if (_cachedCode != null) {
      await _syncToFirebaseEnsuringPublished(_cachedCode!);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey);
    if (code == null || code.isEmpty) return;
    _cachedCode = code;
    final published = await _syncToFirebaseEnsuringPublished(code);
    _cachedCode = published;
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
    final published = await _syncToFirebaseEnsuringPublished(code);
    _cachedCode = published;
    return published;
  }

  Future<String> _syncToFirebaseEnsuringPublished(String code) async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await AppCheckService.ensureActivated();

    var current = code.trim().toUpperCase();

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _syncToFirebaseOnce(current);
        await _verifyPublished(current);
        return current;
      } on FirebaseException catch (e, stack) {
        debugPrint(
          'Kalıcı davet kodu kaydı başarısız ($current, deneme ${attempt + 1}): '
          '${e.code}\n$stack',
        );
        if (e.code == 'permission-denied') {
          final rotated = await _rotateIfBlocked(current);
          if (rotated != null) {
            current = rotated;
            continue;
          }
        }
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
        }
      }
    }

    throw StateError(
      'Cihaz QR kodu sunucuya kaydedilemedi. İnterneti kontrol edip '
      'uygulamayı yeniden açın.',
    );
  }

  Future<void> _verifyPublished(String code) async {
    final snapshot = await _inviteCodes.child(code).get();
    if (!snapshot.exists || snapshot.value is! Map) {
      throw FirebaseException(
        plugin: 'firebase_database',
        code: 'unknown',
        message: 'Davet kodu sunucuda doğrulanamadı.',
      );
    }
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (data['deviceId'] != deviceId) {
      throw FirebaseException(
        plugin: 'firebase_database',
        code: 'permission-denied',
        message: 'Davet kodu başka bir oturuma ait.',
      );
    }
  }

  Future<String?> _rotateIfBlocked(String code) async {
    final normalized = code.trim().toUpperCase();
    try {
      final snapshot = await _inviteCodes.child(normalized).get();
      if (!snapshot.exists || snapshot.value is! Map) return null;

      final deviceId = await DeviceIdentityService.instance.getDeviceId();
      final data = Map<String, dynamic>.from(snapshot.value as Map);
      final existingDevice = data['deviceId'] as String?;
      if (existingDevice == deviceId) {
        // Aynı cihaz, eski auth oturumu — kurallar güncellendiyse tekrar dene.
        return null;
      }
    } catch (e) {
      debugPrint('Davet kodu durumu okunamadı: $e');
    }

    return _rotateLocalCode(normalized);
  }

  Future<String> _rotateLocalCode(String staleCode) async {
    final prefs = await SharedPreferences.getInstance();
    final newCode = RoomCodeGenerator.generate();
    await prefs.setString(_prefKey, newCode);
    _cachedCode = newCode;
    await _removeMapping(staleCode);
    debugPrint('Davet kodu yenilendi: $staleCode → $newCode');
    return newCode;
  }

  Future<void> _syncToFirebaseOnce(String code) async {
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

    try {
      await _database.ref('devices').child(deviceId).update({
        'inviteCode': normalized,
      });
    } catch (e) {
      debugPrint('devices.inviteCode güncellenemedi: $e');
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

    await FirebaseAuthService.instance.ensureSignedIn();
    await AppCheckService.ensureActivated();

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
      if (e.code == 'permission-denied') {
        throw StateError(
          'Sunucu izni reddedildi. Uygulamayı güncelleyin veya birkaç saniye '
          'bekleyip tekrar deneyin.',
        );
      }
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
