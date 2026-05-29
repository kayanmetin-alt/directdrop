import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../services/macos_drop_service.dart';

/// macOS / Windows / Linux: dosyaları uygulama penceresine sürükleyip bırakma.
class DesktopFileDropOverlay extends StatelessWidget {
  const DesktopFileDropOverlay({
    super.key,
    required this.enabled,
    required this.onFilesDropped,
    required this.child,
  });

  final bool enabled;
  final Future<void> Function(List<String> paths) onFilesDropped;
  final Widget child;

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) return child;

    if (Platform.isMacOS) {
      return _MacosFileDropTarget(
        enabled: enabled,
        onFilesDropped: onFilesDropped,
        child: child,
      );
    }

    return _DesktopFileDropTarget(
      enabled: enabled,
      onFilesDropped: onFilesDropped,
      child: child,
    );
  }
}

class _MacosFileDropTarget extends StatefulWidget {
  const _MacosFileDropTarget({
    required this.enabled,
    required this.onFilesDropped,
    required this.child,
  });

  final bool enabled;
  final Future<void> Function(List<String> paths) onFilesDropped;
  final Widget child;

  @override
  State<_MacosFileDropTarget> createState() => _MacosFileDropTargetState();
}

class _MacosFileDropTargetState extends State<_MacosFileDropTarget> {
  bool _dragging = false;
  StreamSubscription<bool>? _dragSub;
  StreamSubscription<List<String>>? _filesSub;

  @override
  void initState() {
    super.initState();
    final service = MacosDropService.instance;
    service.ensureListening();
    _dragSub = service.dragActiveStream.listen((active) {
      if (!mounted) return;
      setState(() => _dragging = active && widget.enabled);
    });
    _filesSub = service.filesDroppedStream.listen((paths) async {
      if (!widget.enabled || paths.isEmpty) return;
      await widget.onFilesDropped(_existingFilePaths(paths));
    });
  }

  @override
  void dispose() {
    _dragSub?.cancel();
    _filesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _DropOverlayVisual(
      dragging: _dragging && widget.enabled,
      child: widget.child,
    );
  }
}

class _DesktopFileDropTarget extends StatefulWidget {
  const _DesktopFileDropTarget({
    required this.enabled,
    required this.onFilesDropped,
    required this.child,
  });

  final bool enabled;
  final Future<void> Function(List<String> paths) onFilesDropped;
  final Widget child;

  @override
  State<_DesktopFileDropTarget> createState() => _DesktopFileDropTargetState();
}

class _DesktopFileDropTargetState extends State<_DesktopFileDropTarget> {
  bool _dragging = false;

  Future<void> _handleDrop(DropDoneDetails detail) async {
    if (mounted) setState(() => _dragging = false);
    if (!widget.enabled) return;

    final paths = _existingFilePaths(
      detail.files.map((file) => file.path).where((path) => path.isNotEmpty),
    );

    if (paths.isEmpty) return;
    await widget.onFilesDropped(paths);
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) {
        if (widget.enabled && mounted) {
          setState(() => _dragging = true);
        }
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      onDragDone: _handleDrop,
      child: _DropOverlayVisual(
        dragging: _dragging && widget.enabled,
        child: widget.child,
      ),
    );
  }
}

List<String> _existingFilePaths(Iterable<String> paths) {
  final result = <String>[];
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      result.add(path);
    }
  }
  return result;
}

class _DropOverlayVisual extends StatelessWidget {
  const _DropOverlayVisual({
    required this.dragging,
    required this.child,
  });

  final bool dragging;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (dragging)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: theme.colorScheme.primary.withValues(alpha: 0.14),
                child: Center(
                  child: Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 24,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            size: 48,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Göndermek için bırakın',
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
