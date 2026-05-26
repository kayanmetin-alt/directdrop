import 'package:flutter/material.dart';

import 'host_screen.dart';
import 'join_screen.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/app_version_label.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('DirectDrop'),
        centerTitle: true,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: AppVersionLabel(compact: true)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Cihazlar arası anlık dosya transferi',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Bir cihazda oda açın, diğerinde QR veya 6 haneli kod ile katılın.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const HostScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Transfer Başlat'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const JoinScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.download),
                label: const Text('Koda Katıl'),
              ),
              const SizedBox(height: 24),
              const DownloadLocationSettings(),
              const Spacer(),
              const AppVersionLabel(),
            ],
          ),
        ),
      ),
    );
  }
}
