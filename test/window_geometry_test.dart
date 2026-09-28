import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/window_geometry.dart';

void main() {
  for (final area in [
    const Rect.fromLTWH(0, 24, 1440, 816),
    const Rect.fromLTWH(0, 24, 1024, 700),
    const Rect.fromLTWH(-1920, -100, 1920, 1040),
    const Rect.fromLTWH(1920, 0, 800, 560),
  ]) {
    test('window fits and centers in logical work area $area', () {
      final bounds = initialWindowBounds(area);
      expect(bounds.center, area.center);
      expect(bounds.left, greaterThanOrEqualTo(area.left));
      expect(bounds.top, greaterThanOrEqualTo(area.top));
      expect(bounds.right, lessThanOrEqualTo(area.right));
      expect(bounds.bottom, lessThanOrEqualTo(area.bottom));
    });
  }
}
