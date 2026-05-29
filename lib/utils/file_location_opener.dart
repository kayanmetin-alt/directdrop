import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

/// İndirilen dosyanın kayıt konumunu sistem dosya yöneticisinde gösterir.
class FileLocationOpener {
  const FileLocationOpener._();

  static const _mobileFilesChannel = MethodChannel('com.directdrop.app/files');

  /// İndirme klasörünü dosya yöneticisinde (veya iOS/Android Dosyalar'da) açar.
  static Future<bool> openDownloadsFolder(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    try {
      if (Platform.isIOS || Platform.isAndroid) {
        try {
          final opened = await _mobileFilesChannel.invokeMethod<bool>(
            'openDownloadsFolder',
            {'path': dirPath},
          );
          return opened == true;
        } on PlatformException catch (e) {
          debugPrint('Mobil klasör açma: ${e.code} ${e.message}');
          if (Platform.isAndroid) {
            final result = await OpenFile.open(dirPath);
            return result.type == ResultType.done;
          }
          return false;
        }
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

      if (Platform.isAndroid) {
        try {
          final opened = await _mobileFilesChannel.invokeMethod<bool>(
            'openSavedFile',
            {'path': filePath},
          );
          if (opened == true) return true;
        } on PlatformException catch (e) {
          debugPrint('Android dosya açma: ${e.code} ${e.message}');
        }
      }

      // iOS / Android yedek: dosyayı sistemde aç.
      final result = await OpenFile.open(filePath);
      return result.type == ResultType.done;
    } catch (e, stack) {
      debugPrint('Dosya konumu açılamadı: $e\n$stack');
      return false;
    }
  }
}
