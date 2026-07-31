import 'dart:io';

import 'package:flutter/services.dart';

/// Pont vers le natif Android pour l'affichage de la fiche SOS sur l'écran
/// verrouillé.
///
/// Deux mécanismes distincts, à ne pas confondre :
///  - `showOverLockScreen` : l'activité s'affiche **par-dessus** l'écran de
///    verrouillage. Le téléphone reste verrouillé — un passant voit la fiche
///    mais n'accède ni aux SMS, ni aux photos, ni au reste de l'appli.
///  - `lockNow` : verrouille l'écran. Nécessite que l'utilisateur ait activé
///    Sunday Tracker comme administrateur d'appareil (droit `force-lock`) ;
///    c'est le seul moyen supporté par Android, et il est révocable à tout
///    moment dans les réglages système.
///
/// iOS n'expose rien d'équivalent : toutes les méthodes y sont sans effet
/// (cf. Live Activity, à traiter séparément).
class SosLockService {
  static const MethodChannel _channel =
      MethodChannel('sunday_tracker/sos_lock');

  static bool get isSupported => Platform.isAndroid;

  /// Affiche (ou non) l'appli au-dessus de l'écran de verrouillage.
  ///
  /// [turnScreenOn] rallume l'écran en plus. Dissocié volontairement : combiné
  /// à [lockNow] il peut faire clignoter l'écran selon le constructeur.
  static Future<void> showOverLockScreen(
    bool show, {
    bool turnScreenOn = false,
  }) async {
    if (!isSupported) return;
    await _channel.invokeMethod('showOverLockScreen', {
      'show': show,
      'turnScreenOn': turnScreenOn,
    });
  }

  /// L'utilisateur a-t-il accordé le droit de verrouiller l'écran ?
  static Future<bool> isAdminActive() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isAdminActive') ?? false;
  }

  /// Ouvre l'écran système d'activation de l'administrateur d'appareil.
  static Future<void> requestAdmin() async {
    if (!isSupported) return;
    await _channel.invokeMethod('requestAdmin');
  }

  /// Verrouille l'écran. Renvoie false si le droit n'a pas été accordé.
  static Future<bool> lockNow() async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('lockNow') ?? false;
  }

  /// État du verrou système : `locked` (écran de veille affiché) et `secure`
  /// (un code/schéma est configuré — sans lui le test ne prouve rien).
  static Future<({bool locked, bool secure})> keyguardState() async {
    if (!isSupported) return (locked: false, secure: false);
    final map = await _channel.invokeMapMethod<String, dynamic>('keyguardState');
    return (
      locked: map?['locked'] == true,
      secure: map?['secure'] == true,
    );
  }
}
