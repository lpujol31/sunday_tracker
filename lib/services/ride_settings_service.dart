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
}
