import 'dart:math' as math;
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

  /// Sortie ancienne (> 30 j). Renforce le voile noir sur le fond de carte et
  /// éclaircit le contour de la vignette pour signaler l'ancienneté, SANS
  /// toucher au tracé ni aux marqueurs (qui restent au-dessus du voile).
  final bool archived;

  /// Date de la sortie (heure locale). Sert à libeller dynamiquement le ruban
  /// d'angle des sorties archivées (« Il y a 42 jours », « Il y a 3 mois »…).
  final DateTime? rideDate;

  const RideTraceThumbnail({
    super.key,
    required this.points,
    this.width = 100,
    this.height = 88,
    this.showMap = true,
    this.archived = false,
    this.rideDate,
  });

  // Couleur de fond sombre, sert aussi de fond quand les tuiles ne chargent pas.
  static const Color _bg = Color(0xFF101418);

  // Charte trace de l'appli (identique à la carte de détail et à la carte de
  // partage) : départ orange → milieu magenta → arrivée violet.
  static const Color traceStart = Color(0xFFFF8A00);
  static const Color traceMid = Color(0xFFD946EF);
  static const Color traceEnd = Color(0xFF6D28D9);

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

  // Dégradé départ (orange) → milieu (magenta) → arrivée (violet).
  static List<Color> traceGradient(int segments) {
    if (segments <= 1) return [traceStart];
    return List.generate(segments, (i) {
      final t = i / (segments - 1);
      if (t <= 0.5) return Color.lerp(traceStart, traceMid, t / 0.5)!;
      return Color.lerp(traceMid, traceEnd, (t - 0.5) / 0.5)!;
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
          child: Stack(
            children: [
              Positioned.fill(child: content),
              // Liseré en coin « + de 30 jours » pour les sorties archivées,
              // clippé par le coin arrondi ci-dessus → rendu ruban.
              if (archived) _archivedRibbon(),
            ],
          ),
        ),
      ),
    );
  }

  // Ruban d'angle « Il y a … » : triangle plein ancré exactement dans le
  // coin haut-gauche (donc il remonte jusqu'au coin, sans laisser de carte
  // visible), avec l'ancienneté en diagonale par-dessus.
  Widget _archivedRibbon() {
    return Positioned(
      top: 0,
      left: 0,
      child: CustomPaint(
        size: const Size(78, 78),
        painter: _CornerRibbonPainter(archivedAgeLabel(rideDate)),
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
    final grad = traceGradient(ridePoints.length - 1);
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
          tileBuilder: _tileBuilder,
        ),
        // Voile sombre pour fondre la carte dans le thème dark/orange et
        // faire ressortir la trace. Sortie archivée : on NE noircit PAS
        // davantage (le fond est désaturé en gris par le tileBuilder, cf.
        // _tileBuilder). On garde même un voile plus léger pour que la
        // mini-carte grise reste lisible et « n'ait pas l'air éteinte ».
        IgnorePointer(
          child: DecoratedBox(
            decoration: archived
                ? const BoxDecoration(color: Color(0x3D000000)) // black @ 0.24
                : const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x47000000), // black @ 0.28
                        Color(0x6B000000), // black @ 0.42
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
        // Marqueurs identiques à ceux de la carte de détail, à l'échelle de la
        // vignette : arrivée (drapeau violet) dessinée d'abord pour qu'en cas
        // de boucle le départ reste visible par-dessus.
        MarkerLayer(markers: [
          Marker(
            point: ridePoints.last,
            width: 20,
            height: 20,
            child: const _EndMarker(iconSize: 15),
          ),
          Marker(
            point: ridePoints.first,
            width: 14,
            height: 14,
            child: const _StartMarker(),
          ),
        ]),
      ],
    );
  }

  // Filtre appliqué aux tuiles topo (claires par défaut).
  //
  // • Sortie récente : léger assombrissement par canal pour coller au thème
  //   sombre de l'appli, en conservant la couleur.
  // • Sortie archivée (> 30 j) : désaturation totale en gris, à luminance
  //   équivalente (mêmes coefficients ~0.72). La carte n'est donc PAS plus
  //   sombre, elle perd juste sa couleur → effet « carte d'archive », et le
  //   tracé coloré (dessiné au-dessus) ressort d'autant mieux.
  Widget _tileBuilder(BuildContext context, Widget tile, TileImage image) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
        archived ? _grayscaleMatrix : _darkenMatrix,
      ),
      child: tile,
    );
  }

  static const List<double> _darkenMatrix = <double>[
    0.72, 0, 0, 0, 0,
    0, 0.74, 0, 0, 0,
    0, 0, 0.70, 0, 0,
    0, 0, 0, 1, 0,
  ];

  // Grayscale luma (0.2126 / 0.7152 / 0.0722) mis à l'échelle 0.72 pour rester
  // à la même luminosité qu'une tuile récente assombrie.
  static const List<double> _grayscaleMatrix = <double>[
    0.1531, 0.5149, 0.0520, 0, 0,
    0.1531, 0.5149, 0.0520, 0, 0,
    0.1531, 0.5149, 0.0520, 0, 0,
    0, 0, 0, 1, 0,
  ];

}

