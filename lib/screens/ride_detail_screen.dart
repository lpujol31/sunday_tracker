import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class RideDetailScreen extends StatefulWidget 
{
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
{
  late String rideName;
  late String rideNote;
  final MapController mapController = MapController();

  // ── Styles de carte (même liste que RideScreen) ────────────────────────────
  static const String _prefKeyMapStyle = 'detail_map_style_index';
  int _mapStyleIndex = 0;
  final List<Map<String, dynamic>> _mapStyles = [
    {'label': 'Plan',      'icon': Icons.map,           'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',                                                'subdomains': <String>[],             'maxZoom': 19},
    {'label': 'Satellite', 'icon': Icons.satellite_alt, 'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'subdomains': <String>[],             'maxZoom': 19},
    {'label': 'Topo',      'icon': Icons.terrain,       'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',                                              'subdomains': <String>['a','b','c'],  'maxZoom': 17},
  ];

  // ── Plein écran carte ──────────────────────────────────────────────────────
  bool _mapFullscreen = false;

  @override
  void initState() {
    super.initState();
    rideName = widget.ride['name'] ?? _defaultName();
    rideNote = widget.ride['note'] ?? '';
    _loadMapStyle();

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

  // ── Persistance style carte ────────────────────────────────────────────────
  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_prefKeyMapStyle) ?? 0;
    if (mounted) setState(() => _mapStyleIndex = saved.clamp(0, _mapStyles.length - 1));
  }

  Future<void> _saveMapStyle(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyMapStyle, index);
  }

  // ── Titre AppBar : "13 juin 2026" ──────────────────────────────────────────
  String _formatDateReadable(dynamic isoString) {
    if (isoString == null) return 'Sortie';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return 'Sortie';
    const months = [
      '', 'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    return '${dt.day} ${months[dt.month]} ${dt.year}';
  }

  // ── Heure seule : "12:39" ──────────────────────────────────────────────────
  String _formatTimeOnly(dynamic isoString) {
    if (isoString == null) return '--:--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  String _formatDateTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year} '
          '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
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

  // ── Vitesse moyenne calculée ───────────────────────────────────────────────
  String _formatAvgSpeed(dynamic meters, dynamic seconds) {
    final d = (meters ?? 0).toDouble();
    final s = (seconds ?? 0).toDouble();
    if (s <= 0) return '-- km/h';
    final kmh = (d / 1000) / (s / 3600);
    return '${kmh.toStringAsFixed(1)} km/h';
  }

  // ── Vitesse max (optionnelle, si enregistrée) ──────────────────────────────
  String _formatMaxSpeed(dynamic kmh) {
    if (kmh == null) return '-- km/h';
    return '${(kmh as num).toStringAsFixed(1)} km/h';
  }

  String _formatWaypointTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  List<Color> _buildGradientColors(int count) {
    const colors = [
      Color(0xFFFF8A00),
      Color(0xFFD946EF),
      Color(0xFF6D28D9),
    ];
    if (count <= 1) return [colors.first];
    return List.generate(count, (i) {
      final t = i / (count - 1);
      if (t <= 0.5) {
        final tt = t / 0.5;
        return Color.lerp(colors[0], colors[1], tt)!;
      } else {
        final tt = (t - 0.5) / 0.5;
        return Color.lerp(colors[1], colors[2], tt)!;
      }
    });
  }

  Future<void> _showEditModal() async {
    final nameController = TextEditingController(text: rideName);
    final noteController = TextEditingController(text: rideNote);

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Modifier la sortie',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text('Nom', style: TextStyle(fontSize: 14, color: Colors.white54)),
              const SizedBox(height: 8),
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'Nom de la sortie',
                  hintStyle: const TextStyle(color: Colors.white38),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
              const SizedBox(height: 8),
              TextField(
                controller: noteController,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  hintText: 'Ajouter une note...',
                  hintStyle: const TextStyle(color: Colors.white38),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
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
            ],
          ),
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
  }

  void _showWaypointPopup(BuildContext context, Map wp) {
    final photos = (wp['photos'] as List?)?.cast<String>() ?? [];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.place, color: Colors.blue, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    'Point mémorisé — ${_formatWaypointTime(wp['timestamp'])}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if ((wp['note'] ?? '').toString().isNotEmpty)
                Text(
                  wp['note'],
                  style: const TextStyle(fontSize: 15, color: Colors.white70),
                )
              else
                const Text(
                  'Aucune note',
                  style: TextStyle(fontSize: 15, color: Colors.white38, fontStyle: FontStyle.italic),
                ),
              if (photos.isNotEmpty) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (_) => Dialog(
                                backgroundColor: Colors.black,
                                child: InteractiveViewer(
                                  child: Image.file(
                                    File(photos[index]),
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            );
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(photos[index]),
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Lat: ${wp['lat'].toStringAsFixed(6)}  Long: ${wp['lng'].toStringAsFixed(6)}',
                style: const TextStyle(fontSize: 12, color: Colors.white38),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pointsData = widget.ride['points'] as List;
    final List<LatLng> ridePoints = pointsData.map((point) {
      return LatLng(point['lat'], point['lng']);
    }).toList();

    final waypointsData = (widget.ride['waypoints'] as List?)?.cast<Map>() ?? [];
    final startPoint = ridePoints.isNotEmpty ? ridePoints.first : LatLng(48.8566, 2.3522);
    final gradientColors = _buildGradientColors(ridePoints.length);

    return Stack(
      children: [
      Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),

      // ── AppBar : nom complet, hauteur automatique ─────────────────────────
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: _showEditModal,
                    behavior: HitTestBehavior.opaque,
                    child: Text(
                      rideName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _showEditModal,
                  child: Tooltip(
                    message: 'Modifier la sortie',
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.edit_outlined, size: 20, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _showShareSheet,
                  child: Tooltip(
                    message: 'Partager',
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.share, size: 20, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      body: Stack(
        children: [
          SingleChildScrollView(
        child: Column(
          children: [

            // ── CARTE ─────────────────────────────────────────────────────────
            // En mode normal seulement — le fullscreen est géré par le Stack parent
            if (!_mapFullscreen)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 240,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: _buildFlutterMap(ridePoints, waypointsData, gradientColors),
                      ),
                      Positioned(
                        bottom: 10, left: 10,
                        child: _buildStyleSelector(),
                      ),
                      Positioned(
                        bottom: 10, right: 10,
                        child: _buildFullscreenButton(fullscreen: false),
                      ),
                    ],
                  ),
                ),
              ),


            // ── STATS GRILLE 2×2 ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 2.4,
                children: [
                  _StatCard(
                    label: 'Distance',
                    value: _formatDistance(widget.ride['distanceMeters']),
                  ),
                  _StatCard(
                    label: 'Durée',
                    value: _formatDuration(widget.ride['durationSeconds']),
                  ),
                  _StatCard(
                    label: 'Vitesse moy.',
                    value: _formatAvgSpeed(
                      widget.ride['distanceMeters'],
                      widget.ride['durationSeconds'],
                    ),
                  ),
                  _StatCard(
                    label: 'Vitesse max.',
                    value: _formatMaxSpeed(widget.ride['maxSpeedKmh']),
                  ),
                ],
              ),
            ),

            // ── DÉPART / ARRIVÉE ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _TimeCard(
                      label: 'Départ',
                      time: _formatTimeOnly(widget.ride['startTime']),
                      dotColor: const Color(0xFFFF8A00),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _TimeCard(
                      label: 'Arrivée',
                      time: _formatTimeOnly(widget.ride['endTime']),
                      dotColor: const Color(0xFF6D28D9),
                    ),
                  ),
                ],
              ),
            ),

            // ── WAYPOINTS LIST ────────────────────────────────────────────────
            if (waypointsData.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.place, color: Colors.blue, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '${waypointsData.length} point${waypointsData.length > 1 ? 's' : ''} mémorisé${waypointsData.length > 1 ? 's' : ''}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ...waypointsData.asMap().entries.map((entry) {
                        final i = entry.key;
                        final wp = entry.value;
                        final note = (wp['note'] ?? '').toString();
                        final photos = (wp['photos'] as List?)?.cast<String>() ?? [];
                        return GestureDetector(
                          onTap: () => _showWaypointPopup(context, wp),
                          child: Container(
                            margin: EdgeInsets.only(bottom: i < waypointsData.length - 1 ? 8 : 0),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF242424),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (photos.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        File(photos.first),
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _formatWaypointTime(wp['timestamp']),
                                        style: const TextStyle(fontSize: 11, color: Colors.white38),
                                      ),
                                      if (photos.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(
                                            '${photos.length} photo${photos.length > 1 ? 's' : ''}',
                                            style: const TextStyle(fontSize: 11, color: Colors.blue),
                                          ),
                                        ),
                                      if (note.isNotEmpty)
                                        Text(
                                          note,
                                          style: const TextStyle(fontSize: 13, color: Colors.white70),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        )
                                      else
                                        const Text(
                                          'Aucune note',
                                          style: TextStyle(fontSize: 13, color: Colors.white24, fontStyle: FontStyle.italic),
                                        ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),

            // ── NOTE SORTIE ───────────────────────────────────────────────────
            if (rideNote.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: GestureDetector(
                  onTap: _showEditModal,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1B1B),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.notes, color: Colors.white54, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text(rideNote, style: const TextStyle(color: Colors.white70, fontSize: 14))),
                      ],
                    ),
                  ),
                ),
              ),

            // ── BOUTON SUPPRIMER — discret, contour seulement ─────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              child: SizedBox(
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
                      builder: (context) {
                        return AlertDialog(
                          backgroundColor: const Color(0xFF1B1B1B),
                          title: const Text('Supprimer'),
                          content: const Text('Cette action supprimera définitivement la sortie ainsi que les données de sécurité associées.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Supprimer'),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmed == true) {
                      await deleteRide(context, widget.ride, widget.rideKey, popAfterDelete: true);
                    }
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Supprimer la sortie'),
                ),
              ),
            ),
          ],
        ),
      ),

        ],
      ),
    ), // Scaffold

      // ── FULLSCREEN overlay — couvre tout l'écran AppBar comprise ────────────
      if (_mapFullscreen)
        Positioned.fill(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              _buildFlutterMap(ridePoints, waypointsData, gradientColors),
              Positioned(
                bottom: 24, left: 16,
                child: _buildStyleSelector(),
              ),
              Positioned(
                bottom: 24, right: 16,
                child: _buildFullscreenButton(fullscreen: true),
              ),
            ],
          ),
        ),
      ], // outer Stack
    );
  }


  // La clé est d'éviter deux FlutterMap simultanés avec le même MapController,
  // ce qui provoque Infinity/NaN dans le calcul des tuiles.
  // ── FlutterMap seul, sans conteneur ─────────────────────────────────────────
  Widget _buildFlutterMap(
    List<LatLng> ridePoints,
    List<Map> waypointsData,
    List<Color> gradientColors,
  ) {
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
          MarkerLayer(
            markers: [
              ...waypointsData.map((wp) => Marker(
                point: LatLng(wp['lat'], wp['lng']),
                width: 36, height: 36,
                child: GestureDetector(
                  onTap: () => _showWaypointPopup(context, wp),
                  child: const Icon(Icons.place, color: Colors.blue, size: 36),
                ),
              )),
              Marker(
                point: ridePoints.first,
                width: 22, height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFFF8A00), width: 2),
                    boxShadow: [BoxShadow(color: const Color(0xFFFF8A00).withValues(alpha: 0.85), blurRadius: 8)],
                  ),
                ),
              ),
              Marker(
                point: ridePoints.last,
                width: 26, height: 26,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF6D28D9), width: 2),
                    boxShadow: [BoxShadow(color: const Color(0xFF6D28D9).withValues(alpha: 0.85), blurRadius: 8)],
                  ),
                  child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ── Boutons overlay : toujours bottom:10 left/right:10 relatifs à la carte ──
  Widget _buildStyleSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_mapStyles.length, (i) {
          final style    = _mapStyles[i];
          final isActive = i == _mapStyleIndex;
          return GestureDetector(
            onTap: () {
              setState(() => _mapStyleIndex = i);
              _saveMapStyle(i);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isActive ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Icon(style['icon'] as IconData, size: 13, color: isActive ? Colors.black : Colors.white70),
                if (isActive) ...[
                  const SizedBox(width: 4),
                  Text(style['label'] as String, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
                ],
              ]),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildFullscreenButton({required bool fullscreen}) {
    return GestureDetector(
      onTap: () => setState(() => _mapFullscreen = !_mapFullscreen),
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }

  Future<void> _showShareSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('Partager', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 20),

              // ── Exporter GPX ── actif
              _shareOption(
                icon: Icons.route,
                iconColor: Colors.orange,
                title: 'Exporter la trace GPX',
                subtitle: 'Fichier compatible GPS, Komoot, Strava…',
                available: true,
                onTap: () { Navigator.pop(ctx); exportAndShareGpx(); },
              ),

              const SizedBox(height: 10),

              // ── Résumé de sortie ── à venir
              _shareOption(
                icon: Icons.image_outlined,
                iconColor: Colors.purple,
                title: 'Partager un résumé',
                subtitle: 'Image ou lien avec stats et carte',
                available: false,
                onTap: null,
              ),

              const SizedBox(height: 10),

              // ── Lien de suivi ── à venir
              _shareOption(
                icon: Icons.link,
                iconColor: Colors.blue,
                title: 'Copier le lien de suivi',
                subtitle: 'Lien vers la position en temps réel',
                available: false,
                onTap: null,
              ),
            ],
          ),
        );
      },
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
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                        if (!available) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                            child: const Text('bientôt', style: TextStyle(fontSize: 9, color: Colors.white38)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white38)),
                  ],
                ),
              ),
              if (available)
                const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
            ],
          ),
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
      buffer.writeln('<trkpt lat="${point['lat']}" lon="${point['lng']}"></trkpt>');
    }
    buffer.writeln('</trkseg>');
    buffer.writeln('</trk>');
    buffer.writeln('</gpx>');

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/sortie_${DateTime.now().millisecondsSinceEpoch}.gpx');
    await file.writeAsString(buffer.toString());

    await Share.shareXFiles([XFile(file.path)], text: 'Trace GPX exportée depuis Sunday Tracker');
  }
}

