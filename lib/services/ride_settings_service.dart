import 'package:shared_preferences/shared_preferences.dart';

/// Réglages liés à l'enregistrement des sorties, persistés dans les
/// préférences locales (SharedPreferences).
///
/// Pour l'instant : le « Mode automatique » (détection auto des pauses et
/// reprises pendant l'enregistrement). Le réglage est stocké ici ; le
/// comportement de détection est branché côté `RideScreen` (cf. étape 2).
class RideSettingsService {
  static const String _kAutoPauseKey = 'ride_auto_pause_enabled';

  /// Valeur par défaut : mode automatique activé (cf. mockup).
  static const bool _kAutoPauseDefault = true;

  static const String _kAdaptToPracticeKey = 'ride_auto_pause_adapt_practice';

  /// Valeur par défaut : les seuils s'adaptent à la pratique choisie.
  static const bool _kAdaptToPracticeDefault = true;

  /// Lit l'état du mode automatique (pause/reprise détectées).
  static Future<bool> isAutoPauseEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoPauseKey) ?? _kAutoPauseDefault;
  }

  /// Active / désactive le mode automatique.
  static Future<void> setAutoPauseEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoPauseKey, value);
  }

  /// Lit si les seuils de détection s'adaptent à la pratique en cours (marche,
  /// vélo route, VTT…) plutôt que d'utiliser un jeu générique unique.
  static Future<bool> isAdaptToPracticeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAdaptToPracticeKey) ?? _kAdaptToPracticeDefault;
  }

  /// Active / désactive l'adaptation des seuils à la pratique.
  static Future<void> setAdaptToPracticeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAdaptToPracticeKey, value);
  }

  static const String _kResumeWatchKey = 'ride_resume_watch_enabled';

  /// Valeur par défaut : le rattrapage de reprise est actif.
  ///
  /// Il est volontairement INDÉPENDANT du mode automatique : oublier de
  /// reprendre est le seul oubli qui détruit des données (trace coupée,
  /// position figée côté live et fiche SOS), et le rattrapage ne peut pas se
  /// tromper au point de fausser une sortie — au pire il enregistre quelques
  /// mètres de marche à l'arrêt, que la porte anti-gigue refuse de graver.
  static const bool _kResumeWatchDefault = true;

  /// Lit le rattrapage de reprise : pendant une pause manuelle, l'app garde une
  /// veille GPS basse conso et relance l'enregistrement dès qu'on s'éloigne
  /// franchement du point de pause.
  static Future<bool> isResumeWatchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kResumeWatchKey) ?? _kResumeWatchDefault;
  }

  /// Active / désactive le rattrapage de reprise.
  static Future<void> setResumeWatchEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kResumeWatchKey, value);
  }
}