/// Marqueur de DÉPART : anneau orange sur fond sombre translucide, halo orange.
/// Même langage visuel que la carte de détail, en plus petit.
class _StartMarker extends StatelessWidget {
  const _StartMarker();

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
          shape: BoxShape.circle,
          border: Border.all(color: RideTraceThumbnail.traceStart, width: 2),
          boxShadow: [
            BoxShadow(
              color: RideTraceThumbnail.traceStart.withValues(alpha: 0.85),
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }
}

/// Marqueur d'ARRIVÉE : drapeau à damier dans un anneau violet, comme sur la
/// carte de détail et dans la timeline des points de passage.
class _EndMarker extends StatelessWidget {
  final double iconSize;

  const _EndMarker({required this.iconSize});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
          border: Border.all(color: RideTraceThumbnail.traceEnd, width: 2),
          boxShadow: [
            BoxShadow(
              color: RideTraceThumbnail.traceEnd.withValues(alpha: 0.85),
              blurRadius: 6,
            ),
          ],
        ),
        child: Icon(
          Icons.sports_score_sharp,
          color: Colors.white,
          size: iconSize,
        ),
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

    // Tracé principal, segment par segment, avec le même dégradé
    // orange → magenta → violet que la mini-carte et la carte de détail.
    final grad = RideTraceThumbnail.traceGradient(points.length - 1);
    final tracePaint = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < points.length - 1; i++) {
      tracePaint.color = grad[i];
      canvas.drawLine(convert(points[i]), convert(points[i + 1]), tracePaint);
    }

    // ── Marqueur d'ARRIVÉE : anneau violet + drapeau à damier ──
    // Dessiné en premier pour qu'en cas de boucle (départ ≈ arrivée),
    // la petite pastille de départ reste visible par-dessus.
    _drawRing(canvas, end, radius: 9, color: RideTraceThumbnail.traceEnd, ringWidth: 2);
    _drawFlag(canvas, end, size: 13);

    // ── Marqueur de DÉPART : anneau orange, par-dessus ──
    _drawRing(canvas, start, radius: 6, color: RideTraceThumbnail.traceStart, ringWidth: 2);
  }

  /// Anneau coloré sur fond sombre translucide, avec halo — équivalent peint
  /// des marqueurs widget de la mini-carte.
  void _drawRing(
    Canvas canvas,
    Offset center, {
    required double radius,
    required Color color,
    required double ringWidth,
  }) {
    canvas.drawCircle(
      center,
      radius + ringWidth,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth,
    );
  }

  /// Drapeau à damier (Icons.sports_score_sharp) dessiné depuis la police
  /// MaterialIcons, pour que l'arrivée porte le même symbole partout.
  void _drawFlag(Canvas canvas, Offset center, {required double size}) {
    const icon = Icons.sports_score_sharp;
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Ancienneté d'une sortie archivée, formatée pour le ruban d'angle.
///
/// Renvoie seulement la partie variable (« 42 jours », « 3 mois », « 1 an »,
/// « 2 ans ») ; le painter la préfixe par « Il y a ». Paliers :
///   • 31 à 59 jours   → « N jours »
///   • 2 à 11 mois      → « N mois »
///   • 12 à 23 mois     → « 1 an »
///   • 24 mois et plus  → « N ans »
String archivedAgeLabel(DateTime? date) {
  if (date == null) return '30 jours'; // repli si la date est inconnue
  final now = DateTime.now();
  final days = now.difference(date).inDays;
  if (days < 60) return '$days jours';

  // Mois calendaires complets écoulés (indépendant de la longueur des mois).
  var months = (now.year - date.year) * 12 + (now.month - date.month);
  if (now.day < date.day) months -= 1;

  if (months < 12) return '$months mois';
  if (months < 24) return '1 an';
  return '${months ~/ 12} ans';
}

/// Ruban d'angle « Il y a … » pour les sorties archivées.
///
/// Dessine un triangle plein ancré dans le coin haut-gauche (sommets (0,0),
/// (s,0), (0,s)) — il touche donc franchement le coin — puis le libellé sur
/// deux lignes, centré et tourné à -45° le long de la diagonale.
class _CornerRibbonPainter extends CustomPainter {
  final String ageLabel;

  const _CornerRibbonPainter(this.ageLabel);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;

    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(s, 0)
      ..lineTo(0, s)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.44));

    final tp = TextPainter(
      text: TextSpan(
        text: 'Il y a\n$ageLabel',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          height: 1.1,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();

    // Centre du texte le long de la diagonale, entre le coin et l'hypoténuse.
    final c = s * 0.30;
    canvas.save();
    canvas.translate(c, c);
    canvas.rotate(-math.pi / 4);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CornerRibbonPainter oldDelegate) =>
      oldDelegate.ageLabel != ageLabel;
}
