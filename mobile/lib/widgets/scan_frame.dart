import 'package:flutter/material.dart';

/// 取景框遮罩：叠在相机预览上，半透明遮罩 + 四角括号 + 缓慢扫光线动画。
class ScanFrameOverlay extends StatefulWidget {
  const ScanFrameOverlay({super.key, this.color = Colors.white});

  final Color color;

  @override
  State<ScanFrameOverlay> createState() => _ScanFrameOverlayState();
}

class _ScanFrameOverlayState extends State<ScanFrameOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _FramePainter(
            progress: _ctrl.value,
            color: widget.color,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter({
    required this.progress,
    required this.color,
    this.inset = 32,
  });

  final double progress;
  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    if (rect.width < 40 || rect.height < 40) return;

    // 半透明遮罩，中间圆角矩形“开窗”露出相机画面
    final hole = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      hole,
      Paint()..color = Colors.black.withValues(alpha: 0.4),
    );

    // 四角括号（略内缩，避开遮罩圆角）
    final b = rect.deflate(3);
    final bracket = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const len = 24.0;
    final tl = b.topLeft,
        tr = b.topRight,
        bl = b.bottomLeft,
        br = b.bottomRight;
    canvas.drawLine(tl, tl + const Offset(len, 0), bracket);
    canvas.drawLine(tl, tl + const Offset(0, len), bracket);
    canvas.drawLine(tr, tr + const Offset(-len, 0), bracket);
    canvas.drawLine(tr, tr + const Offset(0, len), bracket);
    canvas.drawLine(bl, bl + const Offset(len, 0), bracket);
    canvas.drawLine(bl, bl + const Offset(0, -len), bracket);
    canvas.drawLine(br, br + const Offset(-len, 0), bracket);
    canvas.drawLine(br, br + const Offset(0, -len), bracket);

    // 扫光线（上下缓动，两端渐隐）
    final y = b.top + b.height * (0.06 + 0.88 * progress);
    final lineRect = Rect.fromLTWH(b.left, y - 1.5, b.width, 3);
    final shader = LinearGradient(
      colors: [
        color.withValues(alpha: 0),
        color,
        color.withValues(alpha: 0),
      ],
    ).createShader(lineRect);
    canvas.drawLine(
      lineRect.topLeft,
      lineRect.topRight,
      Paint()
        ..shader = shader
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.progress != progress || old.color != color;
}
