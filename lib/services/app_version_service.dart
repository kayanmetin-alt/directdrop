import 'package:package_info_plus/package_info_plus.dart';

/// Uygulama sürüm bilgisi (pubspec.yaml → native bundle).
class AppVersionService {
  AppVersionService._();

  static final AppVersionService instance = AppVersionService._();

  PackageInfo? _info;

  Future<void> load() async {
    _info ??= await PackageInfo.fromPlatform();
  }

  String get version => _info?.version ?? '—';

  String get buildNumber => _info?.buildNumber ?? '—';

  /// Ana ekranda gösterilecek kısa etiket, örn. "Sürüm 1.0.6"
  String get displayLabel => 'Sürüm $version';

  /// Ayırıntılı etiket, örn. "Sürüm 1.0.6 (7)"
  String get detailedLabel => 'Sürüm $version ($buildNumber)';
}
