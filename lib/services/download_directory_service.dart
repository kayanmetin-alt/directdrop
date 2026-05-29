import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Uygulamanın sabit indirme klasörü (kullanıcı değiştiremez).
class DownloadDirectoryService extends ChangeNotifier {
  DownloadDirectoryService._();

  static final DownloadDirectoryService instance = DownloadDirectoryService._();

  Future<void> load() async {}

  Future<Directory> defaultDirectory() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return Directory(
          p.join(userProfile, 'Documents', 'DirectDrop', 'Downloads'),
        );
      }
    }

    if (Platform.isAndroid) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return Directory(p.join(downloads.path, 'DirectDrop'));
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'DirectDrop', 'Downloads'));
  }

  Future<Directory> downloadsDirectory() async {
    await load();
    return defaultDirectory();
  }

  /// Kullanıcıya gösterilen konum (sandbox yolu değil).
  Future<String> displayPath() async {
    if (Platform.isIOS) {
      return 'Dosyalar → iPhone\'umda → DirectDrop → DirectDrop → Downloads';
    }
    if (Platform.isAndroid) {
      return 'Dosyalar → İndirilenler → DirectDrop';
    }
    if (Platform.isMacOS) {
      final dir = await downloadsDirectory();
      return dir.path;
    }
    if (Platform.isWindows) {
      final dir = await downloadsDirectory();
      return dir.path;
    }
    final dir = await downloadsDirectory();
    return dir.path;
  }

  Future<Directory> ensureDownloadsDirectory() async {
    final dir = await downloadsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (Platform.isAndroid) {
      await _migrateLegacyAndroidDownloads(dir);
    }
    return dir;
  }

  /// Eski sürümlerde uygulama içi klasöre kaydedilen dosyaları taşır.
  Future<void> _migrateLegacyAndroidDownloads(Directory target) async {
    final docs = await getApplicationDocumentsDirectory();
    final legacy = Directory(p.join(docs.path, 'DirectDrop', 'Downloads'));
    if (!await legacy.exists()) return;

    await for (final entity in legacy.list()) {
      if (entity is! File) continue;
      final dest = File(p.join(target.path, p.basename(entity.path)));
      if (await dest.exists()) continue;
      try {
        await entity.copy(dest.path);
      } catch (e) {
        debugPrint('Android dosya taşıma: $e');
      }
    }
  }
}
