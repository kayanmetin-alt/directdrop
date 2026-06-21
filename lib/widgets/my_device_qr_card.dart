import 'dart:async';

import 'package:flutter/material.dart';

import '../services/persistent_invite_code_service.dart';
import 'room_code_display.dart';

/// Ana ekranda cihaza özel kalıcı QR — varsayılan kapalı, dokunarak açılır.
class MyDeviceQrCard extends StatefulWidget {
  const MyDeviceQrCard({super.key});

  @override
  State<MyDeviceQrCard> createState() => _MyDeviceQrCardState();
}

class _MyDeviceQrCardState extends State<MyDeviceQrCard> {
  final _service = PersistentInviteCodeService.instance;
  String? _code;
  bool _busy = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final code = await _service.getOrCreate();
      if (mounted) setState(() => _code = code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshCode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('QR yenile'),
        content: const Text(
          'Yeni bir QR oluşturulur. Eski QR ile eşleşmiş cihazlar '
          'yeniden taramak zorunda kalabilir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yenile'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final code = await _service.refresh();
      if (mounted) setState(() => _code = code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleExpanded() {
    if (_code == null && !_busy) return;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(Icons.qr_code_2, color: theme.colorScheme.primary),
            title: const Text('Cihaz QR kodum'),
            subtitle: Text(
              _expanded
                  ? 'Bu QR cihazınıza özeldir.'
                  : code != null
                      ? 'Dokunarak QR kodunu göster'
                      : 'Yükleniyor…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'QR yenile',
                  onPressed: _busy ? null : _refreshCode,
                  icon: const Icon(Icons.refresh),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            onTap: _toggleExpanded,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: _expanded
                ? (code != null
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: RoomCodeDisplay(roomCode: code, embedded: true),
                      )
                    : const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ))
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
