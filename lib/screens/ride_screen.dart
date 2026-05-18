import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class RideScreen extends StatefulWidget {
  const RideScreen({super.key});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {

  String latitude = 'Loading...';
  String longitude = 'Loading...';
  String altitude = 'Loading...';
  StreamSubscription<Position>? positionStream;
  final MapController mapController = MapController();
  bool mapReady = false;
  final List<LatLng> ridePoints = [];
  
  double totalDistance = 0;
  final Distance distanceCalculator = const Distance();

  String accuracy='0';

  @override
  void initState() {
    super.initState();
    startTracking();
  }


  @override
  void dispose() {

    positionStream?.cancel();

    super.dispose();
  }

  Future<void> startTracking() async {

  LocationPermission permission;

  permission = await Geolocator.checkPermission();

  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }

  positionStream = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    ),
  ).listen((Position position) {
    if (ridePoints.isNotEmpty) {

      final lastPoint = ridePoints.last;

      final newPoint = LatLng(
        position.latitude,
        position.longitude,
      );

      totalDistance += distanceCalculator.as(
        LengthUnit.Meter,
        lastPoint,
        newPoint,
      );

    }

    setState(() {
      latitude = position.latitude.toString();
      longitude = position.longitude.toString();
      altitude = position.altitude.toStringAsFixed(1);
      accuracy = position.accuracy.toStringAsFixed(1);
print('ALTITUDE: ${position.altitude}');
print('ACCURACY: ${position.accuracy}');
print('SPEED: ${position.speed}');
SystemSound.play(SystemSoundType.click);
HapticFeedback.mediumImpact();
    });
    if (mapReady) {
      mapController.move(
        LatLng(position.latitude, position.longitude),
        16,
      );
    }
    ridePoints.add(
      LatLng(position.latitude, position.longitude),
    );
  });
}

void initRideInfos() {
    ridePoints.clear();
    totalDistance = 0;
  }

  String formattedDistance() {

    if (totalDistance < 1000) {
      return '${totalDistance.toStringAsFixed(0)} m';
    }

    return '${(totalDistance / 1000).toStringAsFixed(2)} km';
  }

  Color accuracyColor() {
    final value = double.tryParse(accuracy) ?? 999;

    if (value <= 5) {
      return Colors.green;
    }

    if (value <= 15) {
      return Colors.orange;
    }

    return Colors.red;
  }

  String accuracyLabel() {
    final value = double.tryParse(accuracy) ?? 999;

    if (value <= 5) {
      return 'Excellent';
    }

    if (value <= 15) {
      return 'Moyen';
    }

    return 'Faible';
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),

      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: const Text('Ride in progress'),
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),

        child: Column(
          children: [

            ClipRRect(
            borderRadius: BorderRadius.circular(24),

            child: SizedBox(
              height: 300,

              child: FlutterMap(
                mapController: mapController,
                options: MapOptions(
                  initialCenter: LatLng(
                    double.tryParse(latitude) ?? 48.8566,
                    double.tryParse(longitude) ?? 2.3522,
                  ),

                  initialZoom: 15,
                  onMapReady: () {
                    mapReady = true;
                  },
                ),

                children: [

                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.sunday_tracker',
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
                  MarkerLayer(
                    markers: [

                      Marker(
                        point: LatLng(
                          double.tryParse(latitude) ?? 48.8566,
                          double.tryParse(longitude) ?? 2.3522,
                        ),

                        width: 80,
                        height: 80,

                        child: const Icon(
                          Icons.location_on,
                          color: Colors.red,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // GPS + DISTANCE + PRECISION
          IntrinsicHeight(
            child: Row(
              children: [

                // GPS CARD
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1B1B),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        Row(
                          children: const [
                            Icon(
                              Icons.gps_fixed,
                              color: Colors.lightBlue,
                              size: 24,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Position GPS',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        Row(
                          children: [
                            const Icon(Icons.public, color: Colors.lightBlue, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Lat. : $latitude',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            const Icon(Icons.language, color: Colors.lightBlue, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Long. : $longitude',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            const Icon(Icons.terrain, color: Colors.lightBlue, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Alt. : $altitude m',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // RIGHT COLUMN
                Expanded(
                  flex: 4,
                  child: Column(
                    children: [

                      // DISTANCE CARD
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B1B1B),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [

                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(
                                      Icons.route,
                                      color: Colors.orange,
                                      size: 24,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Distance',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 10),

                              Text(
                                formattedDistance(),
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      // GPS ACCURACY CARD
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B1B1B),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [

                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(
                                      Icons.satellite_alt,
                                      color: Colors.lightBlue,
                                      size: 24,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Précision',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 10),

                              Text(
                                '$accuracy m',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: accuracyColor(),
                                ),
                              ),

                              const SizedBox(height: 4),

                              Text(
                                accuracyLabel(),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: accuracyColor(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Spacer(),

          // BUTTONS
          Row(
            children: [

              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[850],
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),

                  onPressed: () {
                    Navigator.pop(context);
                  },

                  child: const Text(
                    'Stop Ride',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),

              const SizedBox(width: 16),

              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),

                  onPressed: () {
                    initRideInfos();
                  },

                  child: const Text(
                    'INIT',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),


              const SizedBox(width: 16),

              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                  ),

                  onPressed: () {},

                  child: const Text(
                    'SOS',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  }
}