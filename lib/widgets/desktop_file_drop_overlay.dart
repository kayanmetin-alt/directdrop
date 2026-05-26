import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

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

    return _DesktopFileDropTarget(
      enabled: enabled,
      onFilesDropped: onFilesDropped,
      child: child,
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

    final paths = <String>[];
    for (final file in detail.files) {
      final path = file.path;
      if (path.isEmpty) continue;

      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        paths.add(path);
      }
    }

    if (paths.isEmpty) return;
    await widget.onFilesDropped(paths);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging && widget.enabled)
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
      ),
    );
  }
}
