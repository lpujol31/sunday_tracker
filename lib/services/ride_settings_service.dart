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
}
