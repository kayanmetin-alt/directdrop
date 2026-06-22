import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../widgets/desktop_centered_layout.dart';
import '../widgets/windows_download_settings.dart';
import 'about_screen.dart';

/// Uygulama ayarları. Yeni seçenekler zamanla buraya eklenebilir.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
      ),
      body: DesktopCenteredLayout(
        child: ListView(
        children: [
          if (Platform.isAndroid || Platform.isIOS) const WindowsDownloadSettings(),
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
