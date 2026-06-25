import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/device_identity_service.dart';
import '../widgets/desktop_centered_layout.dart';
import '../widgets/device_name_editor.dart';
import '../widgets/windows_download_settings.dart';
import 'about_screen.dart';

/// Uygulama ayarları.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identity = DeviceIdentityService.instance;

  @override
  void initState() {
    super.initState();
    _identity.addListener(_onIdentityChanged);
    unawaited(_identity.load());
  }

  @override
  void dispose() {
    _identity.removeListener(_onIdentityChanged);
    super.dispose();
  }

  void _onIdentityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _editDeviceName() async {
    await showDeviceNameEditorDialog(context, isFirstSetup: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
      ),
      body: DesktopCenteredLayout(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.smartphone_outlined),
              title: const Text('Cihaz adı'),
              subtitle: Text(_identity.displayName),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editDeviceName,
            ),
            if (Platform.isAndroid) const WindowsDownloadSettings(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Hakkında'),
              subtitle: const Text('Sürüm, gizlilik politikası ve destek'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AboutScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
