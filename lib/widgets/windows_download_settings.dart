import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../constants/download_urls.dart';

/// Ayarlar: kurulum linkini paylaşma / kopyalama (yalnızca Android).
class WindowsDownloadSettings extends StatelessWidget {
  const WindowsDownloadSettings({super.key});

  String get _version => DownloadUrls.windowsReleaseVersion;

  String get _downloadUrl => DownloadUrls.windowsInstaller(_version);

  String _shareText() => DownloadUrls.windowsShareMessage(
        url: _downloadUrl,
        version: _version,
      );

  Future<void> _shareLink(BuildContext context) async {
    await SharePlus.instance.share(ShareParams(text: _shareText()));
  }

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _shareText()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Windows indirme metni kopyalandı.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.desktop_windows_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Windows bilgisayar indirme',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Bu link doğrudan kurulum dosyasıdır (Setup.exe, zip değil). '
              'Telefon veya Mac\'te çalışmaz; karşı tarafın Windows '
              'bilgisayarına indirip çift tıklayarak kurması gerekir.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _downloadUrl,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _shareLink(context),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Paylaş'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyLink(context),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Kopyala'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
