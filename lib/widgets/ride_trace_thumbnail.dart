import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class RideTraceThumbnail extends StatelessWidget {
  final List points;

  const RideTraceThumbnail({
    super.key,
    required this.points,
  });

  @override
  Widget build(BuildContext context) {
    final ridePoints = points.map((point) {
      return LatLng(
        point['lat'],
        point['lng'],
      );
    }).toList();

    return Container(
    width: 75,
    height: 60,
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white12,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: CustomPaint(
          painter: RideTracePainter(ridePoints),
        ),
      ),
    );
  }
}

class RideTracePainter extends CustomPainter {
  final List<LatLng> points;

  RideTracePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final latitudes = points.map((p) => p.latitude).toList();
    final longitudes = points.map((p) => p.longitude).toList();

    final minLat = latitudes.reduce((a, b) => a < b ? a : b);
    final maxLat = latitudes.reduce((a, b) => a > b ? a : b);
    final minLng = longitudes.reduce((a, b) => a < b ? a : b);
    final maxLng = longitudes.reduce((a, b) => a > b ? a : b);

    const padding = 12.0;

    Offset convert(LatLng point) {
      final x = (point.longitude - minLng) / ((maxLng - minLng) == 0 ? 1 : maxLng - minLng);
      final y = (point.latitude - minLat) / ((maxLat - minLat) == 0 ? 1 : maxLat - minLat);

      return Offset(
        padding + x * (size.width - padding * 2),
        size.height - padding - y * (size.height - padding * 2),
      );
    }

    final path = ui.Path();
    path.moveTo(
      convert(points.first).dx,
      convert(points.first).dy,
    );

    for (final point in points.skip(1)) {
      final offset = convert(point);
      path.lineTo(offset.dx, offset.dy);
    }

    final tracePaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, tracePaint);

    final start = convert(points.first);
    final end = convert(points.last);

    canvas.drawCircle(start, 7, Paint()..color = Colors.green);
    canvas.drawCircle(start, 7, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);

    canvas.drawCircle(end, 7, Paint()..color = Colors.red);
    canvas.drawCircle(end, 7, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}