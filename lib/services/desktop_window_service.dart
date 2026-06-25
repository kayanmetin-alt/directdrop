import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// macOS / Windows pencere boyutu sınırları — telefon benzeri dikdörtgen oran korunur.
class DesktopWindowService {
  DesktopWindowService._();

  static const defaultWidth = 440.0;
  static const defaultHeight = 780.0;
  static const minWidth = 400.0;
  static const minHeight = 720.0;
  static const maxWidth = 520.0;
  static const maxHeight = 920.0;
  static const aspectRatio = defaultWidth / defaultHeight;

  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  static Future<void> configure() async {
    if (!isSupported) return;

    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(minWidth, minHeight));
    await windowManager.setMaximumSize(const Size(maxWidth, maxHeight));
    await windowManager.setAspectRatio(aspectRatio);

    try {
      final size = await windowManager.getSize();
      if (size.width < minWidth ||
          size.height < minHeight ||
          size.width > maxWidth ||
          size.height > maxHeight) {
        await windowManager.setSize(
          const Size(defaultWidth, defaultHeight),
          animate: true,
        );
      }
    } catch (e) {
      debugPrint('Pencere boyutu ayarlanamadı: $e');
    }
  }
}
