import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/download_directory_service.dart';
import '../utils/file_location_opener.dart';

class DownloadLocationSettings extends StatefulWidget {
  const DownloadLocationSettings({
    super.key,
    this.collapsible = false,
    this.initiallyExpanded = false,
  });

  /// Kapalıyken yalnızca «Klasörü aç» görünür; ok ile ayrıntılar açılır.
  final bool collapsible;
  final bool initiallyExpanded;

  @override
  State<DownloadLocationSettings> createState() =>
      _DownloadLocationSettingsState();
}

class _DownloadLocationSettingsState extends State<DownloadLocationSettings> {
  final _service = DownloadDirectoryService.instance;
  String _displayPath = '…';
  bool _busy = false;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded || !widget.collapsible;
    _service.addListener(_onChanged);
    unawaited(_service.load().then((_) => _refreshPath()));
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    unawaited(_refreshPath());
  }

  Future<void> _refreshPath() async {
    final path = await _service.displayPath();
    if (mounted) setState(() => _displayPath = path);
  }

  Future<void> _openFolder() async {
    setState(() => _busy = true);
    try {
      final dir = await _service.ensureDownloadsDirectory();
      final ok = await FileLocationOpener.openDownloadsFolder(dir.path);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Platform.isAndroid
                  ? 'Klasör açılamadı. Dosyalar → İndirilenler → DirectDrop klasörüne gidin.'
                  : 'Dosyalar uygulaması açılamadı. Manuel gidin:\n$_displayPath',
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Klasör açılamadı: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _openFolderButton({bool compact = false}) {
    if (compact) {
      return TextButton.icon(
        onPressed: _busy ? null : _openFolder,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.folder_open_outlined, size: 18),
        label: const Text('Klasörü aç'),
      );
    }

    return FilledButton.icon(
      onPressed: _busy ? null : _openFolder,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.folder_open_outlined),
      label: const Text('Klasörü aç'),
    );
  }

  Widget _detailsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'İndirilen dosyalar her zaman şu konuma kaydedilir:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          _displayPath,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!widget.collapsible) {
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
              _detailsSection(theme),
              const SizedBox(height: 12),
              _openFolderButton(),
            ],
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'İndirme klasörü',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                _openFolderButton(compact: true),
                IconButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  tooltip: _expanded ? 'Ayrıntıları gizle' : 'Ayrıntıları göster',
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _detailsSection(theme),
            ),
          ],
        ],
      ),
    );
  }
}
