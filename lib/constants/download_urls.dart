/// Platform indirme bağlantıları (GitHub Releases).
abstract final class DownloadUrls {
  static const releasesLatest =
      'https://github.com/kayanmetin-alt/directdrop/releases/latest';

  /// Sürümden bağımsız, doğrudan indirme linki. GitHub her zaman en güncel
  /// yayındaki sabit adlı dosyayı (`DirectDrop-Setup.exe`) verir; tıklayınca
  /// .exe doğrudan inmeye başlar. Yeni yayında güncelleme gerektirmez.
  static const windowsInstallerLatest =
      'https://github.com/kayanmetin-alt/directdrop/releases/latest/download/DirectDrop-Setup.exe';

  /// GitHub Releases'teki güncel Windows kurulum sürümü (yalnızca gösterim için).
  /// Her Windows yayınında bu değeri pubspec ile birlikte güncelleyin.
  static const windowsReleaseVersion = '1.3.39';

  static String windowsInstaller([String? version]) =>
      'https://github.com/kayanmetin-alt/directdrop/releases/download/v${version ?? windowsReleaseVersion}/DirectDrop-Setup-${version ?? windowsReleaseVersion}.exe';

  /// Sürümden bağımsız, doğrudan indirme linki (notarize edilmiş Mac .dmg).
  static const macInstallerLatest =
      'https://github.com/kayanmetin-alt/directdrop/releases/latest/download/DirectDrop.dmg';

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
