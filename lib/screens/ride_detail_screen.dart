import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RideDetailScreen extends StatelessWidget 
{

  final Map ride;
  final dynamic rideKey;

  const RideDetailScreen({
    super.key,
    required this.ride,
    required this.rideKey,
  });

  @override
  Widget build(BuildContext context) {

    final pointsData = ride['points'] as List;

    final List<LatLng> ridePoints =
        pointsData.map((point) {

      return LatLng(
        point['lat'],
        point['lng'],
      );

    }).toList();

    final startPoint = ridePoints.isNotEmpty
        ? ridePoints.first
        : LatLng(48.8566, 2.3522);

    return Scaffold(

      backgroundColor: const Color(0xFF0D0D0D),

      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),

        title: const Text(
          'Détail sortie',
        ),
      ),

      body: Column(
        children: [

          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),

              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),

                child: Builder(
                  builder: (context) {

                    final mapController =
                        MapController();

                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      if (ridePoints.isEmpty) {
                        return;
                      }

                      await Future.delayed(
                        const Duration(milliseconds: 300),
                      );

                      final bounds = LatLngBounds.fromPoints(
                        ridePoints,
                      );

                      mapController.fitCamera(
                        CameraFit.bounds(
                          bounds: bounds,
                          padding: const EdgeInsets.all(60),
                        ),
                      );
                    });

                    return FlutterMap(

                      mapController: mapController,

                      options: MapOptions(
                        initialCenter: startPoint,
                        initialZoom: 13,
                      ),

                      children: [

                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',

                          userAgentPackageName:
                              'com.example.sunday_tracker',
                        ),

                        PolylineLayer(
                          polylines: [

                            Polyline(
                              points: ridePoints,
                              strokeWidth: 5,
                              color: Colors.orange,
                            ),
                          ],
                        ),

                        if (ridePoints.isNotEmpty)
                          MarkerLayer(
                            markers: [

                              // POINTS INTERMEDIAIRES
                              ...ridePoints
                                  .skip(1)
                                  .take(ridePoints.length - 2)
                                  .map(
                                    (point) => Marker(
                                      point: point,
                                      width: 10,
                                      height: 10,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.orange,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  // START
                                  Marker(
                                    point: ridePoints.first,

                                    width: 22,
                                    height: 22,

                                    child: Container(

                                      decoration: BoxDecoration(

                                        color: Colors.black.withValues(
                                          alpha: 0.25,
                                        ),


                                        shape: BoxShape.circle,

                                        border: Border.all(
                                          color: Colors.white,
                                          width: 2,
                                        ),

                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.greenAccent.withValues(
                                              alpha: 0.85,
                                            ),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),

                                      
                                    ),
                                  ),
                                  // END
                                  Marker(
                                    point: ridePoints.last,

                                    width: 32,
                                    height: 32,

                                    child: Container(

                                      decoration: BoxDecoration(

                                        color: Colors.black.withValues(
                                          alpha: 0.25,
                                        ),

                                        shape: BoxShape.circle,

                                        border: Border.all(
                                          color: Colors.white,
                                          width: 2,
                                        ),

                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.red.withValues(
                                              alpha: 0.85,
                                            ),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),

                                      child: const Icon(
                                        Icons.sports_score_sharp,
                                        color: Colors.white,
                                        size: 28,
                                      ),
                                    ),
                                  ),                            
                                ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),

            child: SizedBox(

              width: double.infinity,

              child: ElevatedButton.icon(

                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                  ),
                ),

                onPressed: () async {

                  final confirmed =
                      await showDialog<bool>(

                    context: context,

                    builder: (context) {

                      return AlertDialog(

                        backgroundColor:
                            const Color(0xFF1B1B1B),

                        title: const Text(
                          'Supprimer',
                        ),

                        content: const Text(
                          'Cette action supprimera définitivement la sortie ainsi que les données de sécurité associées.',
                        ),

                        actions: [

                          TextButton(

                            onPressed: () {
                              Navigator.pop(
                                context,
                                false,
                              );
                            },

                            child: const Text(
                              'Annuler',
                            ),
                          ),

                          ElevatedButton(

                            style:
                                ElevatedButton.styleFrom(
                              backgroundColor:
                                  Colors.redAccent,
                            ),

                            onPressed: () {
                              Navigator.pop(
                                context,
                                true,
                              );
                            },

                            child: const Text(
                              'Supprimer',
                            ),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirmed == true) 
                  {
                    await deleteRide(
                      context,
                      ride,
                      rideKey,
                      popAfterDelete: true,
                    );                  }
                  },

                icon: const Icon(
                  Icons.delete,
                ),

                label: const Text(
                  'Supprimer la sortie',
                ),
              ),
            ),
          ),          
        ],
      ),
    );
  }
}

  Future<void> deleteRide(
      BuildContext context,
      Map ride,
      dynamic rideKey, {
      bool popAfterDelete = false,
    }) async {

      try {

        final safetySessionId =
            ride['safetySessionId'];

        // DELETE SUPABASE
        if (safetySessionId != null) {

          final supabase =
              Supabase.instance.client;

          await supabase
              .from('safety_positions')
              .delete()
              .eq(
                'session_id',
                safetySessionId,
              );

          await supabase
              .from('safety_sessions')
              .delete()
              .eq(
                'id',
                safetySessionId,
              );
        }

        // DELETE LOCAL
        final ridesBox =
            Hive.box('rides');

        await ridesBox.delete(
          rideKey,
        );

        if (context.mounted) 
        {
          if (popAfterDelete) {
            Navigator.pop(context);
          }

          ScaffoldMessenger.of(context)
              .showSnackBar(

            const SnackBar(
              content: Text(
                'Sortie supprimée',
              ),
            ),
          );
        }

      } catch (e) {

        ScaffoldMessenger.of(context)
            .showSnackBar(

          SnackBar(
            content: Text(
              'Erreur suppression : $e',
            ),
          ),
        );
      }
    }