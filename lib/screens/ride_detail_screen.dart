import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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

class _RideDetailScreenState extends State<RideDetailScreen> {
  late String rideName;
  late String rideNote;
  final MapController mapController = MapController();

  // ── Styles de carte ──────────────────────────────────────────────────────────
  static const String _prefKeyMapStyle = 'detail_map_style_index';
  int _mapStyleIndex = 0;
  final List<Map<String, dynamic>> _mapStyles = [
    {'label': 'Plan',      'icon': Icons.map,           'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',                                                'subdomains': <String>[],            'maxZoom': 19},
    {'label': 'Satellite', 'icon': Icons.satellite_alt, 'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'subdomains': <String>[],            'maxZoom': 19},
    {'label': 'Topo',      'icon': Icons.terrain,       'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',                                              'subdomains': <String>['a','b','c'], 'maxZoom': 17},
  ];

  bool _mapFullscreen = false;

  // ── Blocs collapsibles ───────────────────────────────────────────────────────
  static const String _prefCollapsed = 'detail_blocks_collapsed';
  final Set<String> _collapsed = {};

  // Paires 2 colonnes : collapse l'un => collapse l'autre
  static const Map<String, String> _pairs = {
    'dist':  'duree',
    'duree': 'dist',
    'speed': 'elev',
    'elev':  'speed',
  };

  Future<void> _loadCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefCollapsed);
    setState(() {
      _collapsed.clear();
      if (saved != null) {
        _collapsed.addAll(saved);
      } else {
        _collapsed.addAll(['meteo']); // météo réduite par défaut
      }
    });
  }

  Future<void> _saveCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefCollapsed, _collapsed.toList());
  }

  void _toggleBlock(String id) {
    setState(() {
      final partner = _pairs[id];
      final willCollapse = !_collapsed.contains(id);
      if (willCollapse) {
        _collapsed.add(id);
        if (partner != null) _collapsed.add(partner);
      } else {
        _collapsed.remove(id);
        if (partner != null) _collapsed.remove(partner);
      }
    });
    _saveCollapsed();
  }

  bool _isCollapsed(String id) => _collapsed.contains(id);

  // ── Wrapper bloc collapsible ─────────────────────────────────────────────────
  Widget _collapsibleBlock({
    required String id,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String summary,
    required Widget body,
  }) {
    final collapsed = _isCollapsed(id);
    return GestureDetector(
      onTap: () => _toggleBlock(id),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, collapsed ? 10 : 4),
            child: Row(children: [
              Icon(icon, color: iconColor, size: 12),
              const SizedBox(width: 5),
              Expanded(
                child: collapsed
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 10, color: Color(0xFF8A8A8A))),
                        const SizedBox(height: 3),
                        Text(summary,
                          style: TextStyle(fontSize: 14, color: iconColor, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                      ],
                    )
                  : Text(title, style: const TextStyle(fontSize: 10, color: Color(0xFF8A8A8A))),
              ),              AnimatedRotation(
                turns: collapsed ? -0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF444444), size: 16),
              ),
            ]),
          ),
          AnimatedCrossFade(
            firstChild:  Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: body),
            secondChild: const SizedBox.shrink(),
            crossFadeState: collapsed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ]),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    rideName = widget.ride['name'] ?? _defaultName();
    rideNote = widget.ride['note'] ?? '';
    _loadMapStyle();
    _loadCollapsed();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pointsData = widget.ride['points'] as List;
      final ridePoints = pointsData.map((p) => LatLng(p['lat'], p['lng'])).toList();
      if (ridePoints.isEmpty) return;
      await Future.delayed(const Duration(milliseconds: 300));
      final bounds = LatLngBounds.fromPoints(ridePoints);
      mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
      );
    });
  }

  String _defaultName() {
    final startTime = widget.ride['startTime'];
    if (startTime == null) return 'Sortie';
    final dt = DateTime.tryParse(startTime);
    if (dt == null) return 'Sortie';
    return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
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
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
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
    final kmh = (d / 1000) / (s / 3600);
    return '${kmh.toStringAsFixed(1)} km/h';
  }

  String _formatMaxSpeed(dynamic kmh) {
    if (kmh == null) return '--';
    return '${(kmh as num).toStringAsFixed(1)} km/h';
  }

  String _formatWaypointTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  // ── Gradient tracé (orange → violet) ────────────────────────────────────────
  List<Color> _buildGradientColors(int count) {
    const colors = [Color(0xFFFF8A00), Color(0xFFD946EF), Color(0xFF6D28D9)];
    if (count <= 1) return [colors.first];
    return List.generate(count, (i) {
      final t = i / (count - 1);
      if (t <= 0.5) return Color.lerp(colors[0], colors[1], t / 0.5)!;
      return Color.lerp(colors[1], colors[2], (t - 0.5) / 0.5)!;
    });
  }

  // ── Profil altimétrique — liste de doubles depuis Hive ──────────────────────
  List<double> _buildAltitudeProfile() {
    final pointsData = widget.ride['points'] as List;
    final alts = pointsData
        .map((p) => (p['alt'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
    return alts;
  }

  // ── Modal édition ────────────────────────────────────────────────────────────
  Future<void> _showEditModal() async {
    final nameController = TextEditingController(text: rideName);
    final noteController = TextEditingController(text: rideNote);

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) => Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Modifier la sortie', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 24),
          const Text('Nom', style: TextStyle(fontSize: 14, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: nameController, style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(filled: true, fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              hintText: 'Nom de la sortie', hintStyle: const TextStyle(color: Colors.white38)),
          ),
          const SizedBox(height: 20),
          const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: noteController, style: const TextStyle(color: Colors.white), maxLines: 4,
            decoration: InputDecoration(filled: true, fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              hintText: 'Ajouter une note...', hintStyle: const TextStyle(color: Colors.white38)),
          ),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32))),
            onPressed: () async { Navigator.of(modalContext).pop(); await _saveEdits(nameController.text.trim(), noteController.text.trim()); },
            child: const Text('Sauvegarder', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          )),
        ]),
      ),
    );
  }

  Future<void> _saveEdits(String newName, String newNote) async {
    final box = Hive.box('rides');
    final updatedRide = Map.from(widget.ride);
    updatedRide['name'] = newName.isEmpty ? _defaultName() : newName;
    updatedRide['note'] = newNote;
    await box.put(widget.rideKey, updatedRide);
    setState(() { rideName = updatedRide['name']; rideNote = updatedRide['note']; });
    _syncRideToSupabase(updatedRide);
  }

  Future<void> _deletePhotoFromWaypoint(Map wp, String photoPath) async {
    try { await File(photoPath).delete(); } catch (_) {}
    final photos = wp['photos'] as List?;
    if (photos != null) photos.remove(photoPath);
    await Hive.box('rides').put(widget.rideKey, widget.ride);
    setState(() {});
    _syncRideToSupabase(widget.ride);
  }

  void _syncRideToSupabase(Map ride) async {
    final startedAt = ride['startTime'] as String?;
    final userId = Supabase.instance.client.auth.currentUser?.id;
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

  // ── Popup waypoint ───────────────────────────────────────────────────────────
  void _showWaypointPopup(BuildContext context, Map wp) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final photos = (wp['photos'] as List?)?.cast<String>().toList() ?? [];
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
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
                SizedBox(height: 120, child: ListView.builder(
                  scrollDirection: Axis.horizontal, itemCount: photos.length,
                  itemBuilder: (context, index) {
                    final path = photos[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(children: [
                        GestureDetector(
                          onTap: () => showDialog(context: context, builder: (_) => Dialog(
                            backgroundColor: Colors.black,
                            child: InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
                          )),
                          child: ClipRRect(borderRadius: BorderRadius.circular(12),
                            child: Image.file(File(path), width: 120, height: 120, fit: BoxFit.cover)),
                        ),
                        Positioned(
                          top: 4, right: 4,
                          child: GestureDetector(
                            onTap: () async {
                              await _deletePhotoFromWaypoint(wp, path);
                              setSheetState(() {});
                            },
                            child: Container(
                              width: 22, height: 22,
                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                              child: const Icon(Icons.close, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ]),
                    );
                  },
                )),
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

  // ══════════════════════════════════════════════════════════════════════════════
  // WIDGETS BLOCS
  // ══════════════════════════════════════════════════════════════════════════════

  // ── Carte stat générique ─────────────────────────────────────────────────────
  Widget _statCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    String? sub,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
        ]),
        const SizedBox(height: 5),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: color)),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 10, color: Color(0xFF555555))),
        ],
      ]),
    );
  }

  // ── Profil altimétrique ──────────────────────────────────────────────────────
  Widget _buildElevationProfile(List<double> alts) {
    if (alts.length < 2) return const SizedBox.shrink();
    return Container(
      height: 96,
      color: const Color(0xFF111111),
      child: CustomPaint(
        painter: _AltitudeProfilePainter(alts),
        size: Size.infinite,
      ),
    );
  }

  // ── Card dénivelé ────────────────────────────────────────────────────────────
  // ── Helpers pour blocs collapsibles ────────────────────────────────────────

  String _weatherSummary() {
    final w = (widget.ride['weatherStart'] ?? widget.ride['weatherEnd']) as Map?;
    if (w == null) return '';
    final temp = (w['temp'] as num?)?.toStringAsFixed(0) ?? '--';
    final desc = (w['desc'] as String?) ?? '';
    return '$temp° $desc';
  }

  Widget _buildElevationBody() {
    final dPlus  = (widget.ride['totalElevationMeters'] as num?)?.toDouble() ?? 0;
    final dMinus = (widget.ride['totalElevationDown']   as num?)?.toDouble() ?? 0;
    final altMax = (widget.ride['altitudeMax']          as num?)?.toDouble();
    final altMin = (widget.ride['altitudeMin']          as num?)?.toDouble();
    final maxRef = max(dPlus, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _elevRow('D+', '+${dPlus.toStringAsFixed(0)} m', dPlus / maxRef, const Color(0xFFfb923c)),
      const SizedBox(height: 6),
      _elevRow('D−', '−${dMinus.toStringAsFixed(0)} m', dMinus / maxRef, const Color(0xFFa78bfa)),
      if (altMax != null) ...[
        const SizedBox(height: 6),
        _elevRow('Max', '${altMax.toStringAsFixed(0)} m',
          (altMax - (altMin ?? 0)) / max((altMax - (altMin ?? 0)), 1),
          const Color(0xFF4ade80)),
      ],
    ]);
  }

  Widget _buildMovingTimeBody() {
    final totalSec  = (widget.ride['durationSeconds']   as num?)?.toInt() ?? 0;
    final movingSec = (widget.ride['movingTimeSeconds'] as num?)?.toInt() ?? totalSec;
    final stopSec   = (totalSec - movingSec).clamp(0, totalSec);
    final pct       = totalSec > 0 ? (movingSec / totalSec * 100).round() : 100;
    String fmtSec(int s) {
      final d = Duration(seconds: s);
      return '${d.inHours.toString().padLeft(2,"0")}:${(d.inMinutes % 60).toString().padLeft(2,"0")}';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(fmtSec(movingSec), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
        const Spacer(),
        Text('$pct%', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
      ]),
      const SizedBox(height: 6),
      ClipRRect(borderRadius: BorderRadius.circular(3), child: Row(children: [
        Expanded(flex: movingSec, child: Container(height: 4, color: const Color(0xFF4ade80))),
        if (stopSec > 0) Expanded(flex: stopSec, child: Container(height: 4, color: const Color(0xFF252525))),
      ])),
      const SizedBox(height: 4),
      Text('Arrêts : ${fmtSec(stopSec)}', style: const TextStyle(fontSize: 10, color: Color(0xFF444444))),
    ]);
  }

  Widget _buildWeatherBody() {
    final wStart = widget.ride['weatherStart'] as Map?;
    final wEnd   = widget.ride['weatherEnd']   as Map?;
    if (wStart == null && wEnd == null) return const SizedBox.shrink();
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (wStart != null) Expanded(child: _weatherCol(wStart, 'Départ', _formatTimeOnly(widget.ride['startTime']), const Color(0xFFFF8A00))),
      if (wStart != null && wEnd != null)
        Container(width: 1, color: const Color(0xFF222222), margin: const EdgeInsets.symmetric(horizontal: 10)),
      if (wEnd   != null) Expanded(child: _weatherCol(wEnd, 'Arrivée', _formatTimeOnly(widget.ride['endTime']), const Color(0xFF6D28D9))),
    ]));
  }

  Widget _buildElevationCard() {
    final dPlus     = (widget.ride['totalElevationMeters']  as num?)?.toDouble() ?? 0;
    final dMinus    = (widget.ride['totalElevationDown']    as num?)?.toDouble() ?? 0;
    final altStart  = (widget.ride['altitudeStart']         as num?)?.toDouble();
    final altEnd    = (widget.ride['altitudeEnd']           as num?)?.toDouble();
    final altMax    = (widget.ride['altitudeMax']           as num?)?.toDouble();
    final altMin    = (widget.ride['altitudeMin']           as num?)?.toDouble();

    final maxRef = max(dPlus, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.trending_up, color: Color(0xFFfb923c), size: 12),
          SizedBox(width: 5),
          Text('Dénivelé', style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
        ]),
        const SizedBox(height: 12),
        _elevRow('D+',       '+${dPlus.toStringAsFixed(0)} m',    dPlus  / maxRef,           const Color(0xFFfb923c)),
        const SizedBox(height: 7),
        _elevRow('D−',       '−${dMinus.toStringAsFixed(0)} m',   dMinus / maxRef,           const Color(0xFFa78bfa)),
        if (altMax != null) ...[
          const SizedBox(height: 7),
          _elevRow('Alt. max', '${altMax.toStringAsFixed(0)} m',  (altMax - (altMin ?? 0)) / max((altMax - (altMin ?? 0)), 1), const Color(0xFF4ade80)),
        ],
        if (altMin != null) ...[
          const SizedBox(height: 7),
          _elevRow('Alt. min', '${altMin.toStringAsFixed(0)} m',  0.2,                       const Color(0xFF555555)),
        ],
        if (altStart != null || altEnd != null) ...[
          const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider(color: Color(0xFF222222), height: 1)),
          Row(children: [
            if (altStart != null) Expanded(child: _altMini('Départ', '${altStart.toStringAsFixed(0)} m', const Color(0xFFFF8A00))),
            if (altStart != null && altEnd != null) const SizedBox(width: 8),
            if (altEnd   != null) Expanded(child: _altMini('Arrivée','${altEnd.toStringAsFixed(0)} m',   const Color(0xFF6D28D9))),
          ]),
        ],
      ]),
    );
  }

  Widget _elevRow(String label, String value, double progress, Color color) => Row(children: [
    SizedBox(width: 52, child: Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF555555)))),
    Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0),
        backgroundColor: const Color(0xFF252525), color: color, minHeight: 3))),
    const SizedBox(width: 8),
    SizedBox(width: 52, child: Text(value,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color), textAlign: TextAlign.right)),
  ]);

  Widget _altMini(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(9)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF555555))),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
    ]),
  );

  // ── Temps en mouvement ───────────────────────────────────────────────────────
  Widget _buildMovingTimeCard() {
    final totalSec  = (widget.ride['durationSeconds']      as num?)?.toInt() ?? 0;
    final movingSec = (widget.ride['movingTimeSeconds']    as num?)?.toInt() ?? totalSec;
    final stopSec   = (totalSec - movingSec).clamp(0, totalSec);
    final ratio     = totalSec > 0 ? movingSec / totalSec : 1.0;
    final pct       = (ratio * 100).round();

    String fmtSec(int s) {
      final d = Duration(seconds: s);
      final h = d.inHours.toString().padLeft(2,'0');
      final m = (d.inMinutes % 60).toString().padLeft(2,'0');
      final sc = (d.inSeconds % 60).toString().padLeft(2,'0');
      return '$h:$m:$sc';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.directions_run, color: Color(0xFF4ade80), size: 12),
          SizedBox(width: 5),
          Text('Temps en mouvement', style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(fmtSec(movingSec), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
          const SizedBox(width: 8),
          Text('sur ${fmtSec(totalSec)} total', style: const TextStyle(fontSize: 11, color: Color(0xFF555555))),
          const Spacer(),
          Text('$pct%', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(3), child: Row(children: [
          Expanded(flex: movingSec, child: Container(height: 5, color: const Color(0xFF4ade80))),
          if (stopSec > 0) Expanded(flex: stopSec, child: Container(height: 5, color: const Color(0xFF252525))),
        ])),
        const SizedBox(height: 5),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('En mouvement', style: TextStyle(fontSize: 10, color: Color(0xFF4ade80))),
          Text('Arrêts : ${fmtSec(stopSec)}', style: const TextStyle(fontSize: 10, color: Color(0xFF444444))),
        ]),
      ]),
    );
  }

  // ── Météo départ / arrivée ───────────────────────────────────────────────────
  Widget _buildWeatherCard() {
    final wStart = widget.ride['weatherStart'] as Map?;
    final wEnd   = widget.ride['weatherEnd']   as Map?;
    if (wStart == null && wEnd == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.wb_sunny_outlined, color: Color(0xFFfbbf24), size: 12),
          SizedBox(width: 5),
          Text('Météo', style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
        ]),
        const SizedBox(height: 12),
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wStart != null) Expanded(child: _weatherCol(wStart, 'Au départ', _formatTimeOnly(widget.ride['startTime']), const Color(0xFFFF8A00))),
          if (wStart != null && wEnd != null)
            Container(width: 1, color: const Color(0xFF222222), margin: const EdgeInsets.symmetric(horizontal: 12)),
          if (wEnd   != null) Expanded(child: _weatherCol(wEnd, 'À l\'arrivée', _formatTimeOnly(widget.ride['endTime']), const Color(0xFF6D28D9))),
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
      if (desc.isNotEmpty)
        Text(desc, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
      const SizedBox(height: 4),
      _weatherRow(Icons.air,     '$wind km/h $windDir'),
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

  // ── Points de passage (départ + WP + arrivée unifiés) ───────────────────────
  // ── Wrapper collapsible pour Points de passage ─────────────────────────────
  Widget _collapsiblePassage(List<Map> waypoints) {
    final count = waypoints.length + 2; // +2 pour départ et arrivée
    return _collapsibleBlock(
      id: 'passage',
      icon: Icons.route,
      iconColor: const Color(0xFF60a5fa),
      title: 'Points de passage',
      summary: '$count points',
      body: _buildPassageBody(waypoints),
    );
  }

  // Corps seul des points de passage (sans container externe)
  Widget _buildPassageBody(List<Map> waypoints) {
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
      ...waypoints.map((wp) => _PassageItem(
        type: _PassageType.waypoint,
        time: _formatWaypointTime(wp['timestamp']),
        note: (wp['note'] as String?)?.trim(),
        photos: (wp['photos'] as List?)?.cast<String>() ?? [],
        wp: wp,
      )),
      _PassageItem(type: _PassageType.end, time: endTime, coords: endCoords, altitude: altEnd != null ? '$altEnd m' : null),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: items.asMap().entries.map((e) {
        return _buildPassageItem(e.value, e.key == items.length - 1);
      }).toList(),
    );
  }

  Widget _buildPassagePoints(List<Map> waypoints) {
    final startTime  = _formatTimeOnly(widget.ride['startTime']);
    final endTime    = _formatTimeOnly(widget.ride['endTime']);
    final pointsData = widget.ride['points'] as List;
    final altStart   = (widget.ride['altitudeStart'] as num?)?.toStringAsFixed(0);
    final altEnd     = (widget.ride['altitudeEnd']   as num?)?.toStringAsFixed(0);

    // Coordonnées
    String? startCoords, endCoords;
    if (pointsData.isNotEmpty) {
      final first = pointsData.first;
      final last  = pointsData.last;
      startCoords = '${(first['lat'] as num).toStringAsFixed(4)}° · ${(first['lng'] as num).toStringAsFixed(4)}°';
      endCoords   = '${(last['lat']  as num).toStringAsFixed(4)}° · ${(last['lng']  as num).toStringAsFixed(4)}°';
    }

    // Liste complète : départ, WP intermédiaires, arrivée
    final items = <_PassageItem>[
      _PassageItem(type: _PassageType.start, time: startTime, coords: startCoords, altitude: altStart != null ? '$altStart m' : null),
      ...waypoints.map((wp) => _PassageItem(
        type: _PassageType.waypoint,
        time: _formatWaypointTime(wp['timestamp']),
        note: (wp['note'] as String?)?.trim(),
        photos: (wp['photos'] as List?)?.cast<String>() ?? [],
        wp: wp,
      )),
      _PassageItem(type: _PassageType.end, time: endTime, coords: endCoords, altitude: altEnd != null ? '$altEnd m' : null),
    ];

    final totalCount = items.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.route, color: Color(0xFF60a5fa), size: 12),
          const SizedBox(width: 5),
          const Text('Points de passage', style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
          const SizedBox(width: 6),
          Text('· $totalCount', style: const TextStyle(fontSize: 10, color: Color(0xFF444444))),
        ]),
        const SizedBox(height: 12),
        ...items.asMap().entries.map((e) {
          final idx   = e.key;
          final item  = e.value;
          final isLast = idx == items.length - 1;
          return _buildPassageItem(item, isLast);
        }),
      ]),
    );
  }

  Widget _buildPassageItem(_PassageItem item, bool isLast) {
    Color dotColor;
    Widget dotChild;
    String title;

    switch (item.type) {
      case _PassageType.start:
        dotColor = const Color(0xFF4ade80);
        dotChild = const Icon(Icons.play_arrow_rounded, size: 12, color: Color(0xFF4ade80));
        title = 'Départ';
        break;
      case _PassageType.end:
        dotColor = const Color(0xFF6D28D9);
        dotChild = const Icon(Icons.sports_score_sharp, size: 12, color: Color(0xFF6D28D9));
        title = 'Arrivée';
        break;
      case _PassageType.waypoint:
        dotColor = const Color(0xFF60a5fa);
        dotChild = const Icon(Icons.place, size: 12, color: Color(0xFF60a5fa));
        title = 'Point mémorisé';
        break;
    }

    return GestureDetector(
      onTap: item.type == _PassageType.waypoint && item.wp != null
          ? () => _showWaypointPopup(context, item.wp!)
          : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Colonne gauche : dot + ligne verticale
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
          if (!isLast)
            Container(width: 1.5, height: 32, color: const Color(0xFF252525)),
        ])),
        const SizedBox(width: 10),
        // Colonne droite : contenu
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
                child: Text(item.note!, style: const TextStyle(fontSize: 12, color: Color(0xFF888888)), maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (item.photos != null && item.photos!.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(height: 50, child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: item.photos!.length,
                itemBuilder: (ctx, i) {
                  final path = item.photos![i];
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Stack(children: [
                      GestureDetector(
                        onTap: () => showDialog(context: context, builder: (_) => Dialog(
                          backgroundColor: Colors.black,
                          child: InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
                        )),
                        child: ClipRRect(borderRadius: BorderRadius.circular(7),
                          child: Image.file(File(path), width: 50, height: 50, fit: BoxFit.cover)),
                      ),
                      Positioned(
                        top: 2, right: 2,
                        child: GestureDetector(
                          onTap: () => _deletePhotoFromWaypoint(item.wp!, path),
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

  // ══════════════════════════════════════════════════════════════════════════════
  // CARTE
  // ══════════════════════════════════════════════════════════════════════════════
  Widget _buildFlutterMap(List<LatLng> ridePoints, List<Map> waypointsData, List<Color> gradientColors) {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: ridePoints.isNotEmpty ? ridePoints.first : const LatLng(48.8566, 2.3522),
        initialZoom: 13,
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
            ...waypointsData.map((wp) => Marker(
              point: LatLng(wp['lat'], wp['lng']),
              width: 36, height: 36,
              child: GestureDetector(
                onTap: () => _showWaypointPopup(context, wp),
                child: const Icon(Icons.place, color: Colors.blue, size: 36),
              ),
            )),
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
              child: Container(decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25), shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF6D28D9), width: 2),
                boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.85), blurRadius: 8)],
              ),
              child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 22)),
            ),
          ]),
      ],
    );
  }

  Widget _buildStyleSelector() {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.all(3),
      child: Row(mainAxisSize: MainAxisSize.min, children: List.generate(_mapStyles.length, (i) {
        final style = _mapStyles[i];
        final isActive = i == _mapStyleIndex;
        return GestureDetector(
          onTap: () { setState(() => _mapStyleIndex = i); _saveMapStyle(i); },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: isActive ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Icon(style['icon'] as IconData, size: 13, color: isActive ? Colors.black : Colors.white70),
              if (isActive) ...[
                const SizedBox(width: 4),
                Text(style['label'] as String, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
              ],
            ]),
          ),
        );
      })),
    );
  }

  Widget _buildFullscreenButton({required bool fullscreen}) {
    return GestureDetector(
      onTap: () => setState(() => _mapFullscreen = !_mapFullscreen),
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(10)),
        child: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _buildFitBoundsButton(List<LatLng> ridePoints) {
    return GestureDetector(
      onTap: () {
        if (ridePoints.isEmpty) return;
        final bounds = LatLngBounds.fromPoints(ridePoints);
        mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
        );
      },
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.fit_screen, color: Colors.white, size: 20),
      ),
    );
  }

  // ── Share sheet ──────────────────────────────────────────────────────────────
  Future<void> _showShareSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
          const Text('Partager', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 20),
          _shareOption(icon: Icons.route, iconColor: Colors.orange, title: 'Exporter la trace GPX',
            subtitle: 'Fichier compatible GPS, Komoot, Strava…', available: true,
            onTap: () { Navigator.pop(ctx); exportAndShareGpx(); }),
          const SizedBox(height: 10),
          _shareOption(icon: Icons.image_outlined, iconColor: Colors.purple, title: 'Partager un résumé',
            subtitle: 'Image ou lien avec stats et carte', available: false, onTap: null),
          const SizedBox(height: 10),
          _shareOption(icon: Icons.link, iconColor: Colors.blue, title: 'Copier le lien de suivi',
            subtitle: 'Lien vers la position en temps réel', available: false, onTap: null),
        ]),
      ),
    );
  }

  Widget _shareOption({
    required IconData icon, required Color iconColor,
    required String title, required String subtitle,
    required bool available, required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: available ? onTap : null,
      child: Opacity(
        opacity: available ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(14),
            border: available ? null : Border.all(color: Colors.white12, width: 0.5)),
          child: Row(children: [
            Container(width: 40, height: 40,
              decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: iconColor, size: 20)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                if (!available) ...[
                  const SizedBox(width: 8),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                    child: const Text('bientôt', style: TextStyle(fontSize: 9, color: Colors.white38))),
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

  // ── Export GPX (avec altitude si disponible) ─────────────────────────────────
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

  // ══════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final pointsData     = widget.ride['points'] as List;
    final ridePoints     = pointsData.map((p) => LatLng(p['lat'], p['lng'])).toList();
    final waypointsData  = (widget.ride['waypoints'] as List?)?.cast<Map>() ?? [];
    final gradientColors = _buildGradientColors(ridePoints.length);
    final altProfile     = _buildAltitudeProfile();
    final hasWeather     = widget.ride['weatherStart'] != null || widget.ride['weatherEnd'] != null;
    final hasMovingTime  = widget.ride['movingTimeSeconds'] != null;

    return Stack(children: [
      Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),

        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(width: 40, height: 40,
                  decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.arrow_back, size: 20, color: Colors.white)),
              ),
              const SizedBox(width: 12),
              Expanded(child: GestureDetector(
                onTap: _showEditModal,
                behavior: HitTestBehavior.opaque,
                child: Text(rideName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white, height: 1.3),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              )),
              const SizedBox(width: 8),
              GestureDetector(onTap: _showEditModal,
                child: Container(width: 40, height: 40,
                  decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.edit_outlined, size: 20, color: Colors.white))),
              const SizedBox(width: 8),
              GestureDetector(onTap: _showShareSheet,
                child: Container(width: 40, height: 40,
                  decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.share, size: 20, color: Colors.white))),
            ]),
          )),
        ),

        body: Stack(children: [
          SingleChildScrollView(
            child: Column(children: [

              // ── CARTE (arrondie) + profil altimétrique ─────────────────────
              if (!_mapFullscreen) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(height: 220, child: Stack(clipBehavior: Clip.hardEdge, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(24),
                      child: _buildFlutterMap(ridePoints, waypointsData, gradientColors)),
                    Positioned(bottom: 10, left: 10, child: _buildStyleSelector()),
                    Positioned(top: 10, right: 10, child: _buildFitBoundsButton(ridePoints)),
                    Positioned(bottom: 10, right: 10, child: _buildFullscreenButton(fullscreen: false)),
                  ])),
                ),
                // Profil altimétrique collé sous la carte, même padding latéral
                if (altProfile.length >= 2)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16)),
                      child: _buildElevationProfile(altProfile),
                    ),
                  )
                else
                  const SizedBox(height: 12),
              ],

              // ── Distance / Durée ───────────────────────────────────────────
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _collapsibleBlock(
                    id: 'dist', icon: Icons.route_outlined, iconColor: const Color(0xFFfb923c),
                    title: 'Distance', summary: _formatDistance(widget.ride['distanceMeters']),
                    body: Text(_formatDistance(widget.ride['distanceMeters']),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFFfb923c))),
                  )),
                  const SizedBox(width: 8),
                  // Durée + temps en mouvement intégré
                  Expanded(child: _collapsibleBlock(
                    id: 'duree', icon: Icons.timer_outlined, iconColor: const Color(0xFF4ade80),
                    title: 'Durée', summary: _formatDuration(widget.ride['durationSeconds']),
                    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_formatDuration(widget.ride['durationSeconds']),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
                      if (hasMovingTime) ...[
                        const SizedBox(height: 5),
                        Container(height: 1, color: const Color(0xFF222222)),
                        const SizedBox(height: 5),
                        Row(children: [
                          const Icon(Icons.directions_run, size: 10, color: Color(0xFF555555)),
                          const SizedBox(width: 4),
                          const Text('En mouvement', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
                          const Spacer(),
                          Text(_formatDuration(widget.ride['movingTimeSeconds']),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4ade80))),
                        ]),
                      ],
                    ]),
                  )),
                ])),

              // ── Vitesse / Dénivelé ─────────────────────────────────────────
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _collapsibleBlock(
                    id: 'speed', icon: Icons.show_chart, iconColor: const Color(0xFF60a5fa),
                    title: 'Vitesse moy.',
                    summary: _formatAvgSpeed(widget.ride['distanceMeters'], widget.ride['durationSeconds']),
                    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_formatAvgSpeed(widget.ride['distanceMeters'], widget.ride['durationSeconds']),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Color(0xFF60a5fa))),
                      const SizedBox(height: 2),
                      Text('max ${_formatMaxSpeed(widget.ride["maxSpeedKmh"])}',
                        style: const TextStyle(fontSize: 10, color: Color(0xFF555555))),
                    ]),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _collapsibleBlock(
                    id: 'elev', icon: Icons.trending_up, iconColor: const Color(0xFFfb923c),
                    title: 'Dénivelé',
                    summary: '+${((widget.ride["totalElevationMeters"] as num?) ?? 0).toStringAsFixed(0)} m',
                    body: _buildElevationBody(),
                  )),
                ])),

              // ── Météo pleine largeur ────────────────────────────────────────
              if (hasWeather)
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _collapsibleBlock(
                    id: 'meteo', icon: Icons.wb_sunny_outlined, iconColor: const Color(0xFFfbbf24),
                    title: 'Météo',
                    summary: _weatherSummary(),
                    body: _buildWeatherBody(),
                  )),

              // ── POINTS DE PASSAGE collapsible ─────────────────────────────
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _collapsiblePassage(waypointsData)),

              // ── NOTE SORTIE ────────────────────────────────────────────────
              if (rideNote.isNotEmpty)
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: GestureDetector(
                    onTap: _showEditModal,
                    child: Container(width: double.infinity, padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: const Color(0xFF1B1B1B), borderRadius: BorderRadius.circular(14)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.notes, color: Colors.white54, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(rideNote, style: const TextStyle(color: Colors.white70, fontSize: 14))),
                      ])),
                  )),

              // ── SUPPRIMER ──────────────────────────────────────────────────
              Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                child: SizedBox(width: double.infinity, child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Color(0xFF3A1A1A), width: 1),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32))),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF1B1B1B),
                        title: const Text('Supprimer'),
                        content: const Text('Cette action supprimera définitivement la sortie ainsi que les données de sécurité associées.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                        ],
                      ),
                    );
                    if (confirmed == true) await deleteRide(context, widget.ride, widget.rideKey, popAfterDelete: true);
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Supprimer la sortie'),
                ))),
            ]),
          ),
        ]),
      ),

      // ── FULLSCREEN overlay ───────────────────────────────────────────────────
      if (_mapFullscreen)
        Positioned.fill(child: Stack(clipBehavior: Clip.hardEdge, children: [
          _buildFlutterMap(ridePoints, waypointsData, gradientColors),
          Positioned(bottom: 24, left: 16, child: _buildStyleSelector()),
          Positioned(top: 24, right: 16, child: _buildFitBoundsButton(ridePoints)),
          Positioned(bottom: 24, right: 16, child: _buildFullscreenButton(fullscreen: true)),
        ])),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MODÈLE INTERNE : point de passage
