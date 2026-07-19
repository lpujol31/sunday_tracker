import 'package:hive/hive.dart';
import 'package:latlong2/latlong.dart';

import 'altitude_reference_service.dart';
import 'elevation_stats.dart';

/// Récupération d'une sortie interrompue par un arrêt brutal (batterie à plat,
/// crash, kill Android).
///
/// Pendant un ride, chaque point GPS est gravé au fil de l'eau dans la box Hive
/// `current_ride` (cf. ride_screen : `_currentRideBox?.add(gpsPoint)`). Cette box
/// est vidée à trois moments — au démarrage d'un nouveau ride, à la sauvegarde,
/// et à l'abandon. Donc si elle contient encore des points au lancement de
/// l'app, c'est qu'une sortie ne s'est jamais terminée proprement : le téléphone
/// s'est éteint (batterie), l'app a été tuée, ou elle a planté. On reconstruit
/// alors une sortie exploitable à partir de ces points, plutôt que de la perdre.
///
/// La sortie reconstruite n'a pas tout ce qu'un STOP normal capture (waypoints,
/// météo, vitesses instantanées) : seuls le tracé, les distances, les altitudes
/// et les horaires sont retrouvés. C'est très largement mieux que rien.
class InterruptedRideService {
  static const String boxName = 'current_ride';

  /// Nombre de points en attente. 0 (ou 1) ⇒ aucune sortie récupérable.
  static Future<int> pendingCount() async {
    final box = await Hive.openBox(boxName);
    return box.values.whereType<Map>().length;
  }

  /// Vide la box : l'utilisateur a choisi de jeter la sortie interrompue.
  static Future<void> discard() async {
    final box = await Hive.openBox(boxName);
    await box.clear();
  }

  /// Reconstruit une sortie (mêmes clés que `saveRide`) depuis les points
  /// mémorisés, puis vide la box. Renvoie null si rien d'exploitable.
  static Future<Map<String, dynamic>?> buildRecoveredRide() async {
    final box = await Hive.openBox(boxName);
    final points = box.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
        .where((p) => p['lat'] is num && p['lng'] is num)
        .toList();
    if (points.length < 2) return null;

    DateTime? parseTs(Map p) {
      final raw = p['ts'] ?? p['time'] ?? p['timestamp'];
      return raw is String ? DateTime.tryParse(raw) : null;
    }

    final startTs = parseTs(points.first);
    final endTs = parseTs(points.last);

    // Distance : somme des segments consécutifs, comme le ride live.
    const distance = Distance();
    double meters = 0;
    for (var i = 1; i < points.length; i++) {
      final a = LatLng(
        (points[i - 1]['lat'] as num).toDouble(),
        (points[i - 1]['lng'] as num).toDouble(),
      );
      final b = LatLng(
        (points[i]['lat'] as num).toDouble(),
        (points[i]['lng'] as num).toDouble(),
      );
      meters += distance.as(LengthUnit.Meter, a, b);
    }

    // Altitudes : mêmes calage et filtrage que saveRide (offline-safe : sans
    // réseau, l'offset reste null et les altitudes restent brutes).
    final altOffset = await AltitudeReferenceService().offsetForPoints(points);
    final elevation = elevationStatsFromPoints(points).shifted(altOffset);

    final duration = (startTs != null && endTs != null)
        ? endTs.difference(startTs)
        : Duration.zero;

    final localStart = (startTs ?? DateTime.now()).toLocal();
    final name = 'Sortie récupérée du '
        '${localStart.day.toString().padLeft(2, '0')}/'
        '${localStart.month.toString().padLeft(2, '0')}/${localStart.year}';

    final ride = <String, dynamic>{
      'name': name,
      'note': 'Sortie récupérée automatiquement après un arrêt inattendu '
          '(batterie déchargée ou fermeture de l\'app).',
      'startTime': startTs?.toUtc().toIso8601String(),
      'endTime': endTs?.toUtc().toIso8601String(),
      'durationSeconds': duration.inSeconds,
      'pausedSeconds': 0,
      'distanceMeters': meters,
      'totalElevationMeters': elevation.gain,
      'totalElevationDown': elevation.loss,
      'altitudeStart': elevation.altStart,
      'altitudeEnd': elevation.altEnd,
      'altitudeMax': elevation.altMax,
      'altitudeMin': elevation.altMin,
      'altitudeOffsetMeters': altOffset,
      'points': points,
      'waypoints': <dynamic>[],
      'recovered': true,
    };

    await box.clear();
    return ride;
  }
}
