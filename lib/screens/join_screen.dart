import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/persistent_invite_code_service.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/paired_devices_service.dart';
import '../services/recent_connection_service.dart';
import '../utils/invite_code_parser.dart';
import '../utils/session_exit_helper.dart';
import '../utils/user_facing_error.dart';
import '../widgets/connect_waiting_panel.dart';
import 'transfer_screen.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _codeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  TransferSessionController? _controller;
  String? _error;
  String? _statusMessage;
  String? _pendingPeerName;
  bool _scanning = false;
  bool _joinInProgress = false;
  bool _waitingForApproval = false;

  Future<void> _cancelAndGoHome() async {
    final controller = _controller;
    if (controller != null && !controller.isDisposed) {
      await SessionExitHelper.leaveAndGoHome(
        controller: controller,
        peerDeviceId: controller.peerDeviceId,
        context: context,
      );
      return;
    }
    if (_pendingPeerName != null) {
      PairedDevice? peer;
      for (final device in PairedDevicesService.instance.devices) {
        if (device.displayName == _pendingPeerName) {
          peer = device;
          break;
        }
      }
      if (peer != null) {
        RecentConnectionService.instance.abandonPeerConnection(peer.deviceId);
        await PairedAutoConnectService.instance.leavePeer(peer.deviceId);
      }
    }
    if (!mounted) return;
    setState(() {
      _joinInProgress = false;
      _waitingForApproval = false;
      _statusMessage = null;
      _pendingPeerName = null;
    });
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    _codeController.dispose();
    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
      if (!_controller!.isDisposed) {
        _controller!.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _join({bool fromQr = false}) async {
    if (_joinInProgress) return;

    final code = InviteCodeParser.normalize(_codeController.text);
    _codeController.text = code;

    if (fromQr) {
      if (!InviteCodeParser.isValid(code)) {
        setState(() => _error = 'QR geçersiz kod içermiyor.');
        return;
      }
    } else if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _error = null;
      _statusMessage = null;
      _pendingPeerName = null;
      _waitingForApproval = false;
      _joinInProgress = true;
    });

    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
      if (!_controller!.isDisposed) {
        await _controller!.disconnect();
        _controller!.dispose();
      }
      _controller = null;
    }

    try {
      final lookup = await PersistentInviteCodeService.instance.lookup(code);
      if (lookup != null) {
        setState(() {
          _pendingPeerName = lookup.displayName;
          _waitingForApproval = true;
          _statusMessage = '${lookup.displayName} cihazına istek gönderiliyor…';
        });

        final controller =
            await RecentConnectionService.instance.connectViaDeviceInvite(
          lookup,
          onProgress: (message) {
            if (!mounted) return;
            setState(() => _statusMessage = message);
          },
        );
        if (!mounted) return;
        _controller = controller;
        ActiveSessionRegistry.instance.register(controller);
        setState(() {
          _joinInProgress = false;
          _waitingForApproval = false;
          _statusMessage = null;
        });
        return;
      }

      // QR ile taranan kod cihaz davet kodudur; geçici oda kodu değildir.
      if (fromQr) {
        setState(() {
          _error =
              'Cihaz QR kodu bulunamadı. Karşı cihazda DirectDrop açık olsun, '
              'ana ekranda QR görünsün veya birkaç saniye bekleyip tekrar deneyin.';
          _joinInProgress = false;
          _waitingForApproval = false;
          _statusMessage = null;
          _pendingPeerName = null;
        });
        return;
      }

      setState(() {
        _pendingPeerName = null;
        _waitingForApproval = false;
        _statusMessage = 'Odaya katılınıyor…';
      });

      _controller = TransferSessionController();
      ActiveSessionRegistry.instance.register(_controller!);
      await _controller!.joinRoom(code);
      if (!mounted) return;
      setState(() {
        _joinInProgress = false;
        _statusMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingMessage(e);
        _joinInProgress = false;
        _waitingForApproval = false;
        _statusMessage = null;
        _pendingPeerName = null;
        if (_controller != null) {
          ActiveSessionRegistry.instance.unregister(_controller!);
        }
        _controller?.dispose();
        _controller = null;
      });
    }
  }

  void _onQrDetected(BarcodeCapture capture) {
    if (_joinInProgress || _controller != null) return;
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;

    _codeController.text = InviteCodeParser.normalize(raw);
    setState(() => _scanning = false);
    _join(fromQr: true);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    if (controller != null && controller.session != null) {
      return ChangeNotifierProvider.value(
        value: controller,
        child: TransferScreen(controller: controller),
      );
    }

    if (_joinInProgress && _waitingForApproval && _pendingPeerName != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Koda Katıl'),
          actions: [
            IconButton(
              onPressed: _cancelAndGoHome,
              icon: const Icon(Icons.close),
              tooltip: 'İptal',
            ),
          ],
        ),
        body: SafeArea(
          child: ConnectWaitingPanel(
            peerDisplayName: _pendingPeerName!,
            statusMessage: _statusMessage,
          ),
        ),
      );
    }

    if (_joinInProgress) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Koda Katıl'),
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
                    _statusMessage ?? 'Bağlanılıyor…',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Koda Katıl')),
      body: _scanning
          ? MobileScanner(onDetect: _onQrDetected)
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _codeController,
                      decoration: const InputDecoration(
                        labelText: 'Oda kodu',
                        hintText: 'Örn. AB12CD',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                        LengthLimitingTextInputFormatter(6),
                      ],
                      validator: (value) {
                        if (value == null || value.trim().length < 6) {
                          return '6 haneli oda kodunu girin';
                        }
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _join,
                      child: const Text('Bağlan'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => setState(() => _scanning = true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('QR ile katıl'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
