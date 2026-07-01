import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ride_screen.dart';
import 'ride_detail_screen.dart';
import '../widgets/ride_trace_thumbnail.dart';
import '../widgets/ride_share_card.dart';

import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// PRATIQUES — définition centralisée
// ---------------------------------------------------------------------------

const Map<String, Map<String, dynamic>> kPracticeTypes = {
  'vtt': {
    'label': 'VTT',
    'color': Color(0xFF22C55E),
    'icon': Icons.terrain,
  },
  'enduro': {
    'label': 'Enduro',
    'color': Color(0xFFEF4444),
    'icon': Icons.electric_bolt,
  },
  'route': {
    'label': 'Vélo route',
    'color': Color(0xFF3B82F6),
    'icon': Icons.directions_bike,
  },
  'marche': {
    'label': 'Marche',
    'color': Color(0xFFF59E0B),
    'icon': Icons.directions_walk,
  },
  'running': {
    'label': 'Running',
    'color': Color(0xFFF97316),
    'icon': Icons.directions_run,
  },
  'autre': {
    'label': 'Autre',
    'color': Color(0xFFA855F7),
    'icon': Icons.more_horiz,
  },
};

// ---------------------------------------------------------------------------
// DÉTECTION AUTOMATIQUE DE LA PRATIQUE
// ---------------------------------------------------------------------------
//
// Signaux utilisés :
//   • avgSpeedKmh  = distanceMeters / durationSeconds * 3.6
//   • maxSpeedKmh  = calculé depuis les points GPS si disponibles
//   • slopeRatio   = totalElevationM / distanceKm  (dénivelé par km)
//   • distanceKm   = distanceMeters / 1000
//
// Arbre de décision :
//   avgSpeed < 8 km/h                        → marche
//   avgSpeed < 15 km/h ET slopeRatio > 50   → running
//   avgSpeed < 15 km/h                       → marche (lente)
//   avgSpeed >= 25 km/h ET slopeRatio < 20  → route
//   slopeRatio > 60 OU maxSpeed > 45        → enduro
//   slopeRatio > 30                          → vtt
//   avgSpeed >= 20 ET slopeRatio < 30       → autre
//   fallback                                 → vtt

String detectPractice(Map ride) {
  final distanceM = (ride['distanceMeters'] ?? 0).toDouble();
  final durationS = (ride['durationSeconds'] ?? 1).toDouble();
  final elevationM = (ride['totalElevationMeters'] ?? 0).toDouble();

  if (distanceM <= 0 || durationS <= 0) return 'vtt';

  final distanceKm = distanceM / 1000.0;
  final avgSpeedKmh = (distanceM / durationS) * 3.6;
  final slopeRatio = distanceKm > 0 ? elevationM / distanceKm : 0.0;

  // Calcul vitesse max depuis les points si disponibles
  double maxSpeedKmh = 0;
  final points = ride['points'];
  if (points is List && points.length >= 2) {
    for (int i = 1; i < points.length; i++) {
      final p1 = points[i - 1];
      final p2 = points[i];
      if (p1 is Map && p2 is Map) {
        final lat1 = (p1['lat'] ?? 0.0).toDouble();
        final lon1 = (p1['lng'] ?? 0.0).toDouble();
        final lat2 = (p2['lat'] ?? 0.0).toDouble();
        final lon2 = (p2['lng'] ?? 0.0).toDouble();
        final t1 = DateTime.tryParse(p1['time'] ?? '');
        final t2 = DateTime.tryParse(p2['time'] ?? '');
        if (t1 != null && t2 != null) {
          final dtS = t2.difference(t1).inSeconds.toDouble();
          if (dtS > 0) {
            // Distance approx entre 2 points (formule haversine simplifiée)
            final dLat = (lat2 - lat1) * 111000;
            final dLon = (lon2 - lon1) * 111000 * 0.7; // ~cos(45°)
            final dM = (dLat * dLat + dLon * dLon);
            if (dM > 0) {
              final speedKmh = (dM / (dtS * dtS)) * 0 +
                  (((dLat.abs() + dLon.abs()) / dtS) * 3.6);
              if (speedKmh > maxSpeedKmh) maxSpeedKmh = speedKmh;
            }
          }
        }
      }
    }
  }

  // Arbre de décision
  if (avgSpeedKmh < 8) return 'marche';
  if (avgSpeedKmh < 15 && slopeRatio > 50) return 'running';
  if (avgSpeedKmh < 15) return 'marche';
  if (avgSpeedKmh >= 25 && slopeRatio < 20) return 'route';
  if (slopeRatio > 60 || maxSpeedKmh > 45) return 'enduro';
  if (slopeRatio > 30) return 'vtt';
  if (avgSpeedKmh >= 20 && slopeRatio < 30) return 'autre';
  return 'vtt';
}

// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String appVersion = '';
  String? _buildDate;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Box? _ridesBox;
  bool _recovering = false;
  bool _showOldRides = true;

  @override
  void initState() {
    super.initState();
    loadAppVersion();
    _openBox();
  }

  Future<void> _openBox() async {
    final box = await Hive.openBox('rides');
    if (mounted) setState(() => _ridesBox = box);
    if (box.isEmpty) {
      await _autoRestoreFromRidesTable();
    } else {
      _initialSync();
    }
  }

  // Upload une fois tous les rides Hive existants vers Supabase
  Future<void> _initialSync() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('rides_initial_sync_done') == true) return;
    final box = _ridesBox!;
    if (box.isEmpty) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final rows = <Map<String, dynamic>>[];
      for (int i = 0; i < box.length; i++) {
        final ride = box.getAt(i) as Map?;
        if (ride == null) continue;
        final startedAt = ride['startTime'] as String?;
        if (startedAt == null) continue;
        rows.add({'user_id': userId, 'started_at': startedAt, 'ride_json': ride});
      }
      if (rows.isNotEmpty) {
        await Supabase.instance.client.from('rides').upsert(
          rows,
          onConflict: 'user_id,started_at',
        );
      }
      await prefs.setBool('rides_initial_sync_done', true);
    } catch (e) {
      debugPrint('[SUPABASE] initial sync: $e');
    }
  }

  // Restauration automatique depuis la table rides (métadonnées complètes)
  Future<void> _autoRestoreFromRidesTable() async {
    if (mounted) setState(() => _recovering = true);
    try {
      final rows = await Supabase.instance.client
          .from('rides')
          .select()
          .order('started_at');
      final box = _ridesBox!;
      for (final row in rows) {
        final rideJson = row['ride_json'];
        if (rideJson is Map) {
          await box.add(Map<String, dynamic>.from(rideJson.cast<String, dynamic>()));
        }
      }
      if (mounted && (rows as List).isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${rows.length} sorties restaurées !')),
        );
      }
    } catch (e) {
      debugPrint('[SUPABASE] auto-restore: $e');
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  void _syncRide(Map ride) async {
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

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final phi1 = lat1 * pi / 180;
    final phi2 = lat2 * pi / 180;
    final dPhi = (lat2 - lat1) * pi / 180;
    final dLambda = (lon2 - lon1) * pi / 180;
    final a = sin(dPhi / 2) * sin(dPhi / 2) +
        cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  Future<void> _recoverFromSupabase() async {
    setState(() => _recovering = true);
    try {
      final client = Supabase.instance.client;
      final sessions = await client
          .from('safety_sessions')
          .select()
          .order('started_at');

      final box = _ridesBox!;
      int recovered = 0;

      const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin', 'juil', 'aoû', 'sep', 'oct', 'nov', 'déc'];
      const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

      for (final session in sessions) {
        final sessionId = session['id'];
        final startedAt = session['started_at'] as String;

        // Chemin rapide : ride_json complet déjà stocké dans la session
        if (session['ride_json'] is Map) {
          final rideMap = Map<String, dynamic>.from(
              (session['ride_json'] as Map).cast<String, dynamic>());
          await box.add(rideMap);
          _syncRide(rideMap);
          recovered++;
          continue;
        }

        // Fallback : reconstruction depuis les positions GPS
        final positions = await client
            .from('safety_positions')
            .select()
            .eq('session_id', sessionId)
            .order('created_at', ascending: true);

        if (positions.isEmpty) continue;

        final points = (positions as List).map((p) => {
          'lat': (p['latitude'] as num).toDouble(),
          'lng': (p['longitude'] as num).toDouble(),
          'alt': p['altitude'] != null ? (p['altitude'] as num).toDouble() : null,
          'time': p['created_at'] as String,
        }).toList();

        // Distance totale
        double distanceMeters = 0;
        for (int i = 1; i < points.length; i++) {
          distanceMeters += _haversine(
            points[i - 1]['lat'] as double, points[i - 1]['lng'] as double,
            points[i]['lat'] as double, points[i]['lng'] as double,
          );
        }

        // D+ / D- / altitudes
        double dPlus = 0, dMinus = 0;
        double? altMin, altMax, altStart, altEnd;
        for (int i = 0; i < positions.length; i++) {
          final alt = positions[i]['altitude'] != null
              ? (positions[i]['altitude'] as num).toDouble()
              : null;
          if (alt == null) continue;
          altMin = altMin == null ? alt : min(altMin, alt);
          altMax = altMax == null ? alt : max(altMax, alt);
          if (i == 0) altStart = alt;
          altEnd = alt;
          if (i > 0) {
            final prevAlt = positions[i - 1]['altitude'] != null
                ? (positions[i - 1]['altitude'] as num).toDouble()
                : null;
            if (prevAlt != null) {
              final diff = alt - prevAlt;
              if (diff > 0) { dPlus += diff; } else { dMinus += diff.abs(); }
            }
          }
        }

        // Durée — on utilise toujours la dernière position (created_at server UTC)
        // car ended_at était envoyé en heure locale sans offset = corrompu pour les anciennes sessions
        final start = DateTime.parse(startedAt);
        final end = DateTime.parse(positions.last['created_at'] as String);
        final durationSeconds = end.difference(start).inSeconds;

        // Vitesses
        final avgSpeedKmh = durationSeconds > 0
            ? (distanceMeters / durationSeconds) * 3.6
            : 0.0;

        // Nom auto
        final startLocal = start.toLocal();
        final hour = startLocal.hour;
        final moment = hour < 6 ? 'nuit' : hour < 12 ? 'matin' : hour < 14 ? 'midi' : hour < 18 ? 'après-midi' : hour < 21 ? 'soir' : 'nuit';
        final autoName = 'Sortie du ${days[startLocal.weekday - 1]} ${startLocal.day} ${months[startLocal.month - 1]} ${startLocal.year} · $moment';

        // Géolocalisation du premier point
        String city = '', department = '', region = '';
        if (points.isNotEmpty) {
          try {
            final placemarks = await placemarkFromCoordinates(
              points.first['lat'] as double,
              points.first['lng'] as double,
            );
            if (placemarks.isNotEmpty) {
              city = placemarks.first.locality ?? '';
              department = placemarks.first.subAdministrativeArea ?? '';
              region = placemarks.first.administrativeArea ?? '';
            }
          } catch (_) {}
        }

        final rideMap = <String, dynamic>{
          'name': autoName,
          'note': null,
          'startTime': DateTime.parse(startedAt).toLocal().toIso8601String(),
          'endTime': end.toLocal().toIso8601String(),
          'durationSeconds': durationSeconds,
          'distanceMeters': distanceMeters,
          'totalElevationMeters': dPlus,
          'totalElevationDown': dMinus,
          'altitudeStart': altStart,
          'altitudeEnd': altEnd,
          'altitudeMax': altMax,
          'altitudeMin': altMin,
          'avgSpeedKmh': avgSpeedKmh,
          'safetySessionId': sessionId,
          'safetyShareCode': session['share_code'],
          'points': points,
          'city': city,
          'department': department,
          'region': region,
        };
        rideMap['practice'] = detectPractice(rideMap);
        await box.add(rideMap);
        _syncRide(rideMap);
        recovered++;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$recovered sorties récupérées !')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // FORMATAGE DE DONNEES
  // -------------------------------------------------------------------------

  String _normalizeSearchText(String value) {
    const accents = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
      'ç': 'c',
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
      'ñ': 'n',
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
      'ý': 'y', 'ÿ': 'y',
    };

    return value.toLowerCase().split('').map((char) => accents[char] ?? char).join();
  }

  String _monthName(int month) {
    const months = [
      'janvier', 'fevrier', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'aout', 'septembre', 'octobre', 'novembre', 'decembre',
    ];
    return months[month - 1];
  }

  String _searchableRideText(Map ride, String practiceKey) {
    final practice = kPracticeTypes[practiceKey] ?? kPracticeTypes['vtt']!;
    final practiceLabel = practice['label'] as String;
    final startDate = DateTime.tryParse(ride['startTime'] ?? '')?.toLocal();

    final dateParts = <String>[];
    if (startDate != null) {
      final day = startDate.day.toString().padLeft(2, '0');
      final month = startDate.month.toString().padLeft(2, '0');
      dateParts.addAll([
        startDate.year.toString(),
        month,
        '$day/$month/${startDate.year}',
        '$day-$month-${startDate.year}',
        '${startDate.year}-$month-$day',
        _monthName(startDate.month),
      ]);
    }

    return _normalizeSearchText([
      ride['name'],
      ride['note'],
      ride['city'],
      ride['department'],
      ride['region'],
      ride['practice'],
      practiceLabel,
      ride['startTime'],
      ...dateParts,
    ].where((value) => value != null && value.toString().trim().isNotEmpty).join(' '));
  }

  bool _matchesSearch(Map ride, String practiceKey) {
    final query = _normalizeSearchText(_searchQuery.trim());
    if (query.isEmpty) return true;

    final searchableText = _searchableRideText(ride, practiceKey);
    return query.split(RegExp(r'\s+')).every(searchableText.contains);
  }

  Widget _buildRideSearchField() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _searchQuery = value),
        style: const TextStyle(color: Colors.white, fontSize: 14),
        cursorColor: Colors.orange,
        decoration: InputDecoration(
          hintText: 'Rechercher une sortie...',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
          prefixIcon: const Icon(Icons.search, color: Colors.white54),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white54),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget buildTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Text(
        text.toLowerCase(),
        style: const TextStyle(
          color: Colors.orange,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Tag de pratique coloré + cliquable
  Widget buildPracticeTag(
    String practiceKey,
    dynamic rideKey,
    Box ridesBox,
  ) {
    final practice = kPracticeTypes[practiceKey] ?? kPracticeTypes['vtt']!;
    final icon = practice['icon'] as IconData;
    final label = practice['label'] as String;

    final Color tagColor = practice['color'] as Color;

    return GestureDetector(
      onTap: () => _showPracticePicker(context, rideKey, ridesBox),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: tagColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tagColor.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: tagColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: tagColor,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.keyboard_arrow_down,
              size: 12,
              color: tagColor,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // SÉLECTEUR DE PRATIQUE — bottom sheet
  // -------------------------------------------------------------------------

  void _showPracticePicker(
    BuildContext context,
    dynamic rideKey,
    Box ridesBox,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Poignée
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Choisir la pratique',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Détectée automatiquement · modifiable',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kPracticeTypes.entries.map((e) {
                  final color = e.value['color'] as Color;
                  final icon = e.value['icon'] as IconData;
                  final label = e.value['label'] as String;

                  return GestureDetector(
                    onTap: () async {
                      final existing =
                          ridesBox.get(rideKey) as Map? ?? {};
                      final updated = Map.from(existing)
                        ..['practice'] = e.key;
                      await ridesBox.put(rideKey, updated);
                      _syncRide(updated);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border:
                            Border.all(color: color.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 16, color: color),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------

  Future<void> loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final formattedDate = packageInfo.updateTime != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(packageInfo.updateTime!.toLocal())
        : null;
    final build = packageInfo.buildNumber;
    final formattedBuild = build.length > 2
        ? '${build.substring(0, build.length - 2)}.${build.substring(build.length - 2)}'
        : build;
    setState(() {
      appVersion = 'v${packageInfo.version} build $formattedBuild';
      _buildDate = formattedDate;
    });
  }

  String formatDistance(dynamic meters) {
    final distance = (meters ?? 0).toDouble();
    if (distance < 1000) return '${distance.toStringAsFixed(0)} m';
    return '${(distance / 1000).toStringAsFixed(2)} km';
  }

  String formatDuration(dynamic seconds) {
    final duration = Duration(seconds: seconds ?? 0);
    return duration.toString().split('.').first;
  }

  // -------------------------------------------------------------------------
  // MENU RAPIDE PAR RIDE
  // -------------------------------------------------------------------------

  void _showRideQuickMenu({
    required BuildContext context,
    required Map ride,
    required dynamic rideKey,
    required String rideName,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              ),
            ),
            _rideMenuItem(
              icon: Icons.image_outlined,
              iconColor: Colors.purple,
              title: 'Partager un résumé',
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => RideSharePreviewScreen(
                    ride: Map<String, dynamic>.from(ride),
                    rideName: rideName,
                  ),
                ));
              },
            ),
            const SizedBox(height: 8),
            _rideMenuItem(
              icon: Icons.delete_outline,
              iconColor: Colors.red,
              title: 'Supprimer la sortie',
              titleColor: Colors.red,
              onTap: () async {
                Navigator.pop(sheetCtx);
                await deleteRide(context, ride, rideKey);
              },
            ),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    );
  }

  Widget _rideMenuItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    Color? titleColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(14),
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
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: titleColor ?? Colors.white,
            ),
          ),
        ]),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ridesBox = _ridesBox;
    if (ridesBox == null) return const Scaffold(backgroundColor: Color(0xFF0D0D0D));

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        toolbarHeight: 64,
        titleSpacing: 16,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo_pictogram.png',
              width: 36,
              height: 36,
            ),
            const SizedBox(width: 10),
            const Text(
              'Sunday ',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            ShaderMask(
              shaderCallback: (bounds) => const LinearGradient(
                colors: [Color(0xFFD946EF), Color(0xFFFF8A00)],
              ).createShader(bounds),
              child: const Text(
                'Tracker',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ----------------------------------------------------------------
            // BOUTON START RIDE
            // ----------------------------------------------------------------
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const RideScreen(),
                  ),
                );
              },
              child: Container(
                width: double.infinity,
                height: 78,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xFF6D28D9),
                      Color(0xFFD946EF),
                      Color(0xFFFF8A00),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.orange.withValues(alpha: 0.35),
                      blurRadius: 25,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const Text(
                        'Prêt pour une\nnouvelle aventure ?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.45,
                          letterSpacing: -1,
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 38,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                      const Expanded(
                        child: Text(
                          'DÉMARRER',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.65),
                            width: 6,
                          ),
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Dernières sorties',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 10),
                  ValueListenableBuilder(
                    valueListenable: ridesBox.listenable(),
                    builder: (context, box, _) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${box.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildRideSearchField(),
            const SizedBox(height: 16),

            // ----------------------------------------------------------------
            // LISTE DES SORTIES
            // ----------------------------------------------------------------
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: ridesBox.listenable(),
                builder: (context, box, child) {
                  if (box.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Aucune sortie sauvegardée',
                            style: TextStyle(color: Colors.white54),
                          ),
                          const SizedBox(height: 20),
                          if (_recovering)
                            const Column(
                              children: [
                                CircularProgressIndicator(color: Colors.orange),
                                SizedBox(height: 12),
                                Text(
                                  'Récupération en cours...',
                                  style: TextStyle(color: Colors.white38, fontSize: 13),
                                ),
                              ],
                            )
                          else
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6D28D9),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              onPressed: _recoverFromSupabase,
                              icon: const Icon(Icons.cloud_download_rounded),
                              label: const Text('Récupérer mes sorties'),
                            ),
                        ],
                      ),
                    );
                  }

                  final rides = List.generate(box.length, (index) {
                    final ride = box.getAt(index);
                    return {
                      'key': box.keyAt(index),
                      'ride': ride,
                    };
                  });

                  rides.sort((a, b) {
                    final rideA = a['ride'] as Map;
                    final rideB = b['ride'] as Map;
                    final dateA =
                        DateTime.tryParse(rideA['startTime'] ?? '') ??
                            DateTime(1900);
                    final dateB =
                        DateTime.tryParse(rideB['startTime'] ?? '') ??
                            DateTime(1900);
                    return dateB.compareTo(dateA);
                  });

                  final filteredRides = rides.where((item) {
                    final ride = item['ride'] as Map;
                    final practiceKey = (ride['practice'] as String?)?.isNotEmpty == true
                        ? ride['practice'] as String
                        : detectPractice(ride);
                    return _matchesSearch(ride, practiceKey);
                  }).toList();

                  if (filteredRides.isEmpty) {
                    return Center(
                      child: Text(
                        _searchQuery.trim().isEmpty
                            ? 'Aucune sortie sauvegardée'
                            : 'Aucune sortie trouvée',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    );
                  }

                  final now = DateTime.now();
                  final cutoff = now.subtract(const Duration(days: 30));

                  final recentRides = filteredRides.where((item) {
                    final date = DateTime.tryParse((item['ride'] as Map)['startTime'] ?? '') ?? DateTime(1900);
                    return date.isAfter(cutoff);
                  }).toList();

                  final oldRides = filteredRides.where((item) {
                    final date = DateTime.tryParse((item['ride'] as Map)['startTime'] ?? '') ?? DateTime(1900);
                    return !date.isAfter(cutoff);
                  }).toList();

                  Widget buildCard(dynamic item) {
                    final rideKey = item['key'];
                    final ride = item['ride'] as Map;
                    final startDate = (DateTime.tryParse(ride['startTime'] ?? '') ?? DateTime.now()).toLocal();
                    final isOld = !startDate.isAfter(cutoff);

                    const monthNames = [
                      'JANV', 'FÉV', 'MARS', 'AVR', 'MAI', 'JUIN',
                      'JUIL', 'AOÛT', 'SEPT', 'OCT', 'NOV', 'DÉC',
                    ];
                    final monthStr = monthNames[startDate.month - 1];
                    final departureTime =
                        '${startDate.hour.toString().padLeft(2, '0')}:'
                        '${startDate.minute.toString().padLeft(2, '0')}';

                    final practiceKey = (ride['practice'] as String?)?.isNotEmpty == true
                        ? ride['practice'] as String
                        : detectPractice(ride);

                    return Dismissible(
                      key: ValueKey(rideKey),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (direction) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF1B1B1B),
                            title: const Text('Supprimer la sortie'),
                            content: const Text('Voulez-vous vraiment supprimer cette sortie ?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Annuler'),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Supprimer'),
                              ),
                            ],
                          ),
                        );
                      },
                      onDismissed: (direction) async {
                        await deleteRide(context, ride, rideKey);
                      },
                      child: Opacity(
                        opacity: isOld ? 0.45 : 1.0,
                        child: GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => RideDetailScreen(ride: ride, rideKey: rideKey),
                            ),
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B1B1B),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // ── Bloc date ──
                                    SizedBox(
                                      width: 44,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          FractionallySizedBox(
                                            widthFactor: 0.85,
                                            child: Container(
                                              height: 3,
                                              decoration: BoxDecoration(
                                                color: Colors.orange,
                                                borderRadius: BorderRadius.circular(2),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${startDate.day}',
                                            style: const TextStyle(
                                              fontSize: 26,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                              height: 1.0,
                                            ),
                                          ),
                                          Text(
                                            monthStr,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white70,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                          Text(
                                            '${startDate.year}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Colors.white54,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Container(
                                            width: double.infinity,
                                            height: 1,
                                            color: Colors.white12,
                                          ),
                                          const SizedBox(height: 5),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.flag, size: 10, color: Colors.orange),
                                              const SizedBox(width: 2),
                                              Text(
                                                departureTime,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white60,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    // ── Miniature trace ──
                                    RideTraceThumbnail(points: ride['points'] ?? []),
                                    const SizedBox(width: 12),
                                    // ── Titre + stats ──
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            ride['name'] ?? departureTime,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Row(
                                            children: [
                                              const Icon(Icons.timer, size: 14, color: Colors.white60),
                                              const SizedBox(width: 1),
                                              Text(
                                                formatDuration(ride['durationSeconds']),
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                              const SizedBox(width: 5),
                                              const Icon(Icons.route, size: 14, color: Colors.white60),
                                              const SizedBox(width: 1),
                                              Flexible(
                                                child: Text(
                                                  formatDistance(ride['distanceMeters']),
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if ((ride['note'] ?? '').toString().isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Icon(Icons.edit_note_rounded,
                                                    size: 14, color: Colors.orange),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                  child: Text(
                                                    (ride['note'] as String).trim(),
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.orange,
                                                      fontStyle: FontStyle.italic,
                                                      height: 1.4,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _showRideQuickMenu(
                                        context: context,
                                        ride: ride,
                                        rideKey: rideKey,
                                        rideName: (ride['name'] as String?) ?? departureTime,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.only(left: 4, top: 2),
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(color: const Color(0xFFFF8A00), width: 1.8),
                                          ),
                                          child: const Icon(Icons.more_vert, color: Color(0xFFFF8A00), size: 20),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    buildPracticeTag(practiceKey, rideKey, ridesBox),
                                    if ((ride['department'] ?? '').toString().isNotEmpty)
                                      buildTag('#${ride['department']}'),
                                    if ((ride['region'] ?? '').toString().isNotEmpty)
                                      buildTag('#${ride['region']}'),
                                    if ((ride['city'] ?? '').toString().isNotEmpty)
                                      buildTag('#${ride['city']}'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return ListView(
                    children: [
                      ...recentRides.map(buildCard),
                      if (oldRides.isNotEmpty) ...[
                        GestureDetector(
                          onTap: () => setState(() => _showOldRides = !_showOldRides),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF161616),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.history, color: Colors.white54, size: 20),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Sorties de plus de 30 jours',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.orange,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${oldRides.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  _showOldRides ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  color: Colors.white54,
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_showOldRides) ...oldRides.map(buildCard),
                      ],
                    ],
                  );
                },
              ),
            ),

            const SizedBox(height: 8),
            GestureDetector(
              onTap: _buildDate == null
                  ? null
                  : () => ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Compilé le $_buildDate'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      ),
              child: Text(
                appVersion,
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.white38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}