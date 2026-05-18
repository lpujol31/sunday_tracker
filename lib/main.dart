import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  await Hive.openBox('rides');
  await initializeBackgroundService();

  runApp(const SundayTrackerApp());
}

class SundayTrackerApp extends StatelessWidget {
  const SundayTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sunday Tracker',
      theme: ThemeData.dark(),
      //home: const HomeScreen(),
      home: const HomeScreen(),
    );
  }
}