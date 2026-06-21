import 'package:flutter/material.dart';

/// Android'de Material 3 stretch/glow overscroll efektini kapatır.
class DirectDropScrollBehavior extends MaterialScrollBehavior {
  const DirectDropScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }
}
