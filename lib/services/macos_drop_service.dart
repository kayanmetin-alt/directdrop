import 'dart:async';

import 'package:flutter/services.dart';

/// macOS: Photos gibi uygulamalardan gelen videoları gerçek dosya olarak alır.
class MacosDropService {
  MacosDropService._();

  static final MacosDropService instance = MacosDropService._();

  static const MethodChannel _channel = MethodChannel('com.directdrop.app/drop');

  final StreamController<bool> _dragActiveController =
      StreamController<bool>.broadcast();
  final StreamController<List<String>> _filesController =
      StreamController<List<String>>.broadcast();

  Stream<bool> get dragActiveStream => _dragActiveController.stream;
  Stream<List<String>> get filesDroppedStream => _filesController.stream;

  bool _listening = false;

  void ensureListening() {
    if (_listening) return;
    _listening = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'dragEntered':
          _dragActiveController.add(true);
        case 'dragExited':
          _dragActiveController.add(false);
        case 'droppedFiles':
          final args = call.arguments;
          if (args is List) {
            final paths = args
                .whereType<String>()
                .where((path) => path.isNotEmpty)
                .toList(growable: false);
            if (paths.isNotEmpty) {
              _dragActiveController.add(false);
              _filesController.add(paths);
            }
          }
      }
    });
  }
}
