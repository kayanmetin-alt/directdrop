import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/transfer_file.dart';

/// Aktif dosya transferi sırasında ekranın kapanmasını isteğe bağlı engeller (iOS/Android).
class ScreenWakeService extends ChangeNotifier {
  ScreenWakeService._();

  static final ScreenWakeService instance = ScreenWakeService._();

  static const _keepAwakePrefKey = 'directdrop_keep_awake_during_transfer';

  bool _loaded = false;
  bool _transferActive = false;
  bool _wakelockHeld = false;

  /// Kullanıcının kalıcı tercihi; varsayılan açık.
  bool _keepAwakeEnabled = true;

  bool get isSupported => Platform.isAndroid || Platform.isIOS;
  bool get keepAwakeEnabled => _keepAwakeEnabled;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;

    if (isSupported) {
      final prefs = await SharedPreferences.getInstance();
      _keepAwakeEnabled = prefs.getBool(_keepAwakePrefKey) ?? true;
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> setKeepAwakeEnabled(bool enabled) async {
    if (!isSupported) return;
    if (!_loaded) await load();
    if (_keepAwakeEnabled == enabled) return;

    _keepAwakeEnabled = enabled;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keepAwakePrefKey, enabled);
    } catch (e, stack) {
      debugPrint('Ekran uyanık tutma tercihi kaydedilemedi: $e\n$stack');
    }

    await _applyWakelock();
  }

  Future<void> setTransferActive(bool active) async {
    if (!isSupported) return;
    if (!_loaded) await load();
    if (_transferActive == active) return;

    _transferActive = active;
    await _applyWakelock();
  }

  Future<void> clearTransferActive() => setTransferActive(false);

  static bool hasActiveTransferWork(List<TransferFileItem> items) {
    return items.any((item) {
      switch (item.status) {
        case TransferStatus.pending:
        case TransferStatus.awaitingApproval:
        case TransferStatus.queued:
        case TransferStatus.inProgress:
        case TransferStatus.paused:
        case TransferStatus.verifying:
          return true;
        case TransferStatus.completed:
        case TransferStatus.failed:
        case TransferStatus.cancelled:
          return false;
      }
    });
  }

  Future<void> _applyWakelock() async {
    final shouldHold = _transferActive && _keepAwakeEnabled;

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
