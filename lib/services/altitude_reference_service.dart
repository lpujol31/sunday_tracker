import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Recale les altitudes GPS sur le niveau de la mer.
///
/// `Location.getAltitude()` (Android) renvoie la hauteur au-dessus de
/// l'ellipsoïde WGS84, pas au-dessus du niveau de la mer. L'écart entre les deux
/// — l'ondulation du géoïde — vaut environ +50 m en Ariège : le col de Marrous
/// (990 m) s'y mesure à 1041 m, et le départ comme l'arrivée d'une sortie de
/// 31 km y sont tous deux hauts de 50 et 51 m. C'est un biais constant à
/// l'échelle d'une sortie, donc sans effet sur le D+ (il s'annule dans les
/// différences), mais il fausse toutes les altitudes affichées.
///
/// Plutôt que d'embarquer un modèle de géoïde, on mesure le décalage : on
/// demande à un modèle numérique de terrain l'altitude réelle du sol sous
/// quelques points de la trace, et on prend l'écart médian avec ce qu'a mesuré
/// le GPS. La médiane, et non la moyenne : elle encaisse les points où le MNT se
/// trompe (pont, tunnel) et ceux où le GPS avait décroché.
///
/// **La résolution du MNT est déterminante, et c'est contre-intuitif.** Avec le
/// MNT mondial Copernicus (maille 30 m, via Open-Meteo), le calage était faux de
/// 15 à 20 m : une route est toujours dans une vallée ou taillée à flanc, or un
/// MNT grossier lisse les fonds de vallée *vers le haut* — dans les gorges de
/// l'Arget il annonçait 586 m là où le sol est à 539 m. L'erreur n'étant pas
/// symétrique, même la médiane est tirée vers le bas (35 m au lieu de 52 m).
/// Le RGE ALTI de l'IGN (maille 1 m) n'a pas ce défaut : il rend 50,4 m sur la
/// trace de référence, quand le Garmin barométrique en donne 52. On l'utilise
/// donc en premier, et Open-Meteo seulement en repli hors de France.
///
/// Sans réseau, la méthode ne renvoie rien et l'app affiche les altitudes
/// brutes : c'est dégradé, pas cassé.
class AltitudeReferenceService {
  /// Nombre de points interrogés. Le MNT se trompe lourdement sur certains
  /// points (falaise, pont) : il en faut assez pour que la médiane les ignore.
  /// À douze, elle sautait encore de 35 à 47 m d'un échantillon à l'autre.
  static const int _kSampleCount = 25;

  static const Duration _kTimeout = Duration(seconds: 8);

  /// Écart au-delà duquel on refuse de croire au résultat : l'ondulation du
  /// géoïde ne dépasse pas ±110 m sur Terre. Au-delà, c'est que quelque chose
  /// d'autre a mal tourné, et mieux vaut ne rien corriger que corriger à faux.
  static const double _kMaxPlausibleOffset = 120;

  /// Valeur « pas de donnée » du RGE ALTI (hors couverture France).
  static const double _kIgnNoData = -1000;

  /// Renvoie le décalage à retrancher aux altitudes GPS de cette sortie, ou
  /// `null` si on n'a pas pu l'établir (hors-ligne, trace trop courte, résultat
  /// aberrant). `null` veut dire « ne corrige rien », jamais « corrige de 0 ».
  Future<double?> offsetForPoints(List<dynamic> points) async {
    final samples = _pickSamples(points);
    if (samples.length < 3) return null;

    final ground = await _groundIgn(samples) ?? await _groundOpenMeteo(samples);
    if (ground == null) return null;

    final deltas = <double>[];
    for (int i = 0; i < samples.length; i++) {
      final g = ground[i];
      if (g == null) continue;
      deltas.add(samples[i]['alt']! - g);
    }
    if (deltas.length < 3) return null;

    deltas.sort();
    final offset = deltas[deltas.length ~/ 2];
    if (offset.abs() > _kMaxPlausibleOffset) return null;
    return offset;
  }

  /// RGE ALTI (IGN), maille 1 m, gratuit et sans clé — mais France uniquement.
  Future<List<double?>?> _groundIgn(List<Map<String, double>> samples) async {
    try {
      final lons = samples.map((p) => p['lng']).join('|');
      final lats = samples.map((p) => p['lat']).join('|');
      final uri = Uri.parse(
        'https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json'
        '?lon=$lons&lat=$lats&resource=ign_rge_alti_wld&delimiter=|&zonly=true',
      );
      final res = await http.get(uri).timeout(_kTimeout);
      if (res.statusCode != 200) return null;

      final raw = (jsonDecode(res.body)['elevations'] as List?)?.cast<num>();
      if (raw == null || raw.length != samples.length) return null;

      // Hors couverture, l'IGN rend une sentinelle très négative.
      final out = raw
          .map((v) => v.toDouble() <= _kIgnNoData ? null : v.toDouble())
          .toList();
      if (out.whereType<double>().length < 3) return null;
      return out;
    } catch (e) {
      debugPrint('[ALTITUDE] IGN indisponible: $e');
      return null;
    }
  }

  /// Repli hors de France : MNT mondial Copernicus. Maille 30 m, donc bien moins
  /// fidèle en montagne (cf. commentaire de classe) — mais mieux que rien.
  Future<List<double?>?> _groundOpenMeteo(
      List<Map<String, double>> samples) async {
    try {
      final lats = samples.map((p) => p['lat']).join(',');
      final lngs = samples.map((p) => p['lng']).join(',');
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/elevation'
        '?latitude=$lats&longitude=$lngs',
      );
      final res = await http.get(uri).timeout(_kTimeout);
      if (res.statusCode != 200) return null;

      final raw = (jsonDecode(res.body)['elevation'] as List?)?.cast<num>();
      if (raw == null || raw.length != samples.length) return null;
      return raw.map<double?>((v) => v.toDouble()).toList();
    } catch (e) {
      debugPrint('[ALTITUDE] calage impossible: $e');
      return null;
    }
  }

  /// Échantillonne la trace en écartant les altitudes figées, puis en étalant
  /// les points retenus sur toute la sortie — douze points voisins du départ ne
  /// diraient rien du reste.
  ///
  /// Le rejet des paliers doit être *identique* à celui d'elevation_stats.dart :
  /// tout run de valeurs égales bit à bit saute en entier, première occurrence
  /// comprise. Ne retirer que les répétitions laissait passer la tête de chaque
  /// palier, et ces fausses mesures produisaient des écarts GPS↔MNT aberrants
  /// (9 m, 17 m au lieu de ~47 m) qui polluaient l'échantillon.
  List<Map<String, double>> _pickSamples(List<dynamic> points) {
    final valid = <Map<String, double>>[];
    for (final p in points) {
      if (p is! Map) continue;
      final alt = p['alt'];
      final lat = p['lat'];
      final lng = p['lng'];
      if (alt is! num || lat is! num || lng is! num) continue;
      valid.add({
        'lat': lat.toDouble(),
        'lng': lng.toDouble(),
        'alt': alt.toDouble(),
      });
    }

    final real = <Map<String, double>>[];
    for (int i = 0; i < valid.length;) {
      int j = i;
      while (j + 1 < valid.length && valid[j + 1]['alt'] == valid[i]['alt']) {
        j++;
      }
      if (j == i) real.add(valid[i]);
      i = j + 1;
    }
    if (real.isEmpty) return const [];

    final step = max(1, real.length ~/ _kSampleCount);
    final out = <Map<String, double>>[];
    for (int i = 0; i < real.length && out.length < _kSampleCount; i += step) {
      out.add(real[i]);
    }
    return out;
  }
}
