import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'ride_screen.dart';
import 'ride_detail_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  String formatDistance(dynamic meters) {
    final distance = (meters ?? 0).toDouble();

    if (distance < 1000) {
      return '${distance.toStringAsFixed(0)} m';
    }

    return '${(distance / 1000).toStringAsFixed(2)} km';
  }

  String formatDuration(dynamic seconds) {
    final duration = Duration(seconds: seconds ?? 0);
    return duration.toString().split('.').first;
  }

  @override
  Widget build(BuildContext context) {
    final ridesBox = Hive.box('rides');

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Sunday Tracker'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RideScreen(),
                    ),
                  );
                },
                child: const Text(
                  'Start Ride',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),

            const SizedBox(height: 28),

            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Dernières sorties',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: ValueListenableBuilder(
                valueListenable: ridesBox.listenable(),
                builder: (context, box, child) {
                  if (box.isEmpty) {
                    return const Center(
                      child: Text('Aucune sortie sauvegardée'),
                    );
                  }

                  final rides = List.generate(
                    box.length,
                    (index) {
                      final ride = box.getAt(index);
                      return {
                        'key': box.keyAt(index),
                        'ride': ride,
                      };
                    },
                  );

                  rides.sort((a, b) {
                    final rideA = a['ride'] as Map;
                    final rideB = b['ride'] as Map;

                    final dateA = DateTime.tryParse(rideA['startTime'] ?? '') ?? DateTime(1900);
                    final dateB = DateTime.tryParse(rideB['startTime'] ?? '') ?? DateTime(1900);

                    return dateB.compareTo(dateA);
                  });

                  return ListView.builder(
                    itemCount: rides.length,
                    itemBuilder: (context, index) {
                      final item = rides[index];
                      final rideKey = item['key'];
                      final ride = item['ride'] as Map;

                      final startDate =
                          DateTime.tryParse(ride['startTime'] ?? '') ?? DateTime.now();

                      final formattedDate =
                          '${startDate.day.toString().padLeft(2, '0')}/'
                          '${startDate.month.toString().padLeft(2, '0')}/'
                          '${startDate.year} '
                          '${startDate.hour.toString().padLeft(2, '0')}:'
                          '${startDate.minute.toString().padLeft(2, '0')}';

                      return Dismissible(
                        key: ValueKey(rideKey),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(
                            Icons.delete,
                            color: Colors.white,
                          ),
                        ),
                        confirmDismiss: (direction) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                backgroundColor: const Color(0xFF1B1B1B),
                                title: const Text('Supprimer la sortie'),
                                content: const Text(
                                  'Voulez-vous vraiment supprimer cette sortie ?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, false),
                                    child: const Text('Annuler'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text('Supprimer'),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        onDismissed: (direction) async {
                          await box.delete(rideKey);
                        },
                        child: GestureDetector(
                          onTap: () {

                            Navigator.push(
                              context,

                              MaterialPageRoute(
                                builder: (context) =>
                                    RideDetailScreen(
                                      ride: ride,
                                    ),
                              ),
                            );
                          },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B1B1B),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.route,
                                color: Colors.orange,
                                size: 30,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      formattedDate,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      formatDistance(ride['distanceMeters']),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.white70,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      formatDuration(ride['durationSeconds']),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}