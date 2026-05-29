import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

/// İndirilen dosyanın kayıt konumunu sistem dosya yöneticisinde gösterir.
class FileLocationOpener {
  const FileLocationOpener._();

  static const _iosFilesChannel = MethodChannel('com.directdrop.app/files');

  /// İndirme klasörünü dosya yöneticisinde (veya iOS’ta Dosyalar’da) açar.
  static Future<bool> openDownloadsFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    try {
      if (Platform.isIOS) {
        final opened = await _iosFilesChannel.invokeMethod<bool>(
          'openDownloadsFolder',
          dirPath,
        );
        return opened == true;
      }

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

      if (Platform.isAndroid) {
        final result = await OpenFile.open(dirPath);
        return result.type == ResultType.done;
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