// ── Widget réutilisable : carte stat ──────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 0.3)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFFFF8A00)),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Widget réutilisable : carte heure départ/arrivée ─────────────────────────
class _TimeCard extends StatelessWidget {
  final String label;
  final String time;
  final Color dotColor;

  const _TimeCard({required this.label, required this.time, required this.dotColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.white38)),
              const SizedBox(height: 2),
              Text(time, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Fonction de suppression (inchangée) ──────────────────────────────────────
Future<void> deleteRide(
  BuildContext context,
  Map ride,
  dynamic rideKey, {bool popAfterDelete = false}) async 
  {
    try {
      final safetySessionId = ride['safetySessionId'];
      if (safetySessionId != null) {
        final supabase = Supabase.instance.client;
        await supabase.from('safety_positions').delete().eq('session_id', safetySessionId);
        await supabase.from('safety_sessions').delete().eq('id', safetySessionId);
      }

      final waypoints = (ride['waypoints'] as List?)?.cast<Map>() ?? [];
      for (final wp in waypoints) {
        final photos = (wp['photos'] as List?)?.cast<String>() ?? [];
        for (final path in photos) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (e) {
            print('Erreur suppression photo $path : $e');
          }
        }
      }

      final ridesBox = Hive.box('rides');
      await ridesBox.delete(rideKey);

      if (context.mounted) {
        if (popAfterDelete) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sortie supprimée')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur suppression : $e')),
      );
    }
  }