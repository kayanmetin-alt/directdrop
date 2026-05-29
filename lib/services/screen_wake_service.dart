import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Oda oturumu sırasında ekranın otomatik kapanmasını engeller (iOS/Android).
/// Kullanıcı güç tuşuyla kilitleyince normal kilit davranışı devam eder.
class ScreenWakeService {
  ScreenWakeService._();

  static final ScreenWakeService instance = ScreenWakeService._();

  bool _enabled = false;

  Future<void> setRoomActive(bool active) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    if (active) {
      if (_enabled) return;
      try {
        await WakelockPlus.enable();
        _enabled = true;
      } catch (e, stack) {
        debugPrint('Ekran uyanık tutulamadı: $e\n$stack');
      }
      return;
    }

    if (!_enabled) return;
    try {
      await WakelockPlus.disable();
    } catch (e, stack) {
      debugPrint('Ekran uyanık tutma kapatılamadı: $e\n$stack');
    }
    _enabled = false;
  }
}
