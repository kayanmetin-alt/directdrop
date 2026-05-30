import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/screen_wake_service.dart';

/// Oda ekranı sağ üst ayar menüsü (zamanla genişletilebilir).
class TransferRoomSettingsSheet extends StatefulWidget {
  const TransferRoomSettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const TransferRoomSettingsSheet(),
    );
  }

  @override
  State<TransferRoomSettingsSheet> createState() =>
      _TransferRoomSettingsSheetState();
}

class _TransferRoomSettingsSheetState extends State<TransferRoomSettingsSheet> {
  final _screenWake = ScreenWakeService.instance;

  @override
  void initState() {
    super.initState();
    _screenWake.addListener(_onChanged);
    unawaited(_screenWake.load());
  }

  @override
  void dispose() {
    _screenWake.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Oda ayarları',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (Platform.isIOS || Platform.isAndroid)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  _screenWake.keepAwakeEnabled
                      ? Icons.brightness_7
                      : Icons.brightness_7_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Ekranı uyanık tut'),
                subtitle: Text(
                  _screenWake.keepAwakeEnabled
                      ? 'Oda açıkken ekran kapanmaz.'
                      : 'Ekran normal şekilde kapanır.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                value: _screenWake.keepAwakeEnabled,
                onChanged: _screenWake.isLoaded
                    ? (value) => _screenWake.setKeepAwakeEnabled(value)
                    : null,
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Bu platform için oda ayarı bulunmuyor.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// AppBar'da kullanılacak ayar simgesi; uyanık tutma açıksa dolu gösterilir.
class TransferRoomSettingsIcon extends StatelessWidget {
  const TransferRoomSettingsIcon({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: ScreenWakeService.instance,
      builder: (context, _) {
        final active = ScreenWakeService.instance.keepAwakeEnabled;
        return IconButton(
          onPressed: onPressed,
          tooltip: 'Oda ayarları',
          icon: Icon(
            active ? Icons.settings_brightness : Icons.settings_outlined,
          ),
        );
      },
    );
  }
}
