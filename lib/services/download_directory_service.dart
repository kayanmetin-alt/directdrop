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

    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'DirectDrop', 'Downloads'));
  }

  Future<Directory> downloadsDirectory() async {
    await load();
    return defaultDirectory();
  }

  Future<String> displayPath() async {
    final dir = await downloadsDirectory();
    return dir.path;
  }

  Future<Directory> ensureDownloadsDirectory() async {
    final dir = await downloadsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
