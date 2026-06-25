import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'android_transfer_foreground_service.dart';

/// Aktif transfer/oturum sırasında mobilde süreci canlı tutar.
/// Android: foreground service. iOS: beginBackgroundTask (+ süre dolunca yenileme).
class MobileTransferKeepAliveService {
  MobileTransferKeepAliveService._();

  static const _channel = MethodChannel('com.directdrop.app/transfer_session');

  static bool _sessionActive = false;
  static bool _backgroundKeepalive = false;

  /// Oturum açık/kapalı (Android foreground servisi için).
  static Future<void> setSessionActive(bool active) async {
    _sessionActive = active;
    if (Platform.isAndroid) {
      await AndroidTransferForegroundService.setActive(active);
    }
    if (Platform.isIOS) {
      try {
        await _channel.invokeMethod<void>('setSessionActive', active);
      } catch (e) {
        debugPrint('iOS oturum keep-alive: $e');
      }
    }
    if (!active) {
      await setBackgroundKeepalive(false);
    }
  }

  /// Uygulama arka plana geçtiğinde ek süre iste (iOS).
  static Future<void> setBackgroundKeepalive(bool active) async {
    if (!Platform.isIOS) return;
    if (!_sessionActive) {
      active = false;
    }
    if (active == _backgroundKeepalive) return;
    _backgroundKeepalive = active;

    try {
      await _channel.invokeMethod<void>(
        active ? 'beginBackgroundTask' : 'endBackgroundTask',
      );
    } catch (e) {
      debugPrint('iOS arka plan görevi: $e');
    }
  }
}
