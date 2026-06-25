import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_window_service.dart';

/// Windows'ta sağ köşe panelini, ana pencereyi geçici olarak küçük, çerçevesiz
/// ve hep-üstte bir pencereye dönüştürerek gösterir. Panel kapanınca pencere
/// normal boyutuna döndürülüp tekrar tray'e gizlenir.
///
/// macOS'taki native NSPanel'lerin pure-Dart karşılığıdır; yeni bağımlılık veya
/// native kod gerektirmez.
class WindowsOverlayWindow {
  WindowsOverlayWindow._();

  static final WindowsOverlayWindow instance = WindowsOverlayWindow._();

  static const double width = 360;
  static const double _margin = 16;

  /// Pencere şu an panel moduna dönüştürülmüş mü.
  bool _active = false;
  double _lastHeight = 0;
  bool _busy = false;

  bool get isActive => _active;

  /// Pencereyi köşe paneline dönüştürüp [height] yüksekliğinde gösterir.
  Future<void> show(double height) async {
    if (!Platform.isWindows) return;
    final h = height.clamp(96.0, 640.0);

    // Zaten gösteriliyor ve yükseklik neredeyse aynıysa pencereyi yeniden
    // boyutlandırma (ilerleme güncellemelerinde titremeyi önler).
    if (_active && (h - _lastHeight).abs() < 2) return;
    if (_busy) return;
    _busy = true;
    try {
      if (!_active) {
        // Boyut kısıtlarını gevşet — normal pencere min/max/oran kuralları
        // küçük panele dönüşmeyi engeller.
        await windowManager.setAspectRatio(0);
        await windowManager.setMinimumSize(const Size(1, 1));
        await windowManager.setMaximumSize(const Size(4096, 4096));
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(true);
        await windowManager.setSkipTaskbar(true);
        await windowManager.setAlwaysOnTop(true);
      }
      await windowManager.setSize(Size(width, h));
      await _positionTopRight(h);
      if (!_active) {
        await windowManager.show();
        await windowManager.setAlwaysOnTop(true);
      }
      _active = true;
      _lastHeight = h;
    } catch (e) {
      debugPrint('Windows overlay panel gösterilemedi: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _positionTopRight(double h) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final visSize = display.visibleSize ?? display.size;
      final visPos = display.visiblePosition ?? Offset.zero;
      final x = visPos.dx + visSize.width - width - _margin;
      final y = visPos.dy + _margin;
      await windowManager.setPosition(Offset(x, y));
    } catch (e) {
      debugPrint('Windows overlay konumlandırılamadı: $e');
    }
  }

  /// Panel modundan çıkar; pencere normal boyutuna döndürülür ve tray'e gizlenir.
  /// Panel aktif değilse ana pencereye DOKUNMAZ (yanlışlıkla gizlemeyi önler).
  Future<void> hide() async {
    if (!Platform.isWindows) return;
    if (!_active) return;
    if (_busy) return;
    _busy = true;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.hide();
      // Bir sonraki normal açılış için çerçeveyi ve boyut kısıtlarını geri yükle.
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await DesktopWindowService.configure();
      _active = false;
      _lastHeight = 0;
    } catch (e) {
      debugPrint('Windows overlay panel gizlenemedi: $e');
    } finally {
      _busy = false;
    }
  }
}
