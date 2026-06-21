import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/legal_urls.dart';
import '../widgets/app_version_label.dart';

/// App Store / Play Store için gizlilik politikası ve destek bağlantıları.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.parse(LegalUrls.privacyPolicy);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Gizlilik politikası açılamadı.');
    }
  }

  Future<void> _openSupportEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: LegalUrls.supportEmail,
      query: 'subject=DirectDrop Destek',
    );
    if (!await launchUrl(uri)) {
      throw StateError('E-posta uygulaması açılamadı.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hakkında'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.swap_horiz,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'DirectDrop',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Center(child: AppVersionLabel(detailed: true)),
            const SizedBox(height: 8),
            Text(
              'Cihazlar arası doğrudan dosya transferi. Dosya içeriği sunucuya '
              'yüklenmez; yalnızca eşleştirme için Firebase kullanılır.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Gizlilik Politikası'),
              subtitle: const Text('Veri toplama ve kullanım'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                try {
                  await _openPrivacyPolicy();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$e')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Destek'),
              subtitle: const Text(LegalUrls.supportEmail),
              onTap: () async {
                try {
                  await _openSupportEmail();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$e')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
