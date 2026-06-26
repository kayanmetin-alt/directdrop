/// Platform indirme bağlantıları (GitHub Releases).
abstract final class DownloadUrls {
  static const releasesLatest =
      'https://github.com/kayanmetin-alt/directdrop/releases/latest';

  /// GitHub Releases'teki güncel Windows kurulum sürümü.
  /// Her Windows yayınında bu değeri pubspec ile birlikte güncelleyin.
  static const windowsReleaseVersion = '1.3.35';

  static String windowsInstaller([String? version]) =>
      'https://github.com/kayanmetin-alt/directdrop/releases/download/v${version ?? windowsReleaseVersion}/DirectDrop-Setup-${version ?? windowsReleaseVersion}.exe';

  /// WhatsApp, Mail vb. ile paylaşılacak metin.
  static String windowsShareMessage({
    required String url,
    required String version,
  }) =>
      'DirectDrop — Windows kurulum dosyası (sürüm $version)\n\n'
      'Bu link yalnızca Windows bilgisayarlar içindir (Setup.exe). '
      'iPhone, iPad veya Mac\'te çalışmaz; Windows bilgisayara kurulması gerekir.\n\n'
      'İndir: $url\n\n'
      'Tüm sürümler: $releasesLatest';
}
