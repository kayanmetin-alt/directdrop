import 'dart:io';

import 'package:flutter/material.dart';

/// Mac / Windows / Linux'ta geniş pencerede içeriği ortalar.
class DesktopCenteredLayout extends StatelessWidget {
  const DesktopCenteredLayout({
    super.key,
    required this.child,
    this.maxWidth = 720,
  });

  final Widget child;
  final double maxWidth;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return child;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
