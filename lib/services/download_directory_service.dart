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
        return Directory(p.join(userProfile, 'Documents', 'DirectDrop'));
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
    if (Platform.isIOS) {
      return Directory(p.join(docs.path, 'Downloads'));
    }
    return Directory(p.join(docs.path, 'DirectDrop'));
  }

  Future<Directory> downloadsDirectory() async {
    await load();
    return defaultDirectory();
  }

  /// Kullanıcıya gösterilen konum (sandbox yolu değil).
  Future<String> displayPath() async {
    if (Platform.isIOS) {
      return 'Dosyalar → DirectDrop → Downloads';
    }
    if (Platform.isAndroid) {
      final dir = await downloadsDirectory();
      if (dir.path.contains('/Android/data/')) {
        return 'Dosyalar → DirectDrop → İndirilenler';
      }
      return 'Dosyalar → İndirilenler → DirectDrop';
    }
    if (Platform.isMacOS) {
      return 'Documents → DirectDrop';
    }
    if (Platform.isWindows) {
      return 'Documents → DirectDrop';
    }
    final dir = await downloadsDirectory();
    return dir.path;
  }

  Future<Directory> ensureDownloadsDirectory() async {
    final dir = await downloadsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _migrateLegacyDownloads(dir);
    return dir;
  }

  Future<void> _migrateLegacyDownloads(Directory target) async {
    final sources = <Directory>[];

    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      sources.add(Directory(p.join(docs.path, 'DirectDrop', 'Downloads')));
    } else if (Platform.isAndroid) {
      final docs = await getApplicationDocumentsDirectory();
      sources.add(Directory(p.join(docs.path, 'DirectDrop', 'Downloads')));
      sources.add(Directory(p.join(target.path, 'Downloads')));

      final appDownloads = await getDownloadsDirectory();
      if (appDownloads != null) {
        sources.add(
          Directory(p.join(appDownloads.path, 'DirectDrop', 'Downloads')),
        );
      }
    } else {
      // macOS, Windows ve diğer masaüstü: eski DirectDrop/Downloads yapısı.
      sources.add(Directory(p.join(target.path, 'Downloads')));
      if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null && userProfile.isNotEmpty) {
          sources.add(
            Directory(
              p.join(userProfile, 'Documents', 'DirectDrop', 'Downloads'),
            ),
          );
        }
      } else {
        final docs = await getApplicationDocumentsDirectory();
        sources.add(Directory(p.join(docs.path, 'DirectDrop', 'Downloads')));
      }
    }

    for (final legacy in sources) {
      await _migrateFilesFromDirectory(legacy, target);
    }
  }

  Future<void> _migrateFilesFromDirectory(
    Directory source,
    Directory target,
  ) async {
    if (!await source.exists()) return;
    if (p.normalize(source.path) == p.normalize(target.path)) return;

    await for (final entity in source.list()) {
      if (entity is! File) continue;
      final dest = File(p.join(target.path, p.basename(entity.path)));
      if (await dest.exists()) continue;
      try {
        await entity.copy(dest.path);
      } catch (e) {
        debugPrint('Dosya taşıma (${source.path}): $e');
      }
    }
  }
}
