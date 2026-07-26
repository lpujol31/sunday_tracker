/// Seuils de détection automatique des pauses / reprises, calés sur la vitesse
/// de croisière d'une pratique.
///
/// Pourquoi un profil par pratique : vélo (~25 km/h) et marche (~4-5 km/h) ont
/// des vitesses de croisière dans un rapport ~5. Un seuil bon pour l'un est
/// structurellement mauvais pour l'autre — en particulier le seuil de reprise
/// vélo (5 km/h) est *au-dessus* de la vitesse de marche, donc en rando la
/// reprise ne se déclencherait jamais par la vitesse, seulement par le
/// déplacement, avec du retard.
///
/// Règle de calage : les seuils se positionnent relativement à la croisière —
/// pause ≈ 20-30 %, reprise ≈ 50-60 % (toujours > pause : c'est l'hystérésis
/// qui évite d'osciller à un feu rouge ou dans une montée lente).
class AutoPauseProfile {
  /// Sous ce seuil (km/h), le point est candidat à l'immobilité.
  final double pauseSpeedKmh;

  /// Au-dessus de ce seuil (km/h), on considère qu'on a repris. Strictement
  /// supérieur à [pauseSpeedKmh] (hystérésis).
  final double resumeSpeedKmh;

  /// Éloignement (m) du point de pause qui vaut reprise immédiate, sans attendre
  /// la confirmation de vitesse.
  final double resumeDistanceM;

  /// Déplacement minimal (m) entre deux fixes GPS considéré comme du mouvement
  /// réel (au-dessus du bruit à l'arrêt, cf. distanceFilter du flux).
  final double movedFixM;

  /// Immobilité maintenue avant de basculer en pause.
  final Duration pauseAfter;

  /// Mouvement maintenu avant de confirmer la reprise.
  final Duration resumeAfter;

  const AutoPauseProfile({
    required this.pauseSpeedKmh,
    required this.resumeSpeedKmh,
    required this.resumeDistanceM,
    required this.movedFixM,
    required this.pauseAfter,
    required this.resumeAfter,
  });
}

/// Jeu générique : l'historique validé à vélo le 2026-07-21. Sert quand
/// l'adaptation à la pratique est coupée, ou pour une pratique inconnue /
/// « Auto » / « Autre ».
const AutoPauseProfile kGenericAutoPauseProfile = AutoPauseProfile(
  pauseSpeedKmh: 2.0,
  resumeSpeedKmh: 5.0,
  resumeDistanceM: 20.0,
  movedFixM: 12.0,
  pauseAfter: Duration(seconds: 25),
  resumeAfter: Duration(seconds: 5),
);

/// Profils par clé de pratique (cf. `kPracticeTypes` dans home_screen.dart).
/// Une pratique absente de cette table retombe sur [kGenericAutoPauseProfile].
const Map<String, AutoPauseProfile> kAutoPauseProfiles = {
  // Vélo route ~25 km/h : reste sur le jeu générique validé.
  'route': kGenericAutoPauseProfile,
  // VTT ~12-15 km/h : allures plus basses, seuils resserrés.
  'vtt': AutoPauseProfile(
    pauseSpeedKmh: 1.5,
    resumeSpeedKmh: 4.0,
    resumeDistanceM: 18.0,
    movedFixM: 12.0,
    pauseAfter: Duration(seconds: 25),
    resumeAfter: Duration(seconds: 5),
  ),
  // Enduro : proche du VTT.
  'enduro': AutoPauseProfile(
    pauseSpeedKmh: 1.5,
    resumeSpeedKmh: 4.0,
    resumeDistanceM: 18.0,
    movedFixM: 12.0,
    pauseAfter: Duration(seconds: 25),
    resumeAfter: Duration(seconds: 5),
  ),
  // Marche / rando ~4-5 km/h : reprise sous la vitesse de marche, et pause plus
  // patiente (une montée lente ne doit pas passer pour un arrêt) tout en captant
  // les vrais arrêts (attentes en famille).
  'marche': AutoPauseProfile(
    pauseSpeedKmh: 1.0,
    resumeSpeedKmh: 2.5,
    resumeDistanceM: 12.0,
    movedFixM: 8.0,
    pauseAfter: Duration(seconds: 35),
    resumeAfter: Duration(seconds: 5),
  ),
  // Running ~9-11 km/h.
  'running': AutoPauseProfile(
    pauseSpeedKmh: 1.5,
    resumeSpeedKmh: 3.5,
    resumeDistanceM: 15.0,
    movedFixM: 10.0,
    pauseAfter: Duration(seconds: 20),
    resumeAfter: Duration(seconds: 5),
  ),
  // 'autre' : absent volontairement → jeu générique.
};
