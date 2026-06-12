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
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

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
  StreamSubscription<Position>? gpsInitializationStream;
  final MapController mapController = MapController();
  bool mapReady = false;
  final List<LatLng> ridePoints = [];
  
  double totalDistance = 0;
  final Distance distanceCalculator = const Distance();

  String accuracy='0';

  DateTime? rideStartTime;
  Duration rideDuration = Duration.zero;
  Timer? rideTimer;

  bool rideIsPaused = false;
  bool rideIsStarted = false;

  String? safetySessionId;
  String? safetyShareCode;
  String? safetyUrl;

  Timer? safetyUploadTimer;

  Position? currentPosition;

  bool gpsIsReady = false;
  bool gpsIsInitializing = true;

  DateTime? _lastPointTimestamp;

  final List<Map<String, dynamic>> rideWaypoints = [];
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() 
  {
    super.initState();
    WakelockPlus.enable();
    initializeGps();
  }

  Future<void> initializeGps() async 
  {
    LocationPermission permission;
    permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      setState(() {
        gpsIsInitializing = false;
        gpsIsReady = false;
        accuracy = 'Permission refusée';
      });
      return;
    }

    await gpsInitializationStream?.cancel();

    gpsInitializationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((Position position) async {
      currentPosition = position;
      if (!mounted) return;

      setState(() {
        latitude = position.latitude.toString();
        longitude = position.longitude.toString();
        altitude = position.altitude.toStringAsFixed(1);
        accuracy = position.accuracy.toStringAsFixed(1);
        gpsIsInitializing = false;
        gpsIsReady = position.accuracy <= 20;
      });

      if (mapReady) {
        mapController.move(LatLng(position.latitude, position.longitude), 16);
      }

      if (position.accuracy <= 20) {
        await gpsInitializationStream?.cancel();
        gpsInitializationStream = null;
      }
    });
  }

  Future<void> startRide() async 
  {
    await gpsInitializationStream?.cancel();
    gpsInitializationStream = null;

    await startForegroundService();
    await createSafetySession();
    await shareSafetyLink();

    rideStartTime = DateTime.now();

    rideTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        setState(() {
          rideDuration = DateTime.now().difference(rideStartTime!);
        });
      },
    );

    await startTracking();

    setState(() {
      rideIsStarted = true;
    });
  }

  Future<void> stopTrackingImmediately() async {
    rideTimer?.cancel();
    await positionStream?.cancel();
    positionStream = null;
    safetyUploadTimer?.cancel();
    safetyUploadTimer = null;
    FlutterBackgroundService().invoke('stopService');
    WakelockPlus.disable();
    setState(() { rideIsPaused = true; });
  }

  Future discardRide() async 
  {
    try {
      safetyUploadTimer?.cancel();
      await positionStream?.cancel();
      rideTimer?.cancel();

      if (safetySessionId != null) {
        final supabase = Supabase.instance.client;
        await supabase.from('safety_positions').delete().eq('session_id', safetySessionId!);
        await supabase.from('safety_sessions').delete().eq('id', safetySessionId!);
      }
    } catch (e) {
      print('Erreur abandon ride : $e');
    }
  }

  Future<void> startForegroundService() async 
  {
    print('START FOREGROUND SERVICE');
    final serviceStarted = await FlutterBackgroundService().startService();
    print('FOREGROUND SERVICE STARTED: $serviceStarted');
  }

  @override
  void dispose() 
  {
    positionStream?.cancel();
    gpsInitializationStream?.cancel();
    rideTimer?.cancel();
    WakelockPlus.disable();
    FlutterBackgroundService().invoke('stopService');
    safetyUploadTimer?.cancel();
    super.dispose();
  }

  // Copie une photo dans le dossier permanent de l'appli
  Future<String> _copyPhotoToPermanentDir(String sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${appDir.path}/waypoint_photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    final fileName = 'wp_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${photosDir.path}/$fileName';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _showAddWaypointModal() async 
  {
    final noteController = TextEditingController();
    final List<String> selectedPhotoPaths = [];

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  const Text(
                    'Mémoriser un point',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lat: $latitude  Long: $longitude',
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                  const SizedBox(height: 20),

                  // NOTE
                  const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      hintText: 'Décris ce point...',
                      hintStyle: const TextStyle(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // PHOTOS
                  Row(
                    children: [
                      const Text('Photos', style: TextStyle(fontSize: 14, color: Colors.white54)),
                      const SizedBox(width: 8),
                      Text(
                        '${selectedPhotoPaths.length}/3',
                        style: const TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // MINIATURES + BOUTON AJOUT
                  Row(
                    children: [

                      // Miniatures des photos sélectionnées
                      ...selectedPhotoPaths.map((path) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                File(path),
                                width: 72,
                                height: 72,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: GestureDetector(
                                onTap: () {
                                  setModalState(() {
                                    selectedPhotoPaths.remove(path);
                                  });
                                },
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )),

                      // Bouton ajouter photo (visible si < 3 photos)
                      if (selectedPhotoPaths.length < 3)
                        GestureDetector(
                          onTap: () async {
                            // Choix source : appareil photo ou galerie
                            final source = await showModalBottomSheet<ImageSource>(
                              context: ctx,
                              backgroundColor: const Color(0xFF2A2A2A),
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                              ),
                              builder: (c) => Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.camera_alt, color: Colors.white),
                                      title: const Text('Appareil photo', style: TextStyle(color: Colors.white)),
                                      onTap: () => Navigator.pop(c, ImageSource.camera),
                                    ),
                                    ListTile(
                                      leading: const Icon(Icons.photo_library, color: Colors.white),
                                      title: const Text('Galerie', style: TextStyle(color: Colors.white)),
                                      onTap: () => Navigator.pop(c, ImageSource.gallery),
                                    ),
                                  ],
                                ),
                              ),
                            );

                            if (source == null) return;

                            final picked = await _imagePicker.pickImage(
                              source: source,
                              imageQuality: 80,
                              maxWidth: 1200,
                            );

                            if (picked != null) {
                              setModalState(() {
                                selectedPhotoPaths.add(picked.path);
                              });
                            }
                          },
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Icon(Icons.add_a_photo, color: Colors.white38, size: 28),
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // BOUTON MÉMORISER
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                      ),
                      onPressed: () async {
                        final lat = double.tryParse(latitude);
                        final lng = double.tryParse(longitude);
                        if (lat == null || lng == null) return;

                        // Copie les photos dans le dossier permanent
                        final List<String> permanentPaths = [];
                        for (final path in selectedPhotoPaths) {
                          final permanentPath = await _copyPhotoToPermanentDir(path);
                          permanentPaths.add(permanentPath);
                        }

                        setState(() {
                          rideWaypoints.add({
                            'lat': lat,
                            'lng': lng,
                            'note': noteController.text.trim(),
                            'timestamp': DateTime.now().toIso8601String(),
                            'photos': permanentPaths,
                          });
                        });

                        Navigator.of(modalContext).pop();

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Point mémorisé !')),
                        );
                      },
                      icon: const Icon(Icons.place),
                      label: const Text('Mémoriser', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String generateShareCode() 
  {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(8, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  Future<void> uploadSafetyPosition() async 
  {
    if (safetySessionId == null || currentPosition == null) return;

    final supabase = Supabase.instance.client;
    print('BEFORE UPLOAD SAFETY POSITION');
    await supabase.from('safety_positions').insert({
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
      const Duration(seconds: 15),
      (timer) async { await uploadSafetyPosition(); },
    );
  }

  Future<void> createSafetySession() async 
  {
    final supabase = Supabase.instance.client;
    final shareCode = generateShareCode();

    final response = await supabase
        .from('safety_sessions')
        .insert({'share_code': shareCode, 'status': 'in_progress'})
        .select()
        .single();

    safetySessionId = response['id'];
    safetyShareCode = shareCode;
    safetyUrl = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';

    print('SAFETY SESSION CREATED: $safetySessionId');
    print('SHARE CODE: $safetyShareCode');
    startSafetyUploadTimer();
  }

  Future<void> shareSafetyLink() async 
  {
    if (safetyShareCode == null) return;

    final safetyUrl = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    final message = '''

  Je démarre une sortie avec Sunday Tracker.

  Tu peux consulter ma dernière position connue ici :

  $safetyUrl

  ''';

    await Share.share(message, subject: 'Sunday Tracker Safety Beacon');
  }

  Future<void> _showExitRideModal() async 
  {
    final screenNavigator = Navigator.of(context);

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Quitter la sortie ?',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text('Que souhaitez-vous faire ?', style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 32),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(modalContext).pop(),
                  child: const Text('Continuer', style: TextStyle(color: Color(0xFFD0BCFF), fontSize: 18)),
                ),
              ),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    Navigator.of(modalContext).pop();
                    await cancelRide();
                    if (!mounted) return;
                    screenNavigator.pop();
                  },
                  child: const Text(
                    'Terminer sans sauvegarder',
                    style: TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.of(modalContext).pop();
                    await saveRide();
                    if (!mounted) return;
                    screenNavigator.pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5A4F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                  ),
                  child: const Text('Sauvegarder et quitter', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Future<void> cancelRide() async {
    safetyUploadTimer?.cancel();
    await positionStream?.cancel();
    rideTimer?.cancel();

    if (safetySessionId != null) {
      final supabase = Supabase.instance.client;
      await supabase.from('safety_positions').delete().eq('session_id', safetySessionId!);
      await supabase.from('safety_sessions').delete().eq('id', safetySessionId!);
    }
  }

  Future<void> togglePauseRide() async {
    if (!rideIsPaused) {
      await positionStream?.cancel();
      positionStream = null;
      rideTimer?.cancel();
      safetyUploadTimer?.cancel();
      setState(() { rideIsPaused = true; });
      await Supabase.instance.client.from('safety_sessions').update({'status': 'paused'}).eq('id', safetySessionId!);
      return;
    }

    rideStartTime = DateTime.now().subtract(rideDuration);
    rideTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) { setState(() { rideDuration = DateTime.now().difference(rideStartTime!); }); },
    );
    await startTracking();
    startSafetyUploadTimer();
    setState(() { rideIsPaused = false; });
    await Supabase.instance.client.from('safety_sessions').update({'status': 'in_progress'}).eq('id', safetySessionId!);
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
      'safetySessionId': safetySessionId,
      'safetyShareCode': safetyShareCode,
      'points': ridePoints.map((point) => {'lat': point.latitude, 'lng': point.longitude}).toList(),
      'waypoints': rideWaypoints,
    };

    await box.add(ride);

    await Supabase.instance.client
        .from('safety_sessions')
        .update({'status': 'finished', 'ended_at': DateTime.now().toIso8601String()})
        .eq('id', safetySessionId!);

    print('Sortie sauvegardée : $ride');
  }

  Future<void> startTracking() async 
  {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: kDebugMode ? 0 : 5,
      ),
    ).listen((Position position) {

      currentPosition = position;
      final newPoint = LatLng(position.latitude, position.longitude);

      print('=== NOUVEAU POINT ===');
      print('lat: ${position.latitude}, lon: ${position.longitude}');
      print('accuracy: ${position.accuracy}');
      print('timestamp: ${position.timestamp}');
      print('ridePoints.length: ${ridePoints.length}');

      setState(() {
        gpsIsReady = position.accuracy <= 15;
        latitude = position.latitude.toString();
        longitude = position.longitude.toString();
        altitude = position.altitude.toStringAsFixed(1);
        accuracy = position.accuracy.toStringAsFixed(1);
      });

      if (mapReady) mapController.move(newPoint, 16);

      if (position.accuracy > 20) {
        print('>>> REJETÉ précision: ${position.accuracy.toStringAsFixed(1)} m');
        return;
      }

      if (ridePoints.isNotEmpty) {
        final lastPoint = ridePoints.last;
        final distance = distanceCalculator.as(LengthUnit.Meter, lastPoint, newPoint);

        final dt = (_lastPointTimestamp != null && position.timestamp != null)
            ? position.timestamp!.difference(_lastPointTimestamp!).inSeconds.abs()
            : 1;

        final maxAllowedDistance = (50.0 * max(dt, 1)) + (position.accuracy * 5);

        print('distance: ${distance.toStringAsFixed(0)} m / max autorisé: ${maxAllowedDistance.toStringAsFixed(0)} m / dt: $dt s');

        if (distance > maxAllowedDistance) {
          print('>>> REJETÉ saut GPS: ${distance.toStringAsFixed(0)} m');
          return;
        }

        totalDistance += distance;
      } else {
        print('>>> ridePoints VIDE, premier point ajouté sans filtre saut');
      }

      ridePoints.add(newPoint);
      _lastPointTimestamp = position.timestamp ?? DateTime.now();
      print('>>> ACCEPTÉ, total points: ${ridePoints.length}, distance: ${totalDistance.toStringAsFixed(0)} m');
    });
  }

  Future<Map<String, String>> getRideLocationTags() async 
  {
    if (ridePoints.isEmpty) return {'city': '', 'department': '', 'region': ''};

    final startPoint = ridePoints.first;

    try {
      final placemarks = await placemarkFromCoordinates(startPoint.latitude, startPoint.longitude);
      if (placemarks.isEmpty) return {'city': '', 'department': '', 'region': ''};
      final place = placemarks.first;
      return {
        'city': place.locality ?? '',
        'department': place.subAdministrativeArea ?? '',
        'region': place.administrativeArea ?? '',
      };
    } catch (e) {
      print('Erreur reverse geocoding : $e');
      return {'city': '', 'department': '', 'region': ''};
    }
  }

  String formattedDuration() 
  {
    final hours = rideDuration.inHours.toString().padLeft(2, '0');
    final minutes = (rideDuration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (rideDuration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String formattedDistance() 
  {
    if (totalDistance < 1000) return '${totalDistance.toStringAsFixed(0)} m';
    return '${(totalDistance / 1000).toStringAsFixed(2)} km';
  }

  Color accuracyColor() 
  {
    final value = double.tryParse(accuracy) ?? 999;
    if (value <= 5) return Colors.green;
    if (value <= 15) return Colors.orange;
    return Colors.red;
  }

  Future<void> handleBackPressed() async 
  {
    if (!rideIsStarted) {
      Navigator.of(context).pop();
      return;
    }
    await _showExitRideModal();
  }

  @override
  Widget build(BuildContext context) 
  {
    return WillPopScope(
      onWillPop: () async {
        await handleBackPressed();
        return false;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: handleBackPressed),
          title: const Text('Ride in progress'),
          actions: [
            if (rideIsStarted)...[
              IconButton(
                icon: const Icon(Icons.travel_explore),
                tooltip: 'Voir le suivi en direct',
                onPressed: () async {
                  if (safetyUrl == null) return;
                  final uri = Uri.parse(safetyUrl!);
                  try {
                    await launchUrl(uri, mode: LaunchMode.platformDefault);
                  } catch (e) {
                    print('Erreur launchUrl: $e');
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.share),
                tooltip: 'Partager le lien safety',
                onPressed: shareSafetyLink,
              ),
            ],
          ],
        ),

        body: Padding(
          padding: const EdgeInsets.all(16),
          child: gpsIsInitializing
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 24),
                      Text('Initialisation GPS...', style: TextStyle(fontSize: 18, color: Colors.white)),
                    ],
                  ),
                )
              : !gpsIsReady
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.gps_off, size: 80, color: Colors.orange),
                        const SizedBox(height: 24),
                        const Text('Recherche du signal GPS...', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Text('Précision actuelle : $accuracy m', style: const TextStyle(fontSize: 18)),
                        const SizedBox(height: 32),
                        const CircularProgressIndicator(),
                      ],
                    ),
                  )
                : Column(
                    children: [

                      ClipRRect(
                        borderRadius: BorderRadius.circular(28),
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
                              onMapReady: () { mapReady = true; },
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.example.sunday_tracker',
                              ),
                              PolylineLayer(
                                polylines: [
                                  Polyline(points: ridePoints, strokeWidth: 5, color: Colors.orange),
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
                                    child: const Icon(Icons.location_on, color: Colors.red, size: 40),
                                  ),
                                  ...rideWaypoints.map((wp) => Marker(
                                    point: LatLng(wp['lat'], wp['lng']),
                                    width: 36,
                                    height: 36,
                                    child: const Icon(Icons.place, color: Colors.blue, size: 36),
                                  )),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 10),

                      IntrinsicHeight(
                        child: Row(
                          children: [

                            // GPS CARD
                            Expanded(
                              flex: 5,
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF181818),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: const [
                                      Icon(Icons.gps_fixed, color: Colors.lightBlue, size: 24),
                                      SizedBox(width: 5),
                                      Text('Position GPS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                    ]),
                                    const SizedBox(height: 10),
                                    Row(children: [
                                      const Icon(Icons.public, color: Colors.lightBlue, size: 18),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text('Lat. : $latitude', style: const TextStyle(fontSize: 14))),
                                    ]),
                                    const SizedBox(height: 12),
                                    Row(children: [
                                      const Icon(Icons.language, color: Colors.lightBlue, size: 18),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text('Long. : $longitude', style: const TextStyle(fontSize: 14))),
                                    ]),
                                    const SizedBox(height: 12),
                                    Row(children: [
                                      const Icon(Icons.terrain, color: Colors.lightBlue, size: 18),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text('Alt. : $altitude m', style: const TextStyle(fontSize: 14))),
                                    ]),
                                    const SizedBox(height: 12),
                                    Row(children: [
                                      const Icon(Icons.satellite_alt, color: Colors.lightBlue, size: 18),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text(
                                        'Précision : $accuracy m',
                                        style: TextStyle(fontSize: 14, color: accuracyColor()),
                                      )),
                                    ]),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(width: 12),

                            // DISTANCE + DURÉE
                            Expanded(
                              flex: 4,
                              child: Column(
                                children: [
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
                                                Icon(Icons.route, color: Colors.orange, size: 24),
                                                SizedBox(width: 6),
                                                Text('Distance', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(formattedDistance(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.orange)),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
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
                                                Icon(Icons.timer, color: Colors.teal, size: 24),
                                                SizedBox(width: 6),
                                                Text('Durée', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(formattedDuration(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
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

                      if (!rideIsStarted)
                        const Text('GPS prêt', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal))
                      else if (safetyShareCode != null)
                        Text(safetyUrl!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal)),

                      const Spacer(),

                      if (!rideIsStarted)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              padding: const EdgeInsets.symmetric(vertical: 18),
                            ),
                            onPressed: startRide,
                            child: const Text('Démarrer la sortie', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ),
                        )
                      else
                        Row(
                          children: [

                            /// STOP
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey[850],
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                                onPressed: () async {
                                  await stopTrackingImmediately();
                                  await _showExitRideModal();
                                },
                                child: const Text('STOP', style: TextStyle(fontSize: 18)),
                              ),
                            ),

                            const SizedBox(width: 12),

                            /// PAUSE / REPRISE
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: rideIsPaused ? Colors.green : Colors.orange,
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                                onPressed: togglePauseRide,
                                child: Text(rideIsPaused ? 'Reprendre' : 'Pause', style: const TextStyle(fontSize: 18)),
                              ),
                            ),

                            const SizedBox(width: 12),

                            /// WAYPOINT
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                                onPressed: _showAddWaypointModal,
                                child: const Icon(Icons.place, size: 22, color: Colors.white),
                              ),
                            ),

                            const SizedBox(width: 12),

                            /// SOS
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                                onPressed: () {},
                                child: const Text('SOS', style: TextStyle(fontSize: 18)),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
        ),
      ),
    );
  }
}
