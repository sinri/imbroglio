import 'dart:math' as math;
import 'dart:ui';

Rect initialWindowBounds(Rect workArea) {
  final width = math.min(1320.0, math.max(1.0, workArea.width - 32));
  final height = math.min(860.0, math.max(1.0, workArea.height - 32));
  return Rect.fromCenter(center: workArea.center, width: width, height: height);
}
