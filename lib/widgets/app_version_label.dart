import 'package:flutter/material.dart';

import '../services/app_version_service.dart';

/// Ana ekranın altında sürüm numarasını gösterir.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key, this.detailed = false, this.compact = false});

  final bool detailed;
  /// AppBar gibi dar alanlarda kısa gösterim: "v1.0.7"
  final bool compact;

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(force: true);
    }
  }

  Future<void> _load({bool force = false}) async {
    await AppVersionService.instance.load(forceReload: force);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = AppVersionService.instance;
    final label = widget.compact
        ? 'v${service.version}'
        : widget.detailed
            ? service.detailedLabel
            : service.displayLabel;

    return Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: widget.compact ? FontWeight.w600 : null,
          ),
    );
  }
}
