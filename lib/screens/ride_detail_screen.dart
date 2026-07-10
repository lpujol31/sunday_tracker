import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:sunday_tracker/widgets/ride_share_card.dart';
import 'package:sunday_tracker/utils/date_labels.dart';
import 'package:sunday_tracker/utils/geo_labels.dart';
import 'package:sunday_tracker/screens/home_screen.dart' show kPracticeTypes, detectPractice;
import 'package:sunday_tracker/services/photo_sync_service.dart';
import 'package:sunday_tracker/services/pending_deletions_service.dart';
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class RideDetailScreen extends StatefulWidget {
  final Map ride;
  final dynamic rideKey;

  const RideDetailScreen({
    super.key,
    required this.ride,
    required this.rideKey,
  });

  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen>
    with TickerProviderStateMixin {
  late String rideName;
  late String rideNote;
  final MapController mapController = MapController();

  // Animation maison de la taille du panneau : on pilote `jumpTo` frame par
  // frame (l'animateTo natif du DraggableScrollableSheet est peu fiable ici —
  // il se fait interrompre et s'arrête en chemin).
  late final AnimationController _sizeAnimCtrl;
  VoidCallback? _sizeAnimListener;

  // ── Styles de carte ──────────────────────────────────────────────────────────
  static const String _prefKeyMapStyle = 'detail_map_style_index';
  int _mapStyleIndex = 0;

  // ── Noms des lieux (départ / arrivée) ────────────────────────────────────────
  // Résolus par géocodage inverse. Pour les sorties récentes ils sont déjà dans
  // le Map (calculés à la sauvegarde) ; pour les anciennes on les backfill à
  // l'ouverture puis on les réécrit dans Hive (une seule fois, offline ensuite).
  String? _startCity;
  String? _endCity;

  // ── Recentrage auto ──────────────────────────────────────────────────────────
  bool _recentering = true;
  late List<LatLng> _ridePoints;
  final List<Map<String, dynamic>> _mapStyles = [
    {'label': 'Plan',      'icon': Icons.map,           'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',                                                'subdomains': <String>[],            'maxZoom': 19},
    {'label': 'Satellite', 'icon': Icons.satellite_alt, 'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'subdomains': <String>[],            'maxZoom': 19},
    {'label': 'Topo',      'icon': Icons.terrain,       'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',                                              'subdomains': <String>['a','b','c'], 'maxZoom': 17},
  ];

  // ── Sheet glissant ───────────────────────────────────────────────────────────
  // Plancher historique du mode réduit. La taille réduite réelle (_minSize) est
  // calculée en pixels à chaque build : la carte réduite a une hauteur ~fixe, or
  // 0.32 de l'écran ne suffisait pas sur beaucoup de mobiles → le haut de la
  // carte (pastille « Voir les détails ») était rogné. Voir _computeMinSize.
  static const double _kMinFloor    = 0.32;
  static const double _kInitialSize = 0.50; // « Agrandir » → 50 % carte / 50 % panneau
  static const double _kMaxSize     = 0.95; // tirer plus haut → plein écran
  static const double _kFloorSize   = 0.01;
  double _minSize = _kMinFloor; // recalculé dans build() selon l'écran
  late DraggableScrollableController _sheetController;
  bool _isClosing = false;

  // Taille réduite du panneau, en fraction d'écran, dérivée de la hauteur réelle
  // (px) de l'overlay réduit : pastille + carte flottante (pratique / départ /
  // arrivée / distance / durée). Sensible à la hauteur d'écran ET au facteur de
  // mise à l'échelle du texte (accessibilité) pour ne jamais tronquer le haut.
  double _computeMinSize() {
    final mq = MediaQuery.of(context);
    final ts = mq.textScaler.scale(1.0).clamp(1.0, 1.6);
    // ~110 px fixes (icônes, paddings, séparateurs) + ~150 px de texte qui
    // grandit avec le facteur d'échelle, + la marge système du bas.
    final overlayPx = 110 + 150 * ts + mq.padding.bottom;
    final needed = overlayPx / mq.size.height;
    return needed.clamp(_kMinFloor, 0.44);
  }

  // ── Cheat code debug (5 taps rapides sur la poignée du panneau) ──────────────
  bool _showDebugPanel = false;
  int _debugTapCount = 0;
  DateTime? _lastDebugTap;
  int? _debugStorageBytes;      // octets utilisés sur le Storage (null = pas mesuré)
  int _debugUploadedPhotos = 0; // url != null → déjà sur le Storage
  int _debugPendingPhotos = 0;  // url == null ET fichier local présent → uploadables
  int _debugOrphanPhotos = 0;   // url == null ET fichier local absent → perdues

  // ════════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ════════════════════════════════════════════════════════════════════════════
  @override
  void initState() {
    super.initState();
    rideName = widget.ride['name'] ?? _defaultName();
    rideNote = widget.ride['note'] ?? '';
    _loadMapStyle();
    _ridePoints = (widget.ride['points'] as List)
        .map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()))
        .toList();
    // Noms de lieux : depuis le Map si présents (sorties récentes), sinon
    // backfill par géocodage inverse (anciennes sorties).
    _startCity = _nonEmpty(widget.ride['startCity']) ?? _nonEmpty(widget.ride['city']);
    _endCity = _nonEmpty(widget.ride['endCity']);
    if ((_startCity == null || _endCity == null) && _ridePoints.isNotEmpty) {
      _backfillPlaceNames();
    }
    _sheetController = DraggableScrollableController();
    _sheetController.addListener(_onPanelChanged);
    _sizeAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_ridePoints.isEmpty) return;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      _fitToRoute(panelFraction: _minSize);
    });
  }

  @override
  void dispose() {
    _sizeAnimCtrl.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  // Anime la taille du panneau vers [target] en pilotant jumpTo frame par
  // frame (robuste : rien ne peut interrompre l'animation, contrairement à
  // DraggableScrollableController.animateTo).
  void _animateSheetTo(double target) {
    if (!_sheetController.isAttached) return;
    final begin = _sheetController.size;
    if (_sizeAnimListener != null) {
      _sizeAnimCtrl.removeListener(_sizeAnimListener!);
    }
    _sizeAnimCtrl.stop();
    final anim = _sizeAnimCtrl.drive(
      Tween<double>(begin: begin, end: target)
          .chain(CurveTween(curve: Curves.easeOut)),
    );
    _sizeAnimListener = () {
      if (_sheetController.isAttached) {
        _sheetController.jumpTo(anim.value.clamp(_kFloorSize, _kMaxSize));
      }
    };
    _sizeAnimCtrl.addListener(_sizeAnimListener!);
    _sizeAnimCtrl.forward(from: 0);
  }

  // ════════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ════════════════════════════════════════════════════════════════════════════

  void _onPanelChanged() {
    if (_recentering && _sheetController.isAttached) {
      _fitToRoute(panelFraction: _sheetController.size.clamp(_minSize, _kMaxSize));
    }
    if (_sheetController.isAttached && _sheetController.size < 0.10 && !_isClosing) {
      _isClosing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  void _fitToRoute({double? panelFraction}) {
    if (!mounted || _ridePoints.isEmpty) return;
    final screenH = MediaQuery.of(context).size.height;
    final safeTop = MediaQuery.of(context).padding.top;
    final fraction = panelFraction ??
        (_sheetController.isAttached ? _sheetController.size : _kInitialSize);
    mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(_ridePoints),
        padding: EdgeInsets.fromLTRB(30, safeTop + 80, 30, screenH * fraction + 20),
      ),
    );
  }

  // Renvoie la chaîne si elle est non vide, sinon null.
  String? _nonEmpty(dynamic v) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  // Backfill des noms de lieux pour les sorties qui n'en ont pas (anciennes
  // sorties, ou géocodage raté à la sauvegarde). Résout 1er + dernier point,
  // met à jour l'UI, puis persiste dans Hive + Supabase — une seule fois.
  Future<void> _backfillPlaceNames() async {
    String? start = _startCity;
    String? end = _endCity;
    try {
      if (start == null) {
        final marks = await placemarkFromCoordinates(
            _ridePoints.first.latitude, _ridePoints.first.longitude);
        if (marks.isNotEmpty) start = _nonEmpty(cityFromPlacemark(marks.first));
      }
      if (end == null) {
        // Boucle : départ ≈ arrivée → on réutilise la ville de départ.
        final last = _ridePoints.last;
        final first = _ridePoints.first;
        final sameSpot = (last.latitude - first.latitude).abs() < 1e-4 &&
            (last.longitude - first.longitude).abs() < 1e-4;
        if (sameSpot) {
          end = start;
        } else {
          final marks = await placemarkFromCoordinates(last.latitude, last.longitude);
          if (marks.isNotEmpty) end = _nonEmpty(cityFromPlacemark(marks.first));
        }
      }
    } catch (_) {
      // Hors-ligne / géocodeur indispo : on retentera à la prochaine ouverture.
    }
    if (!mounted) return;
    if (start == _startCity && end == _endCity) return; // rien de neuf
    setState(() {
      _startCity = start;
      _endCity = end;
    });
    // Persistance (seulement ce qu'on a réussi à résoudre).
    if (start == null && end == null) return;
    final updated = Map.from(widget.ride);
    if (start != null) {
      updated['startCity'] = start;
      updated['city'] ??= start;
    }
    if (end != null) updated['endCity'] = end;
    widget.ride['startCity'] = updated['startCity'];
    widget.ride['endCity'] = updated['endCity'];
    widget.ride['city'] = updated['city'];
    await Hive.box('rides').put(widget.rideKey, updated);
    _syncRideToSupabase(updated);
  }

  String _defaultName() {
    final startTime = widget.ride['startTime'];
    if (startTime == null) return 'Sortie';
    final dt = DateTime.tryParse(startTime);
    if (dt == null) return 'Sortie';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateSub() {
    final startTime = widget.ride['startTime'];
    if (startTime == null) return '';
    final dt = DateTime.tryParse(startTime)?.toLocal();
    if (dt == null) return '';
    const months = ['jan.','fév.','mars','avr.','mai','juin','juil.','août','sep.','oct.','nov.','déc.'];
    String dayLabel(DateTime d) => '${kFrDaysShort[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
    String hm(DateTime d) => '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    final startH = hm(dt);
    final endTime = widget.ride['endTime'];
    final dtEnd = endTime != null ? DateTime.tryParse(endTime)?.toLocal() : null;
    if (dtEnd == null) return '${dayLabel(dt)} ${dt.year} | $startH';
    final sameDay = dt.year == dtEnd.year &&
        dt.month == dtEnd.month && dt.day == dtEnd.day;
    // Même journée (cas courant) : « dim. 5 juil. 2026 | 09:38 - 11:04 ».
    if (sameDay) return '${dayLabel(dt)} ${dt.year} | $startH - ${hm(dtEnd)}';
    // Sortie à cheval sur deux dates (rando de nuit) : on montre les deux jours.
    return '${dayLabel(dt)} $startH → ${dayLabel(dtEnd)} ${hm(dtEnd)}';
  }

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_prefKeyMapStyle) ?? 0;
    if (mounted) setState(() => _mapStyleIndex = saved.clamp(0, _mapStyles.length - 1));
  }

  Future<void> _saveMapStyle(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyMapStyle, index);
  }

  // ── Formatters ───────────────────────────────────────────────────────────────
  String _formatTimeOnly(dynamic isoString) {
    if (isoString == null) return '--:--';
    final dt = DateTime.tryParse(isoString)?.toLocal();
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDistance(dynamic meters) {
    final d = (meters ?? 0).toDouble();
    if (d < 1000) return '${d.toStringAsFixed(0)} m';
    return '${(d / 1000).toStringAsFixed(2)} km';
  }

  String _formatDuration(dynamic seconds) {
    final duration = Duration(seconds: seconds ?? 0);
    final h = duration.inHours.toString().padLeft(2, '0');
    final m = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatAvgSpeed(dynamic meters, dynamic seconds) {
    final d = (meters ?? 0).toDouble();
    final s = (seconds ?? 0).toDouble();
    if (s <= 0) return '--';
    return '${((d / 1000) / (s / 3600)).toStringAsFixed(1)} km/h';
  }

  List<double> _buildSpeedProfile() {
    final pts = widget.ride['points'] as List;
    if (pts.length < 2) return [];

    // Si les points ont un champ speed (m/s), on l'utilise directement
    if (pts.first['speed'] != null) {
      return pts.map((p) {
        final s = (p['speed'] as num?)?.toDouble();
        if (s == null) return null;
        final kmh = s * 3.6;
        return (kmh >= 0 && kmh < 200) ? kmh : null;
      }).whereType<double>().toList();
    }

    // Construire la liste de timestamps par point
    List<DateTime?> times;
    final firstTimeRaw = pts.first['time'] ?? pts.first['timestamp'];
    if (firstTimeRaw != null) {
      // Les points ont un champ time ou timestamp
      times = pts.map((p) {
        final t = (p['time'] ?? p['timestamp']) as String?;
        return t != null ? DateTime.tryParse(t) : null;
      }).toList();
    } else {
      // Pas de timestamp par point : on interpole depuis startTime + durationSeconds
      final startStr = widget.ride['startTime'] as String?;
      final totalSec = (widget.ride['durationSeconds'] as num?)?.toDouble() ?? 0;
      if (startStr == null || totalSec <= 0) return [];
      final start = DateTime.tryParse(startStr);
      if (start == null) return [];
      final intervalMs = (totalSec * 1000) / (pts.length - 1);
      times = List.generate(pts.length,
        (i) => start.add(Duration(milliseconds: (i * intervalMs).round())));
    }

    // Calculer la vitesse entre points consécutifs (haversine)
    final speeds = <double>[];
    for (int i = 1; i < pts.length; i++) {
      final t1 = times[i - 1];
      final t2 = times[i];
      if (t1 == null || t2 == null) continue;
      final dtS = t2.difference(t1).inSeconds.toDouble();
      if (dtS <= 0) continue;
      final lat1 = (pts[i - 1]['lat'] as num).toDouble();
      final lon1 = (pts[i - 1]['lng'] as num).toDouble();
      final lat2 = (pts[i]['lat'] as num).toDouble();
      final lon2 = (pts[i]['lng'] as num).toDouble();
      final dLat = (lat2 - lat1) * 111000;
      final dLon = (lon2 - lon1) * 111000 * cos(lat1 * pi / 180);
      final dM   = sqrt(dLat * dLat + dLon * dLon);
      final kmh  = (dM / dtS) * 3.6;
      if (kmh >= 0 && kmh < 200) speeds.add(kmh);
    }
    return speeds;
  }

  String _fmtCompactTime(int seconds) {
    final d = Duration(seconds: seconds);
    if (d.inHours > 0) {
      return '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _formatWaypointTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ── Gradient tracé ───────────────────────────────────────────────────────────
  List<Color> _buildGradientColors(int count) {
    const colors = [Color(0xFFFF8A00), Color(0xFFD946EF), Color(0xFF6D28D9)];
    if (count <= 1) return [colors.first];
    return List.generate(count, (i) {
      final t = i / (count - 1);
      if (t <= 0.5) return Color.lerp(colors[0], colors[1], t / 0.5)!;
      return Color.lerp(colors[1], colors[2], (t - 0.5) / 0.5)!;
    });
  }

  // ── Profil altimétrique ──────────────────────────────────────────────────────
  List<double> _buildAltitudeProfile() {
    final pointsData = widget.ride['points'] as List;
    return pointsData
        .map((p) => (p['alt'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
  }

  // ════════════════════════════════════════════════════════════════════════════
  // MODALS
  // ════════════════════════════════════════════════════════════════════════════
  Future<void> _showEditModal({bool focusNote = false}) async {
    final nameController = TextEditingController(text: rideName);
    final noteController = TextEditingController(text: rideNote);
    final nameFocus = FocusNode();
    final noteFocus = FocusNode();

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (focusNote) {
            noteFocus.requestFocus();
          } else {
            nameFocus.requestFocus();
          }
        });
        return Padding(
          padding: EdgeInsets.only(
            left: 24, right: 24, top: 24,
            bottom: MediaQuery.of(modalContext).viewInsets.bottom +
                24 +
                MediaQuery.of(modalContext).padding.bottom,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Modifier la sortie',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 24),
            const Text('Nom', style: TextStyle(fontSize: 14, color: Colors.white54)),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              focusNode: nameFocus,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true, fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                hintText: 'Nom de la sortie', hintStyle: const TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
            const SizedBox(height: 8),
            TextField(
              controller: noteController,
              focusNode: noteFocus,
              style: const TextStyle(color: Colors.white),
              maxLines: 4,
              decoration: InputDecoration(
                filled: true, fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                hintText: 'Ajouter une note…', hintStyle: const TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                ),
                onPressed: () async {
                  Navigator.of(modalContext).pop();
                  await _saveEdits(nameController.text.trim(), noteController.text.trim());
                },
                child: const Text('Sauvegarder', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _showNoteEditor() async {
    final controller = TextEditingController(text: rideNote);
    final focusNode  = FocusNode();

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1E22),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) => focusNode.requestFocus());
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom +
                20 +
                MediaQuery.of(ctx).padding.bottom,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.white24,
                borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 18),
            Row(children: [
              const Icon(Icons.notes, color: Color(0xFF60a5fa), size: 18),
              const SizedBox(width: 8),
              const Text('Note',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              maxLines: 6,
              minLines: 3,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF242830),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
                hintText: 'Écris ta note ici…',
                hintStyle: const TextStyle(color: Colors.white30),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    foregroundColor: Colors.white54),
                  child: const Text('Annuler', style: TextStyle(fontSize: 15)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _saveEdits(rideName, controller.text.trim());
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563eb),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: const Text('Enregistrer',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ]),
        );
      },
    );
  }

  Future<void> _saveEdits(String newName, String newNote) async {
    final box = Hive.box('rides');
    final updatedRide = Map.from(widget.ride);
    updatedRide['name'] = newName.isEmpty ? _defaultName() : newName;
    updatedRide['note'] = newNote;
    await box.put(widget.rideKey, updatedRide);
    setState(() {
      rideName = updatedRide['name'];
      rideNote = updatedRide['note'];
    });
    _syncRideToSupabase(updatedRide);
  }

  Future<void> _deletePhotoFromWaypoint(Map wp, dynamic photoEntry) async {
    final local = photoLocalPath(photoEntry);
    final url = photoUrl(photoEntry);
    // Retire l'entrée en reconstruisant une nouvelle liste (robuste même si la
    // liste d'origine est non-modifiable, ex. sortie restaurée depuis JSON).
    final current = (wp['photos'] as List?) ?? const [];
    wp['photos'] = current
        .where((e) => !(identical(e, photoEntry) ||
            (photoLocalPath(e) == local && photoUrl(e) == url)))
        .toList();
    // Rafraîchit l'UI tout de suite : la croix ne doit jamais attendre le réseau.
    await Hive.box('rides').put(widget.rideKey, widget.ride);
    if (mounted) setState(() {});
    _syncRideToSupabase(widget.ride);
    // Nettoyage disque + Storage en arrière-plan (non bloquant).
    () async {
      if (local != null) { try { await File(local).delete(); } catch (_) {} }
      if (url != null) { try { await deletePhotoRemote(url); } catch (_) {} }
    }();
  }

  void _syncRideToSupabase(Map ride) async {
    final startedAt = ride['startTime'] as String?;
    final userId    = Supabase.instance.client.auth.currentUser?.id;
    if (startedAt == null || userId == null) return;
    try {
      await Supabase.instance.client.from('rides').upsert(
        {'user_id': userId, 'started_at': startedAt, 'ride_json': ride},
        onConflict: 'user_id,started_at',
      );
      final sessionId = ride['safetySessionId'];
      if (sessionId != null) {
        await Supabase.instance.client
            .from('safety_sessions')
            .update({'ride_json': ride})
            .eq('id', sessionId);
      }
    } catch (e) {
      debugPrint('[SUPABASE] sync ride: $e');
    }
  }

  // Ouvre une photo de waypoint en plein écran avec zoom + bouton Supprimer.
  Future<void> _openWaypointPhotoViewer({
    required dynamic entry,
    required VoidCallback onDelete,
  }) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dctx) => Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: photoWidget(entry, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(dctx).padding.top + 12,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.of(dctx).pop(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close, color: Colors.white, size: 22),
              ),
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(dctx).padding.bottom + 28,
            left: 0, right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  Navigator.of(dctx).pop();
                  onDelete();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('Supprimer la photo',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Popup waypoint ───────────────────────────────────────────────────────────
  void _showWaypointPopup(BuildContext context, Map wp, {int? number}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final photos = (wp['photos'] as List?)?.toList() ?? [];
          return Padding(
            padding: EdgeInsets.fromLTRB(
                24, 24, 24, 24 + MediaQuery.of(ctx).padding.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                // Pastille numérotée (raccord avec le pin sur la carte), repli
                // sur l'icône si le rang est inconnu.
                if (number != null)
                  Container(
                    width: 24, height: 24,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Colors.blue, shape: BoxShape.circle),
                    child: Text('$number',
                      style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800, height: 1)),
                  )
                else
                  const Icon(Icons.place, color: Colors.blue, size: 22),
                const SizedBox(width: 10),
                Text('Point mémorisé — ${_formatWaypointTime(wp['timestamp'])}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ]),
              const SizedBox(height: 12),
              if ((wp['note'] ?? '').toString().isNotEmpty)
                Text(wp['note'], style: const TextStyle(fontSize: 15, color: Colors.white70))
              else
                const Text('Aucune note', style: TextStyle(fontSize: 15, color: Colors.white38, fontStyle: FontStyle.italic)),
              if (photos.isNotEmpty) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      final entry = photos[index];
                      // Tap → visualiseur plein écran (avec bouton Supprimer).
                      // Plus de croix sur la vignette : trop petite à viser.
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => _openWaypointPhotoViewer(
                            entry: entry,
                            onDelete: () async {
                              await _deletePhotoFromWaypoint(wp, entry);
                              setSheetState(() {});
                            },
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: photoWidget(entry, width: 120, height: 120),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Lat: ${wp['lat'].toStringAsFixed(6)}  Long: ${wp['lng'].toStringAsFixed(6)}',
                style: const TextStyle(fontSize: 12, color: Colors.white38)),
              const SizedBox(height: 8),
            ]),
          );
        },
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // CARTE
  // ════════════════════════════════════════════════════════════════════════════

  // Barycentre du tracé (moyenne lat/lng), calculé une fois. Sert à décaler les
  // pins de waypoint vers l'EXTÉRIEUR : pour une boucle, le barycentre est à
  // l'intérieur → le pin part dehors et ne recouvre jamais la trace.
  double? _traceMeanLat, _traceMeanLng;
  void _ensureTraceCentroid() {
    if (_traceMeanLat != null) return;
    if (_ridePoints.isEmpty) { _traceMeanLat = 0; _traceMeanLng = 0; return; }
    var sLat = 0.0, sLng = 0.0;
    for (final p in _ridePoints) { sLat += p.latitude; sLng += p.longitude; }
    _traceMeanLat = sLat / _ridePoints.length;
    _traceMeanLng = sLng / _ridePoints.length;
  }

  /// Direction unitaire (repère écran) PERPENDICULAIRE à la trace au niveau du
  /// waypoint [at]. Le pin est décalé sur le côté de la trace, du côté qui pointe
  /// vers l'EXTÉRIEUR (loin du barycentre) : sur une boucle, le pin sort donc de
  /// la boucle au lieu de tomber dedans. Repli sur un biais « vers le haut »
  /// (sinon vers la droite) quand le waypoint est ~au centre du tracé.
  Offset _leaderDirection(LatLng at) {
    final trace = _ridePoints;
    if (trace.length < 2) return const Offset(0, -1);
    var nearest = 0;
    var best = double.infinity;
    for (var i = 0; i < trace.length; i++) {
      final dLat = trace[i].latitude - at.latitude;
      final dLng = trace[i].longitude - at.longitude;
      final d = dLat * dLat + dLng * dLng;
      if (d < best) { best = d; nearest = i; }
    }
    final a = trace[max(0, nearest - 2)];
    final b = trace[min(trace.length - 1, nearest + 2)];
    final latRad = at.latitude * pi / 180;
    final cosLat = cos(latRad);
    // Tangente en repère écran (mercator local) : x ∝ Δlng·cos(lat), y ∝ -Δlat.
    final tx = (b.longitude - a.longitude) * cosLat;
    final ty = -(b.latitude - a.latitude);
    final tlen = sqrt(tx * tx + ty * ty);
    if (tlen < 1e-12) return const Offset(0, -1);
    var px = -ty / tlen; // perpendiculaire = tangente tournée de 90°
    var py = tx / tlen;
    // Vecteur « vers l'extérieur » = du barycentre vers le waypoint (repère écran).
    _ensureTraceCentroid();
    final outX = (at.longitude - _traceMeanLng!) * cosLat;
    final outY = -(at.latitude - _traceMeanLat!);
    if (outX * outX + outY * outY > 1e-12) {
      // Choisit la perpendiculaire du même côté que l'extérieur.
      if (px * outX + py * outY < 0) { px = -px; py = -py; }
    } else {
      // Waypoint ~au barycentre : repli sur le biais historique.
      if (py > 1e-6) { px = -px; py = -py; } // vers le haut
      else if (py.abs() <= 1e-6 && px < 0) { px = -px; } // sinon vers la droite
    }
    return Offset(px, py);
  }

  /// Marker waypoint : pin flottant numéroté décalé perpendiculairement à la
  /// trace, relié par une fine ligne à un point posé sur sa vraie position GPS.
  /// La boîte est centrée sur la coordonnée (alignment center) et assez grande
  /// pour contenir le décalage dans n'importe quelle direction. Seul le pin est
  /// cliquable (ouvre le popup) : le reste de la boîte laisse passer les taps.
  Marker _waypointMarker(Map wp, int number) {
    const color = Color(0xFF2563EB); // bleu soutenu, bon contraste avec le blanc
    const lead = 30.0;   // longueur du trait de rappel (px écran)
    const box = 120.0;
    const badge = 30.0;  // diamètre de la pastille numérotée
    final at = LatLng((wp['lat'] as num).toDouble(), (wp['lng'] as num).toDouble());
    final dir = _leaderDirection(at);
    final tip = Offset(dir.dx * lead, dir.dy * lead);
    final angle = atan2(tip.dy, tip.dx);
    // RepaintBoundary : isole le marqueur dans sa propre couche de composition.
    // Combiné au trait de rappel dessiné en widget (et non plus en CustomPaint),
    // ça supprime le « fantôme » gris qu'Impeller laissait à l'ancienne position
    // du marqueur quand la caméra se recalait (ouverture + drag du panneau).
    return Marker(
      point: at,
      width: box,
      height: box,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Trait de rappel : du point GPS (centre) vers la pastille.
            Transform.translate(
              offset: Offset(tip.dx / 2, tip.dy / 2),
              child: Transform.rotate(
                angle: angle,
                child: Container(
                  width: lead, height: 2,
                  decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(1)),
                ),
              ),
            ),
            // Point posé sur la trace = vraie position GPS du waypoint.
            Container(
              width: 9, height: 9,
              decoration: BoxDecoration(
                color: color, shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
            // Pastille ronde numérotée, déportée au bout du trait. Chiffre gros
            // et centré → nettement plus lisible que le petit numéro logé dans
            // la tête d'une goutte location_on.
            Transform.translate(
              offset: tip,
              child: GestureDetector(
                onTap: () => _showWaypointPopup(context, wp, number: number),
                child: Container(
                  width: badge, height: badge,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color, shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 4),
                    ],
                  ),
                  child: Text('$number',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: number >= 10 ? 13 : 16,
                      fontWeight: FontWeight.w800, height: 1),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlutterMap(List<LatLng> ridePoints, List<Map> waypointsData, List<Color> gradientColors) {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: ridePoints.isNotEmpty ? ridePoints.first : const LatLng(48.8566, 2.3522),
        initialZoom: 13,
        onTap: (tapPos, latLng) {
          if (_sheetController.isAttached && _sheetController.size > _minSize + 0.02) {
            _animateSheetTo(_minSize);
          }
        },
      ),
      children: [
        TileLayer(
          key: ValueKey(_mapStyleIndex),
          urlTemplate: _mapStyles[_mapStyleIndex]['url'] as String,
          subdomains: _mapStyles[_mapStyleIndex]['subdomains'] as List<String>,
          maxZoom: (_mapStyles[_mapStyleIndex]['maxZoom'] as int).toDouble(),
          userAgentPackageName: 'com.example.sunday_tracker',
        ),
        if (ridePoints.length >= 2)
          PolylineLayer(
            polylines: List.generate(ridePoints.length - 1, (i) => Polyline(
              points: [ridePoints[i], ridePoints[i + 1]],
              strokeWidth: 5,
              color: gradientColors[i],
            )),
          ),
        if (ridePoints.isNotEmpty)
          MarkerLayer(markers: [
            Marker(
              point: ridePoints.first, width: 22, height: 22,
              child: Container(decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25), shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFFF8A00), width: 2),
                boxShadow: [BoxShadow(color: const Color(0xFFFF8A00).withValues(alpha: 0.85), blurRadius: 8)],
              )),
            ),
            Marker(
              point: ridePoints.last, width: 26, height: 26,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25), shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF6D28D9), width: 2),
                  boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.85), blurRadius: 8)],
                ),
                child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 22),
              ),
            ),
            // Waypoints dessinés en DERNIER (au-dessus des markers départ /
            // arrivée). Chaque WP est un pin flottant numéroté décalé
            // PERPENDICULAIREMENT à la trace, relié par une fine ligne à un point
            // posé sur sa vraie position GPS — évite toute superposition avec les
            // markers structurels, même pour un WP proche de l'arrivée.
            for (final (i, wp) in waypointsData.indexed)
              _waypointMarker(wp, i + 1),
          ]),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // TOP BAR FLOTTANTE
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildTopBar() {
    const double barH = 54;
    return SizedBox(
      height: barH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _floatingBtn(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: _showEditModal,
              behavior: HitTestBehavior.opaque,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rideName,
                          style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
                            letterSpacing: -0.4,
                          ),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(_formatDateSub(),
                          style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.65)),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _floatingBtn(
            onTap: _showShareSheet,
            width: 52,
            child: const Icon(Icons.ios_share, size: 22, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _floatingBtn({required VoidCallback onTap, required Widget child, double width = 44}) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            width: width,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // CONTRÔLES CARTE — bouton primaire + groupe sombre (style mockup)
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildMapControls(List<LatLng> ridePoints) {
    // Tout dans un seul container — boutons collés, taille compacte
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: 46,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Recentrer — fond bleu dans le groupe
              GestureDetector(
                onTap: () {
                  setState(() => _recentering = !_recentering);
                  if (_recentering) _fitToRoute();
                },
                child: SizedBox(
                  width: 46, height: 46,
                  child: Center(
                    child: Icon(
                      Icons.my_location,
                      color: _recentering ? const Color(0xFF2da8ff) : Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
              // Séparateur
              Container(height: 1, color: Colors.white.withValues(alpha: 0.09)),
              // Calques — cycle entre les styles de fond
              GestureDetector(
                onTap: () {
                  final next = (_mapStyleIndex + 1) % _mapStyles.length;
                  setState(() => _mapStyleIndex = next);
                  _saveMapStyle(next);
                },
                child: SizedBox(
                  width: 46, height: 46,
                  child: Center(
                    child: Icon(
                      _mapStyles[_mapStyleIndex]['icon'] as IconData,
                      color: Colors.white, size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PANNEAU GLISSANT
  // ════════════════════════════════════════════════════════════════════════════
  Widget _buildSheetContent(
    ScrollController scrollController,
    List<double> altProfile,
    List<Map> waypointsData,
    bool hasWeather,
    List<LatLng> ridePoints,
  ) {
    const panelColor = Color(0xF2111416);
    const decoration = BoxDecoration(
      color: panelColor,
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(28),
        topRight: Radius.circular(28),
      ),
    );

    // Cartes détaillées (mode étendu).
    final detailCards = <Widget>[
      _buildElevChartCard(altProfile),
      const SizedBox(height: 10),
      _buildSpeedCard(),
      const SizedBox(height: 10),
      if (hasWeather) ...[
        _buildWeatherCard(),
        const SizedBox(height: 10),
      ],
      Container(height: 1, color: Colors.white.withValues(alpha: 0.07)),
      const SizedBox(height: 14),
      _buildPassagePoints(waypointsData),
      const SizedBox(height: 10),
      _buildNoteCard(),
      const SizedBox(height: 14),
      _buildDeleteBtn(),
    ];

    return AnimatedBuilder(
      animation: _sheetController,
      builder: (context, _) {
        final isReduced = !_sheetController.isAttached ||
            _sheetController.size < _minSize + 0.05;

        void toggle() {
          _animateSheetTo(isReduced ? _kInitialSize : _minSize);
        }

        // En-tête étendu : poignée + titre + date + statut « Terminée »
        // + mini-bande.
        Widget expandedHeader() => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Poignée — cheat code : 5 taps rapides → panneau debug sortie
                GestureDetector(
                  onTap: _onDebugTap,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 44),
                    child: Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: _showEditModal,
                              behavior: HitTestBehavior.opaque,
                              child: Text(
                                rideName,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: -0.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _buildPracticeAndEndpointsRow(),
                ),
                const SizedBox(height: 14),
                _buildMiniStrip(),
                const SizedBox(height: 12),
              ],
            );

        // IMPORTANT : la structure des slivers est IDENTIQUE dans les deux
        // modes (mêmes dimensions de scroll). Sinon, changer le contenu à
        // mi-course interrompt l'animation du sheet → animateTo(0.5) se bloque.
        // Le look réduit est obtenu par opacité (contenu masqué) + un overlay
        // flottant, sans jamais toucher aux slivers.
        return Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: isReduced ? null : decoration,
                child: CustomScrollView(
                  controller: scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverOpacity(
                      opacity: isReduced ? 0.0 : 1.0,
                      sliver: SliverToBoxAdapter(child: expandedHeader()),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                          14, 10, 14,
                          40 + MediaQuery.of(context).padding.bottom),
                      sliver: SliverOpacity(
                        opacity: isReduced ? 0.0 : 1.0,
                        sliver: SliverList(
                          delegate: SliverChildListDelegate(detailCards),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Overlay flottant en mode réduit : pastille + card ancrées en bas.
            // Les GestureDetector sont en onTap seul → le drag vertical traverse
            // jusqu'au scroll dessous, qui redimensionne le sheet.
            if (isReduced)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: toggle,
                      behavior: HitTestBehavior.opaque,
                      child: _buildReducedCard(),
                    ),
                    SizedBox(height: 8 + MediaQuery.of(context).padding.bottom),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  // ── Carte réduite enrichie (flottante) ───────────────────────────────────────
  // En-tête pratique + « Départ → Arrivée » + badge, puis mini-bande stats.
  Widget _buildReducedCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 10),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Poignée incrustée en haut du panneau (même style qu'agrandi).
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Ligne du haut : pavé pratique à gauche, Départ / Arrivée à droite
            _buildPracticeAndEndpointsRow(),
            const SizedBox(height: 10),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
            const SizedBox(height: 4),
            // Ligne du bas : Distance / Durée (icônes + valeurs plus grosses)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _miniStat(Icons.route_outlined, const Color(0xFFfb923c),
                    _formatDistance(widget.ride['distanceMeters']), 'Distance',
                    iconSize: 28, valueSize: 30),
                  Container(width: 1, color: Colors.white.withValues(alpha: 0.10)),
                  _miniStat(Icons.timer_outlined, const Color(0xFF4ade80),
                    _formatDuration(widget.ride['durationSeconds']), 'Durée',
                    iconSize: 28, valueSize: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Ligne partagée (réduit + étendu) : pavé pratique à gauche, Départ / Arrivée
  // (date-heure) à droite.
  Widget _buildPracticeAndEndpointsRow() {
    // Sortie « d'un jour » (cas courant) → heure seule ; sortie à cheval sur
    // deux dates (rando de nuit) → on préfixe le jour+mois pour lever l'ambiguïté.
    final startDt = DateTime.tryParse('${widget.ride['startTime']}')?.toLocal();
    final endDt   = DateTime.tryParse('${widget.ride['endTime']}')?.toLocal();
    final sameDay = startDt == null || endDt == null ||
        (startDt.year == endDt.year &&
            startDt.month == endDt.month &&
            startDt.day == endDt.day);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Un peu plus de place à droite quand on doit aussi afficher la date.
        Expanded(flex: sameDay ? 6 : 5, child: _buildPracticeHeader()),
        const SizedBox(width: 10),
        Expanded(
          flex: sameDay ? 4 : 5,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Couleurs raccord avec les marqueurs du tracé :
              // départ = orange, arrivée = violet.
              _endpointRow(
                Icons.schedule, const Color(0xFFfb923c), 'Départ',
                _formatEndpointTime(widget.ride['startTime'], showDate: !sameDay, showSeconds: true)),
              const SizedBox(height: 10),
              _endpointRow(
                Icons.sports_score, const Color(0xFFa78bfa), 'Arrivée',
                _formatEndpointTime(widget.ride['endTime'], showDate: !sameDay, showSeconds: true)),
            ],
          ),
        ),
      ],
    );
  }

  // Une ligne « Départ / Arrivée » : icône + libellé + date-heure.
  Widget _endpointRow(IconData icon, Color color, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 22, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9aa4ad))),
              const SizedBox(height: 1),
              Text(value,
                style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }

  // Heure de départ/arrivée. « 07:58 » en journée ; « 5 juil. · 07:58 » quand
  // la sortie chevauche deux dates (rando de nuit), pour ne pas perdre le jour.
  // [showSeconds] ajoute les secondes (HH:MM:SS) pour une lecture précise des
  // heures de départ / arrivée (raccord avec le cockpit du live).
  String _formatEndpointTime(dynamic iso, {required bool showDate, bool showSeconds = false}) {
    if (iso == null) return '--';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '--';
    var h = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (showSeconds) h = '$h:${dt.second.toString().padLeft(2, '0')}';
    if (!showDate) return h;
    const months = ['jan.','fév.','mars','avr.','mai','juin','juil.','août','sep.','oct.','nov.','déc.'];
    return '${dt.day} ${months[dt.month - 1]} · $h';
  }

  // En-tête pratique : une seule puce (icône + label) + itinéraire.
  // Partagé entre la carte réduite et le header étendu.
  Widget _buildPracticeHeader() {
    final practiceKey = _nonEmpty(widget.ride['practice']) ?? detectPractice(widget.ride);
    final practice = kPracticeTypes[practiceKey] ?? kPracticeTypes['vtt']!;
    final Color pColor = practice['color'] as Color;
    final IconData pIcon = practice['icon'] as IconData;
    final String pLabel = practice['label'] as String;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Puce unique icône + label (avant : pastille ronde + badge = doublon).
        Container(
          padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
          decoration: BoxDecoration(
            color: pColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: pColor.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(pIcon, color: pColor, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(pLabel,
                  style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: pColor),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildRouteLine(),
      ],
    );
  }

  // Ligne « Départ → Arrivée ». Affiche un placeholder discret tant que le
  // géocodage n'a pas résolu les noms.
  Widget _buildRouteLine() {
    final start = _startCity;
    final end = _endCity;
    if (start == null && end == null) {
      return Text('Localisation…',
        style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.5)),
        maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    // Un seul côté résolu (géocodage partiel) → un seul nom.
    if (start == null || end == null) {
      return Text(start ?? end!,
        style: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
          letterSpacing: -0.3),
        maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    // Départ + arrivée résolus → « A → B » (y compris boucle « A → A »).
    return Row(children: [
      Flexible(
        child: Text(start,
          style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
            letterSpacing: -0.3),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(Icons.arrow_forward, size: 15, color: Colors.white.withValues(alpha: 0.6)),
      ),
      Flexible(
        child: Text(end,
          style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
            letterSpacing: -0.3),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ]);
  }

  // ── Mini bande stats ─────────────────────────────────────────────────────────
  Widget _buildMiniStrip({bool floating = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(floating ? 12 : 14, 0, floating ? 12 : 14, 0),
      child: Container(
        decoration: BoxDecoration(
          // Réduit (flottant sur la carte) : fond sombre translucide + ombre.
          // Étendu (dans le panneau) : léger voile blanc.
          color: floating
              ? Colors.black.withValues(alpha: 0.72)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: floating
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Row(children: [
          _miniStat(Icons.route_outlined, const Color(0xFFfb923c),
            _formatDistance(widget.ride['distanceMeters']), 'Distance'),
          Container(width: 1, height: 48, color: Colors.white.withValues(alpha: 0.10)),
          _miniStat(Icons.timer_outlined, const Color(0xFF4ade80),
            _formatDuration(widget.ride['durationSeconds']), 'Durée'),
        ]),
      ),
    );
  }

  Widget _miniStat(IconData icon, Color color, String value, String label,
      {int flex = 1, double valueSize = 24, double iconSize = 22}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: iconSize, color: color),
            const SizedBox(height: 3),
            Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
              textAlign: TextAlign.center),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                style: TextStyle(fontSize: valueSize, fontWeight: FontWeight.w700, color: color,
                    letterSpacing: -0.5, height: 1.0)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Carte dénivelé avec graphe ───────────────────────────────────────────────
  Widget _buildElevChartCard(List<double> altProfile) {
    final dPlus    = (widget.ride['totalElevationMeters'] as num?)?.toDouble() ?? 0;
    final dMinus   = (widget.ride['totalElevationDown']   as num?)?.toDouble() ?? 0;
    final altStart = (widget.ride['altitudeStart']        as num?)?.toDouble();
    final altEnd   = (widget.ride['altitudeEnd']          as num?)?.toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF171B1F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.trending_up, size: 15, color: Color(0xFFfb923c)),
          const SizedBox(width: 7),
          const Text('Dénivelé',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
        ]),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SizedBox(
                height: 180,
                child: altProfile.length >= 2
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _buildElevationProfile(altProfile, altStart: altStart, altEnd: altEnd),
                    )
                  : Center(
                      child: Text('Pas de données altitude',
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.30))),
                    ),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _elevStatItem('+${dPlus.toStringAsFixed(0)} m',  'D+', const Color(0xFFfb923c)),
                const SizedBox(height: 20),
                _elevStatItem('−${dMinus.toStringAsFixed(0)} m', 'D−', const Color(0xFFa78bfa)),
              ],
            ),
          ],
        ),
      ]),
    );
  }

  Widget _elevStatItem(String value, String label, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.5)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
    ]);
  }

  // ── Profil altimétrique (CustomPaint) ────────────────────────────────────────
  Widget _buildElevationProfile(List<double> alts, {double? altStart, double? altEnd}) {
    if (alts.length < 2) return const SizedBox.shrink();
    return ColoredBox(
      color: const Color(0xFF111111),
      child: CustomPaint(
        painter: _AltitudeProfilePainter(alts, altStart: altStart, altEnd: altEnd),
        child: const SizedBox.expand(),
      ),
    );
  }

  // ── Section Vitesse ──────────────────────────────────────────────────────────
  Widget _buildSpeedCard() {
    final totalSec  = (widget.ride['durationSeconds']   as num?)?.toInt() ?? 0;
    final movingSec = (widget.ride['movingTimeSeconds'] as num?)?.toInt() ?? totalSec;
    final stopSec   = (totalSec - movingSec).clamp(0, totalSec);
    final avgSpeed  = _formatAvgSpeed(widget.ride['distanceMeters'], widget.ride['durationSeconds']);

    final speedPts  = _buildSpeedProfile();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF171B1F),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Titre
        Row(children: [
          const Icon(Icons.speed_outlined, size: 15, color: Color(0xFF60a5fa)),
          const SizedBox(width: 7),
          const Text('Vitesse',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
        ]),
        const SizedBox(height: 14),
        // KPI + graphe
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('VITESSE MOYENNE',
              style: TextStyle(fontSize: 10, color: Color(0xFF666666), letterSpacing: 0.5)),
            const SizedBox(height: 6),
            Text(avgSpeed,
              style: const TextStyle(
                fontSize: 30, fontWeight: FontWeight.w800,
                color: Color(0xFF60a5fa), letterSpacing: -1)),
          ]),
          const SizedBox(width: 14),
          if (speedPts.length >= 2)
            Expanded(
              child: SizedBox(
                height: 110,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    painter: _SpeedProfilePainter(speedPts),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        // Barre temps
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(children: [
            Expanded(
              flex: movingSec.clamp(1, totalSec),
              child: Container(height: 6, color: const Color(0xFF60a5fa))),
            if (stopSec > 0)
              Expanded(
                flex: stopSec,
                child: Container(height: 6, color: const Color(0xFF252525))),
          ]),
        ),
        const SizedBox(height: 8),
        // Légende
        Row(children: [
          Text(_fmtCompactTime(movingSec),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF60a5fa))),
          const SizedBox(width: 5),
          const Text('en mouvement',
            style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
          const SizedBox(width: 10),
          Container(width: 1, height: 14, color: const Color(0xFF444444)),
          const SizedBox(width: 10),
          Text(_fmtCompactTime(stopSec),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFaabbcc))),
          const SizedBox(width: 5),
          const Text('arrêté',
            style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
        ]),
      ]),
    );
  }


  // ── Météo ────────────────────────────────────────────────────────────────────
  Widget _buildWeatherCard() {
    final wStart = widget.ride['weatherStart'] as Map?;
    final wEnd   = widget.ride['weatherEnd']   as Map?;
    if (wStart == null && wEnd == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF171B1F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.wb_sunny_outlined, color: Color(0xFFfbbf24), size: 13),
          const SizedBox(width: 6),
          const Text('Météo', style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
        ]),
        const SizedBox(height: 12),
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wStart != null)
            Expanded(child: _weatherCol(wStart, 'Au départ',   _formatTimeOnly(widget.ride['startTime']), const Color(0xFFFF8A00))),
          if (wStart != null && wEnd != null)
            Container(width: 1, color: const Color(0xFF222222), margin: const EdgeInsets.symmetric(horizontal: 12)),
          if (wEnd != null)
            Expanded(child: _weatherCol(wEnd, "À l'arrivée", _formatTimeOnly(widget.ride['endTime']), const Color(0xFF6D28D9))),
        ])),
      ]),
    );
  }

  Widget _weatherCol(Map w, String title, String time, Color accentColor) {
    final temp     = (w['temp']     as num?)?.toStringAsFixed(0) ?? '--';
    final wind     = (w['wind']     as num?)?.toStringAsFixed(0) ?? '--';
    final windDir  = (w['windDir']  as String?) ?? '';
    final humidity = (w['humidity'] as num?)?.toInt();
    final desc     = (w['desc']     as String?) ?? '';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.circle, color: accentColor, size: 7),
        const SizedBox(width: 5),
        Text('$title · $time', style: TextStyle(fontSize: 10, color: accentColor)),
      ]),
      const SizedBox(height: 8),
      Text('$temp°', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: accentColor)),
      const SizedBox(height: 4),
      if (desc.isNotEmpty) Text(desc, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
      const SizedBox(height: 4),
      _weatherRow(Icons.air,              '$wind km/h $windDir'),
      if (humidity != null)
        _weatherRow(Icons.water_drop_outlined, '$humidity% humidité'),
    ]);
  }

  Widget _weatherRow(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Row(children: [
      Icon(icon, size: 11, color: const Color(0xFF555555)),
      const SizedBox(width: 5),
      Flexible(child: Text(text, style: const TextStyle(fontSize: 10, color: Color(0xFF666666)))),
    ]),
  );

  // ── Points de passage ────────────────────────────────────────────────────────
  Widget _buildPassagePoints(List<Map> waypoints) {
    final startTime  = _formatTimeOnly(widget.ride['startTime']);
    final endTime    = _formatTimeOnly(widget.ride['endTime']);
    final pointsData = widget.ride['points'] as List;
    final altStart   = (widget.ride['altitudeStart'] as num?)?.toStringAsFixed(0);
    final altEnd     = (widget.ride['altitudeEnd']   as num?)?.toStringAsFixed(0);

    String? startCoords, endCoords;
    if (pointsData.isNotEmpty) {
      final first = pointsData.first;
      final last  = pointsData.last;
      startCoords = '${(first['lat'] as num).toStringAsFixed(4)}° · ${(first['lng'] as num).toStringAsFixed(4)}°';
      endCoords   = '${(last['lat']  as num).toStringAsFixed(4)}° · ${(last['lng']  as num).toStringAsFixed(4)}°';
    }

    final items = <_PassageItem>[
      _PassageItem(type: _PassageType.start, time: startTime, coords: startCoords, altitude: altStart != null ? '$altStart m' : null),
      ...waypoints.indexed.map((e) => _PassageItem(
        type: _PassageType.waypoint,
        time: _formatWaypointTime(e.$2['timestamp']),
        note: (e.$2['note'] as String?)?.trim(),
        photos: (e.$2['photos'] as List?)?.toList() ?? [],
        wp: e.$2,
        number: e.$1 + 1,
      )),
      _PassageItem(type: _PassageType.end, time: endTime, coords: endCoords, altitude: altEnd != null ? '$altEnd m' : null),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF171B1F),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.route, color: Color(0xFF60a5fa), size: 13),
          const SizedBox(width: 6),
          const Text('Points de passage', style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
          const SizedBox(width: 6),
          Text('· ${items.length}', style: const TextStyle(fontSize: 11, color: Color(0xFF444444))),
        ]),
        const SizedBox(height: 12),
        ...items.asMap().entries.map((e) => _buildPassageItem(e.value, e.key == items.length - 1)),
      ]),
    );
  }

  Widget _buildPassageItem(_PassageItem item, bool isLast) {
    Color dotColor;
    Widget dotChild;
    String title;

    switch (item.type) {
      case _PassageType.start:
        dotColor = const Color(0xFFFF8A00);
        dotChild = const Icon(Icons.play_arrow_rounded, size: 12, color: Color(0xFFFF8A00));
        title    = 'Départ';
        break;
      case _PassageType.end:
        dotColor = const Color(0xFF6D28D9);
        dotChild = const Icon(Icons.sports_score_sharp, size: 12, color: Color(0xFF6D28D9));
        title    = 'Arrivée';
        break;
      case _PassageType.waypoint:
        dotColor = const Color(0xFF60a5fa);
        // Numéro du waypoint (raccord avec le pin numéroté sur la carte),
        // repli sur l'icône si le rang est indisponible.
        dotChild = item.number != null
            ? Text('${item.number}',
                style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF60a5fa), height: 1))
            : const Icon(Icons.place, size: 12, color: Color(0xFF60a5fa));
        title    = 'Point mémorisé';
        break;
    }

    return GestureDetector(
      onTap: item.type == _PassageType.waypoint && item.wp != null
          ? () => _showWaypointPopup(context, item.wp!, number: item.number)
          : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 28, child: Column(children: [
          Container(
            width: 26, height: 26,
            decoration: BoxDecoration(
              color: dotColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: dotColor, width: 1.5),
            ),
            child: Center(child: dotChild),
          ),
          if (!isLast) Container(width: 1.5, height: 32, color: const Color(0xFF252525)),
        ])),
        const SizedBox(width: 10),
        Expanded(child: Padding(
          padding: EdgeInsets.only(bottom: isLast ? 8 : 0, top: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              Text(item.time, style: const TextStyle(fontSize: 11, color: Color(0xFF555555))),
            ]),
            if (item.coords != null)
              Padding(padding: const EdgeInsets.only(top: 2),
                child: Text(item.coords!, style: const TextStyle(fontSize: 10, color: Color(0xFF555555)))),
            if (item.altitude != null)
              Padding(padding: const EdgeInsets.only(top: 1),
                child: Text('Altitude : ${item.altitude}', style: const TextStyle(fontSize: 10, color: Color(0xFF555555)))),
            if (item.note != null && item.note!.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 3),
                child: Text(item.note!, style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
                  maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (item.photos != null && item.photos!.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(height: 50, child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: item.photos!.length,
                itemBuilder: (ctx, i) {
                  final entry = item.photos![i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Stack(children: [
                      GestureDetector(
                        onTap: () => showDialog(context: context, builder: (_) => Dialog(
                          backgroundColor: Colors.black,
                          child: InteractiveViewer(child: photoWidget(entry, fit: BoxFit.contain)),
                        )),
                        child: ClipRRect(borderRadius: BorderRadius.circular(7),
                          child: photoWidget(entry, width: 50, height: 50)),
                      ),
                      Positioned(top: 2, right: 2,
                        child: GestureDetector(
                          onTap: () => _deletePhotoFromWaypoint(item.wp!, entry),
                          child: Container(
                            width: 16, height: 16,
                            decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 10, color: Colors.white),
                          ),
                        ),
                      ),
                    ]),
                  );
                },
              )),
            ],
            if (!isLast) const SizedBox(height: 6),
          ]),
        )),
      ]),
    );
  }

  // ── Note ─────────────────────────────────────────────────────────────────────
  Widget _buildNoteCard() {
    final hasNote = rideNote.isNotEmpty;
    return GestureDetector(
      onTap: _showNoteEditor,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF171B1F),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasNote
                ? Colors.white.withValues(alpha: 0.07)
                : const Color(0xFF2563eb).withValues(alpha: 0.22)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
            hasNote ? Icons.notes : Icons.add_circle_outline_rounded,
            color: hasNote ? Colors.white38 : const Color(0xFF60a5fa),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: hasNote
                ? Text(rideNote,
                    style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.45),
                    maxLines: 3, overflow: TextOverflow.ellipsis)
                : const Text('Ajouter une note à cette sortie…',
                    style: TextStyle(
                      color: Color(0xFF4d6080), fontSize: 14,
                      fontStyle: FontStyle.italic)),
          ),
        ]),
      ),
    );
  }

  // ── Bouton supprimer ─────────────────────────────────────────────────────────
  Widget _buildDeleteBtn() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.redAccent,
          side: const BorderSide(color: Color(0xFF3A1A1A), width: 1),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
        ),
        onPressed: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1B1B1B),
              title: const Text('Supprimer'),
              content: const Text('Cette action supprimera définitivement la sortie ainsi que les données de sécurité associées.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annuler'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Supprimer'),
                ),
              ],
            ),
          );
          if (confirmed == true && mounted) {
            await deleteRide(context, widget.ride, widget.rideKey, popAfterDelete: true);
          }
        },
        icon: const Icon(Icons.delete_outline, size: 18),
        label: const Text('Supprimer la sortie'),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PARTAGE
  // ════════════════════════════════════════════════════════════════════════════
  Future<void> _showShareSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 20, 24, 32 + MediaQuery.of(ctx).padding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(
            width: 36, height: 4, margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          )),
          const Text('Partager', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 20),
          _shareOption(
            icon: Icons.route, iconColor: Colors.orange,
            title: 'Exporter la trace GPX',
            subtitle: 'Fichier compatible GPS, Komoot, Strava…',
            available: true,
            onTap: () { Navigator.pop(ctx); exportAndShareGpx(); },
          ),
          const SizedBox(height: 10),
          _shareOption(
            icon: Icons.image_outlined, iconColor: Colors.purple,
            title: 'Partager un résumé',
            subtitle: 'Image avec stats et trace GPS',
            available: true,
            onTap: () { Navigator.pop(ctx); _shareRideImage(); },
          ),
          const SizedBox(height: 10),
          _shareOption(
            icon: Icons.link, iconColor: Colors.blue,
            title: 'Copier le lien de suivi',
            subtitle: 'Lien vers la position en temps réel',
            available: false, onTap: null,
          ),
        ]),
      ),
    );
  }

  Widget _shareOption({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool available,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: available ? onTap : null,
      child: Opacity(
        opacity: available ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(14),
            border: available ? null : Border.all(color: Colors.white12, width: 0.5),
          ),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                if (!available) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                    child: const Text('bientôt', style: TextStyle(fontSize: 9, color: Colors.white38)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white38)),
            ])),
            if (available) const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
          ]),
        ),
      ),
    );
  }

  void _shareRideImage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RideSharePreviewScreen(
          ride: Map<String, dynamic>.from(widget.ride),
          rideName: rideName,
        ),
      ),
    );
  }

  Future<void> exportAndShareGpx() async {
    final pointsData = widget.ride['points'] as List;
    if (pointsData.isEmpty) return;

    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<gpx version="1.1" creator="Sunday Tracker" xmlns="http://www.topografix.com/GPX/1/1">');
    buffer.writeln('<trk>');
    buffer.writeln('<name>$rideName</name>');
    buffer.writeln('<trkseg>');
    for (final point in pointsData) {
      final alt = point['alt'] != null ? '\n  <ele>${point['alt']}</ele>' : '';
      buffer.writeln('<trkpt lat="${point['lat']}" lon="${point['lng']}">$alt\n</trkpt>');
    }
    buffer.writeln('</trkseg>');
    buffer.writeln('</trk>');
    buffer.writeln('</gpx>');

    final dir  = await getTemporaryDirectory();
    final file = File('${dir.path}/sortie_${DateTime.now().millisecondsSinceEpoch}.gpx');
    await file.writeAsString(buffer.toString());
    await Share.shareXFiles([XFile(file.path)], text: 'Trace GPX exportée depuis Sunday Tracker');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ════════════════════════════════════════════════════════════════════════════
  // ════════════════════════════════════════════════════════════════════════════
  // CHEAT CODE DEBUG — 5 taps rapides sur la poignée du panneau
  // ════════════════════════════════════════════════════════════════════════════
  void _onDebugTap() {
    final now = DateTime.now();
    if (_lastDebugTap == null ||
        now.difference(_lastDebugTap!) > const Duration(seconds: 1)) {
      _debugTapCount = 0;
    }
    _lastDebugTap = now;
    _debugTapCount++;
    if (_debugTapCount >= 5) {
      _debugTapCount = 0;
      HapticFeedback.mediumImpact();
      setState(() => _showDebugPanel = !_showDebugPanel);
      if (_showDebugPanel) _refreshStorageDebug();
    }
  }

  // Compte les photos de cette sortie par état (uploadée / à uploader / perdue)
  // et mesure l'espace Storage global (RPC serveur). Appelé à l'ouverture.
  Future<void> _refreshStorageDebug() async {
    var uploaded = 0, pending = 0, orphan = 0;
    for (final wp in (widget.ride['waypoints'] as List? ?? const [])) {
      if (wp is! Map) continue;
      for (final p in (wp['photos'] as List? ?? const [])) {
        if (photoUrl(p) != null) {
          uploaded++; // déjà sur le Storage
          continue;
        }
        final local = photoLocalPath(p);
        if (local != null && File(local).existsSync()) {
          pending++; // uploadable par le balayeur
        } else {
          orphan++; // fichier local perdu → jamais uploadable
        }
      }
    }
    int? bytes;
    try {
      final res = await Supabase.instance.client.rpc('waypoint_storage_usage');
      if (res is num) {
        bytes = res.toInt();
      } else if (res is String) {
        bytes = int.tryParse(res);
      }
    } catch (e) {
      debugPrint('[DEBUG] storage usage: $e');
    }
    if (mounted) {
      setState(() {
        _debugUploadedPhotos = uploaded;
        _debugPendingPhotos = pending;
        _debugOrphanPhotos = orphan;
        _debugStorageBytes = bytes;
      });
    }
  }

  String _fmtMo(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} Mo';

  // Panneau debug de la sortie : infos GPS, stats brutes, IDs, lien Sunday Live
  // (tap = copier), et état du Storage. Ancré sous la top bar, scrollable.
  Widget _buildDebugOverlay() {
    if (!_showDebugPanel) return const SizedBox.shrink();
    final safeTop = MediaQuery.of(context).padding.top;
    final ride = widget.ride;

    final points = ride['points'] as List? ?? const [];
    final ptsAlt = points.where((p) => p is Map && p['alt'] != null).length;
    final wps = ride['waypoints'] as List? ?? const [];
    var photoTotal = 0;
    for (final wp in wps) {
      if (wp is Map) photoTotal += (wp['photos'] as List?)?.length ?? 0;
    }

    final shareCode = ride['safetyShareCode'];
    final liveUrl = shareCode != null
        ? 'https://sunday-tracker-live.web.app/?code=$shareCode'
        : null;

    double d(dynamic v) => (v ?? 0).toDouble();
    const dim = TextStyle(color: Colors.white54, fontSize: 11);

    return Positioned(
      top: safeTop + 74,
      left: 12,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - 24,
          maxHeight: MediaQuery.of(context).size.height * 0.62,
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3)),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 13,
              height: 1.5,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('── DEBUG SORTIE ──')),
                      GestureDetector(
                        onTap: () => setState(() => _showDebugPanel = false),
                        child: const Icon(Icons.close,
                            size: 18, color: Colors.greenAccent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text('── GPS ──'),
                  Text('tracé     : ${points.length} pts'),
                  Text('avec alt  : $ptsAlt pts'),
                  Text('waypoints : ${wps.length}'),
                  Text('photos    : $photoTotal'),
                  const SizedBox(height: 6),
                  const Text('── STATS BRUTES ──'),
                  Text('distance  : ${d(ride['distanceMeters']).toStringAsFixed(0)} m'),
                  Text('durée     : ${ride['durationSeconds'] ?? 0} s'),
                  Text('D+        : ${d(ride['totalElevationMeters']).toStringAsFixed(0)} m'),
                  Text('D-        : ${d(ride['totalElevationDown']).toStringAsFixed(0)} m'),
                  Text('v. moy    : ${d(ride['avgSpeedKmh']).toStringAsFixed(1)} km/h'),
                  Text('pratique  : ${ride['practice'] ?? '—'}'),
                  Text('lieu      : ${[
                    ride['city'],
                    ride['department'],
                    ride['region'],
                  ].where((e) => (e ?? '').toString().isNotEmpty).join(' · ')}'),
                  const SizedBox(height: 6),
                  const Text('── DATES ──'),
                  Text('début : ${ride['startTime'] ?? '—'}', style: dim),
                  Text('fin   : ${ride['endTime'] ?? '—'}', style: dim),
                  const SizedBox(height: 6),
                  const Text('── SUNDAY LIVE ──'),
                  if (liveUrl != null)
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: liveUrl));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Lien Sunday Live copié'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Text(
                        '$liveUrl  ⧉ copier',
                        style: const TextStyle(
                          color: Color(0xFF60a5fa),
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    const Text('(pas de session live)', style: dim),
                  const SizedBox(height: 6),
                  const Text('── IDS ──'),
                  Text('rideKey   : ${widget.rideKey}', style: dim),
                  Text('sessionId : ${ride['safetySessionId'] ?? '—'}', style: dim),
                  Text('shareCode : ${shareCode ?? '—'}', style: dim),
                  const SizedBox(height: 6),
                  const Text('── STOCKAGE ──'),
                  Text(_debugStorageBytes == null
                      ? 'utilisé   : … / 1 Go'
                      : 'utilisé   : ${_fmtMo(_debugStorageBytes!)} / 1 Go'),
                  if (_debugStorageBytes != null)
                    Text(
                      'libre     : ${_fmtMo(1073741824 - _debugStorageBytes!)} '
                      '(${(_debugStorageBytes! / 1073741824 * 100).toStringAsFixed(1)} % util.)',
                    ),
                  Text('uploadées : $_debugUploadedPhotos photo(s)'),
                  Text('à uploader: $_debugPendingPhotos photo(s)'),
                  if (_debugOrphanPhotos > 0)
                    Text(
                      'perdues   : $_debugOrphanPhotos (fichier local absent)',
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Recalcule la taille réduite (px → fraction) pour cet écran avant de bâtir
    // le sheet : garantit que la carte réduite tient toujours en entier.
    _minSize = _computeMinSize();
    final safeTop       = MediaQuery.of(context).padding.top;
    final pointsData    = widget.ride['points'] as List;
    final ridePoints    = pointsData.map((p) => LatLng(p['lat'], p['lng'])).toList();
    final waypointsData = (widget.ride['waypoints'] as List?)?.cast<Map>() ?? [];
    final gradColors    = _buildGradientColors(ridePoints.length);
    final altProfile    = _buildAltitudeProfile();
    final hasWeather    = widget.ride['weatherStart'] != null || widget.ride['weatherEnd'] != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Carte plein écran
          Positioned.fill(
            child: _buildFlutterMap(ridePoints, waypointsData, gradColors),
          ),

          // 2. Dégradé haut pour lisibilité de la top bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: safeTop + 110,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.72),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // 3. Top bar flottante
          Positioned(
            top: safeTop + 12,
            left: 16, right: 16,
            child: _buildTopBar(),
          ),

          // 4. Boutons carte — bas droite, juste au-dessus du panneau
          AnimatedBuilder(
            animation: _sheetController,
            builder: (context, child) {
              final screenH = MediaQuery.of(context).size.height;
              final panelSize = _sheetController.isAttached
                  ? _sheetController.size
                  : _kInitialSize;
              final panelH = screenH * panelSize;
              // Visible en réduit, disparaît quand le panneau monte vers plein écran
              final fadeStart = _minSize + 0.15;
              final fadeEnd   = _minSize + 0.30;
              final opacity = ((fadeEnd - panelSize) / (fadeEnd - fadeStart))
                  .clamp(0.0, 1.0);
              return Positioned(
                right: 10,
                bottom: panelH + 10,
                child: IgnorePointer(
                  ignoring: opacity < 0.05,
                  child: Opacity(opacity: opacity, child: child!),
                ),
              );
            },
            child: _buildMapControls(ridePoints),
          ),

          // 5. Panneau glissant
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: _minSize,
            minChildSize: _kFloorSize,
            maxChildSize: _kMaxSize,
            // Pas de snap : sinon la simulation de snap interrompt animateTo
            // (le panneau s'arrête en chemin). Drag libre → la carte se réduit
            // en continu ; les boutons « Voir/Réduire » animent vers 0.50/0.20.
            snap: false,
            builder: (context, scrollController) => _buildSheetContent(
              scrollController,
              altProfile,
              waypointsData,
              hasWeather,
              ridePoints,
            ),
          ),

          // 6. Cheat code debug : 5 taps sur la poignée du panneau
          _buildDebugOverlay(),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// MODÈLE INTERNE
// ════════════════════════════════════════════════════════════════════════════
enum _PassageType { start, waypoint, end }

class _PassageItem {
  final _PassageType type;
  final String time;
  final String? coords;
  final String? altitude;
  final String? note;
  final List? photos;
  final Map? wp;
  final int? number; // rang du waypoint (1-based) — raccord avec le pin sur la carte

  const _PassageItem({
    required this.type,
    required this.time,
    this.coords,
    this.altitude,
    this.note,
    this.photos,
    this.wp,
    this.number,
  });
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil de vitesse
// ════════════════════════════════════════════════════════════════════════════
class _SpeedProfilePainter extends CustomPainter {
  final List<double> speeds;

  const _SpeedProfilePainter(this.speeds);

  // Lissage par moyenne glissante (fenêtre = 5)
  List<double> _smooth(List<double> data) {
    const w = 5;
    final out = <double>[];
    for (int i = 0; i < data.length; i++) {
      final lo = (i - w ~/ 2).clamp(0, data.length - 1);
      final hi = (i + w ~/ 2).clamp(0, data.length - 1);
      double sum = 0;
      for (int j = lo; j <= hi; j++) { sum += data[j]; }
      out.add(sum / (hi - lo + 1));
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (speeds.length < 2) return;

    final smoothed = _smooth(speeds);

    // Le pic local sert TOUJOURS de référence d'échelle → max est toujours en haut
    final peak = smoothed.reduce(max).clamp(1.0, 300.0);

    // Zone de dessin : topPad réservé au badge + connecteur
    const topPad = 54.0;
    const botPad = 4.0;
    final drawH  = size.height - topPad - botPad;

    double xOf(int i)    => i / (smoothed.length - 1) * size.width;
    double yOf(double s) => topPad + drawH - (s / peak) * drawH;

    // ── Remplissage gradient ────────────────────────────────────────────────
    final fillPath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (int i = 1; i < smoothed.length; i++) {
      fillPath.lineTo(xOf(i), yOf(smoothed[i]));
    }
    fillPath
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad), Offset(0, size.height),
          [const Color(0xFF60a5fa).withValues(alpha: 0.18),
           const Color(0xFF60a5fa).withValues(alpha: 0.01)],
        )
        ..style = PaintingStyle.fill,
    );

    // ── Tracé ligne ─────────────────────────────────────────────────────────
    final linePath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (int i = 1; i < smoothed.length; i++) {
      linePath.lineTo(xOf(i), yOf(smoothed[i]));
    }
    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFF60a5fa)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // ── Indice du max (sur données lissées) ─────────────────────────────────
    int maxIdx = 0;
    for (int i = 1; i < smoothed.length; i++) {
      if (smoothed[i] > smoothed[maxIdx]) maxIdx = i;
    }
    final px = xOf(maxIdx);
    final py = yOf(smoothed[maxIdx]); // ≈ topPad puisque peak = smoothed.reduce(max)

    // ── Badge MAX — toujours dans la zone topPad, centré sur px ─────────────
    final valStr = '${speeds.reduce(max).toStringAsFixed(1)} km/h';
    final tpLabel = TextPainter(
      text: const TextSpan(text: 'MAX',
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
          color: Color(0xFFbfdbfe), letterSpacing: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    final tpVal = TextPainter(
      text: TextSpan(text: valStr,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout();

    const hP = 10.0; const vP = 6.0; const lineGap = 2.0;
    final bw = max(tpLabel.width, tpVal.width) + hP * 2;
    final bh = tpLabel.height + lineGap + tpVal.height + vP * 2;

    // Badge ancré en haut, centré sur px
    const byFixed = 2.0;
    final bx = (px - bw / 2).clamp(2.0, size.width - bw - 2);

    // Fond bleu foncé + bordure bleue
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(bx, byFixed, bw, bh), const Radius.circular(8)),
      Paint()..color = const Color(0xFF1e3a8a),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(bx, byFixed, bw, bh), const Radius.circular(8)),
      Paint()
        ..color = const Color(0xFF60a5fa)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Textes centrés
    tpLabel.paint(canvas, Offset(bx + (bw - tpLabel.width) / 2, byFixed + vP));
    tpVal.paint(canvas, Offset(bx + (bw - tpVal.width) / 2, byFixed + vP + tpLabel.height + lineGap));

    // ── Connecteur : badge → point ──────────────────────────────────────────
    final connY1 = byFixed + bh + 1;
    final connY2 = py - 5;
    if (connY2 > connY1) {
      canvas.drawLine(Offset(px, connY1), Offset(px, connY2),
        Paint()
          ..color = const Color(0xFF60a5fa).withValues(alpha: 0.6)
          ..strokeWidth = 1.0);
    }

    // Marqueur point
    canvas.drawCircle(Offset(px, py), 4.5, Paint()..color = const Color(0xFF1e3a8a));
    canvas.drawCircle(Offset(px, py), 4.5, Paint()
      ..color = const Color(0xFF93c5fd)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);
  }

  @override
  bool shouldRepaint(_SpeedProfilePainter old) => old.speeds != speeds;
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil altimétrique
// ════════════════════════════════════════════════════════════════════════════
class _AltitudeProfilePainter extends CustomPainter {
  final List<double> alts;
  final double? altStart;
  final double? altEnd;

  const _AltitudeProfilePainter(this.alts, {this.altStart, this.altEnd});

  @override
  void paint(Canvas canvas, Size size) {
    if (alts.length < 2) return;

    final minAlt = alts.reduce(min);
    final maxAlt = alts.reduce(max);
    final range  = (maxAlt - minAlt).clamp(1.0, double.infinity);

    // Espace réservé : en haut pour ALT MAX + badges coins,
    // en bas pour ALT MIN placé sous le point minimum.
    const topPad = 50.0;
    const botPad = 46.0;
    final drawH  = size.height - topPad - botPad;

    double xOf(int i)      => i / (alts.length - 1) * size.width;
    double yOf(double alt) => topPad + drawH - ((alt - minAlt) / range) * drawH;

    // ── Aire remplie ──────────────────────────────────────────────────────────
    final linePath = ui.Path()..moveTo(xOf(0), yOf(alts[0]));
    for (int i = 1; i < alts.length; i++) { linePath.lineTo(xOf(i), yOf(alts[i])); }

    canvas.drawPath(
      ui.Path.from(linePath)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad), Offset(0, size.height),
          [const Color(0xFFfb923c).withValues(alpha: 0.40),
           const Color(0xFFfb923c).withValues(alpha: 0.01)],
        )
        ..style = PaintingStyle.fill,
    );

    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFFfb923c)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // ── Indices ───────────────────────────────────────────────────────────────
    int maxIdx = 0, minIdx = 0;
    for (int i = 1; i < alts.length; i++) {
      if (alts[i] > alts[maxIdx]) maxIdx = i;
      if (alts[i] < alts[minIdx]) minIdx = i;
    }

    // ── Utilitaires ───────────────────────────────────────────────────────────
    TextPainter tp(String text, double fs, Color color, {FontWeight fw = FontWeight.w600, double ls = 0}) =>
      TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: fs, fontWeight: fw, color: color, letterSpacing: ls)),
        textDirection: TextDirection.ltr,
      )..layout();

    void drawMarker(double x, double y, {double r = 4.5, double alpha = 1.0}) {
      canvas.drawCircle(Offset(x, y), r, Paint()..color = const Color(0xFF111111));
      canvas.drawCircle(Offset(x, y), r, Paint()
        ..color = const Color(0xFFfb923c).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4);
    }

    void drawConnector(double x1, double y1, double x2, double y2, {double alpha = 0.35}) {
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), Paint()
        ..color = const Color(0xFFfb923c).withValues(alpha: alpha)
        ..strokeWidth = 0.8);
    }

    // ── Badge coin (DÉPART / ARRIVÉE) — priorité secondaire ──────────────────
    // Positionné en coin fixe, relié au vrai point par un trait discret.
    void drawCornerBadge(int idx, String label, String value, {required bool isLeft}) {
      final px = xOf(idx);
      final py = yOf(alts[idx]);

      final tpL = tp(label, 8, const Color(0xFF777777), ls: 0.3);
      final tpV = tp(value, 10, const Color(0xFFCCCCCC), fw: FontWeight.w700);

      const hP = 6.0; const vP = 3.5; const lG = 1.5;
      final bw = max(tpL.width, tpV.width) + hP * 2;
      final bh = tpL.height + lG + tpV.height + vP * 2;
      final bx = isLeft ? 2.0 : size.width - bw - 2;
      const by = 2.0;

      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(6)),
        Paint()..color = const Color(0xFF1A1E22).withValues(alpha: 0.88),
      );
      tpL.paint(canvas, Offset(bx + (bw - tpL.width) / 2, by + vP));
      tpV.paint(canvas, Offset(bx + (bw - tpV.width) / 2, by + vP + tpL.height + lG));

      // Connecteur du coin au vrai point
      final anchorX = bx + (isLeft ? bw : 0);
      final anchorY = by + bh / 2;
      drawConnector(anchorX, anchorY, px, py, alpha: 0.25);
      drawMarker(px, py, r: 3.5, alpha: 0.55);
    }

    // ── Badge principal (ALT MAX / ALT MIN) — priorité forte ─────────────────
    void drawMainBadge(int idx, String label, String value, {
      required bool above,
      bool highlighted = false,
    }) {
      final x = xOf(idx);
      final y = yOf(alts[idx]);

      const hP = 8.0; const vP = 5.0; const lG = 2.0; const gap = 7.0;

      final tpL = tp(label, 9,
        highlighted ? Colors.white.withValues(alpha: 0.92) : const Color(0xFFbbbbbb),
        ls: 0.3);
      final tpV = tp(value, 13, Colors.white, fw: FontWeight.bold);

      final bw = max(tpL.width, tpV.width) + hP * 2;
      final bh = tpL.height + lG + tpV.height + vP * 2;

      final bx = (x - bw / 2).clamp(2.0, size.width - bw - 2);
      final by = above
          ? (y - 4.5 - gap - bh).clamp(0.0, size.height - bh - 2)
          : (y + 4.5 + gap).clamp(0.0, size.height - bh - 2);

      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(8)),
        Paint()..color = highlighted ? const Color(0xFFe07820) : const Color(0xFF21262D),
      );
      tpL.paint(canvas, Offset(bx + (bw - tpL.width) / 2, by + vP));
      tpV.paint(canvas, Offset(bx + (bw - tpV.width) / 2, by + vP + tpL.height + lG));

      // Connecteur et marqueur
      final connY1 = above ? by + bh + 1 : by - 1;
      final connY2 = above ? y - 4.5 : y + 4.5;
      drawConnector(x, connY1, x, connY2, alpha: highlighted ? 0.55 : 0.35);
      drawMarker(x, y, alpha: highlighted ? 1.0 : 0.8);
    }

    // Ordre de dessin : coins (low priority) → MIN → MAX (par-dessus tout)
    drawCornerBadge(0,               'DÉPART',  '${(altStart ?? alts.first).toStringAsFixed(0)} m', isLeft: true);
    drawCornerBadge(alts.length - 1, 'ARRIVÉE', '${(altEnd   ?? alts.last ).toStringAsFixed(0)} m', isLeft: false);
    drawMainBadge(minIdx, 'ALT MIN', '${alts[minIdx].toStringAsFixed(0)} m', above: false);
    drawMainBadge(maxIdx, 'ALT MAX', '${alts[maxIdx].toStringAsFixed(0)} m', above: true, highlighted: true);
  }

  @override
  bool shouldRepaint(_AltitudeProfilePainter old) =>
      old.alts != alts || old.altStart != altStart || old.altEnd != altEnd;
}

