import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/screen_wake_service.dart';

/// Oda ekranında: ekranın otomatik kapanmasını engelleme tercihi (iOS/Android).
class ScreenWakeSettings extends StatefulWidget {
  const ScreenWakeSettings({super.key});

  @override
  State<ScreenWakeSettings> createState() => _ScreenWakeSettingsState();
}

class _ScreenWakeSettingsState extends State<ScreenWakeSettings> {
  final _service = ScreenWakeService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    unawaited(_service.load());
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Card(
      child: SwitchListTile(
        secondary: Icon(
          Icons.brightness_7_outlined,
          color: theme.colorScheme.primary,
        ),
        title: const Text('Ekranı uyanık tut'),
        subtitle: Text(
          _service.keepAwakeEnabled
              ? 'Oda açıkken ekran kapanmaz (güç tuşuyla kilitleyebilirsiniz).'
              : 'Ekran normal şekilde kapanır.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value: _service.keepAwakeEnabled,
        onChanged: _service.isLoaded
            ? (value) => _service.setKeepAwakeEnabled(value)
            : null,
      ),
    );
  }
}
