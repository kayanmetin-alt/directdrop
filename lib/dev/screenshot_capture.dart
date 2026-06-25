import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../providers/transfer_session_controller.dart';
import '../screens/about_screen.dart';
import '../screens/host_screen.dart';
import '../screens/join_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/transfer_screen.dart';
import '../services/active_session_registry.dart';
import '../services/startup_gate.dart';

/// Mağaza ekran görüntüleri için otomasyon.
/// Kullanım: --dart-define=SCREENSHOT_STEP=home|host|join|transfer|settings|about|host_daemon|join_connect
class ScreenshotCapture {
  ScreenshotCapture._();

  static const step = String.fromEnvironment('SCREENSHOT_STEP', defaultValue: '');
  static const roomCodeFile = '/tmp/directdrop_room_code.txt';
  static const readyFile = '/tmp/directdrop_screenshot_ready';

  // Release derlemelerinde otomasyon asla çalışmamalı; yanlışlıkla bir build
  // bayrağı verilse bile kReleaseMode kontrolü devre dışı bırakır.
  static bool get isEnabled => !kReleaseMode && step.isNotEmpty;

  static Future<void> clearLocalLists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('directdrop_paired_devices');
    await prefs.remove('directdrop_transfer_history');
  }

  static Future<void> runAfterBootstrap() async {
    if (!isEnabled) return;

    await clearLocalLists();
    await StartupGate.waitReady();

    // Firebase + servislerin oturması için kısa bekleme.
    await Future<void>.delayed(const Duration(seconds: 2));

    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      throw StateError('Navigator hazır değil (step=$step)');
    }

    switch (step) {
      case 'home':
        break;
      case 'host':
        await nav.push<void>(
          MaterialPageRoute<void>(builder: (_) => const HostScreen()),
        );
        await _waitForRoomCode(timeout: const Duration(seconds: 30));
        break;
      case 'join':
        await nav.push<void>(
          MaterialPageRoute<void>(builder: (_) => const JoinScreen()),
        );
        break;
      case 'settings':
        await nav.push<void>(
          MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
        );
        break;
      case 'about':
        await nav.push<void>(
          MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
        );
        break;
      case 'host_daemon':
        await nav.push<void>(
          MaterialPageRoute<void>(builder: (_) => const HostScreen()),
        );
        final code = await _waitForRoomCode(timeout: const Duration(seconds: 30));
        await File(roomCodeFile).writeAsString(code);
        await _waitForTransferScreen(timeout: const Duration(minutes: 2));
        break;
      case 'join_connect':
        final codeFile = File(roomCodeFile);
        var code = '';
        for (var i = 0; i < 60; i++) {
          if (codeFile.existsSync()) {
            code = codeFile.readAsStringSync().trim();
            if (code.length >= 6) break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (code.length < 6) {
          throw StateError('Oda kodu dosyası bulunamadı: $roomCodeFile');
        }

        final controller = TransferSessionController();
        ActiveSessionRegistry.instance.register(controller);
        await controller.joinRoom(code);
        await nav.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => TransferScreen(controller: controller),
          ),
        );
        await _waitForPeerConnected(controller);
        break;
      default:
        throw StateError('Bilinmeyen SCREENSHOT_STEP: $step');
    }

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await File(readyFile).writeAsString(step);
  }

  static Future<String> _waitForRoomCode({
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final controller = ActiveSessionRegistry.instance.activeController;
      final session = controller?.session;
      if (session != null && session.roomCode.length >= 6) {
        return session.roomCode;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('Oda kodu zaman aşımı');
  }

  static Future<void> _waitForTransferScreen({
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final controller = ActiveSessionRegistry.instance.activeController;
      if (controller?.session?.remotePeerId != null) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw StateError('Transfer ekranı zaman aşımı (host_daemon)');
  }

  static Future<void> _waitForPeerConnected(
    TransferSessionController controller,
  ) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (controller.session?.remotePeerId != null) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    throw StateError('Eş bağlantısı zaman aşımı (join_connect)');
  }
}
