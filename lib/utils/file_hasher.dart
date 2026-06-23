import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class FileHasher {
  static Future<String> sha256File(
    String path, {
    void Function(double fraction)? onProgress,
  }) async {
    final file = File(path);
    final total = await file.length();
    if (total == 0) {
      onProgress?.call(1.0);
      return sha256.convert([]).toString();
    }

    var read = 0;
    final stream = file.openRead().map((chunk) {
      read += chunk.length;
      onProgress?.call((read / total).clamp(0.0, 1.0));
      return chunk;
    });
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  static String sha256Bytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  static String sha256String(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }
}
