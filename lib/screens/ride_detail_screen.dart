import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class RideDetailScreen extends StatelessWidget {

  final Map ride;

  const RideDetailScreen({
    super.key,
    required this.ride,
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
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 3,
                                    ),
                                  ),
                                ),
                              ),

                              // END
                              Marker(
                                point: ridePoints.last,
                                width: 22,
                                height: 22,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 3,
                                    ),
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
        ],
      ),
    );
  }
}