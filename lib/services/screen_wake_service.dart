import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Oda oturumunda ekranın otomatik kapanmasını isteğe bağlı engeller (iOS/Android).
/// Varsayılan kapalıdır; kullanıcı tercihi kalıcı kaydedilir.
class ScreenWakeService extends ChangeNotifier {
  ScreenWakeService._();

  static final ScreenWakeService instance = ScreenWakeService._();

  static const _prefKey = 'keep_screen_awake_in_room';

  bool _loaded = false;
  bool _keepAwakeEnabled = false;
  bool _roomActive = false;
  bool _wakelockHeld = false;

  bool get isSupported => Platform.isAndroid || Platform.isIOS;
  bool get keepAwakeEnabled => _keepAwakeEnabled;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (!isSupported) {
      _loaded = true;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    _keepAwakeEnabled = prefs.getBool(_prefKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setKeepAwakeEnabled(bool enabled) async {
    if (!isSupported) return;
    if (!_loaded) await load();
    if (_keepAwakeEnabled == enabled) return;

    _keepAwakeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, enabled);
    notifyListeners();
    await _applyWakelock();
  }

  Future<void> setRoomActive(bool active) async {
    if (!isSupported) return;
    if (!_loaded) await load();
    if (_roomActive == active) return;

    _roomActive = active;
    await _applyWakelock();
  }

  Future<void> _applyWakelock() async {
    final shouldHold = _roomActive && _keepAwakeEnabled;

    if (shouldHold && !_wakelockHeld) {
      try {
        await WakelockPlus.enable();
        _wakelockHeld = true;
      } catch (e, stack) {
        debugPrint('Ekran uyanık tutulamadı: $e\n$stack');
      }
      return;
    }

    if (!shouldHold && _wakelockHeld) {
      try {
        await WakelockPlus.disable();
      } catch (e, stack) {
        debugPrint('Ekran uyanık tutma kapatılamadı: $e\n$stack');
      }
      _wakelockHeld = false;
    }
  }
}
