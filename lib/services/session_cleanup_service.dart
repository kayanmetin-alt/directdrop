import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'active_session_registry.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'firebase_auth_service.dart';
import 'pair_connect_coordinator.dart';
import 'paired_devices_service.dart';
import 'recent_connection_service.dart';

/// Uygulama açılışında ve çökme sonrası yarım kalan oturumları temizler.
class SessionCleanupService {
  SessionCleanupService._();

  static final SessionCleanupService instance = SessionCleanupService._();

  static const _gracefulShutdownKey = 'directdrop_graceful_shutdown_v1';

  final DeviceRegistryService _registry = DeviceRegistryService();
  final PairConnectCoordinator _coordinator = PairConnectCoordinator();

  /// Önceki açılış düzgün kapanmadıysa (çökme / zorla kapatma) true.
  bool get lastLaunchWasUnclean => _lastLaunchWasUnclean;
  bool _lastLaunchWasUnclean = false;

  Future<void> resetOnLaunch() async {
    try {
      await ActiveSessionRegistry.instance.forceReleaseAll();
    } catch (e, stack) {
      debugPrint('Oturum sıfırlama (launch): $e\n$stack');
    }
  }

  /// main() içinde Auth sonrası, davet dinleyicisi öncesinde çağrılır.
  Future<void> onLaunchAfterAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final graceful = prefs.getBool(_gracefulShutdownKey) ?? true;
    _lastLaunchWasUnclean = !graceful;

    // Bu açılışı hemen "çalışıyor" olarak işaretle; temizlik yavaş olsa bile
    // işaret kaybolmasın (sonraki çökme yine tespit edilsin).
    await prefs.setBool(_gracefulShutdownKey, false);

    if (_lastLaunchWasUnclean) {
      debugPrint(
        'Önceki oturum düzgün kapanmadı — her şey sıfırlanıyor.',
      );
      // Önce bayat otomatik bağlanmayı bastır, böylece temizlik sürerken
      // yarım kalan oturuma geri dönülmez.
      RecentConnectionService.instance.suppressAutoConnectThisLaunch = true;
      RecentConnectionService.instance.clearIncomingInvite();
      RecentConnectionService.instance.clearIncomingReconnect();
      RecentConnectionService.instance.clearAutoConnectActive();
      await _clearReconnectArtifacts();
    }
  }

  Future<void> markGracefulShutdown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_gracefulShutdownKey, true);
    } catch (e) {
      debugPrint('Graceful shutdown işareti yazılamadı: $e');
    }
  }

  Future<void> _clearReconnectArtifacts() async {
    const opTimeout = Duration(seconds: 4);
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      final myId = await DeviceIdentityService.instance.getDeviceId();
      await PairedDevicesService.instance.load();

      await _registry.clearAllInvitesForDevice(myId).timeout(opTimeout);

      for (final peer in PairedDevicesService.instance.devices) {
        await _coordinator
            .clearSession(myDeviceId: myId, peerDeviceId: peer.deviceId)
            .timeout(opTimeout, onTimeout: () {});
        await _registry
            .clearPairInvitesBetween(
              myDeviceId: myId,
              peerDeviceId: peer.deviceId,
            )
            .timeout(opTimeout, onTimeout: () {});
      }
    } catch (e, stack) {
      debugPrint('Çökme sonrası davet temizliği: $e\n$stack');
    }
  }
}
