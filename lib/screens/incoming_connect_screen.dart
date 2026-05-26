import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/paired_devices_service.dart';
import 'transfer_screen.dart';

class IncomingConnectScreen extends StatefulWidget {
  const IncomingConnectScreen({
    super.key,
    required this.request,
  });

  final WakeRequest request;

  @override
  State<IncomingConnectScreen> createState() => _IncomingConnectScreenState();
}

class _IncomingConnectScreenState extends State<IncomingConnectScreen> {
  TransferSessionController? _controller;
  String? _error;
  bool _joining = false;

  bool get _isKnownPeer {
    return PairedDevicesService.instance.isKnownPeer(
      deviceId: widget.request.fromDeviceId,
      displayName: widget.request.fromDeviceName,
    );
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  void _bootstrap() {
    final existing = PairedAutoConnectService.instance
        .sessionFor(widget.request.fromDeviceId);
    if (existing != null) {
      _controller = existing;
      ActiveSessionRegistry.instance.register(existing);
      existing.addListener(_onSessionChanged);
      if (existing.isConnected) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
        return;
      }
      _joining = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }

    if (_isKnownPeer) {
      unawaited(_accept());
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _accept() async {
    if (_joining) return;

    setState(() {
      _joining = true;
      _error = null;
    });

    try {
      final controller =
          await PairedAutoConnectService.instance.acceptWakeRequest(
        widget.request,
      );
      ActiveSessionRegistry.instance.register(controller);
      _controller = controller;
      controller.addListener(_onSessionChanged);
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _joining = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onSessionChanged);
    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null && controller.isConnected) {
      return ChangeNotifierProvider.value(
        value: controller,
        child: TransferScreen(
          controller: controller,
          incomingFromName: widget.request.fromDeviceName,
        ),
      );
    }

    final theme = Theme.of(context);
    final isFileRequest =
        widget.request.type == WakeRequestType.fileRequest;

    return Scaffold(
      appBar: AppBar(title: Text(widget.request.fromDeviceName)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_joining) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  '${widget.request.fromDeviceName} ile bağlanılıyor…',
                  style: theme.textTheme.titleMedium,
                ),
              ] else ...[
                Icon(
                  Icons.devices,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  isFileRequest
                      ? '${widget.request.fromDeviceName} dosya göndermek istiyor'
                      : '${widget.request.fromDeviceName} bağlanmak istiyor',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Bağlanmak için onaylayın.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _accept,
                  child: const Text('Bağlan'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
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
                  onPressed: _accept,
                  child: const Text('Tekrar dene'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
