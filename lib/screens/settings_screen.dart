import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/legal_urls.dart';
import '../services/developer_mode_service.dart';
import '../services/device_identity_service.dart';
import '../widgets/desktop_centered_layout.dart';
import '../widgets/device_name_editor.dart';
import '../widgets/windows_download_settings.dart';
import 'about_screen.dart';
import 'diagnostics_screen.dart';

/// Uygulama ayarları.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identity = DeviceIdentityService.instance;
  final _devMode = DeveloperModeService.instance;

  @override
  void initState() {
    super.initState();
    _identity.addListener(_onIdentityChanged);
    _devMode.addListener(_onIdentityChanged);
    unawaited(_identity.load());
    unawaited(_devMode.load());
  }

  @override
  void dispose() {
    _identity.removeListener(_onIdentityChanged);
    _devMode.removeListener(_onIdentityChanged);
    super.dispose();
  }

  void _onIdentityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _editDeviceName() async {
    await showDeviceNameEditorDialog(context, isFirstSetup: false);
  }

  Future<void> _openWebsite() async {
    final uri = Uri.parse(LegalUrls.website);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Web sitesi açılamadı.');
    }
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
              leading: const Icon(Icons.language_outlined),
              title: const Text('Web sitesi'),
              subtitle: const Text('Tüm sürümleri indir, destek ve gizlilik'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                try {
                  await _openWebsite();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$e')),
                  );
                }
              },
            ),
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
            if (_devMode.unlocked) ..._buildDeveloperSection(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDeveloperSection() {
    return [
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          'GELİŞTİRİCİ',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.build_outlined),
        title: const Text('Geliştirici Araçları'),
        subtitle: const Text('Bağlantı tanılama gibi araçları gösterir'),
        value: _devMode.toolsEnabled,
        onChanged: (v) => unawaited(_devMode.setToolsEnabled(v)),
      ),
      if (_devMode.toolsEnabled)
        ListTile(
          leading: const Icon(Icons.health_and_safety_outlined),
          title: const Text('Bağlantı Tanılama'),
          subtitle: const Text('Firebase/RTDB bağlantı testleri'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DiagnosticsScreen(),
              ),
            );
          },
        ),
      ListTile(
        leading: Icon(
          Icons.lock_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: const Text('Geliştirici modunu kapat'),
        subtitle: const Text('Araçları gizler, son kullanıcı görünümüne döner'),
        onTap: () => unawaited(_devMode.lock()),
      ),
    ];
  }
}
