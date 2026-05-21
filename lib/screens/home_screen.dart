import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ride_screen.dart';
import 'ride_detail_screen.dart';
import '../widgets/ride_trace_thumbnail.dart';

import 'package:intl/intl.dart';

class HomeScreen extends StatefulWidget 
{
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> 
{
  String appVersion = '';

  @override
  void initState() {
    super.initState();
    loadAppVersion();
  }

  // FORMATAGE DE DONNEES
  Widget buildTag(String text) 
  {
    final formattedText =
        text.toLowerCase();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),

      decoration: BoxDecoration(

        color: Colors.orange.withValues(
          alpha: 0.15,
        ),

        borderRadius:
            BorderRadius.circular(20),

        border: Border.all(
          color: Colors.orange.withValues(
            alpha: 0.3,
          ),
        ),
      ),

      child: Text(
        formattedText,

        style: const TextStyle(
          color: Colors.orange,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
  Future<void> loadAppVersion() async 
  {
    final packageInfo = await PackageInfo.fromPlatform();

    final formattedDate = packageInfo.updateTime != null
        ? DateFormat('dd/MM/yyyy HH:mm').format(packageInfo.updateTime!)
        : null;

    setState(() {
      appVersion =
          'v${packageInfo.version}+${packageInfo.buildNumber}'
          '${formattedDate != null ? ' - $formattedDate' : ''}';
    });
  }

  String formatDistance(dynamic meters) 
  {
    final distance = (meters ?? 0).toDouble();

    if (distance < 1000) {
      return '${distance.toStringAsFixed(0)} m';
    }

    return '${(distance / 1000).toStringAsFixed(2)} km';
  }

  String formatDuration(dynamic seconds) 
  {
    final duration = Duration(seconds: seconds ?? 0);
    return duration.toString().split('.').first;
  }

  @override
  Widget build(BuildContext context) 
  {
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

            const SizedBox(height: 20),
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

                    final dateA =
                        DateTime.tryParse(rideA['startTime'] ?? '') ??
                            DateTime(1900);
                    final dateB =
                        DateTime.tryParse(rideB['startTime'] ?? '') ??
                            DateTime(1900);

                    return dateB.compareTo(dateA);
                  });

                  return ListView.builder(
                    itemCount: rides.length,
                    itemBuilder: (context, index) {
                      final item = rides[index];
                      final rideKey = item['key'];
                      final ride = item['ride'] as Map;

                      final startDate =
                          DateTime.tryParse(ride['startTime'] ?? '') ??
                              DateTime.now();

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
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Annuler'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Supprimer'),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        onDismissed: (direction) async {
                          await deleteRide(
                            context,
                            ride,
                            rideKey,
                          );
                        },
                        child: GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => RideDetailScreen(
                                  ride: ride,
                                  rideKey: rideKey,
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [

                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [

                                    RideTraceThumbnail(
                                      points: ride['points'] ?? [],
                                    ),

                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [

                                          Text(
                                            'Sortie du $formattedDate',
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),

                                          const SizedBox(height: 5),
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.timer,
                                                size: 16,
                                                color: Colors.white60,
                                              ),

                                              const SizedBox(width: 4),
                                              Text(
                                                formatDuration(
                                                  ride['durationSeconds'],
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),

                                              const SizedBox(width: 4),
                                              const Icon(
                                                Icons.route,
                                                size: 16,
                                                color: Colors.white60,
                                              ),

                                              const SizedBox(width: 4),
                                              Text(
                                                formatDistance(
                                                  ride['distanceMeters'],
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),

                                    const SizedBox(width: 5),
                                    const Icon(
                                      Icons.chevron_right,
                                      color: Colors.orange,
                                      size: 30,
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 14),

                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [

                                    if ((ride['department'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag(
                                        '#${ride['department']}',
                                      ),

                                    if ((ride['region'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag(
                                        '#${ride['region']}',
                                      ),

                                    if ((ride['city'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag(
                                        '#${ride['city']}',
                                      ),
                                  ],
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

            const SizedBox(height: 8),
            Text(
              appVersion,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}