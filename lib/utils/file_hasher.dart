import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class FileHasher {
  static Future<String> sha256File(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String sha256Bytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  static String sha256String(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }
}
