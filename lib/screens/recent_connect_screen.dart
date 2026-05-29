import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/recent_connection_service.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'transfer_screen.dart';

class RecentConnectScreen extends StatefulWidget {
  const RecentConnectScreen({super.key, required this.peer});

  final PairedDevice peer;

  @override
  State<RecentConnectScreen> createState() => _RecentConnectScreenState();
}

class _RecentConnectScreenState extends State<RecentConnectScreen> {
  TransferSessionController? _controller;
  String? _error;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _controller = null;
    });

    try {
      final controller =
          await RecentConnectionService.instance.connectToPeer(widget.peer);
      if (!mounted) {
        controller.disconnect();
        controller.dispose();
        return;
      }
      _ownsController = true;
      _controller = controller;
      ActiveSessionRegistry.instance.register(controller);
      RecentConnectionService.instance.clearIncomingInvite();
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
      if (_ownsController && !_controller!.isDisposed) {
        _controller!.disconnect();
        _controller!.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.peer.displayName)),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.link_off,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _connect,
                child: const Text('Tekrar dene'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const HostScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Yeni oda (QR)'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const JoinScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.download),
                label: const Text('Koda katıl (QR)'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.peer.displayName)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  '${widget.peer.displayName} ile bağlanılıyor…',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Karşı cihazda uygulama açıksa otomatik eşleşir.\n'
                  'Olmazsa diğer taraftan da listeden bağlanmayı deneyin.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.isConnected) {
          return ChangeNotifierProvider.value(
            value: controller,
            child: TransferScreen(
              controller: controller,
              peerDeviceId: widget.peer.deviceId,
              peerDisplayName: widget.peer.displayName,
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text(widget.peer.displayName)),
          body: const Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}
