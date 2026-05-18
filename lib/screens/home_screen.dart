import 'package:flutter/material.dart';
import 'ride_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sunday Tracker'),
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const RideScreen(),
              ),
            );
          },
          child: const Text('Start Ride'),
        ),
      ),
    );
  }
}