// ══════════════════════════════════════════════════════════════════════════════
enum _PassageType { start, waypoint, end }

class _PassageItem {
  final _PassageType type;
  final String time;
  final String? coords;
  final String? altitude;
  final String? note;
  final List<String>? photos;
  final Map? wp;

  const _PassageItem({
    required this.type,
    required this.time,
    this.coords,
    this.altitude,
    this.note,
    this.photos,
    this.wp,
  });
}

// ══════════════════════════════════════════════════════════════════════════════
// PAINTER : profil altimétrique
// ══════════════════════════════════════════════════════════════════════════════
class _AltitudeProfilePainter extends CustomPainter {
  final List<double> alts;
  const _AltitudeProfilePainter(this.alts);

  @override
  void paint(Canvas canvas, Size size) {
    if (alts.length < 2) return;

    final minAlt = alts.reduce(min);
    final maxAlt = alts.reduce(max);
    final range  = (maxAlt - minAlt).clamp(1.0, double.infinity);

    // Padding haut pour les badges, bas pour la ligne de base
    const topPad = 26.0;
    const botPad = 6.0;
    final drawH = size.height - topPad - botPad;

    double xOf(int i) => i / (alts.length - 1) * size.width;
    double yOf(double alt) => topPad + drawH - ((alt - minAlt) / range) * drawH;

    final path = ui.Path();
    path.moveTo(xOf(0), yOf(alts[0]));
    for (int i = 1; i < alts.length; i++) {
      path.lineTo(xOf(i), yOf(alts[i]));
    }

    // Remplissage dégradé
    final fillPath = ui.Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final gradient = ui.Gradient.linear(
      Offset(0, topPad), Offset(0, size.height),
      [const Color(0xFFfb923c).withValues(alpha: 0.45), const Color(0xFFfb923c).withValues(alpha: 0.02)],
    );
    canvas.drawPath(fillPath, Paint()..shader = gradient..style = PaintingStyle.fill);

    // Ligne
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFFfb923c)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // Indices des points min et max
    int maxIdx = 0, minIdx = 0;
    for (int i = 1; i < alts.length; i++) {
      if (alts[i] > alts[maxIdx]) maxIdx = i;
      if (alts[i] < alts[minIdx]) minIdx = i;
    }

