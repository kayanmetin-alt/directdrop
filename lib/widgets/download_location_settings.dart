import 'dart:async';

import 'package:flutter/material.dart';

import '../services/download_directory_service.dart';

class DownloadLocationSettings extends StatefulWidget {
  const DownloadLocationSettings({super.key});

  @override
  State<DownloadLocationSettings> createState() =>
      _DownloadLocationSettingsState();
}

class _DownloadLocationSettingsState extends State<DownloadLocationSettings> {
  final _service = DownloadDirectoryService.instance;
  String _displayPath = '…';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    unawaited(_service.load().then((_) => _refreshPath()));
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    _refreshPath();
  }

  Future<void> _refreshPath() async {
    final path = await _service.displayPath();
    if (mounted) setState(() => _displayPath = path);
  }

  Future<void> _pickFolder() async {
    setState(() => _busy = true);
    try {
      await _service.pickDirectory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('İndirme klasörü güncellendi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Klasör seçilemedi: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetFolder() async {
    setState(() => _busy = true);
    try {
      await _service.resetToDefault();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Varsayılan indirme klasörü kullanılıyor.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'İndirme klasörü',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _displayPath,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFolder,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.drive_folder_upload_outlined),
                    label: const Text('Klasör seç'),
                  ),
                ),
                if (_service.hasCustomPath) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _busy ? null : _resetFolder,
                    tooltip: 'Varsayılana dön',
                    icon: const Icon(Icons.restore),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
