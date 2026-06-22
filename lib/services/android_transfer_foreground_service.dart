import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Aktif transfer sırasında Android sürecini canlı tutar (galeri / dosya açılınca kopmasın).
class AndroidTransferForegroundService {
  AndroidTransferForegroundService._();

  static const _channel = MethodChannel('com.directdrop.app/transfer_session');

  static Future<void> setActive(bool active) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>(
        active ? 'startForeground' : 'stopForeground',
      );
    } catch (e) {
      debugPrint('Android ön plan servisi: $e');
    }
  }
}
