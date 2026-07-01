import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Preview screen – affiché avant le partage pour que l'utilisateur voie la carte
// ─────────────────────────────────────────────────────────────────────────────

class RideSharePreviewScreen extends StatefulWidget {
  final Map<String, dynamic> ride;
  final String rideName;

  const RideSharePreviewScreen({
    super.key,
    required this.ride,
    required this.rideName,
  });

  @override
  State<RideSharePreviewScreen> createState() => _RideSharePreviewScreenState();
}

class _RideSharePreviewScreenState extends State<RideSharePreviewScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  bool _sharing = false;
  int _mapStyleIndex = 0;

  Future<void> _captureAndShare() async {
    setState(() => _sharing = true);
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await Future.delayed(const Duration(milliseconds: 80));
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final bytes = byteData.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sunday_tracker_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path)], text: widget.rideName);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060609),
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white54),
                ),
                const Expanded(
                  child: Text(
                    'Aperçu du partage',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ]),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: RepaintBoundary(
                        key: _repaintKey,
                        child: RideShareCard(
                          ride: widget.ride,
                          rideName: widget.rideName,
                          mapStyleIndex: _mapStyleIndex,
                        ),
                      ),
                    ),
                  ),
                ),
                // Bouton de cycle des styles de carte — incrusté sur la carte,
                // hors RepaintBoundary donc absent de l'image exportée.
                Positioned(
                  right: 28,
                  bottom: 28,
                  child: GestureDetector(
                    onTap: () => setState(() =>
                        _mapStyleIndex = (_mapStyleIndex + 1) % RideShareCard.mapStyles.length),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Icon(
                        RideShareCard.mapStyles[_mapStyleIndex]['icon'] as IconData,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _sharing ? null : _captureAndShare,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8A00),
                    disabledBackgroundColor: const Color(0xFF7A4200),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: _sharing
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.share_rounded, color: Colors.white, size: 20),
                  label: Text(
                    _sharing ? 'Préparation…' : 'Partager',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte de partage – rendu autonome à taille fixe
// ─────────────────────────────────────────────────────────────────────────────

class RideShareCard extends StatelessWidget {
  final Map<String, dynamic> ride;
  final String rideName;
  final int mapStyleIndex;

  static const double kWidth  = 390.0;
  static const double kHeight = 710.0;

  static const mapStyles = <Map<String, dynamic>>[
    {'label': 'Plan',      'icon': Icons.map,           'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',                                                'subdomains': <String>[]},
    {'label': 'Satellite', 'icon': Icons.satellite_alt, 'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'subdomains': <String>[]},
    {'label': 'Topo',      'icon': Icons.terrain,       'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',                                              'subdomains': <String>['a', 'b', 'c']},
  ];

  const RideShareCard({
    super.key,
    required this.ride,
    required this.rideName,
    this.mapStyleIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kWidth,
      height: kHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Container(
          color: const Color(0xFF080B12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              _buildStats(),
              Expanded(child: _buildMapArea()),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  // ── En-tête ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    final startTime = ride['startTime'] as String?;
    final endTime   = ride['endTime']   as String?;
    final dt    = startTime != null ? DateTime.tryParse(startTime)?.toLocal() : null;
    final dtEnd = endTime   != null ? DateTime.tryParse(endTime)?.toLocal()   : null;

    String sub = '';
    if (dt != null) {
      const days   = ['Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi','Dimanche'];
      const months = ['jan.','fév.','mars','avr.','mai','juin','juil.','août','sep.','oct.','nov.','déc.'];
      final sh = '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
      sub = '${days[dt.weekday - 1]} ${dt.day} ${months[dt.month - 1]} ${dt.year}';
      if (dtEnd != null) {
        final eh = '${dtEnd.hour.toString().padLeft(2,'0')}:${dtEnd.minute.toString().padLeft(2,'0')}';
        sub += ' · $sh–$eh';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          rideName,
          style: const TextStyle(
            fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ]),
    );
  }

  // ── Bandeau de stats ───────────────────────────────────────────────────────
  Widget _buildStats() {
    final distM  = (ride['distanceMeters']       ?? 0.0).toDouble();
    final durS   = ((ride['durationSeconds']     ?? 0) as num).toInt();
    final dPlus  = (ride['totalElevationMeters'] ?? 0.0).toDouble();
    final dMinus = (ride['totalElevationDown']   ?? 0.0).toDouble();

    final distVal  = distM < 1000
        ? '${distM.toStringAsFixed(0)} m'
        : '${(distM / 1000).toStringAsFixed(2)} km';

    final dur    = Duration(seconds: durS);
    final durVal = dur.inHours > 0
        ? '${dur.inHours}h${(dur.inMinutes % 60).toString().padLeft(2, '0')}'
        : '${dur.inMinutes.toString().padLeft(2, '0')}:${(dur.inSeconds % 60).toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1320),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          _statCell(distVal,                            'Distance',  const Color(0xFFFF8A00)),
          _vDivider(),
          _statCell(durVal,                             'Durée',     Colors.white),
          _vDivider(),
          _statCell('+${dPlus.toStringAsFixed(0)} m',  'D+',        const Color(0xFF4ADE80)),
          _vDivider(),
          _statCell('−${dMinus.toStringAsFixed(0)} m', 'D−',        const Color(0xFF60A5FA)),
        ]),
      ),
    );
  }

  static Widget _vDivider() => Container(
    width: 1, height: 32,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: Colors.white12,
  );

  static Widget _statCell(String value, String label, Color color) => Expanded(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(
        value,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, height: 1.0),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 3),
      Text(
        label,
        style: const TextStyle(fontSize: 11, color: Colors.white30, letterSpacing: 0.3),
        textAlign: TextAlign.center,
      ),
    ]),
  );

  // ── Zone carte (élément principal) ─────────────────────────────────────────
  Widget _buildMapArea() {
    final rawPts = ride['points'] as List;
    final pts = rawPts
        .map((p) => _Pt((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
        .toList();

    final minLat = pts.map((p) => p.lat).reduce(min);
    final maxLat = pts.map((p) => p.lat).reduce(max);
    final minLng = pts.map((p) => p.lng).reduce(min);
    final maxLng = pts.map((p) => p.lng).reduce(max);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(
          builder: (_, constraints) {
            final sz = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                SizedBox(
                  width: sz.width,
                  height: sz.height,
                  child: FlutterMap(
                    options: MapOptions(
                      initialCameraFit: CameraFit.bounds(
                        bounds: LatLngBounds(
                          ll.LatLng(minLat, minLng),
                          ll.LatLng(maxLat, maxLng),
                        ),
                        padding: const EdgeInsets.all(32),
                      ),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.none,
                      ),
                    ),
                    children: [
                      TileLayer(
                        key: ValueKey(mapStyleIndex),
                        urlTemplate: mapStyles[mapStyleIndex]['url'] as String,
                        subdomains: mapStyles[mapStyleIndex]['subdomains'] as List<String>,
                        userAgentPackageName: 'com.lpujol31.sunday_tracker',
                      ),
                    ],
                  ),
                ),
                CustomPaint(
                  size: sz,
                  painter: _TracePainter(points: pts),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Pied de page ───────────────────────────────────────────────────────────
  Widget _buildFooter() {
    final city     = ride['city']     as String?;
    final practice = ride['practice'] as String?;
    final dPlus  = (ride['totalElevationMeters'] ?? 0.0).toDouble();
    final altMin = (ride['altitudeMin']          ?? 0.0).toDouble();
    final altMax = (ride['altitudeMax']          ?? 0.0).toDouble();

    const practiceMap = {
      'route': 'Route', 'vtt': 'VTT', 'enduro': 'Enduro',
      'marche': 'Marche', 'running': 'Running',
    };
    final practiceLabel = practiceMap[practice] ?? 'Activité';
    final detail =
        '$practiceLabel · D+ ${dPlus.toStringAsFixed(0)} m · Alt. ${altMin.toStringAsFixed(0)}–${altMax.toStringAsFixed(0)} m';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (city != null && city.isNotEmpty)
              Text(city, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ]),
        ),
        Row(children: [
          Container(
            width: 14, height: 14,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF8A00), Color(0xFF6D28D9)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'Sunday Tracker',
            style: TextStyle(fontSize: 9.5, color: Colors.white30, fontWeight: FontWeight.w500),
          ),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Point GPS
// ─────────────────────────────────────────────────────────────────────────────

class _Pt {
  final double lat;
  final double lng;
  const _Pt(this.lat, this.lng);
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter – tracé GPS dégradé
// ─────────────────────────────────────────────────────────────────────────────

class _TracePainter extends CustomPainter {
  final List<_Pt> points;

  _TracePainter({required this.points});

  static const _colors = [Color(0xFFFF8A00), Color(0xFFD946EF), Color(0xFF6D28D9)];

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final proj = _Projection.fit(points, size);

    // 3 passes : halo large → halo moyen → trait principal
    _drawTrace(canvas, proj, width: 14, alpha: 0.10);
    _drawTrace(canvas, proj, width:  8, alpha: 0.28);
    _drawTrace(canvas, proj, width:  4, alpha: 1.00);

    // Marqueur départ (orange)
    _drawMarker(canvas, proj.project(points.first), _colors[0], isStart: true);
    // Marqueur arrivée (violet)
    _drawMarker(canvas, proj.project(points.last),  _colors[2], isStart: false);
  }


  void _drawTrace(Canvas canvas, _Projection proj, {required double width, required double alpha}) {
    final paint = Paint()
      ..strokeWidth = width
      ..strokeCap   = StrokeCap.round
      ..strokeJoin  = StrokeJoin.round
      ..style       = PaintingStyle.stroke;

    for (int i = 0; i < points.length - 1; i++) {
      final t = i / (points.length - 1);
      paint.color = _lerp(t).withValues(alpha: alpha);
      canvas.drawLine(proj.project(points[i]), proj.project(points[i + 1]), paint);
    }
  }

  Color _lerp(double t) {
    if (t <= 0.5) return Color.lerp(_colors[0], _colors[1], t / 0.5)!;
    return Color.lerp(_colors[1], _colors[2], (t - 0.5) / 0.5)!;
  }

  void _drawMarker(Canvas canvas, Offset c, Color color, {required bool isStart}) {
    // Halo
    canvas.drawCircle(c, 16, Paint()..color = color.withValues(alpha: 0.18));
    // Anneau blanc
    canvas.drawCircle(c,  9, Paint()..color = Colors.white.withValues(alpha: 0.92));
    // Remplissage coloré
    canvas.drawCircle(c,  6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.points != points;
}

// ─────────────────────────────────────────────────────────────────────────────
// Projection équirectangulaire (min/max, cosLat sur lng uniquement)
// ─────────────────────────────────────────────────────────────────────────────

class _Projection {
  final double _minLat, _maxLat, _minLng, _maxLng;
  final double _cosLat;
  final Size   _size;

  _Projection._({
    required double minLat, required double maxLat,
    required double minLng, required double maxLng,
    required double cosLat, required Size size,
  })  : _minLat = minLat, _maxLat = maxLat,
        _minLng = minLng, _maxLng = maxLng,
        _cosLat = cosLat, _size = size;

  factory _Projection.fit(List<_Pt> pts, Size size) {
    final minLat = pts.map((p) => p.lat).reduce(min);
    final maxLat = pts.map((p) => p.lat).reduce(max);
    final minLng = pts.map((p) => p.lng).reduce(min);
    final maxLng = pts.map((p) => p.lng).reduce(max);
    final cosLat = cos((minLat + maxLat) / 2 * pi / 180);
    return _Projection._(
      minLat: minLat, maxLat: maxLat,
      minLng: minLng, maxLng: maxLng,
      cosLat: cosLat, size: size,
    );
  }

  Offset project(_Pt p) {
    const pad = 28.0;
    final geoW = max((_maxLng - _minLng) * _cosLat, 1e-6);
    final geoH = max( _maxLat - _minLat,             1e-6);
    final tW   = _size.width  - 2 * pad;
    final tH   = _size.height - 2 * pad;
    final scale = min(tW / geoW, tH / geoH);
    final offX  = (_size.width  - geoW * scale) / 2;
    final offY  = (_size.height - geoH * scale) / 2;
    final x = offX + (p.lng - _minLng) * _cosLat * scale;
    final y = offY + (_maxLat - p.lat) * scale; // Y inversé (lat croît vers le haut)
    return Offset(x, y);
  }
}
