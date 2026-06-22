import '../services/paired_auto_connect_service.dart';

/// Yeni eşleşmeye geçmeden önce diğer aktif oturumları kapatır.
class SessionSwitchHelper {
  SessionSwitchHelper._();

  static Future<void> prepareForPeer(String newPeerDeviceId) async {
    await PairedAutoConnectService.instance.disconnectAllExcept(newPeerDeviceId);
  }
}
