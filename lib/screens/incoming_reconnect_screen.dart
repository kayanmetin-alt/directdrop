import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/recent_connection_service.dart';
import '../utils/user_facing_error.dart';
import 'transfer_screen.dart';

/// Karşı cihazdan gelen yeniden bağlanma isteği — onay / ret.
class IncomingReconnectScreen extends StatefulWidget {
  const IncomingReconnectScreen({
    super.key,
    required this.request,
    this.peer,
    this.autoApprove = false,
  });

  final ReconnectRequest request;
  final PairedDevice? peer;
  final bool autoApprove;

  @override
  State<IncomingReconnectScreen> createState() =>
      _IncomingReconnectScreenState();
}

class _IncomingReconnectScreenState extends State<IncomingReconnectScreen> {
  TransferSessionController? _controller;
  String? _error;
  bool _busy = false;

  String get _displayName =>
      widget.peer?.displayName ?? widget.request.fromDeviceName;

  @override
  void initState() {
    super.initState();
    if (widget.autoApprove) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_approve());
      });
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      ActiveSessionRegistry.instance.unregister(controller);
    }
    super.dispose();
  }

  Future<void> _reject() async {
    await RecentConnectionService.instance
        .rejectReconnectRequest(widget.request);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _approve() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final controller = widget.autoApprove
          ? await RecentConnectionService.instance
              .approveReconnectRequest(widget.request)
          : await RecentConnectionService.instance.approveIncomingReconnect();
      if (!mounted) {
        controller?.disconnect();
        controller?.dispose();
        return;
      }
      if (controller == null) {
        setState(() {
          _error = 'Bağlantı başlatılamadı.';
          _busy = false;
        });
        return;
      }
      _controller = controller;
      ActiveSessionRegistry.instance.register(controller);
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingMessage(e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.isConnected) {
            return ChangeNotifierProvider.value(
              value: controller,
              child: TransferScreen(
                controller: controller,
                peerDeviceId: widget.request.fromDeviceId,
                peerDisplayName: _displayName,
              ),
            );
          }

          return Scaffold(
            appBar: AppBar(title: Text(_displayName)),
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
                        '$_displayName ile bağlantı kuruluyor…',
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

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(_displayName)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.link,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  '$_displayName bağlantı kurmak istiyor',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Onayladığınızda oda açılır ve dosya transferi başlayabilir.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                if (_busy) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('Oda açılıyor…'),
                ] else ...[
                  FilledButton(
                    onPressed: _approve,
                    child: const Text('Onayla'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _reject,
                    child: const Text('Reddet'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _approve,
                    child: const Text('Tekrar dene'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
