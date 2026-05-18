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

    setState(() {
      latitude = position.latitude.toString();
      longitude = position.longitude.toString();
      altitude = position.altitude.toStringAsFixed(1);
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

            // GPS INFO
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),

              decoration: BoxDecoration(
                color: const Color(0xFF1B1B1B),
                borderRadius: BorderRadius.circular(20),
              ),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  const Text(
                    'GPS Position',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 20),

                  Text(
                    'Latitude: $latitude',
                    style: const TextStyle(fontSize: 16),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    'Longitude: $longitude',
                    style: const TextStyle(fontSize: 16),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    'Altitude: $altitude',
                    style: const TextStyle(fontSize: 16),
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