import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Draggable 4-corner court overlay for pre-stream calibration.
///
/// Corners are expressed in snapshot pixel coordinates; the overlay maps
/// them into the contain-fit display rect so drags stay aligned with the
/// image at any viewport size. The connecting polygon is the court boundary
/// the referee confirms before the ball-tracking stream may start.
class CourtCalibrationOverlay extends StatefulWidget {
  const CourtCalibrationOverlay({
    super.key,
    required this.initialCorners,
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    this.onChanged,
  }) : assert(initialCorners.length == 4);

  final List<Offset> initialCorners;
  final Uint8List? imageBytes;
  final int? imageWidth;
  final int? imageHeight;
  final ValueChanged<List<Offset>>? onChanged;

  @override
  State<CourtCalibrationOverlay> createState() =>
      _CourtCalibrationOverlayState();
}

class _CourtCalibrationOverlayState extends State<CourtCalibrationOverlay> {
  late List<Offset> _corners;

  @override
  void initState() {
    super.initState();
    _corners = List.of(widget.initialCorners);
  }

  @override
  void didUpdateWidget(CourtCalibrationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialCorners != widget.initialCorners) {
      _corners = List.of(widget.initialCorners);
    }
  }

  void _moveHandle(int index, Offset displayDelta, Size displaySize) {
    final imgSize = _imageSize(displaySize);
    final scale = _fitScale(displaySize, imgSize);
    setState(() {
      final next = _corners[index] + displayDelta / scale;
      _corners[index] = Offset(
        next.dx.clamp(0, imgSize.width),
        next.dy.clamp(0, imgSize.height),
      );
    });
    widget.onChanged?.call(List.unmodifiable(_corners));
  }

  Size _imageSize(Size displaySize) {
    final w = widget.imageWidth;
    final h = widget.imageHeight;
    if (w != null && h != null && w > 0 && h > 0) {
      return Size(w.toDouble(), h.toDouble());
    }
    return displaySize;
  }

  double _fitScale(Size displaySize, Size imgSize) {
    if (imgSize.width <= 0 || imgSize.height <= 0) return 1;
    final s = (displaySize.width / imgSize.width)
        .clamp(0.0, double.infinity)
        .toDouble();
    final s2 = displaySize.height / imgSize.height;
    return s < s2 ? s : s2;
  }

  Offset _toDisplay(Offset point, Size displaySize) {
    final imgSize = _imageSize(displaySize);
    final scale = _fitScale(displaySize, imgSize);
    final shown = Size(imgSize.width * scale, imgSize.height * scale);
    final origin = Offset(
      (displaySize.width - shown.width) / 2,
      (displaySize.height - shown.height) / 2,
    );
    return origin + point * scale;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final displaySize = Size(constraints.maxWidth, constraints.maxHeight);
        final displayed = _corners
            .map((corner) => _toDisplay(corner, displaySize))
            .toList();
        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.imageBytes != null)
              Image.memory(widget.imageBytes!, fit: BoxFit.contain)
            else
              Container(color: AppColors.surface),
            Positioned.fill(
              child: CustomPaint(
                painter: _CourtPolygonPainter(displayed),
              ),
            ),
            for (var i = 0; i < 4; i++)
              Positioned(
                left: displayed[i].dx - 18,
                top: displayed[i].dy - 18,
                child: GestureDetector(
                  key: ValueKey('court-handle-$i'),
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) =>
                      _moveHandle(i, details.delta, displaySize),
                  child: Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: AppColors.courtGreenBright,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Center(
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CourtPolygonPainter extends CustomPainter {
  const _CourtPolygonPainter(this.corners);

  /// Corners numbered 1=TR, 2=TL, 3=BR, 4=BL (indices 0-3).
  /// Edges: top 1-2, bottom 3-4, right 1-3, left 2-4.
  static const edges = [
    [0, 1],
    [2, 3],
    [0, 2],
    [1, 3],
  ];

  final List<Offset> corners;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    // Perimeter loop for the fill: TR → BR → BL → TL.
    final path = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.courtGreenBright.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    final edgePaint = Paint()
      ..color = AppColors.courtGreenBright
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final edge in edges) {
      canvas.drawLine(corners[edge[0]], corners[edge[1]], edgePaint);
    }
  }

  @override
  bool shouldRepaint(_CourtPolygonPainter oldDelegate) =>
      oldDelegate.corners != corners;
}
