import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Apple cihazlarda HEIC dosyalarını JPEG'e dönüştürür.
class PhotoExportService {
  PhotoExportService._();

  static const MethodChannel _mediaChannel =
      MethodChannel('com.directdrop.app/media_picker');

  static Future<List<String>> preparePathsForTransfer(
    List<String> paths, {
    required bool preferJpeg,
  }) async {
    if (!preferJpeg || paths.isEmpty) return paths;
    if (!Platform.isIOS && !Platform.isMacOS) return paths;

    final heicPaths = paths.where(_isHeicPath).toList(growable: false);
    if (heicPaths.isEmpty) return paths;

    try {
      final converted = await _mediaChannel.invokeMethod<List<dynamic>>(
        'convertHeicToJpeg',
        {'paths': heicPaths},
      );
      if (converted == null || converted.length != heicPaths.length) {
        return paths;
      }

      final bySource = <String, String>{};
      for (var i = 0; i < heicPaths.length; i++) {
        final next = converted[i];
        if (next is String && next.isNotEmpty) {
          bySource[heicPaths[i]] = next;
        }
      }

      return paths
          .map((path) => bySource[path] ?? path)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Fotoğraf JPEG\'e dönüştürülemedi.');
    }
  }

  static bool _isHeicPath(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.heic':
      case '.heif':
        return true;
      default:
        return false;
    }
  }
}
