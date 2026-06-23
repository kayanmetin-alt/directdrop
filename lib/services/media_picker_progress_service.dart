import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum MediaPreparePhase { exporting, hashing }

/// Medya hazırlığı (iCloud indirme / hash) ilerleme olayı.
class MediaPrepareProgressEvent {
  const MediaPrepareProgressEvent({
    required this.phase,
    required this.completed,
    required this.total,
    required this.fraction,
    this.fileName,
  });

  final MediaPreparePhase phase;
  final int completed;
  final int total;
  final double fraction;
  final String? fileName;

  factory MediaPrepareProgressEvent.fromMap(Map<dynamic, dynamic> map) {
    final phaseRaw = map['phase'] as String? ?? 'exporting';
    return MediaPrepareProgressEvent(
      phase: phaseRaw == 'hashing'
          ? MediaPreparePhase.hashing
          : MediaPreparePhase.exporting,
      completed: (map['completed'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 1,
      fraction: (map['fraction'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0,
      fileName: map['fileName'] as String?,
    );
  }
}

/// Native export + Dart hash ilerlemesini birleştirir.
class MediaPickerProgressService {
  MediaPickerProgressService._();

  static final MediaPickerProgressService instance =
      MediaPickerProgressService._();

  static const _events =
      EventChannel('com.directdrop.app/media_picker_events');
  static const _methods =
      MethodChannel('com.directdrop.app/media_picker');

  final _controller = StreamController<MediaPrepareProgressEvent>.broadcast();
  Stream<MediaPrepareProgressEvent> get stream => _controller.stream;

  StreamSubscription<dynamic>? _nativeSub;
  bool _listening = false;

  void emit(MediaPrepareProgressEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  void reset() {
    emit(const MediaPrepareProgressEvent(
      phase: MediaPreparePhase.exporting,
      completed: 0,
      total: 1,
      fraction: 0,
    ));
  }

  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;
    if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) {
      return;
    }
    _nativeSub ??= _events.receiveBroadcastStream().listen(
      (data) {
        if (data is Map) {
          emit(MediaPrepareProgressEvent.fromMap(data));
        }
      },
      onError: (_) {},
    );
  }

  Future<void> stopListening() async {
    _listening = false;
    await _nativeSub?.cancel();
    _nativeSub = null;
  }

  Future<void> cancelNativeExport() async {
    if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) {
      return;
    }
    try {
      await _methods.invokeMethod<void>('cancelPhotoExport');
    } on PlatformException {
      // Yoksay — export zaten bitmiş olabilir.
    }
  }
}
