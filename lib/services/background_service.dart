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

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();

    service.setForegroundNotificationInfo(
      title: 'Sunday Tracker',
      content: 'Sortie en cours — tracking GPS actif',
    );
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
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