import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentityService {
  DeviceIdentityService._();

  static final DeviceIdentityService instance = DeviceIdentityService._();

  static const _deviceIdKey = 'directdrop_device_id';
  static const _uuid = Uuid();

  String? _cachedId;

  Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = _uuid.v4();
      await prefs.setString(_deviceIdKey, id);
    }
    _cachedId = id;
    return id;
  }

  String get platformLabel {
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'other';
  }

  String get displayName {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows';
    return 'DirectDrop';
  }
}
