import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(32),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.of(modalContext).pop();
                    await _saveEdits(
                      nameController.text.trim(),
                      noteController.text.trim(),
                    );
                  },
                  child: const Text(
                    'Sauvegarder',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
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

  @override
  Widget build(BuildContext context) {
    final pointsData = widget.ride['points'] as List;
    final List<LatLng> ridePoints = pointsData.map((point) {
      return LatLng(point['lat'], point['lng']);
    }).toList();

    final startPoint = ridePoints.isNotEmpty
        ? ridePoints.first
        : LatLng(48.8566, 2.3522);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: Text(
          rideName,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Modifier',
            onPressed: _showEditModal,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Exporter GPX',
            onPressed: exportAndShareGpx,
          ),
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
                        CameraFit.bounds(
                          bounds: bounds,
                          padding: const EdgeInsets.all(60),
                        ),
                      );
                    });

                    return FlutterMap(
                      mapController: mapController,
                      options: MapOptions(
                        initialCenter: startPoint,
                        initialZoom: 13,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.sunday_tracker',
                        ),
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: ridePoints,
                              strokeWidth: 5,
                              color: Colors.orange,
                            ),
                          ],
                        ),
                        if (ridePoints.isNotEmpty)
                          MarkerLayer(
                            markers: [
                              ...ridePoints.skip(1).take(ridePoints.length - 2).map(
                                (point) => Marker(
                                  point: point,
                                  width: 10,
                                  height: 10,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 1),
                                    ),
                                  ),
                                ),
                              ),
                              Marker(
                                point: ridePoints.first,
                                width: 22,
                                height: 22,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.greenAccent.withValues(alpha: 0.85),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Marker(
                                point: ridePoints.last,
                                width: 32,
                                height: 32,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.red.withValues(alpha: 0.85),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.sports_score_sharp,
                                    color: Colors.white,
                                    size: 28,
                                  ),
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

                  // LIGNE 1 : DÉPART / ARRIVÉE
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Départ', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 4),
                            Text(
                              _formatDateTime(widget.ride['startTime']),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
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
                              Text(
                                _formatDateTime(widget.ride['endTime']),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 5), // était 16
                  Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 5), // était 16

                  // LIGNE 2 : DISTANCE / DURÉE
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Distance', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 4),
                            Text(
                              _formatDistance(widget.ride['distanceMeters']),
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.orange),
                            ),
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
                              Text(
                                _formatDuration(widget.ride['durationSeconds']),
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.orange),
                              ),
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

          // NOTE (affichée si non vide)
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
                    Expanded(
                      child: Text(
                        rideNote,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(32),
                  ),
                ),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1B1B1B),
                        title: const Text('Supprimer'),
                        content: const Text(
                          'Cette action supprimera définitivement la sortie ainsi que les données de sécurité associées.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Annuler'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Supprimer'),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirmed == true) {
                    await deleteRide(
                      context,
                      widget.ride,
                      widget.rideKey,
                      popAfterDelete: true,
                    );
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

    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Trace GPX exportée depuis Sunday Tracker',
    );
  }
}

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