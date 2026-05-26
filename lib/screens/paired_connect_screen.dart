import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/paired_presence_service.dart';
import 'transfer_screen.dart';

class PairedConnectScreen extends StatefulWidget {
  const PairedConnectScreen({
    super.key,
    required this.peer,
    this.wakeType = WakeRequestType.connect,
    this.preferAutoConnect = true,
  });

  final PairedDevice peer;
  final WakeRequestType wakeType;
  final bool preferAutoConnect;

  @override
  State<PairedConnectScreen> createState() => _PairedConnectScreenState();
}

class _PairedConnectScreenState extends State<PairedConnectScreen> {
  TransferSessionController? _controller;
  String? _error;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    PairedAutoConnectService.instance.addListener(_onAutoConnectChanged);
    _connect();
  }

  void _onAutoConnectChanged() {
    if (!mounted || _controller?.isConnected == true) return;
    final session =
        PairedAutoConnectService.instance.sessionFor(widget.peer.deviceId);
    if (session != null && session != _controller) {
      _bindSession(session);
    }
  }

  Future<void> _connect() async {
    try {
      await PairedAutoConnectService.instance.requestConnection(
        widget.peer,
        force: true,
      );

      var session =
          PairedAutoConnectService.instance.sessionFor(widget.peer.deviceId);
      if (session != null) {
        _bindSession(session);
        if (session.isConnected) return;
      }

      if (PairedPresenceService.instance.isStrictlyOnline(widget.peer.deviceId)) {
        session = await PairedAutoConnectService.instance.waitForSession(
          widget.peer.deviceId,
        );
        if (session != null && session.isConnected) {
          _bindSession(session);
          return;
        }
      }

      final pending =
          PairedAutoConnectService.instance.sessionFor(widget.peer.deviceId);
      if (pending != null) {
        _bindSession(pending);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _bindSession(TransferSessionController session) {
    _controller = session;
    _ownsController = false;
    ActiveSessionRegistry.instance.register(session);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PairedAutoConnectService.instance.removeListener(_onAutoConnectChanged);
    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
      if (_ownsController) {
        unawaited(_controller!.disconnect());
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
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _controller = null;
                    });
                    unawaited(_connect());
                  },
                  child: const Text('Tekrar dene'),
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
        appBar: AppBar(title: Text(widget.peer.displayName)),
        body: const Center(child: CircularProgressIndicator()),
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

        final waitingOnline =
            PairedPresenceService.instance.isStrictlyOnline(widget.peer.deviceId);

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
                    waitingOnline
                        ? 'Otomatik bağlanılıyor…'
                        : '${widget.peer.displayName} henüz çevrimiçi değil…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    waitingOnline
                        ? 'Eşleşmiş cihazlar onay istemeden bağlanır.'
                        : 'Karşı cihazda uygulamayı açık tutun.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
