import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Alertes vibrées pendant une sortie : « tu es toujours en pause » et
/// « l'enregistrement a repris tout seul ».
///
/// Pourquoi des canaux à part : celui du service de premier plan
/// (`sunday_tracker_channel`) est volontairement en `Importance.low` — la
/// notification permanente « Sortie en cours » ne doit ni sonner ni vibrer,
/// sinon elle serait insupportable. Or un rappel doit, lui, traverser une poche
/// de blouson : il lui faut `Importance.high`.
///
/// Et deux canaux plutôt qu'un seul : à partir d'Android 8, le motif de
/// vibration est porté par le CANAL, pas par la notification. Deux motifs
/// distincts (donc reconnaissables sans sortir le téléphone) imposent donc deux
/// canaux :
///   • pause   → deux vibrations courtes  ( •• )   « décide quelque chose »
///   • reprise → une vibration longue     ( —— )   « c'est reparti, c'est fait »
class RideAlertsService {
  static const String pauseChannelId = 'sunday_tracker_pause';
  static const String resumeChannelId = 'sunday_tracker_resume';

  // Ids de notification : distincts de celui du foreground service (888).
  static const int pauseReminderId = 889;
  static const int resumeNoticeId = 890;

  static const String _resumeActionId = 'resume_ride';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Appelé quand l'utilisateur touche le bouton « Reprendre » du rappel de
  /// pause. Branché par l'écran de sortie (et remis à null en sortant).
  static VoidCallback? onResumeRequested;

  static Future<void> init() async {
    if (_ready) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        pauseChannelId,
        'Rappel de pause',
        description:
            'Rappelle que la sortie est toujours en pause (deux vibrations).',
        importance: Importance.high,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 220, 160, 220]),
      ),
    );
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        resumeChannelId,
        'Reprise rattrapée',
        description:
            'Signale que l\'enregistrement a repris tout seul (une vibration '
            'longue).',
        importance: Importance.high,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(<int>[0, 700]),
      ),
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        // Seul le bouton « Reprendre » relance la sortie. Un simple appui sur le
        // corps de la notification ne fait qu'ouvrir l'appli : reprendre sur un
        // tap involontaire (poche) serait pire que le problème traité.
        if (response.actionId == _resumeActionId) onResumeRequested?.call();
      },
    );
    _ready = true;
  }

  /// Demande la permission de notifier (Android 13+). Appelée au DÉPART de la
  /// sortie et pas à l'ouverture de l'écran : une boîte de dialogue système en
  /// pleine initialisation GPS tomberait comme un cheveu sur la soupe.
  static Future<void> ensurePermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Rappel « la sortie est en pause depuis [since] », avec un bouton
  /// « Reprendre » pour repartir sans naviguer dans l'appli.
  static Future<void> showPauseReminder(Duration since) async {
    await init();
    await _plugin.show(
      pauseReminderId,
      '⏸ Sortie en pause depuis ${_fmt(since)}',
      'Tu es reparti sans reprendre l\'enregistrement ?',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          pauseChannelId,
          'Rappel de pause',
          channelDescription:
              'Rappelle que la sortie est toujours en pause (deux vibrations).',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          // Reste affichée tant qu'on n'a pas repris : c'est un pense-bête, pas
          // une info fugace.
          autoCancel: false,
          onlyAlertOnce: false,
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(
              _resumeActionId,
              'Reprendre',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
    );
  }

  /// Avis « tu es reparti, l'enregistrement a repris tout seul ».
  static Future<void> showResumeNotice() async {
    await init();
    await _plugin.show(
      resumeNoticeId,
      '▶ Enregistrement repris',
      'Tu es reparti — la sortie s\'est relancée toute seule.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          resumeChannelId,
          'Reprise rattrapée',
          channelDescription:
              'Signale que l\'enregistrement a repris tout seul (une '
              'vibration longue).',
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
          timeoutAfter: 60000, // l'info a une durée de vie courte
        ),
      ),
    );
  }

  /// Retire le rappel de pause (à la reprise, ou à l'arrêt de la sortie).
  static Future<void> cancelPauseReminder() async {
    if (!_ready) return;
    await _plugin.cancel(pauseReminderId);
  }

  /// Retire toutes les alertes de sortie (fin de sortie, sortie de l'écran).
  static Future<void> cancelAll() async {
    if (!_ready) return;
    await _plugin.cancel(pauseReminderId);
    await _plugin.cancel(resumeNoticeId);
  }

  /// « 12 min », « 1 h 05 » — lisible d'un coup d'œil sur l'écran verrouillé.
  static String _fmt(Duration d) {
    if (d.inHours >= 1) {
      return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes} min';
  }
}
