import 'package:flutter/material.dart';

/// 黑羽 · 羽毛图标
class FeatherPainter extends CustomPainter {
  final Color color;
  FeatherPainter({this.color = const Color(0xFFD9A94B)});

  static Offset _q(Offset a, Offset c, Offset b, double t) {
    final mt = 1 - t;
    return Offset(
      mt * mt * a.dx + 2 * mt * t * c.dx + t * t * b.dx,
      mt * mt * a.dy + 2 * mt * t * c.dy + t * t * b.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.028
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const p0 = Offset(0.16, 0.94); // 羽根
    const c0 = Offset(0.22, 0.48); // 羽轴控制点
    const p1 = Offset(0.82, 0.08); // 羽尖

    Offset o(Offset p) => Offset(p.dx * w, p.dy * h);

    // 羽片轮廓
    final vane = Path()
      ..moveTo(o(p1).dx, o(p1).dy)
      ..quadraticBezierTo(w * 0.98, h * 0.34, w * 0.58, h * 0.60)
      ..quadraticBezierTo(w * 0.38, h * 0.72, o(p0).dx, o(p0).dy)
      ..quadraticBezierTo(w * 0.10, h * 0.52, w * 0.42, h * 0.22)
      ..quadraticBezierTo(w * 0.60, h * 0.10, o(p1).dx, o(p1).dy)
      ..close();
    canvas.drawPath(vane, fillPaint);
    canvas.drawPath(vane, strokePaint);

    // 羽轴
    final shaft = Path()
      ..moveTo(o(p0).dx, o(p0).dy)
      ..quadraticBezierTo(o(c0).dx, o(c0).dy, o(p1).dx, o(p1).dy);
    canvas.drawPath(shaft, strokePaint);

    // 羽枝
    final barbPaint = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.016
      ..strokeCap = StrokeCap.round;
    for (double t = 0.18; t < 0.92; t += 0.11) {
      final base = _q(p0, c0, p1, t);
      final ahead = _q(p0, c0, p1, t + 0.06);
      // 垂直于羽轴方向向两侧画短羽枝
      final dir = Offset(ahead.dx - base.dx, ahead.dy - base.dy);
      final len = dir.distance;
      if (len < 1e-6) continue;
      final n1 = Offset(-dir.dy / len, dir.dx / len);
      final n2 = Offset(dir.dy / len, -dir.dx / len);
      final l = w * 0.10 * (1 - t * 0.55);
      canvas.drawLine(
        o(base),
        o(base) + n1 * l,
        barbPaint,
      );
      canvas.drawLine(
        o(base),
        o(base) + n2 * l * 0.85,
        barbPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant FeatherPainter oldDelegate) =>
      oldDelegate.color != color;
}

class FeatherIcon extends StatelessWidget {
  final double size;
  final Color color;
  const FeatherIcon({super.key, this.size = 24, this.color = const Color(0xFFD9A94B)});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: FeatherPainter(color: color),
    );
  }
}
