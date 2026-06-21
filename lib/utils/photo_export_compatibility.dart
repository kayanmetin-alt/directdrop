/// Fotoğraf gönderiminde HEIC yerine JPEG tercih edilip edilmeyeceğini belirler.
///
/// Android veya Windows tarafında gönderen/alıcı varsa JPEG kullanılır.
/// Yalnızca Apple ekosistemi (iOS ↔ iOS, iOS ↔ macOS, macOS ↔ macOS) HEIC kalır.
class PhotoExportCompatibility {
  const PhotoExportCompatibility._();

  static bool prefersJpeg({
    required String localPlatform,
    String? peerPlatform,
  }) {
    if (_requiresJpeg(localPlatform)) return true;
    final peer = peerPlatform?.trim().toLowerCase();
    if (peer == null || peer.isEmpty || peer == 'unknown') return false;
    return _requiresJpeg(peer);
  }

  static bool _requiresJpeg(String platform) {
    switch (platform.trim().toLowerCase()) {
      case 'android':
      case 'windows':
        return true;
      default:
        return false;
    }
  }
}
