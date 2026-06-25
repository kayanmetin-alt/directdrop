import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'device_registry_service.dart';
import 'persistent_invite_code_service.dart';

class DeviceIdentityService extends ChangeNotifier {
  DeviceIdentityService._();

  static final DeviceIdentityService instance = DeviceIdentityService._();

  static const _deviceIdKey = 'directdrop_device_id';
  static const _displayNameKey = 'directdrop_display_name';
  static const _displayNameConfiguredKey = 'directdrop_display_name_configured';
  static const _uuid = Uuid();

  static const _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const maxDisplayNameLength = 32;

  String? _cachedId;
  String? _customDisplayName;
  bool _configured = false;
  bool _loaded = false;

  bool get _usesSecureStorage => Platform.isIOS || Platform.isMacOS;

  bool get isLoaded => _loaded;
  bool get needsDisplayNameSetup => _loaded && !_configured;

  Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);

    if ((id == null || id.isEmpty) && _usesSecureStorage) {
      id = await _secureStorage.read(key: _deviceIdKey);
    }

    if (id == null || id.isEmpty) {
      id = _uuid.v4();
    }

    await prefs.setString(_deviceIdKey, id);
    if (_usesSecureStorage) {
      await _secureStorage.write(key: _deviceIdKey, value: id);
    }

    _cachedId = id;
    return id;
  }

  Future<void> resetDeviceId() async {
    _cachedId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deviceIdKey);
    if (_usesSecureStorage) {
      await _secureStorage.delete(key: _deviceIdKey);
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _customDisplayName = prefs.getString(_displayNameKey);
    _configured = prefs.getBool(_displayNameConfiguredKey) ?? false;

    // iOS/macOS: uygulama silinip yeniden kurulsa bile Keychain'den geri yükle.
    if (!_configured && _usesSecureStorage) {
      final secureName = await _secureStorage.read(key: _displayNameKey);
      final secureConfigured =
          await _secureStorage.read(key: _displayNameConfiguredKey);
      if (secureName != null &&
          secureName.isNotEmpty &&
          secureConfigured == 'true') {
        _customDisplayName = secureName;
        _configured = true;
        await prefs.setString(_displayNameKey, secureName);
        await prefs.setBool(_displayNameConfiguredKey, true);
      }
    }

    _loaded = true;

    // Mevcut ayarları Keychain'e yedekle (bir sonraki kurulumda korunur).
    if (_configured && _usesSecureStorage && _customDisplayName != null) {
      final secureConfigured =
          await _secureStorage.read(key: _displayNameConfiguredKey);
      if (secureConfigured != 'true') {
        await _secureStorage.write(
          key: _displayNameKey,
          value: _customDisplayName!,
        );
        await _secureStorage.write(
          key: _displayNameConfiguredKey,
          value: 'true',
        );
      }
    }

    notifyListeners();
  }

  String get platformLabel {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'other';
  }

  String get platformDefaultName {
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows';
    return 'DirectDrop';
  }

  String get displayName {
    final custom = _customDisplayName?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return platformDefaultName;
  }

  Future<void> setDisplayName(String rawName) async {
    await load();
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Cihaz adı boş olamaz.');
    }
    if (trimmed.length > maxDisplayNameLength) {
      throw ArgumentError(
        'Cihaz adı en fazla $maxDisplayNameLength karakter olabilir.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, trimmed);
    await prefs.setBool(_displayNameConfiguredKey, true);
    if (_usesSecureStorage) {
      await _secureStorage.write(key: _displayNameKey, value: trimmed);
      await _secureStorage.write(
        key: _displayNameConfiguredKey,
        value: 'true',
      );
    }

    _customDisplayName = trimmed;
    _configured = true;
    notifyListeners();

    try {
      await DeviceRegistryService().registerCurrentDevice();
      await PersistentInviteCodeService.instance.resyncCurrentMapping();
    } catch (e, stack) {
      debugPrint('Cihaz adı güncellenirken kayıt hatası: $e\n$stack');
    }
  }

  static String? validateDisplayName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Bir cihaz adı girin.';
    if (trimmed.length > maxDisplayNameLength) {
      return 'En fazla $maxDisplayNameLength karakter.';
    }
    return null;
  }
}
