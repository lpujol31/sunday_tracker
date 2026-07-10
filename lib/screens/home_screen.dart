import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ride_screen.dart';
import 'ride_detail_screen.dart';
import 'account_screen.dart';
import '../services/photo_sync_service.dart';
import '../services/pending_deletions_service.dart';
import '../services/account_service.dart';
import '../utils/date_labels.dart';
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
    'color': Color(0xFF14B8A6),
    'icon': Icons.directions_walk,
  },
  'running': {
    'label': 'Running',
    'color': Color(0xFFEC4899),
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

/// Charge utile légère écrite dans `safety_sessions.ride_json` : uniquement ce
/// que le viewer web lit (trace dense, waypoints, stats). Évite de dupliquer la
/// sortie entière (météo, notes, ville…) — moins de volume, et surtout moins
/// d'exposition via le `share_code` partagé aux proches. La sortie complète vit
/// dans la table `rides`.
Map<String, dynamic> liveSessionRideJson(Map ride) => {
      'points': ride['points'],
      'waypoints': ride['waypoints'],
      'distanceMeters': ride['distanceMeters'],
      'durationSeconds': ride['durationSeconds'],
    };

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
  final AccountService _account = AccountService();
  bool _accountSaved = false;

  @override
  void initState() {
    super.initState();
    loadAppVersion();
    _refreshAccountStatus();
    _openBox();
  }

  void _refreshAccountStatus() {
    final saved = _account.currentStatus().isSaved;
    if (mounted) {
      setState(() => _accountSaved = saved);
    } else {
      _accountSaved = saved;
    }
  }

  /// Icône compte : silhouette dans un rond (avatar) + pastille verte accrochée
  /// au coin quand le compte est sauvegardé (rattaché à un email).
  Widget _accountBadge({required bool saved, required double size}) {
    final dot = size * 0.40;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: Color(0xFF1F1F1F),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_outline,
                color: Colors.white, size: size * 0.6),
          ),
          if (saved)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: const Color(0xFF0D0D0D), width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ouvre l'écran « Mon compte ». Au retour, rafraîchit l'état (icône + carte).
  Future<void> _openAccountScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountScreen(onRecovered: _onAccountRecovered),
      ),
    );
    _refreshAccountStatus();
  }

  /// Après une récupération (Flow B) : on bascule sur un autre compte. On vide
  /// d'abord le local (sinon les sorties de l'ancien compte resteraient affichées
  /// et pourraient se recopier sous le nouveau), puis on rapatrie l'historique du
  /// compte retrouvé depuis Supabase.
  Future<void> _onAccountRecovered() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('rides_initial_sync_done');
    await _ridesBox?.clear();
    await _autoRestoreFromRidesTable();
    _refreshAccountStatus();
  }

  Future<void> _openBox() async {
    final box = await Hive.openBox('rides');
    if (mounted) setState(() => _ridesBox = box);
    // Rejoue d'abord les suppressions faites hors-ligne : le serveur doit être
    // nettoyé AVANT toute restauration/re-sync, sinon une sortie supprimée
    // hors-ligne ressusciterait.
    await flushPendingDeletions();
    if (box.isEmpty) {
      await _autoRestoreFromRidesTable();
    } else {
      _initialSync();
    }
    // Rattrape en arrière-plan les photos pas encore montées sur le Storage
    // (offline-safe : sans réseau, ça ne fait rien et retentera au prochain lancement).
    syncPendingPhotos();
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
      final pending = pendingDeletionKeys();
      for (final row in rows) {
        final rideJson = row['ride_json'];
        if (rideJson is Map) {
          final ride = Map<String, dynamic>.from(rideJson.cast<String, dynamic>());
          // Ne pas ressusciter une sortie en cours de suppression serveur.
          if (pending.contains(ride['startTime'])) continue;
          await box.add(ride);
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

  // Pull-to-refresh : recharge les sorties (et leurs infos) depuis Supabase
  // puis rattrape les photos en attente. Merge par startTime pour éviter
  // les doublons ; met à jour les sorties existantes.
  Future<void> _refreshFromSupabase() async {
    final box = _ridesBox;
    if (box == null) return;
    // Rejoue les suppressions en attente avant de retélécharger, sinon on
    // réinjecterait une sortie qu'on vient de supprimer hors-ligne.
    await flushPendingDeletions();
    final pending = pendingDeletionKeys();
    try {
      final rows = await Supabase.instance.client
          .from('rides')
          .select()
          .order('started_at');

      // Index des sorties déjà présentes, par startTime.
      final existingKeys = <String, dynamic>{};
      for (int i = 0; i < box.length; i++) {
        final ride = box.getAt(i) as Map?;
        final startedAt = ride?['startTime'] as String?;
        if (startedAt != null) existingKeys[startedAt] = box.keyAt(i);
      }

      for (final row in rows) {
        final rideJson = row['ride_json'];
        if (rideJson is! Map) continue;
        final ride =
            Map<String, dynamic>.from(rideJson.cast<String, dynamic>());
        final startedAt = ride['startTime'] as String?;
        if (startedAt == null) continue;
        // Ne pas ressusciter une sortie en cours de suppression serveur.
        if (pending.contains(startedAt)) continue;
        if (existingKeys.containsKey(startedAt)) {
          await box.put(existingKeys[startedAt], ride);
        } else {
          await box.add(ride);
        }
      }
    } catch (e) {
      debugPrint('[SUPABASE] refresh: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Actualisation impossible (hors ligne ?)')),
        );
      }
    }
    // Rattrape les photos pas encore montées sur le Storage (offline-safe).
    await syncPendingPhotos();
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
            .update({'ride_json': liveSessionRideJson(ride)})
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

      for (final session in sessions) {
        final sessionId = session['id'];
        final startedAt = session['started_at'] as String;

        // Les sorties complètes sont restaurées depuis la table `rides`
        // (_autoRestoreFromRidesTable). Ici on reconstruit depuis les positions
        // GPS, pour les sessions jamais sauvegardées (ex. crash en cours de sortie).
        // safety_sessions.ride_json ne contient plus qu'une charge allégée
        // (points + waypoints), pas la sortie entière.
        final lightRideJson =
            session['ride_json'] is Map ? session['ride_json'] as Map : null;
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
        final autoName = 'Sortie du ${kFrDaysShort[startLocal.weekday - 1]} ${startLocal.day} ${months[startLocal.month - 1]} ${startLocal.year} · $moment';

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
          'waypoints': lightRideJson?['waypoints'],
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

  // Étiquette compteur (waypoints / photos) : teinte violette « contenu »,
  // reprise du dégradé signature de l'appli, distincte de l'orange des lieux.
  Widget buildCountTag(IconData icon, int count, String label) {
    const color = Color(0xFFC084FC);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            '$count $label',
            style: const TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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

  // Étiquette « lieu » (départ / arrivée) : icône + nom de commune, teinte
  // dédiée (vert départ, rouge arrivée) pour se distinguer des #zones orange.
  Widget buildPlaceTag(IconData icon, String place, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            place,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: tagColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tagColor.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: tagColor),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: tagColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.keyboard_arrow_down,
              size: 14,
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
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, 32 + MediaQuery.of(context).padding.bottom),
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

  // Centre le contenu tout en restant défilable, pour que le pull-to-refresh
  // fonctionne même quand la liste est vide.
  Widget _refreshableCenter({required Widget child}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: child),
          ),
        );
      },
    );
  }

  // Menu ⋮ d'une carte (partager / supprimer). Extrait pour être réutilisé par
  // la carte téléphone sans dupliquer le bloc de la carte tablette.
  Widget _buildRideMenu(
      BuildContext context, Map ride, dynamic rideKey, String departureTime) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      position: PopupMenuPosition.under,
      onSelected: (value) async {
        if (value == 'share') {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => RideSharePreviewScreen(
              ride: Map<String, dynamic>.from(ride),
              rideName: (ride['name'] as String?) ?? departureTime,
            ),
          ));
        } else if (value == 'delete') {
          await deleteRide(context, ride, rideKey);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<String>(
          value: 'share',
          child: Row(children: [
            Icon(Icons.image_outlined, color: Colors.purple, size: 20),
            SizedBox(width: 12),
            Text('Partager un résumé', style: TextStyle(color: Colors.white)),
          ]),
        ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, color: Colors.red, size: 20),
            SizedBox(width: 12),
            Text('Supprimer la sortie', style: TextStyle(color: Colors.red)),
          ]),
        ),
      ],
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF232323),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: const Icon(Icons.more_vert, color: Colors.white70, size: 20),
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

    // Adaptation aux petits écrans : les valeurs de référence (tablette /
    // téléphone large) restent inchangées ; on ne réduit que sous ces seuils
    // pour éviter les débordements sur téléphones étroits.
    final screenW = MediaQuery.of(context).size.width;
    final isNarrow = screenW < 380;
    final isVeryNarrow = screenW < 340;

    // Miniature de trace : dimensionnée à partir de la largeur réellement
    // disponible dans la carte, en réservant un minimum pour la colonne
    // titre / stats. Sur téléphone étroit elle rétrécit (jusqu'à 64 px) ; sur
    // écran large / tablette elle reste à sa taille de référence (96 px).
    final cardInnerW = screenW - 60; // 32 padding page + 28 padding carte
    final double thumbW =
        (cardInnerW - 44 - 40 - 24 - 130).clamp(64.0, 96.0);
    final double thumbH = thumbW * 84 / 96;

    // Sur téléphone (< 600 dp, breakpoint tablette Material), les étiquettes
    // sont sorties de la colonne étroite pour occuper toute la largeur de la
    // carte sur une ligne dédiée. Sur tablette, on garde l'affichage inline.
    final tagsFullWidth = screenW < 600;

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
        actions: [
          IconButton(
            tooltip: 'Mon compte',
            onPressed: _openAccountScreen,
            icon: _accountBadge(saved: _accountSaved, size: 30),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
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
                      Flexible(
                        child: Text(
                          'Prêt pour une\nnouvelle aventure ?',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isNarrow ? 13 : 15,
                            height: 1.45,
                            letterSpacing: -1,
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 38,
                        margin: EdgeInsets.symmetric(
                            horizontal: isNarrow ? 8 : 12),
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                      Expanded(
                        child: Text(
                          'DÉMARRER',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isVeryNarrow ? 18 : (isNarrow ? 20 : 23),
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

            // ----------------------------------------------------------------
            // CARTE DE RAPPEL — sauvegarde du compte (masquée si déjà sauvegardé)
            // ----------------------------------------------------------------
            if (!_accountSaved) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: _openAccountScreen,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1206),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFFF8A00).withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Color(0xFFFF8A00), size: 24),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Sauvegarde tes sorties',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Rattache ton email pour ne rien perdre',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: Colors.white38, size: 22),
                    ],
                  ),
                ),
              ),
            ],

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
              child: RefreshIndicator(
                onRefresh: _refreshFromSupabase,
                color: Colors.orange,
                backgroundColor: const Color(0xFF1B1B1B),
                child: ValueListenableBuilder(
                valueListenable: ridesBox.listenable(),
                builder: (context, box, child) {
                  if (box.isEmpty) {
                    return _refreshableCenter(
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
                    return _refreshableCenter(
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
                    final endDate =
                        DateTime.tryParse(ride['endTime'] ?? '')?.toLocal();
                    final arrivalTime = endDate == null
                        ? null
                        : '${endDate.hour.toString().padLeft(2, '0')}:'
                            '${endDate.minute.toString().padLeft(2, '0')}';

                    final practiceKey = (ride['practice'] as String?)?.isNotEmpty == true
                        ? ride['practice'] as String
                        : detectPractice(ride);

                    // Compteurs de contenu enrichi (WP + photos) pour les badges.
                    var wpCount = 0;
                    var photoCount = 0;
                    final wps = ride['waypoints'] as List?;
                    if (wps != null) {
                      wpCount = wps.length;
                      for (final wp in wps) {
                        if (wp is Map) {
                          photoCount += (wp['photos'] as List?)?.length ?? 0;
                        }
                      }
                    }

                    // Lieux départ / arrivée : startCity (fallback ancienne
                    // clé `city`) et endCity. On n'affiche l'arrivée que si elle
                    // diffère du départ (sinon redondant sur une boucle).
                    final startCity =
                        (ride['startCity'] ?? ride['city'] ?? '').toString().trim();
                    final endCity = (ride['endCity'] ?? '').toString().trim();

                    final hasTags = wpCount > 0 ||
                        photoCount > 0 ||
                        startCity.isNotEmpty ||
                        endCity.isNotEmpty ||
                        (ride['department'] ?? '').toString().isNotEmpty ||
                        (ride['region'] ?? '').toString().isNotEmpty;

                    // Étiquettes (WP / photos / lieux), construites une fois et
                    // affichées soit inline dans la colonne (tablette), soit
                    // sur une ligne pleine largeur sous la carte (téléphone).
                    final tagChildren = <Widget>[
                      if (wpCount > 0)
                        buildCountTag(Icons.place, wpCount, 'WP'),
                      if (photoCount > 0)
                        buildCountTag(Icons.photo_camera, photoCount,
                            photoCount > 1 ? 'photos' : 'photo'),
                      if (startCity.isNotEmpty)
                        buildPlaceTag(Icons.trip_origin, startCity,
                            const Color(0xFF22C55E)),
                      if (endCity.isNotEmpty && endCity != startCity)
                        buildPlaceTag(Icons.sports_score, endCity,
                            const Color(0xFFEF4444)),
                      if ((ride['department'] ?? '').toString().isNotEmpty)
                        buildTag('#${ride['department']}'),
                      if ((ride['region'] ?? '').toString().isNotEmpty)
                        buildTag('#${ride['region']}'),
                    ];

                    // Durée compacte pour la carte téléphone : « 0:17:37 » → « 17:37 ».
                    var durCompact = formatDuration(ride['durationSeconds']);
                    if (durCompact.startsWith('0:')) {
                      durCompact = durCompact.substring(2);
                    }

                    void openDetail() => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                RideDetailScreen(ride: ride, rideKey: rideKey),
                          ),
                        );

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
                          onTap: openDetail,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B1B1B),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: tagsFullWidth
                                // ────────────────────────────────────────────
                                // CARTE TÉLÉPHONE (proposition 2A) : titre en
                                // haut pleine largeur, grande carte encadrée par
                                // la date et l'icône du moment, stats + pratique
                                // sur une ligne, étiquettes pleine largeur.
                                // ────────────────────────────────────────────
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // ── Titre + menu ──
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              ride['name'] ?? departureTime,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildRideMenu(
                                              context, ride, rideKey, departureTime),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      // ── Date · grande carte · moment ──
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          SizedBox(
                                            width: 52,
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.center,
                                              children: [
                                                Text(
                                                  '${startDate.day}',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 34,
                                                    fontWeight: FontWeight.w800,
                                                    color: Colors.white,
                                                    height: 1.0,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  monthStr,
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.white70,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                                Text(
                                                  '${startDate.year}',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.white54,
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                // Heure de départ, sous la date.
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    const Icon(Icons.flag,
                                                        size: 11, color: Colors.orange),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      departureTime,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: Colors.white60,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                // Heure d'arrivée, sous le départ.
                                                if (arrivalTime != null) ...[
                                                  const SizedBox(height: 3),
                                                  Row(
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      const Icon(Icons.sports_score,
                                                          size: 11, color: Color(0xFFEF4444)),
                                                      const SizedBox(width: 3),
                                                      Text(
                                                        arrivalTime,
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                          color: Colors.white60,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                              width: 1, height: 84, color: Colors.white12),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: openDetail,
                                              child: RideTraceThumbnail(
                                                points: ride['points'] ?? [],
                                                width: double.infinity,
                                                height: 118,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      // ── Stats · pratique ──
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Wrap(
                                              spacing: 10,
                                              runSpacing: 4,
                                              crossAxisAlignment: WrapCrossAlignment.center,
                                              children: [
                                                Row(mainAxisSize: MainAxisSize.min, children: [
                                                  const Icon(Icons.timer, size: 14, color: Colors.white60),
                                                  const SizedBox(width: 4),
                                                  Text(durCompact, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                                                ]),
                                                Row(mainAxisSize: MainAxisSize.min, children: [
                                                  const Icon(Icons.route, size: 14, color: Colors.white60),
                                                  const SizedBox(width: 4),
                                                  Text(formatDistance(ride['distanceMeters']), style: const TextStyle(fontSize: 13, color: Colors.white70)),
                                                ]),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          buildPracticeTag(practiceKey, rideKey, ridesBox),
                                        ],
                                      ),
                                      if ((ride['note'] ?? '').toString().isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Icon(Icons.edit_note_rounded, size: 16, color: Colors.orange),
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
                                      if (hasTags) ...[
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: tagChildren,
                                        ),
                                      ],
                                    ],
                                  )
                                // ────────────────────────────────────────────
                                // CARTE TABLETTE — inchangée.
                                // ────────────────────────────────────────────
                                : Row(
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
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: openDetail,
                                      child: RideTraceThumbnail(
                                        points: ride['points'] ?? [],
                                        width: thumbW,
                                        height: thumbH,
                                      ),
                                    ),
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
                                          const SizedBox(height: 7),
                                          // Pratique : information essentielle,
                                          // remontée sous le titre au niveau des
                                          // stats (durée / distance).
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: buildPracticeTag(
                                                practiceKey, rideKey, ridesBox),
                                          ),
                                          const SizedBox(height: 7),
                                          // Durée + distance : en Wrap pour que
                                          // la distance passe à la ligne plutôt
                                          // que d'être tronquée sur écran étroit.
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 4,
                                            crossAxisAlignment: WrapCrossAlignment.center,
                                            children: [
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(Icons.timer, size: 14, color: Colors.white60),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    formatDuration(ride['durationSeconds']),
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      color: Colors.white70,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(Icons.route, size: 14, color: Colors.white60),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    formatDistance(ride['distanceMeters']),
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      color: Colors.white70,
                                                    ),
                                                  ),
                                                ],
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
                                          // Tablette : étiquettes inline dans
                                          // la colonne. Téléphone : rendues plus
                                          // bas, pleine largeur.
                                          if (hasTags && !tagsFullWidth) ...[
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: tagChildren,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4, top: 2),
                                      child: PopupMenuButton<String>(
                                        tooltip: 'Actions',
                                        color: const Color(0xFF1A1A1A),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        position: PopupMenuPosition.under,
                                        onSelected: (value) async {
                                          if (value == 'share') {
                                            Navigator.push(context, MaterialPageRoute(
                                              builder: (_) => RideSharePreviewScreen(
                                                ride: Map<String, dynamic>.from(ride),
                                                rideName: (ride['name'] as String?) ?? departureTime,
                                              ),
                                            ));
                                          } else if (value == 'delete') {
                                            await deleteRide(context, ride, rideKey);
                                          }
                                        },
                                        itemBuilder: (_) => [
                                          const PopupMenuItem<String>(
                                            value: 'share',
                                            child: Row(children: [
                                              Icon(Icons.image_outlined, color: Colors.purple, size: 20),
                                              SizedBox(width: 12),
                                              Text('Partager un résumé',
                                                  style: TextStyle(color: Colors.white)),
                                            ]),
                                          ),
                                          const PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Row(children: [
                                              Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                              SizedBox(width: 12),
                                              Text('Supprimer la sortie',
                                                  style: TextStyle(color: Colors.red)),
                                            ]),
                                          ),
                                        ],
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: const Color(0xFF232323),
                                            border: Border.all(color: Colors.white24, width: 1),
                                          ),
                                          child: const Icon(Icons.more_vert, color: Colors.white70, size: 20),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                          ),
                        ),
                      ),
                    );
                  }

                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom),
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
                  fontSize: 11,
                  color: Colors.white60,
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}