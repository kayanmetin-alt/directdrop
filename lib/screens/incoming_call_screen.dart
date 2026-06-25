import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../models/reconnect_request.dart';
import '../services/desktop_background_service.dart';
import '../services/recent_connection_service.dart';
import 'incoming_reconnect_screen.dart';

/// Gelen bağlantı isteğini tam ekran, belirgin bir kart olarak gösterir.
/// Hangi ekranda olunursa olunsun önüne gelir; titreşim + ses ile fark edilir.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key, required this.request});

  final ReconnectRequest request;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _alertTimer;
  bool _handled = false;
  ModalRoute<dynamic>? _myRoute;

  String get _displayName => widget.request.fromDeviceName;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _startAlerting();
    RecentConnectionService.instance.addListener(_onServiceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _myRoute = ModalRoute.of(context);
  }

  @override
  void dispose() {
    RecentConnectionService.instance.removeListener(_onServiceChanged);
    _stopAlerting();
    _pulse.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (_handled || !mounted) return;
    final current = RecentConnectionService.instance.incomingReconnectRequest;
    if (current == null ||
        current.fromDeviceId != widget.request.fromDeviceId) {
      _dismiss();
    }
  }

  void _startAlerting() {
    _alertOnce();
    _alertTimer = Timer.periodic(
      const Duration(milliseconds: 2200),
      (_) => _alertOnce(),
    );
  }

  void _stopAlerting() {
    _alertTimer?.cancel();
    _alertTimer = null;
  }

  void _alertOnce() {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}
    try {
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  void _approve() {
    if (_handled) return;
    _handled = true;
    _stopAlerting();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => IncomingReconnectScreen(
          request: widget.request,
          autoApprove: true,
        ),
      ),
    );
  }

  Future<void> _reject() async {
    if (_handled) return;
    _handled = true;
    _stopAlerting();
    await RecentConnectionService.instance.rejectReconnectRequest(
      widget.request,
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  void _dismiss() {
    if (_handled) return;
    _handled = true;
    _stopAlerting();
    if (!mounted) return;
    final nav = Navigator.of(context);
    final route = _myRoute;
    if (route != null && !route.isCurrent) {
      nav.removeRoute(route);
    } else {
      nav.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = _displayName.isNotEmpty
        ? _displayName.characters.first.toUpperCase()
        : '?';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_handled) {
          unawaited(_reject());
        }
      },
      child: Scaffold(
        backgroundColor: theme.colorScheme.surfaceContainerLow,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.link_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Bağlantı isteği',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final glow = 0.35 + _pulse.value * 0.25;
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary
                                .withValues(alpha: glow),
                            blurRadius: 28 + _pulse.value * 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: child,
                    );
                  },
                  child: Material(
                    color: theme.colorScheme.surface,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _DeviceBadge(initial: initial),
                          const SizedBox(height: 20),
                          Text(
                            _displayName,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'cihazınıza bağlanmak ve dosya transferi '
                            'başlatmak istiyor.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 20),
                          _LinkPulseIndicator(pulse: _pulse),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _approve,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Bağlantıyı onayla'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _reject,
                  icon: Icon(
                    Icons.close_rounded,
                    color: theme.colorScheme.error,
                  ),
                  label: Text(
                    'Reddet',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceBadge extends StatelessWidget {
  const _DeviceBadge({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: theme.textTheme.displaySmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LinkPulseIndicator extends StatelessWidget {
  const _LinkPulseIndicator({required this.pulse});

  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.devices_rounded,
              size: 22,
              color: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.7 + pulse.value * 0.3),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: theme.colorScheme.primary
                    .withValues(alpha: 0.5 + pulse.value * 0.5),
              ),
            ),
            Icon(
              Icons.link_rounded,
              size: 24,
              color: theme.colorScheme.primary
                  .withValues(alpha: 0.6 + pulse.value * 0.4),
            ),
          ],
        );
      },
    );
  }
}

/// Masaüstünde uygulama penceresini öne getirir.
Future<void> activateAppWindowForCall() async {
  if (Platform.isMacOS) {
    // macOS: menü çubuğuna gizliyse pencereyi geri getirir.
    await DesktopBackgroundService.instance.showMainWindow();
    return;
  }
  if (Platform.isWindows) {
    // Windows normal pencere uygulaması: simge durumundaysa öne getir.
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }
}
