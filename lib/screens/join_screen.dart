import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../providers/transfer_session_controller.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/active_session_registry.dart';
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
  bool _scanning = false;
  bool _joinInProgress = false;

  @override
  void initState() {
    super.initState();
    PairedAutoConnectService.instance.setManualSessionActive(true);
  }

  @override
  void dispose() {
    PairedAutoConnectService.instance.setManualSessionActive(false);
    _codeController.dispose();
    if (_controller != null) {
      ActiveSessionRegistry.instance.unregister(_controller!);
    }
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _join({bool fromQr = false}) async {
    if (_joinInProgress) return;

    if (fromQr) {
      final code = _codeController.text.trim().toUpperCase();
      if (code.length < 6) {
        setState(() => _error = 'QR geçersiz oda kodu içermiyor.');
        return;
      }
    } else if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _error = null;
      _joinInProgress = true;
      _controller?.dispose();
      _controller = TransferSessionController();
      ActiveSessionRegistry.instance.register(_controller!);
    });

    try {
      await _controller!.joinRoom(_codeController.text);
      if (!mounted) return;
      setState(() => _joinInProgress = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _joinInProgress = false;
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

    _codeController.text = raw.trim().toUpperCase();
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

    if (controller != null && (_controller!.isBusy || _joinInProgress)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Koda Katıl')),
        body: const Center(child: CircularProgressIndicator()),
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
