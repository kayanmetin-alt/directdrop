import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../models/reconnect_request.dart';
import '../services/recent_connection_service.dart';
import '../screens/incoming_call_screen.dart';

/// Gelen bağlantı isteğini tüm platformlarda tam ekran (gelen arama tarzı)
/// gösterir. Hangi ekranda olunursa olunsun isteği önüne getirir.
class IncomingReconnectPrompt {
  IncomingReconnectPrompt._();

  static bool _screenOpen = false;
  static String? _openForDeviceId;
  static int? _openForCreatedAt;
  static ReconnectRequest? _pendingRequest;
  static int _retryCount = 0;
  static const _maxRetries = 30;

  static bool get isVisible => _screenOpen;

  /// UI hazır olana kadar bekleyerek isteği gösterir.
  static void scheduleShow(ReconnectRequest request) {
    if (_screenOpen &&
        _openForDeviceId == request.fromDeviceId &&
        _openForCreatedAt == request.clientCreatedAt) {
      return;
    }
    _pendingRequest = request;
    _retryCount = 0;
    _enqueueShowAttempt();
  }

  static void _enqueueShowAttempt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_tryShowPending());
    });
  }

  static Future<void> _tryShowPending() async {
    final request = _pendingRequest;
    if (request == null) return;

    final nav = rootNavigatorKey.currentState;
    final context = rootNavigatorKey.currentContext;
    if (nav == null || context == null || !context.mounted) {
      if (_retryCount++ < _maxRetries) {
        _enqueueShowAttempt();
        return;
      }
      debugPrint('Bağlantı isteği ekranı açılamadı (navigator hazır değil).');
      return;
    }

    _pendingRequest = null;
    await _showCallScreen(nav, request);
  }

  static Future<void> _showCallScreen(
    NavigatorState nav,
    ReconnectRequest request,
  ) async {
    if (_screenOpen) {
      if (_openForDeviceId == request.fromDeviceId &&
          _openForCreatedAt == request.clientCreatedAt) {
        return;
      }
      // Aynı cihazdan daha yeni bir istek; mevcut ekranı bırak, güncelleme
      // RecentConnectionService dinleyicisi üzerinden kendini yeniler.
      return;
    }

    await activateAppWindowForCall();

    _screenOpen = true;
    _openForDeviceId = request.fromDeviceId;
    _openForCreatedAt = request.clientCreatedAt;

    nav
        .push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => IncomingCallScreen(request: request),
      ),
    )
        .whenComplete(() {
      _screenOpen = false;
      if (_openForDeviceId == request.fromDeviceId &&
          _openForCreatedAt == request.clientCreatedAt) {
        _openForDeviceId = null;
        _openForCreatedAt = null;
      }
    });
  }

  /// Uygulama açıldığında veya ön plana dönüldüğünde bekleyen isteği tekrar dene.
  static void retryPendingIfAny() {
    final pending = RecentConnectionService.instance.incomingReconnectRequest;
    if (pending != null && !_screenOpen) {
      scheduleShow(pending);
    }
  }
}
