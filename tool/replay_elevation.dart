// Rejoue une trace GPS réelle et compare l'ancien calcul de dénivelé au
// nouveau. Sert à calibrer les filtres sur des données de terrain.
//
//   dart run tool/replay_elevation.dart <fichier.json>
//
// Le fichier peut être une ligne de `safety_sessions` (avec `ride_json`), un
// `ride_json` seul, ou directement un tableau de points {ts, lat, lng, alt}.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sunday_tracker/services/elevation_stats.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/replay_elevation.dart <fichier.json>');
    exit(64);
  }

  final raw = jsonDecode(File(args.first).readAsStringSync());
  final points = _extractPoints(raw);
  if (points.isEmpty) {
    stderr.writeln('Aucun point trouvé dans ${args.first}');
    exit(1);
  }

  // ── Ancien calcul : cumul point à point, seuil 0,5 m (ride_screen.dart) ──
  double legacyGain = 0, legacyLoss = 0;
  double? prev;
  for (final p in points) {
    final alt = (p['alt'] as num).toDouble();
    if (prev != null) {
      final d = alt - prev;
      if (d > 0.5) legacyGain += d;
      if (d < -0.5) legacyLoss += -d;
    }
    prev = alt;
  }
  final rawAlts = points.map((p) => (p['alt'] as num).toDouble()).toList();

  final stats = elevationStatsFromPoints(points);

  final start = DateTime.parse(points.first['ts'] as String);
  final end = DateTime.parse(points.last['ts'] as String);
  final distanceKm = _traceLengthMeters(points) / 1000;

  String m(num v) => '${v.toStringAsFixed(0)} m';

  print('Points          : ${points.length}');
  print('Durée           : ${end.difference(start)}');
  print('Distance        : ${distanceKm.toStringAsFixed(1)} km');
  print('');
  print('                   ANCIEN        NOUVEAU');
  print('D+              : ${m(legacyGain).padRight(14)}${m(stats.gain)}');
  print('D−              : ${m(legacyLoss).padRight(14)}${m(stats.loss)}');
  print('Alt. max        : ${m(rawAlts.reduce(max)).padRight(14)}'
      '${m(stats.altMax!)}');
  print('Alt. min        : ${m(rawAlts.reduce(min)).padRight(14)}'
      '${m(stats.altMin!)}');
  print('Alt. départ     : ${m(rawAlts.first).padRight(14)}${m(stats.altStart!)}');
  print('Alt. arrivée    : ${m(rawAlts.last).padRight(14)}${m(stats.altEnd!)}');
  print('');
  // Contrôle de cohérence : sur une boucle, D+ − D− doit valoir l'écart entre
  // l'altitude d'arrivée et celle de départ. Un écart important trahit du bruit
  // compté comme du dénivelé.
  final closure = stats.gain - stats.loss;
  final expected = stats.altEnd! - stats.altStart!;
  print('Cohérence (D+ − D− vs arrivée − départ) :');
  print('  ancien  : ${m(legacyGain - legacyLoss)} vs '
      '${m(rawAlts.last - rawAlts.first)}');
  print('  nouveau : ${m(closure)} vs ${m(expected)}');
}

List<Map<String, dynamic>> _extractPoints(dynamic raw) {
  dynamic node = raw;
  if (node is List && node.isNotEmpty && node.first is Map &&
      (node.first as Map).containsKey('ride_json')) {
    node = node.first;
  }
  if (node is Map && node['ride_json'] != null) node = node['ride_json'];
  if (node is Map && node['points'] != null) node = node['points'];
  if (node is! List) return [];
  return node
      .whereType<Map>()
      .where((p) => p['alt'] is num && p['ts'] is String)
      .map((p) => Map<String, dynamic>.from(p))
      .toList();
}

double _traceLengthMeters(List<Map<String, dynamic>> points) {
  double total = 0;
  for (int i = 1; i < points.length; i++) {
    total += _haversine(
      (points[i - 1]['lat'] as num).toDouble(),
      (points[i - 1]['lng'] as num).toDouble(),
      (points[i]['lat'] as num).toDouble(),
      (points[i]['lng'] as num).toDouble(),
    );
  }
  return total;
}

double _haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}
