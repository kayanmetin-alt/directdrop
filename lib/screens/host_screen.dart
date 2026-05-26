import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/transfer_session_controller.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/active_session_registry.dart';
import '../widgets/room_code_display.dart';
import 'transfer_screen.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  late final TransferSessionController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    PairedAutoConnectService.instance.setManualSessionActive(true);
    _controller = TransferSessionController();
    ActiveSessionRegistry.instance.register(_controller);
    _createRoom();
  }

  Future<void> _createRoom() async {
    try {
      await _controller.createRoom();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    PairedAutoConnectService.instance.setManualSessionActive(false);
    ActiveSessionRegistry.instance.unregister(_controller);
    unawaited(_controller.disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final session = _controller.session;

          if (_error != null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Transfer Başlat')),
              body: Center(child: Text(_error!)),
            );
          }

          if (session == null || _controller.isBusy) {
            return Scaffold(
              appBar: AppBar(title: const Text('Transfer Başlat')),
              body: const Center(child: CircularProgressIndicator()),
            );
          }

          if (session.remotePeerId != null) {
            return TransferScreen(controller: _controller);
          }

          return Scaffold(
            appBar: AppBar(title: const Text('Transfer Başlat')),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  RoomCodeDisplay(roomCode: session.roomCode),
                  const SizedBox(height: 24),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Diğer cihazın katılması bekleniyor…',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
