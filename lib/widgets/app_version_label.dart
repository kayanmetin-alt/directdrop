import 'package:flutter/material.dart';

import '../services/app_version_service.dart';

/// Ana ekranın altında sürüm numarasını gösterir.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key, this.detailed = false});

  final bool detailed;

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppVersionService.instance.load();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final service = AppVersionService.instance;
    final label =
        widget.detailed ? service.detailedLabel : service.displayLabel;

    return Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
    );
  }
}
