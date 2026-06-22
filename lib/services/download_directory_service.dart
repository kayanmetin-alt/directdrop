import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Uygulamanın sabit indirme klasörü (kullanıcı değiştiremez).
class DownloadDirectoryService extends ChangeNotifier {
  DownloadDirectoryService._();

  static final DownloadDirectoryService instance = DownloadDirectoryService._();

  static const _filesChannel = MethodChannel('com.directdrop.app/files');

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
      try {
        final nativePath =
            await _filesChannel.invokeMethod<String>('getDownloadsDirectory');
        if (nativePath != null && nativePath.isNotEmpty) {
          return Directory(nativePath);
        }
      } catch (e) {
        debugPrint('Android indirme dizini alınamadı: $e');
      }

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
      final dir = await downloadsDirectory();
      if (dir.path.contains('/Android/data/')) {
        return 'Dosyalar → Android → DirectDrop → Download → DirectDrop';
      }
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
    final sources = <Directory>[];

    final docs = await getApplicationDocumentsDirectory();
    sources.add(Directory(p.join(docs.path, 'DirectDrop', 'Downloads')));

    final appDownloads = await getDownloadsDirectory();
    if (appDownloads != null) {
      sources.add(Directory(p.join(appDownloads.path, 'DirectDrop')));
    }

    for (final legacy in sources) {
      if (!await legacy.exists()) continue;
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
}
