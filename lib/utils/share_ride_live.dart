import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// URL publique du viewer web « Sunday Live » (replay de la sortie).
/// `null` si la sortie n'a jamais eu de session live (pas de `share_code`) :
/// dans ce cas il n'y a rien à rejouer côté web.
String? liveReplayUrl(Map ride) {
  final code = ride['safetyShareCode'];
  if (code == null || code.toString().trim().isEmpty) return null;
  return 'https://sunday-tracker-live.web.app/?code=$code';
}

/// Libellé (emoji + texte) de chaque pratique pour le résumé texte du partage.
/// Dupliqué ici volontairement : un util ne doit pas dépendre d'un écran, et le
/// jeu de pratiques bouge rarement. Les clés correspondent à `kPracticeTypes`.
const Map<String, String> _practiceShareLabels = {
  'vtt': '🚵 VTT',
  'enduro': '🏍️ Enduro',
  'route': '🚴 Vélo route',
  'marche': '🚶 Marche',
  'running': '🏃 Running',
  'autre': '🧭 Sortie',
};

/// Partage le lien vers le replay de la sortie plutôt qu'une image générée : le
/// viewer web contient déjà la carte animée + les stats, inutile de dupliquer
/// tout ça dans une carte-image. On accompagne le lien d'un court résumé texte.
///
/// L'aperçu (logo + slogan « Partez libre ») visible dans la messagerie est
/// généré automatiquement à partir des balises Open Graph du site, comme pour le
/// partage du direct : il suffit de laisser l'URL seule sur la dernière ligne.
Future<void> shareRideLiveLink(
  BuildContext context,
  Map ride,
  String rideName,
) async {
  final url = liveReplayUrl(ride);
  if (url == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Replay indisponible : cette sortie n\'a pas de lien live.'),
      ),
    );
    return;
  }

  final distM = (ride['distanceMeters'] ?? 0.0).toDouble();
  final durS = ((ride['durationSeconds'] ?? 0) as num).toInt();
  final dPlus = (ride['totalElevationMeters'] ?? 0.0).toDouble();

  final distVal = distM < 1000
      ? '${distM.toStringAsFixed(0)} m'
      : '${(distM / 1000).toStringAsFixed(2)} km';
  final dur = Duration(seconds: durS);
  final durVal = dur.inHours > 0
      ? '${dur.inHours}h${(dur.inMinutes % 60).toString().padLeft(2, '0')}'
      : '${dur.inMinutes} min';

  // On préfère la pratique au dénivelé dans le résumé ; repli sur le D+ si la
  // sortie n'a pas de pratique connue (anciennes sorties).
  final practiceLabel = _practiceShareLabels[ride['practice']?.toString()];
  final thirdStat = practiceLabel ?? 'D+ ${dPlus.toStringAsFixed(0)} m';

  final text = '$rideName\n'
      '$distVal · $durVal · $thirdStat\n\n'
      'Revis le parcours en replay 👇\n$url';

  await Share.share(text, subject: rideName);
}
