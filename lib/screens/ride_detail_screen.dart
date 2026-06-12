import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'dart:io';

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

  @override
  void initState() {
    super.initState();
    rideName = widget.ride['name'] ?? _defaultName();
    rideNote = widget.ride['note'] ?? '';
  }

  String _defaultName() {
    final startTime = widget.ride['startTime'];
    if (startTime == null) return 'Sortie';
    final dt = DateTime.tryParse(startTime);
    if (dt == null) return 'Sortie';
    return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
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

  String _formatWaypointTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  // Interpolation de couleur pour le dégradé du tracé
  List<Color> _buildGradientColors(int count) {
    const colors = [
      Color(0xFF6D28D9),
      Color(0xFFD946EF),
      Color(0xFFFF8A00),
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

    // Tracé en dégradé : on découpe en segments colorés
    final gradientColors = _buildGradientColors(ridePoints.length);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: Text(rideName, overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Modifier', onPressed: _showEditModal),
          IconButton(icon: const Icon(Icons.share), tooltip: 'Exporter GPX', onPressed: exportAndShareGpx),
        ],
      ),

      body: Column(
        children: [

          // CARTE
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Builder(
                  builder: (context) {
                    final mapController = MapController();
                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      if (ridePoints.isEmpty) return;
                      await Future.delayed(const Duration(milliseconds: 300));
                      final bounds = LatLngBounds.fromPoints(ridePoints);
                      mapController.fitCamera(
                        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
                      );
                    });

                    return FlutterMap(
                      mapController: mapController,
                      options: MapOptions(initialCenter: startPoint, initialZoom: 13),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.sunday_tracker',
                        ),

                        // TRACÉ EN DÉGRADÉ : un segment par paire de points
                        if (ridePoints.length >= 2)
                          PolylineLayer(
                            polylines: List.generate(ridePoints.length - 1, (i) {
                              return Polyline(
                                points: [ridePoints[i], ridePoints[i + 1]],
                                strokeWidth: 5,
                                color: gradientColors[i],
                              );
                            }),
                          ),

                        if (ridePoints.isNotEmpty)
                          MarkerLayer(
                            markers: [

                              // WAYPOINTS
                              ...waypointsData.map((wp) => Marker(
                                point: LatLng(wp['lat'], wp['lng']),
                                width: 36,
                                height: 36,
                                child: GestureDetector(
                                  onTap: () => _showWaypointPopup(context, wp),
                                  child: const Icon(Icons.place, color: Colors.blue, size: 36),
                                ),
                              )),

                              // POINT DE DÉPART
                              Marker(
                                point: ridePoints.first,
                                width: 22,
                                height: 22,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF6D28D9), width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF6D28D9).withValues(alpha: 0.85),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // POINT D'ARRIVÉE
                              Marker(
                                point: ridePoints.last,
                                width: 26,
                                height: 26,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFFF8A00), width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFFFF8A00).withValues(alpha: 0.85),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(Icons.sports_score_sharp, color: Colors.white, size: 22),
                                ),
                              ),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),

          // STATS CARD
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B1B),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Départ', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 4),
                            Text(_formatDateTime(widget.ride['startTime']), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      Container(width: 1, height: 36, color: Colors.white12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Arrivée', style: TextStyle(fontSize: 11, color: Colors.white38)),
                              const SizedBox(height: 4),
                              Text(_formatDateTime(widget.ride['endTime']), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Distance', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 4),
                            Text(_formatDistance(widget.ride['distanceMeters']), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.orange)),
                          ],
                        ),
                      ),
                      Container(width: 1, height: 36, color: Colors.white12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Durée', style: TextStyle(fontSize: 11, color: Colors.white38)),
                              const SizedBox(height: 4),
                              Text(_formatDuration(widget.ride['durationSeconds']), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.orange)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // WAYPOINTS LIST
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
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.blue,
                                          ),
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

          // NOTE SORTIE
          if (rideNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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

          // BOUTON SUPPRIMER
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
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
                icon: const Icon(Icons.delete),
                label: const Text('Supprimer la sortie'),
              ),
            ),
          ),
        ],
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

Future<void> deleteRide(
  BuildContext context,
  Map ride,
  dynamic rideKey, {bool popAfterDelete = false}) async 
  {
    try {
      // SUPABASE
      final safetySessionId = ride['safetySessionId'];
      if (safetySessionId != null) {
        final supabase = Supabase.instance.client;
        await supabase.from('safety_positions').delete().eq('session_id', safetySessionId);
        await supabase.from('safety_sessions').delete().eq('id', safetySessionId);
      }

      // PHOTOS des waypoints
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

      // HIVE
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