// ════════════════════════════════════════════════════════════════════════════
// SUPPRESSION
// ════════════════════════════════════════════════════════════════════════════
Future<void> deleteRide(BuildContext context, Map ride, dynamic rideKey, {bool popAfterDelete = false}) async {
  try {
    // 1. Hive = source de vérité locale : on supprime en premier pour que la
    //    sortie disparaisse de la liste même hors-ligne. Le nettoyage réseau
    //    qui suit est best-effort (chaque appel isolé dans son try/catch).
    await Hive.box('rides').delete(rideKey);

    // 2. Fichiers photos locaux.
    final waypoints = (ride['waypoints'] as List?)?.cast<Map>() ?? [];
    for (final wp in waypoints) {
      final photos = (wp['photos'] as List?) ?? [];
      for (final entry in photos) {
        final local = photoLocalPath(entry);
        if (local != null) {
          try { final f = File(local); if (await f.exists()) await f.delete(); } catch (_) {}
        }
      }
    }

    // 3. Nettoyage serveur via la file de suppressions en attente.
    //    On persiste la suppression AVANT de tenter le réseau : si l'appareil
    //    est hors-ligne, flushPendingDeletions() échoue en silence mais l'entrée
    //    reste et sera rejouée au prochain lancement / refresh (garantit que
    //    safety_positions, safety_sessions, rides et le Storage finissent bien
    //    nettoyés). En ligne, la suppression part immédiatement.
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    final startedAt = ride['startTime'] as String?;
    final safetySessionId = ride['safetySessionId'] as String?;

    if (startedAt != null) {
      await enqueueRideDeletion(
        startedAt: startedAt,
        userId: userId,
        safetySessionId: safetySessionId,
      );
      await flushPendingDeletions();
    }

    if (context.mounted) {
      if (popAfterDelete) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sortie supprimée')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur suppression : $e')));
    }
  }
}
