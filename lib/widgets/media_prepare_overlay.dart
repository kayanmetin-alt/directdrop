import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/media_picker_progress_service.dart';

class MediaPrepareCancelledException implements Exception {
  @override
  String toString() => 'Medya hazırlığı iptal edildi';
}

class MediaPrepareReporter {
  void reportHashProgress({
    required int fileIndex,
    required int fileCount,
    required double fileFraction,
    required String fileName,
  }) {
    final overall = fileCount == 0
        ? 0.0
        : ((fileIndex + fileFraction) / fileCount).clamp(0.0, 1.0);
    MediaPickerProgressService.instance.emit(
      MediaPrepareProgressEvent(
        phase: MediaPreparePhase.hashing,
        completed: fileIndex,
        total: fileCount,
        fraction: overall,
        fileName: fileName,
      ),
    );
  }
}

/// Hazırlık diyaloğunu gösterir; [action] bitince kapanır.
Future<T?> runMediaPrepare<T>(
  BuildContext context,
  Future<T> Function(MediaPrepareReporter reporter) action,
) async {
  if (!context.mounted) return null;

  await MediaPickerProgressService.instance.startListening();
  MediaPickerProgressService.instance.reset();
  final reporter = MediaPrepareReporter();

  if (!context.mounted) return null;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => _MediaPrepareDialog(
      onCancel: () async {
        await MediaPickerProgressService.instance.cancelNativeExport();
        if (dialogContext.mounted) {
          Navigator.of(dialogContext).pop();
        }
      },
    ),
  );

  await Future<void>.delayed(const Duration(milliseconds: 32));

  try {
    return await action(reporter);
  } on PlatformException catch (e) {
    if (e.code == 'cancelled') return null;
    rethrow;
  } on MediaPrepareCancelledException {
    return null;
  } finally {
    await MediaPickerProgressService.instance.stopListening();
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) {
        nav.pop();
      }
    }
  }
}

class _MediaPrepareDialog extends StatefulWidget {
  const _MediaPrepareDialog({required this.onCancel});

  final VoidCallback onCancel;

  @override
  State<_MediaPrepareDialog> createState() => _MediaPrepareDialogState();
}

class _MediaPrepareDialogState extends State<_MediaPrepareDialog> {
  MediaPrepareProgressEvent _event = const MediaPrepareProgressEvent(
    phase: MediaPreparePhase.exporting,
    completed: 0,
    total: 1,
    fraction: 0,
  );
  StreamSubscription<MediaPrepareProgressEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = MediaPickerProgressService.instance.stream.listen((event) {
      if (mounted) setState(() => _event = event);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  String get _title {
    switch (_event.phase) {
      case MediaPreparePhase.exporting:
        return 'Medya hazırlanıyor';
      case MediaPreparePhase.hashing:
        return 'Dosya doğrulanıyor';
    }
  }

  String get _subtitle {
    switch (_event.phase) {
      case MediaPreparePhase.exporting:
        return 'Seçilen fotoğraf ve videolar cihazınıza indiriliyor olabilir '
            '(iCloud / Fotoğraflar). Bu adımı işletim sistemi yapar; '
            'DirectDrop bekliyor — uygulama donmadı.';
      case MediaPreparePhase.hashing:
        return 'Gönderimden önce dosya bütünlüğü kontrol ediliyor. '
            'Büyük videolarda bu birkaç dakika sürebilir.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countLabel =
        _event.total > 1 ? '${_event.completed + 1} / ${_event.total}' : null;
    final percent = (_event.fraction * 100).clamp(0, 100).toStringAsFixed(0);

    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value:
                  _event.fraction > 0 ? _event.fraction.clamp(0.02, 1.0) : null,
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (countLabel != null) countLabel,
                '%$percent',
              ].join(' · '),
              style: theme.textTheme.labelLarge,
              textAlign: TextAlign.center,
            ),
            if (_event.fileName != null && _event.fileName!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _event.fileName!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: widget.onCancel,
            child: const Text('Vazgeç'),
          ),
        ],
      ),
    );
  }
}