    // Dessin d'un marqueur cercle + badge étiquette au-dessus du point
    void drawBadge(int idx, String label) {
      final x = xOf(idx);
      final y = yOf(alts[idx]);

      // Cercle marqueur sur la courbe
      canvas.drawCircle(Offset(x, y), 4.5,
          Paint()..color = const Color(0xFF111111)..style = PaintingStyle.fill);
      canvas.drawCircle(Offset(x, y), 4.5,
          Paint()
            ..color = const Color(0xFFfb923c)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);

      // Badge pill au-dessus du cercle
      const hPad = 7.0;
      const vPad = 3.5;
      const gap  = 7.0;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Color(0xFFFFFFFF),
            letterSpacing: 0.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final bw = tp.width + hPad * 2;
      final bh = tp.height + vPad * 2;

      // Badge centré sur x, au-dessus du cercle, clampé dans le canvas
      double bx = (x - bw / 2).clamp(2.0, size.width - bw - 2);
      double by = (y - 4.5 - gap - bh).clamp(2.0, size.height - bh - 2);

      final badgeRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, by, bw, bh),
        const Radius.circular(9),
      );
      canvas.drawRRect(badgeRRect, Paint()..color = const Color(0xFF252525));
      tp.paint(canvas, Offset(bx + hPad, by + vPad));
    }

    drawBadge(maxIdx, '${maxAlt.toStringAsFixed(0)} m MAX');
    drawBadge(minIdx, '${minAlt.toStringAsFixed(0)} m MIN');
  }

  @override
  bool shouldRepaint(_AltitudeProfilePainter old) => old.alts != alts;
}

// ══════════════════════════════════════════════════════════════════════════════
// SUPPRESSION (inchangée)
// ══════════════════════════════════════════════════════════════════════════════
Future<void> deleteRide(BuildContext context, Map ride, dynamic rideKey, {bool popAfterDelete = false}) async {
  try {
    final safetySessionId = ride['safetySessionId'];
    if (safetySessionId != null) {
      final supabase = Supabase.instance.client;
      await supabase.from('safety_positions').delete().eq('session_id', safetySessionId);
      await supabase.from('safety_sessions').delete().eq('id', safetySessionId);
    }

    final startedAt = ride['startTime'] as String?;
    if (startedAt != null) {
      await Supabase.instance.client.from('rides').delete().eq('started_at', startedAt);
    }

    final waypoints = (ride['waypoints'] as List?)?.cast<Map>() ?? [];
    for (final wp in waypoints) {
      final photos = (wp['photos'] as List?)?.cast<String>() ?? [];
      for (final path in photos) {
        try { final f = File(path); if (await f.exists()) await f.delete(); } catch (_) {}
      }
    }

    await Hive.box('rides').delete(rideKey);

    if (context.mounted) {
      if (popAfterDelete) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sortie supprimée')));
    }
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur suppression : $e')));
  }
}