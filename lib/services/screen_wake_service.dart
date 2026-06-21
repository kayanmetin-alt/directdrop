import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Oda oturumunda ekranın otomatik kapanmasını isteğe bağlı engeller (iOS/Android).
///
/// Her yeni oda varsayılan olarak ekranı uyanık tutar. Kullanıcı oturum
/// içinde ayarı değiştirirse tercih yalnızca o bağlantı için geçerlidir;
/// sonraki oda yine varsayılan (uyanık) ile başlar.
class ScreenWakeService extends ChangeNotifier {
  ScreenWakeService._();

  static final ScreenWakeService instance = ScreenWakeService._();

  bool _loaded = false;
  bool _roomActive = false;
  bool _wakelockHeld = false;

  /// Geçerli oda oturumu için ekran uyanık tutma (oda açılınca true).
  bool _sessionKeepAwake = true;

  bool get isSupported => Platform.isAndroid || Platform.isIOS;
  bool get keepAwakeEnabled => _sessionKeepAwake;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (!isSupported) {
      _loaded = true;
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Oturum içinde kullanıcı ayarı değiştirdiğinde çağrılır.
  Future<void> setKeepAwakeEnabled(bool enabled) async {
    if (!isSupported) return;
    if (!_loaded) await load();
    if (_sessionKeepAwake == enabled) return;

    _sessionKeepAwake = enabled;
    notifyListeners();
    await _applyWakelock();
  }

  Future<void> setRoomActive(bool active) async {
    if (!isSupported) return;
    if (!_loaded) await load();

    if (active && !_roomActive) {
      // Yeni oda: varsayılan ekran uyanık; önceki oturum tercihini taşıma.
      _sessionKeepAwake = true;
      notifyListeners();
    }

    if (_roomActive == active) return;
    _roomActive = active;
    await _applyWakelock();
  }

  Future<void> _applyWakelock() async {
    final shouldHold = _roomActive && _sessionKeepAwake;

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
