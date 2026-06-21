import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/recent_connection_service.dart';
import '../utils/session_exit_helper.dart';
import '../utils/user_facing_error.dart';
import '../widgets/connect_waiting_panel.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'transfer_screen.dart';

class RecentConnectScreen extends StatefulWidget {
  const RecentConnectScreen({
    super.key,
    required this.peer,
    this.autoAcceptInvite = false,
  });

  final PairedDevice peer;
  /// Karşı taraftan gelen davetle otomatik odaya katıl.
  final bool autoAcceptInvite;

  @override
  State<RecentConnectScreen> createState() => _RecentConnectScreenState();
}

class _RecentConnectScreenState extends State<RecentConnectScreen> {
  TransferSessionController? _controller;
  String? _error;
  String? _statusMessage;
  bool _ownsController = false;
  bool _wasEverConnected = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    RecentConnectionService.instance.abandonPeerConnection(widget.peer.deviceId);

    setState(() {
      _error = null;
      _statusMessage = widget.autoAcceptInvite
          ? '${widget.peer.displayName} sizi bekliyor…'
          : 'Bağlantı başlatılıyor…';
      _controller = null;
    });

    try {
      final service = RecentConnectionService.instance;
      final controller = widget.autoAcceptInvite
          ? await service.acceptInviteFromPeer(
              widget.peer,
              onProgress: (message) {
                if (!mounted) return;
                setState(() => _statusMessage = message);
              },
            )
          : await service.connectToPeer(
              widget.peer,
              onProgress: (message) {
                if (!mounted) return;
                setState(() => _statusMessage = message);
              },
            );
      if (!mounted) {
        controller.disconnect();
        controller.dispose();
        return;
      }
      _ownsController = true;
      _controller = controller;
      ActiveSessionRegistry.instance.register(controller);
      service.clearIncomingInvite();
      setState(() => _statusMessage = null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingMessage(e);
        _statusMessage = null;
      });
    }
  }

  Future<void> _cancelAndGoHome() async {
    final controller = _controller;
    if (controller != null && !controller.isDisposed) {
      await SessionExitHelper.leaveAndGoHome(
        controller: controller,
        peerDeviceId: widget.peer.deviceId,
        context: context,
      );
      return;
    }
    RecentConnectionService.instance.abandonPeerConnection(widget.peer.deviceId);
    await PairedAutoConnectService.instance.leavePeer(widget.peer.deviceId);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    RecentConnectionService.instance.clearAutoConnectActive();
    final controller = _controller;
    if (controller != null) {
      ActiveSessionRegistry.instance.unregister(controller);
      if (_ownsController && !controller.isDisposed) {
        unawaited(controller.disconnect(userInitiated: true));
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.peer.displayName)),
        body: SafeArea(
          child: SingleChildScrollView(
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
                  style: Theme.of(context).textTheme.bodyLarge,
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
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.peer.displayName),
          actions: [
            IconButton(
              onPressed: _cancelAndGoHome,
              icon: const Icon(Icons.close),
              tooltip: 'İptal',
            ),
          ],
        ),
        body: SafeArea(
          child: widget.autoAcceptInvite
              ? Center(
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
                        if (_statusMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _statusMessage!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : ConnectWaitingPanel(
                  peerDisplayName: widget.peer.displayName,
                  statusMessage: _statusMessage,
                ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.isConnected) {
          _wasEverConnected = true;
        }

        if (controller.isConnected || _wasEverConnected) {
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
          appBar: AppBar(
            title: Text(widget.peer.displayName),
            actions: [
              IconButton(
                onPressed: _cancelAndGoHome,
                icon: const Icon(Icons.close),
                tooltip: 'İptal',
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
