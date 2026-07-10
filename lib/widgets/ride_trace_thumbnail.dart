import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Miniature d'une sortie affichée dans la liste d'accueil.
///
/// Rend une vraie mini-carte sombre/topographique (tuiles OpenTopoMap
/// non interactives) avec la trace GPS en surimpression. Hors ligne, les
/// tuiles ne se chargent pas : on garde alors un fond sombre + la trace,
/// donc la vignette reste lisible sans réseau.
class RideTraceThumbnail extends StatelessWidget {
  final List points;
  final double width;
  final double height;

  /// Fond de carte (tuiles réseau). Désactivable pour un rendu 100 % offline
  /// (trace seule sur fond sombre).
  final bool showMap;

  const RideTraceThumbnail({
    super.key,
    required this.points,
    this.width = 100,
    this.height = 88,
    this.showMap = true,
  });

  // Couleur de fond sombre, sert aussi de fond quand les tuiles ne chargent pas.
  static const Color _bg = Color(0xFF101418);

  List<LatLng> _latLngPoints() {
    final result = <LatLng>[];
    for (final point in points) {
      if (point is Map) {
        final lat = point['lat'];
        final lng = point['lng'];
        if (lat is num && lng is num) {
          result.add(LatLng(lat.toDouble(), lng.toDouble()));
        }
      }
    }
    return result;
  }

  // Réduit le nombre de points pour alléger le rendu (une seule vignette n'a
  // pas besoin de milliers de segments).
  List<LatLng> _downsample(List<LatLng> pts, int maxPoints) {
    if (pts.length <= maxPoints) return pts;
    final step = pts.length / maxPoints;
    final out = <LatLng>[];
    for (double i = 0; i < pts.length - 1; i += step) {
      out.add(pts[i.floor()]);
    }
    out.add(pts.last); // toujours conserver l'arrivée
    return out;
  }

  // Dégradé départ (vert) → milieu (orange) → arrivée (rouge).
  List<Color> _traceGradient(int segments) {
    const start = Color(0xFF22C55E);
    const mid = Color(0xFFF59E0B);
    const end = Color(0xFFEF4444);
    if (segments <= 1) return [start];
    return List.generate(segments, (i) {
      final t = i / (segments - 1);
      if (t <= 0.5) return Color.lerp(start, mid, t / 0.5)!;
      return Color.lerp(mid, end, (t - 0.5) / 0.5)!;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ridePoints = _downsample(_latLngPoints(), 80);

    // Bornes de la trace : nécessaires pour cadrer la carte. Si elles sont
    // dégénérées (0 ou 1 point distinct), on retombe sur le rendu peintre.
    final bounds = _boundsOrNull(ridePoints);

    final Widget content;
    if (!showMap || bounds == null) {
      content = CustomPaint(painter: RideTracePainter(ridePoints));
    } else {
      content = _buildMap(ridePoints, bounds);
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      // La vignette n'est jamais interactive : on la rend transparente aux
      // gestes pour que le tap traverse jusqu'au GestureDetector de la carte
      // (ouverture du détail). Sans ça, le GestureDetector interne de
      // FlutterMap absorbe le tap, même avec InteractiveFlag.none.
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: content,
        ),
      ),
    );
  }

  LatLngBounds? _boundsOrNull(List<LatLng> pts) {
    if (pts.length < 2) return null;
    final bounds = LatLngBounds.fromPoints(pts);
    // Étendue nulle (tous les points confondus) → cadrage impossible.
    if (bounds.north == bounds.south && bounds.east == bounds.west) return null;
    return bounds;
  }

  Widget _buildMap(List<LatLng> ridePoints, LatLngBounds bounds) {
    final grad = _traceGradient(ridePoints.length - 1);
    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(14),
        ),
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
        backgroundColor: _bg,
        keepAlive: false,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          maxZoom: 17,
          userAgentPackageName: 'com.example.sunday_tracker',
          tileBuilder: _darkTileBuilder,
        ),
        // Voile sombre pour fondre la carte dans le thème dark/orange et
        // faire ressortir la trace.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.28),
                  Colors.black.withValues(alpha: 0.42),
                ],
              ),
            ),
          ),
        ),
        PolylineLayer(
          polylines: List.generate(
            ridePoints.length - 1,
            (i) => Polyline(
              points: [ridePoints[i], ridePoints[i + 1]],
              strokeWidth: 3.5,
              color: grad[i],
            ),
          ),
        ),
        MarkerLayer(markers: [
          Marker(
            point: ridePoints.last,
            width: 16,
            height: 16,
            child: _dot(const Color(0xFFEF4444), ring: 2),
          ),
          Marker(
            point: ridePoints.first,
            width: 12,
            height: 12,
            child: _dot(const Color(0xFF22C55E), ring: 1.6),
          ),
        ]),
      ],
    );
  }

  // Assombrit légèrement les tuiles topo (claires par défaut) pour coller au
  // thème sombre de l'appli.
  Widget _darkTileBuilder(BuildContext context, Widget tile, TileImage image) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        0.72, 0, 0, 0, 0,
        0, 0.74, 0, 0, 0,
        0, 0, 0.70, 0, 0,
        0, 0, 0, 1, 0,
      ]),
      child: tile,
    );
  }

  Widget _dot(Color color, {required double ring}) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: ring),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 2,
          ),
        ],
      ),
    );
  }
}

/// Rendu de secours (offline strict ou trace dégénérée) : trace seule dessinée
/// sur le fond sombre, sans tuiles réseau.
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
