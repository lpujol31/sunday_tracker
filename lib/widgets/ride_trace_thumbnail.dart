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

    final start = convert(points.first);
    final end = convert(points.last);

    // Couleurs départ → arrivée (vert → rouge).
    const startColor = Color(0xFF16A34A); // vert
    const endColor = Color(0xFFEF4444); // rouge

    // Ombre portée sous le tracé : effet relief « posé sur la carte ».
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2);
    canvas.save();
    canvas.translate(0, 1.2);
    canvas.drawPath(path, shadowPaint);
    canvas.restore();

    // Tracé principal en dégradé départ → arrivée.
    final tracePaint = Paint()
      ..shader = ui.Gradient.linear(
        start,
        end,
        const [startColor, endColor],
      )
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, tracePaint);

    // ── Marqueur d'ARRIVÉE : plus grand, rouge, mis en avant (halo) ──
    // Dessiné en premier pour qu'en cas de boucle (départ ≈ arrivée),
    // la petite pastille de départ reste visible par-dessus.
    canvas.drawCircle(
      end,
      12,
      Paint()
        ..color = endColor.withValues(alpha: 0.28)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3),
    );
    _drawMarker(canvas, end, radius: 7, color: endColor, ringWidth: 2.4);

    // ── Marqueur de DÉPART : petit, vert, par-dessus ──
    _drawMarker(canvas, start, radius: 4, color: startColor, ringWidth: 1.6);
  }

  /// Pastille pleine cerclée de blanc, avec une légère ombre de contact.
  void _drawMarker(
    Canvas canvas,
    Offset center, {
    required double radius,
    required Color color,
    required double ringWidth,
  }) {
    canvas.drawCircle(
      center.translate(0, 0.8),
      radius + ringWidth / 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 1.5),
    );
    canvas.drawCircle(center, radius, Paint()..color = color);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}