import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
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