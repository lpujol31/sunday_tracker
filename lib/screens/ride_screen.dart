import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geocoding/geocoding.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';
import 'package:share_plus/share_plus.dart';

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

  // GPS : précision
  String accuracy='0';

  // RIDE : durée
  DateTime? rideStartTime;
  Duration rideDuration = Duration.zero;
  Timer? rideTimer;

  // RIDE : état
  bool rideIsPaused = false;

  String? safetySessionId;
  String? safetyShareCode;

  Timer? safetyUploadTimer;

  Position? currentPosition;

  @override
  void initState() 
  {
    super.initState();

    WakelockPlus.enable();

    startForegroundService();
    createSafetySession();

    rideStartTime = DateTime.now();

    rideTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        setState(() {
          rideDuration = DateTime.now().difference(rideStartTime!);
        });
      },
    );

    startTracking();
  }

  Future<void> startForegroundService() async 
  {
    print('START FOREGROUND SERVICE');

    final serviceStarted =
        await FlutterBackgroundService().startService();

    print('FOREGROUND SERVICE STARTED: $serviceStarted');
  }

  @override
  void dispose() 
  {
    positionStream?.cancel();
    rideTimer?.cancel();
    WakelockPlus.disable();
    FlutterBackgroundService().invoke('stopService');
    safetyUploadTimer?.cancel();
    super.dispose();
  }

  String generateShareCode() 
  {
    const chars =
        'abcdefghijklmnopqrstuvwxyz0123456789';

    final random = Random();

    return String.fromCharCodes(
      Iterable.generate(
        8,
        (_) => chars.codeUnitAt(
          random.nextInt(chars.length),
        ),
      ),
    );
  }

  Future<void> uploadSafetyPosition() async 
  {
    if (safetySessionId == null ||
        currentPosition == null) {
      return;
    }

    final supabase = Supabase.instance.client;

    print('BEFORE UPLOAD SAFETY POSITION');
    await supabase
        .from('safety_positions')
        .insert({
          'session_id': safetySessionId,
          'latitude': currentPosition!.latitude,
          'longitude': currentPosition!.longitude,
        });

    print('AFTER UPLOAD SAFETY POSITION');
  }

  void startSafetyUploadTimer() 
  {
    print('startSafetyUploadTimer()');
    safetyUploadTimer = Timer.periodic(
    const Duration(seconds: 30),
    (timer) async {
      await uploadSafetyPosition();
    },
    );
  }

  Future<void> createSafetySession() async 
  {
    final supabase = Supabase.instance.client;

    final shareCode = generateShareCode();

    final response = await supabase
        .from('safety_sessions')
        .insert({
          'share_code': shareCode,
           'status': 'in_progress',
        })
        .select()
        .single();

    safetySessionId = response['id'];
    safetyShareCode = shareCode;

    print(
      'SAFETY SESSION CREATED: $safetySessionId',
    );

    print(
      'SHARE CODE: $safetyShareCode',
    );
    startSafetyUploadTimer();
    print('AVANT shareSafetyLink');
    await shareSafetyLink();
    print('APRES shareSafetyLink');
  }

  Future<void> shareSafetyLink() async 
  {

    if (safetyShareCode == null) {
      return;
    }

    final safetyUrl =
        'https://sunday-tracker-live.web.app/?code=$safetyShareCode';

    final message = '''

  Je démarre une sortie avec Sunday Tracker.

  Tu peux consulter ma dernière position connue ici :

  $safetyUrl

  Ce lien est uniquement destiné à la sécurité.

  ''';

    await Share.share(
      message,
      subject: 'Sunday Tracker Safety Beacon',
    );
  }

  Future<void> togglePauseRide() async {
    if (!rideIsPaused) 
    {
      await positionStream?.cancel();
      rideTimer?.cancel();

      setState(() {
        rideIsPaused = true;
      });
      await Supabase.instance.client
        .from('safety_sessions')
        .update({'status': 'paused'})
        .eq('id', safetySessionId!);

      return;
    }

    rideStartTime = DateTime.now().subtract(rideDuration);

    rideTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        setState(() {
          rideDuration = DateTime.now().difference(rideStartTime!);
        });
      },
    );

    startTracking();

    setState(() {
      rideIsPaused = false;
    });
    await Supabase.instance.client
      .from('safety_sessions')
      .update({'status': 'in_progress'})
      .eq('id', safetySessionId!);
  }

  Future<void> saveRide() async 
  {
    final box = await Hive.openBox('rides');

    final locationTags = await getRideLocationTags();

    final ride = {
      'startTime': rideStartTime?.toIso8601String(),
      'endTime': DateTime.now().toIso8601String(),
      'durationSeconds': rideDuration.inSeconds,
      'distanceMeters': totalDistance,
      'city': locationTags['city'],
      'department': locationTags['department'],
      'region': locationTags['region'],
      'points': ridePoints
          .map((point) => {
                'lat': point.latitude,
                'lng': point.longitude,
              })
          .toList(),
    };

    await box.add(ride);

    await Supabase.instance.client
        .from('safety_sessions')
        .update({
          'status': 'finished',
          'ended_at': DateTime.now().toIso8601String(),
        })
        .eq('id', safetySessionId!);

    print('Sortie sauvegardée : $ride');
  }

  Future<void> startTracking() async 
  {

  LocationPermission permission;

  permission = await Geolocator.checkPermission();

  if (permission == LocationPermission.denied) 
  {
    permission = await Geolocator.requestPermission();
  }

  positionStream = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    ),
  ).listen((Position position) {
    if (ridePoints.isNotEmpty) {
      
      currentPosition = position;
      
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

  void resetRideInfos() 
  {
      ridePoints.clear();
      totalDistance = 0;
  }


  Future<Map<String, String>> getRideLocationTags() async 
  {
    if (ridePoints.isEmpty) {
      return {
        'city': '',
        'department': '',
        'region': '',
      };
    }

    final startPoint = ridePoints.first;

    try {
      final placemarks = await placemarkFromCoordinates(
        startPoint.latitude,
        startPoint.longitude,
      );

      if (placemarks.isEmpty) {
        return {
          'city': '',
          'department': '',
          'region': '',
        };
      }

      final place = placemarks.first;

      return {
        'city': place.locality ?? '',
        'department': place.subAdministrativeArea ?? '',
        'region': place.administrativeArea ?? '',
      };
    } catch (e) {
      print('Erreur reverse geocoding : $e');

      return {
        'city': '',
        'department': '',
        'region': '',
      };
    }
  }

  // Formatage de données
  String formattedDuration() 
  {
    final hours = rideDuration.inHours.toString().padLeft(2, '0');
    final minutes = (rideDuration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (rideDuration.inSeconds % 60).toString().padLeft(2, '0');

    return '$hours:$minutes:$seconds';
  }

  String formattedDistance() 
  {

    if (totalDistance < 1000) {
      return '${totalDistance.toStringAsFixed(0)} m';
    }

    return '${(totalDistance / 1000).toStringAsFixed(2)} km';
  }

  Color accuracyColor() 
  {
    final value = double.tryParse(accuracy) ?? 999;

    if (value <= 5) {
      return Colors.green;
    }

    if (value <= 15) {
      return Colors.orange;
    }

    return Colors.red;
  }

  String accuracyLabel() 
  {
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

        // GPS + DISTANCE + DUREE
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

                          const Icon(
                            Icons.public,
                            color: Colors.lightBlue,
                            size: 18,
                          ),

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

                          const Icon(
                            Icons.language,
                            color: Colors.lightBlue,
                            size: 18,
                          ),

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

                          const Icon(
                            Icons.terrain,
                            color: Colors.lightBlue,
                            size: 18,
                          ),

                          const SizedBox(width: 10),

                          Expanded(
                            child: Text(
                              'Alt. : $altitude m',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      Row(
                        children: [

                          const Icon(
                            Icons.satellite_alt,
                            color: Colors.lightBlue,
                            size: 18,
                          ),

                          const SizedBox(width: 10),

                          Expanded(
                            child: Text(
                              'Précision : $accuracy m',
                              style: TextStyle(
                                fontSize: 14,
                                color: accuracyColor(),
                              ),
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

                    // DURATION CARD
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
                                    Icons.timer,
                                    color: Colors.teal,
                                    size: 24,
                                  ),

                                  SizedBox(width: 6),

                                  Text(
                                    'Durée',
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
                              formattedDuration(),

                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.teal,
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
        Text(
          '$safetyShareCode',

          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.teal,
          ),
        ),

        const Spacer(),

        Row(
          children: [

            // STOP RIDE
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey[850],
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),

                onPressed: () async {

                  final result = await showDialog<String>(
                    context: context,

                    builder: (context) {
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1B1B1B),

                        title: const Text(
                          'Terminer la sortie',
                        ),

                        content: const Text(
                          'Que souhaitez-vous faire avec cette sortie ?',
                        ),

                        actions: [

                          TextButton(
                            onPressed: () =>
                                Navigator.pop(context, 'cancel'),

                            child: const Text(
                              'Annuler',
                            ),
                          ),

                          TextButton(
                            onPressed: () =>
                                Navigator.pop(context, 'discard'),

                            child: const Text(
                              'Arrêter sans sauvegarder',

                              style: TextStyle(
                                color: Colors.orange,
                              ),
                            ),
                          ),

                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),

                            onPressed: () =>
                                Navigator.pop(context, 'save'),

                            child: const Text(
                              'Sauvegarder',
                            ),
                          ),
                        ],
                      );
                    },
                  );

                  if (result == 'save') {

                    await saveRide();

                    if (!context.mounted) return;

                    Navigator.pop(context);
                  }

                  if (result == 'discard') {

                    if (!context.mounted) return;

                    Navigator.pop(context);
                  }
                },

                child: const Text(
                  'STOP',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),

            const SizedBox(width: 16),

            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: rideIsPaused ? Colors.green : Colors.orange,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                onPressed: () {
                  togglePauseRide();
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,

                  children: [

                    Icon(
                      rideIsPaused
                          ? Icons.play_arrow
                          : Icons.pause,

                      size: 20,
                      color: Colors.white,
                    ),

                    const SizedBox(width: 4),

                    Text(
                      rideIsPaused
                          ? 'Reprise'
                          : 'Pause',

                      style: const TextStyle(
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(width: 16),

            // RESET
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),

                onPressed: () {
                  resetRideInfos();
                },

                child: const Text(
                  'Reset',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),

            const SizedBox(width: 16),
            // SOS
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
        ),        ],
      ),
    ),
  );
  }
}