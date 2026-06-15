import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ride_screen.dart';
import 'ride_detail_screen.dart';
import '../widgets/ride_trace_thumbnail.dart';

import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// PRATIQUES — définition centralisée
// ---------------------------------------------------------------------------

const Map<String, Map<String, dynamic>> kPracticeTypes = {
  'vtt': {
    'label': 'VTT',
    'color': Color(0xFF22C55E),
    'icon': Icons.terrain,
  },
  'enduro': {
    'label': 'Enduro',
    'color': Color(0xFFEF4444),
    'icon': Icons.electric_bolt,
  },
  'route': {
    'label': 'Vélo route',
    'color': Color(0xFF3B82F6),
    'icon': Icons.directions_bike,
  },
  'marche': {
    'label': 'Marche',
    'color': Color(0xFFF59E0B),
    'icon': Icons.directions_walk,
  },
  'running': {
    'label': 'Running',
    'color': Color(0xFFF97316),
    'icon': Icons.directions_run,
  },
  'autre': {
    'label': 'Autre',
    'color': Color(0xFFA855F7),
    'icon': Icons.more_horiz,
  },
};

// ---------------------------------------------------------------------------
// DÉTECTION AUTOMATIQUE DE LA PRATIQUE
// ---------------------------------------------------------------------------
//
// Signaux utilisés :
//   • avgSpeedKmh  = distanceMeters / durationSeconds * 3.6
//   • maxSpeedKmh  = calculé depuis les points GPS si disponibles
//   • slopeRatio   = totalElevationM / distanceKm  (dénivelé par km)
//   • distanceKm   = distanceMeters / 1000
//
// Arbre de décision :
//   avgSpeed < 8 km/h                        → marche
//   avgSpeed < 15 km/h ET slopeRatio > 50   → running
//   avgSpeed < 15 km/h                       → marche (lente)
//   avgSpeed >= 25 km/h ET slopeRatio < 20  → route
//   slopeRatio > 60 OU maxSpeed > 45        → enduro
//   slopeRatio > 30                          → vtt
//   avgSpeed >= 20 ET slopeRatio < 30       → autre
//   fallback                                 → vtt

String detectPractice(Map ride) {
  final distanceM = (ride['distanceMeters'] ?? 0).toDouble();
  final durationS = (ride['durationSeconds'] ?? 1).toDouble();
  final elevationM = (ride['totalElevationMeters'] ?? 0).toDouble();

  if (distanceM <= 0 || durationS <= 0) return 'vtt';

  final distanceKm = distanceM / 1000.0;
  final avgSpeedKmh = (distanceM / durationS) * 3.6;
  final slopeRatio = distanceKm > 0 ? elevationM / distanceKm : 0.0;

  // Calcul vitesse max depuis les points si disponibles
  double maxSpeedKmh = 0;
  final points = ride['points'];
  if (points is List && points.length >= 2) {
    for (int i = 1; i < points.length; i++) {
      final p1 = points[i - 1];
      final p2 = points[i];
      if (p1 is Map && p2 is Map) {
        final lat1 = (p1['lat'] ?? 0.0).toDouble();
        final lon1 = (p1['lng'] ?? 0.0).toDouble();
        final lat2 = (p2['lat'] ?? 0.0).toDouble();
        final lon2 = (p2['lng'] ?? 0.0).toDouble();
        final t1 = DateTime.tryParse(p1['time'] ?? '');
        final t2 = DateTime.tryParse(p2['time'] ?? '');
        if (t1 != null && t2 != null) {
          final dtS = t2.difference(t1).inSeconds.toDouble();
          if (dtS > 0) {
            // Distance approx entre 2 points (formule haversine simplifiée)
            final dLat = (lat2 - lat1) * 111000;
            final dLon = (lon2 - lon1) * 111000 * 0.7; // ~cos(45°)
            final dM = (dLat * dLat + dLon * dLon);
            if (dM > 0) {
              final speedKmh = (dM / (dtS * dtS)) * 0 +
                  (((dLat.abs() + dLon.abs()) / dtS) * 3.6);
              if (speedKmh > maxSpeedKmh) maxSpeedKmh = speedKmh;
            }
          }
        }
      }
    }
  }

  // Arbre de décision
  if (avgSpeedKmh < 8) return 'marche';
  if (avgSpeedKmh < 15 && slopeRatio > 50) return 'running';
  if (avgSpeedKmh < 15) return 'marche';
  if (avgSpeedKmh >= 25 && slopeRatio < 20) return 'route';
  if (slopeRatio > 60 || maxSpeedKmh > 45) return 'enduro';
  if (slopeRatio > 30) return 'vtt';
  if (avgSpeedKmh >= 20 && slopeRatio < 30) return 'autre';
  return 'vtt';
}

// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String appVersion = '';

  @override
  void initState() {
    super.initState();
    loadAppVersion();
  }

  // -------------------------------------------------------------------------
  // FORMATAGE DE DONNEES
  // -------------------------------------------------------------------------

  Widget buildTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: Text(
        text.toLowerCase(),
        style: const TextStyle(
          color: Colors.orange,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// Tag de pratique coloré + cliquable
  Widget buildPracticeTag(
    String practiceKey,
    dynamic rideKey,
    Box ridesBox,
  ) {
    final practice = kPracticeTypes[practiceKey] ?? kPracticeTypes['vtt']!;
    final icon = practice['icon'] as IconData;
    final label = practice['label'] as String;

    // Couleur fixe cyan — tranche avec les tags orange et les couleurs de pratique
    const Color tagColor = Color(0xFF06B6D4);

    return GestureDetector(
      onTap: () => _showPracticePicker(context, rideKey, ridesBox),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: tagColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tagColor.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: tagColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: tagColor,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 12,
              color: tagColor,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // SÉLECTEUR DE PRATIQUE — bottom sheet
  // -------------------------------------------------------------------------

  void _showPracticePicker(
    BuildContext context,
    dynamic rideKey,
    Box ridesBox,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Poignée
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Choisir la pratique',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Détectée automatiquement · modifiable',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kPracticeTypes.entries.map((e) {
                  final color = e.value['color'] as Color;
                  final icon = e.value['icon'] as IconData;
                  final label = e.value['label'] as String;

                  return GestureDetector(
                    onTap: () async {
                      // Lire la ride existante et y ajouter la pratique
                      final existing =
                          ridesBox.get(rideKey) as Map? ?? {};
                      final updated = Map.from(existing)
                        ..['practice'] = e.key;
                      await ridesBox.put(rideKey, updated);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border:
                            Border.all(color: color.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 16, color: color),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: TextStyle(
                              color: color,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------

  Future<void> loadAppVersion() async {
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

  String formatDistance(dynamic meters) {
    final distance = (meters ?? 0).toDouble();
    if (distance < 1000) return '${distance.toStringAsFixed(0)} m';
    return '${(distance / 1000).toStringAsFixed(2)} km';
  }

  String formatDuration(dynamic seconds) {
    final duration = Duration(seconds: seconds ?? 0);
    return duration.toString().split('.').first;
  }

  // -------------------------------------------------------------------------
  // DELETE
  // -------------------------------------------------------------------------

  Future<void> deleteRide(
      BuildContext context, Map ride, dynamic rideKey) async {
    final ridesBox = Hive.box('rides');
    await ridesBox.delete(rideKey);
  }

  // -------------------------------------------------------------------------
  // BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ridesBox = Hive.box('rides');

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        toolbarHeight: 70,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                children: [
                  const TextSpan(
                    text: 'Sunday ',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  WidgetSpan(
                    child: ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [
                          Color(0xFF6D28D9),
                          Color(0xFFD946EF),
                          Color(0xFFFF8A00),
                        ],
                      ).createShader(bounds),
                      child: const Text(
                        'Tracker',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Text(
              'Prêt pour une nouvelle aventure ?',
              style: TextStyle(fontSize: 12, color: Colors.white),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ----------------------------------------------------------------
            // BOUTON START RIDE
            // ----------------------------------------------------------------
            SizedBox(
              width: double.infinity,
              height: 108,
              child: GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RideScreen(),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xFF6D28D9),
                        Color(0xFFD946EF),
                        Color(0xFFFF8A00),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.orange.withOpacity(0.35),
                        blurRadius: 25,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 82,
                          height: 82,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.15),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.3),
                              width: 16,
                            ),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                        const SizedBox(width: 24),
                        const Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'START RIDE',
                                  style: TextStyle(
                                    fontSize: 38,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 42,
                        ),
                      ],
                    ),
                  ),
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

            // ----------------------------------------------------------------
            // LISTE DES SORTIES
            // ----------------------------------------------------------------
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: ridesBox.listenable(),
                builder: (context, box, child) {
                  if (box.isEmpty) {
                    return const Center(
                      child: Text('Aucune sortie sauvegardée'),
                    );
                  }

                  final rides = List.generate(box.length, (index) {
                    final ride = box.getAt(index);
                    return {
                      'key': box.keyAt(index),
                      'ride': ride,
                    };
                  });

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

                      final startDate = (DateTime.tryParse(ride['startTime'] ?? '') ?? DateTime.now()).toLocal();

                      final formattedDate =
                          '${startDate.day.toString().padLeft(2, '0')}/'
                          '${startDate.month.toString().padLeft(2, '0')}/'
                          '${startDate.year} '
                          '${startDate.hour.toString().padLeft(2, '0')}:'
                          '${startDate.minute.toString().padLeft(2, '0')}';

                      // ── Pratique : stockée dans Hive ou détectée auto ──
                      final practiceKey = (ride['practice'] as String?)
                              ?.isNotEmpty ==
                          true
                          ? ride['practice'] as String
                          : detectPractice(ride);

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
                          await deleteRide(context, ride, rideKey);
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    RideTraceThumbnail(
                                      points: ride['points'] ?? [],
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      ride['name'] ?? formattedDate,
                                                      maxLines: 2,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                    if (ride['name'] != null &&
                                                        ride['name'].toString().isNotEmpty) ...[
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        formattedDate,
                                                        style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Colors.white38,
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 5),
                                          Wrap(
                                            spacing: 2,
                                            runSpacing: 4,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              const Icon(
                                                Icons.timer,
                                                size: 16,
                                                color: Colors.white60,
                                              ),
                                              Text(
                                                formatDuration(
                                                  ride['durationSeconds'],
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),
                                              const Icon(
                                                Icons.route,
                                                size: 16,
                                                color: Colors.white60,
                                              ),
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
                                          // APRÈS
                                          if ((ride['note'] ?? '').toString().isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            // Ajouter un Row avec une petite icône devant
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                const Icon(
                                                  Icons.edit_note_rounded,
                                                  size: 14,
                                                  color: Colors.orange,
                                                ),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                  child: Text(
                                                    (ride['note'] as String).trim(),
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.orange,
                                                      fontStyle: FontStyle.italic,
                                                      height: 1.4,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),                                            
                                          ],                                          
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

                                // ── Tags géo + tag pratique ──
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    // Tag pratique — en premier, coloré
                                    buildPracticeTag(
                                      practiceKey,
                                      rideKey,
                                      ridesBox,
                                    ),

                                    if ((ride['department'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag('#${ride['department']}'),

                                    if ((ride['region'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag('#${ride['region']}'),

                                    if ((ride['city'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      buildTag('#${ride['city']}'),
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