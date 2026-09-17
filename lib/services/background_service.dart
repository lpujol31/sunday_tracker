import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String notificationChannelId = 'sunday_tracker_channel';
const int foregroundNotificationId = 888;

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    'Sunday Tracker',
    description: 'Notification utilisée pendant le suivi GPS.',
    importance: Importance.low,
  );

  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
  androidConfiguration: AndroidConfiguration(
    onStart: onStartBackgroundService,
    autoStart: false,
    isForegroundMode: true,

    foregroundServiceTypes: [
      AndroidForegroundType.location,
    ],

    notificationChannelId: notificationChannelId,
    initialNotificationTitle: 'Sunday Tracker',
    initialNotificationContent: 'Sortie en cours — tracking actif',
    foregroundServiceNotificationId: foregroundNotificationId,
  ),
  iosConfiguration: IosConfiguration(
    autoStart: false,
    onForeground: onStartBackgroundService,
  ),
);
}

/// Texte par défaut de la notification permanente (sortie en cours de roulage).
const String kDefaultNotificationContent = 'Sortie en cours — tracking GPS actif';

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();

    service.setForegroundNotificationInfo(
      title: 'Sunday Tracker',
      content: kDefaultNotificationContent,
    );
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Texte de la notification permanente piloté depuis l'écran de sortie : elle
  // affichait « Sortie en cours » même en pause, c'est-à-dire exactement
  // l'inverse de la réalité au moment où ça compte (on oublie de reprendre).
  // Cf. `_pushNotificationState()` dans ride_screen.dart.
  service.on('updateNotification').listen((event) {
    if (service is! AndroidServiceInstance) return;
    service.setForegroundNotificationInfo(
      title: (event?['title'] as String?) ?? 'Sunday Tracker',
      content: (event?['content'] as String?) ?? kDefaultNotificationContent,
    );
  });

  Timer.periodic(
    const Duration(seconds: 10),
    (timer) async {
      if (service is AndroidServiceInstance) {
        final isForeground = await service.isForegroundService();

        if (!isForeground) {
          timer.cancel();
        }
      }
    },
  );
}