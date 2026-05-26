import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kullanıcının seçtiği veya varsayılan indirme klasörü.
class DownloadDirectoryService extends ChangeNotifier {
  DownloadDirectoryService._();

  static final DownloadDirectoryService instance = DownloadDirectoryService._();

  static const _prefKey = 'directdrop_download_dir';

  String? _customPath;
  bool _loaded = false;

  String? get customPath => _customPath;
  bool get hasCustomPath =>
      _customPath != null && _customPath!.trim().isNotEmpty;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _customPath = prefs.getString(_prefKey);
    _loaded = true;
  }

  Future<Directory> defaultDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'DirectDrop', 'Downloads'));
  }

  Future<Directory> downloadsDirectory() async {
    await load();

    if (hasCustomPath) {
      final custom = Directory(_customPath!);
      if (await custom.exists()) {
        return custom;
      }
      debugPrint('Özel indirme klasörü bulunamadı, varsayılan kullanılıyor.');
    }

    return defaultDirectory();
  }

  Future<String> displayPath() async {
    await load();
    if (hasCustomPath) return _customPath!;
    final dir = await defaultDirectory();
    return dir.path;
  }

  Future<String?> pickDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'İndirilen dosyaların kaydedileceği klasör',
    );
    if (selected == null || selected.isEmpty) return null;

    final dir = Directory(selected);
    if (!await dir.exists()) {
      throw StateError('Seçilen klasör bulunamadı.');
    }

    await setCustomPath(selected);
    return selected;
  }

  Future<void> setCustomPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, path);
    _customPath = path;
    _loaded = true;
    notifyListeners();
  }

  Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    _customPath = null;
    _loaded = true;
    notifyListeners();
  }

  Future<Directory> ensureDownloadsDirectory() async {
    final dir = await downloadsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
