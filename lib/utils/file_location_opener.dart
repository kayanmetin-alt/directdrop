import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

/// İndirilen dosyanın kayıt konumunu sistem dosya yöneticisinde gösterir.
class FileLocationOpener {
  const FileLocationOpener._();

  /// İndirme klasörünü dosya yöneticisinde (veya iOS’ta Dosyalar’da) açar.
  static Future<bool> openDownloadsFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    try {
      if (Platform.isWindows) {
        final normalized = p.normalize(dirPath).replaceAll('/', r'\');
        await Process.run('explorer.exe', [normalized], runInShell: true);
        return true;
      }

      if (Platform.isMacOS) {
        await Process.run('open', [dirPath]);
        return true;
      }

      if (Platform.isLinux) {
        await Process.run('xdg-open', [dirPath]);
        return true;
      }

      // iOS / Android: mümkünse klasörü aç; olmazsa içerideki bir dosyayı göster.
      final result = await OpenFile.open(dirPath);
      if (result.type == ResultType.done) return true;

      await for (final entity in dir.list()) {
        if (entity is File) {
          return revealSavedFile(entity.path);
        }
      }

      return false;
    } catch (e, stack) {
      debugPrint('İndirme klasörü açılamadı: $e\n$stack');
      return false;
    }
  }

  static Future<bool> revealSavedFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    try {
      if (Platform.isWindows) {
        final normalized = p.normalize(filePath).replaceAll('/', r'\');
        await Process.run(
          'explorer.exe',
          ['/select,', normalized],
          runInShell: true,
        );
        return true;
      }

      if (Platform.isMacOS) {
        await Process.run('open', ['-R', filePath]);
        return true;
      }

      if (Platform.isLinux) {
        await Process.run('xdg-open', [p.dirname(filePath)]);
        return true;
      }

      // iOS: klasör açılamaz; dosyayı sistemde aç.
      final result = await OpenFile.open(filePath);
      return result.type == ResultType.done;
    } catch (e, stack) {
      debugPrint('Dosya konumu açılamadı: $e\n$stack');
      return false;
    }
  }
}
