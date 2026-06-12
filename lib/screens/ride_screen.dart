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

  String accuracy = '0';

  DateTime? rideStartTime;
  Duration rideDuration = Duration.zero;
  Timer? rideTimer;

  bool rideIsPaused = false;
  bool rideIsStarted = false;
  bool gpsDetailsExpanded = false;

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
  void initState() {
    super.initState();
    WakelockPlus.enable();
    initializeGps();
  }

  Future<void> initializeGps() async {
    LocationPermission permission = await Geolocator.checkPermission();
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
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
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
      if (mapReady) mapController.move(LatLng(position.latitude, position.longitude), 16);
      if (position.accuracy <= 20) {
        await gpsInitializationStream?.cancel();
        gpsInitializationStream = null;
      }
    });
  }

  Future<void> startRide() async {
    await gpsInitializationStream?.cancel();
    gpsInitializationStream = null;
    await startForegroundService();
    await createSafetySession();
    await shareSafetyLink();

    rideStartTime = DateTime.now();
    rideTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() { rideDuration = DateTime.now().difference(rideStartTime!); });
    });

    await startTracking();
    setState(() { rideIsStarted = true; });
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

  Future discardRide() async {
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

  Future<void> startForegroundService() async {
    final serviceStarted = await FlutterBackgroundService().startService();
    print('FOREGROUND SERVICE STARTED: $serviceStarted');
  }

  @override
  void dispose() {
    positionStream?.cancel();
    gpsInitializationStream?.cancel();
    rideTimer?.cancel();
    WakelockPlus.disable();
    FlutterBackgroundService().invoke('stopService');
    safetyUploadTimer?.cancel();
    super.dispose();
  }

  Future<String> _copyPhotoToPermanentDir(String sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${appDir.path}/waypoint_photos');
    if (!await photosDir.exists()) await photosDir.create(recursive: true);
    final fileName = 'wp_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${photosDir.path}/$fileName';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _showAddWaypointModal() async {
    final noteController = TextEditingController();
    final List<String> selectedPhotoPaths = [];

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24, right: 24, top: 24,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Mémoriser un point', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 8),
                  Text('Lat: $latitude  Long: $longitude', style: const TextStyle(fontSize: 12, color: Colors.white38)),
                  const SizedBox(height: 20),
                  const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: InputDecoration(
                      filled: true, fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      hintText: 'Décris ce point...', hintStyle: const TextStyle(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(children: [
                    const Text('Photos', style: TextStyle(fontSize: 14, color: Colors.white54)),
                    const SizedBox(width: 8),
                    Text('${selectedPhotoPaths.length}/3', style: const TextStyle(fontSize: 12, color: Colors.white38)),
                  ]),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      ...selectedPhotoPaths.map((path) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(children: [
                          ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(File(path), width: 72, height: 72, fit: BoxFit.cover)),
                          Positioned(top: 2, right: 2, child: GestureDetector(
                            onTap: () => setModalState(() => selectedPhotoPaths.remove(path)),
                            child: Container(width: 20, height: 20, decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.close, size: 14, color: Colors.white)),
                          )),
                        ]),
                      )),
                      if (selectedPhotoPaths.length < 3)
                        GestureDetector(
                          onTap: () async {
                            final source = await showModalBottomSheet<ImageSource>(
                              context: ctx,
                              backgroundColor: const Color(0xFF2A2A2A),
                              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                              builder: (c) => Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  ListTile(leading: const Icon(Icons.camera_alt, color: Colors.white), title: const Text('Appareil photo', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(c, ImageSource.camera)),
                                  ListTile(leading: const Icon(Icons.photo_library, color: Colors.white), title: const Text('Galerie', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(c, ImageSource.gallery)),
                                ]),
                              ),
                            );
                            if (source == null) return;
                            final picked = await _imagePicker.pickImage(source: source, imageQuality: 80, maxWidth: 1200);
                            if (picked != null) setModalState(() => selectedPhotoPaths.add(picked.path));
                          },
                          child: Container(
                            width: 72, height: 72,
                            decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white24)),
                            child: const Icon(Icons.add_a_photo, color: Colors.white38, size: 28),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                      ),
                      onPressed: () async {
                        final lat = double.tryParse(latitude);
                        final lng = double.tryParse(longitude);
                        if (lat == null || lng == null) return;
                        final List<String> permanentPaths = [];
                        for (final path in selectedPhotoPaths) {
                          permanentPaths.add(await _copyPhotoToPermanentDir(path));
                        }
                        setState(() {
                          rideWaypoints.add({'lat': lat, 'lng': lng, 'note': noteController.text.trim(), 'timestamp': DateTime.now().toIso8601String(), 'photos': permanentPaths});
                        });
                        Navigator.of(modalContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Point mémorisé !')));
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

  String generateShareCode() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(Iterable.generate(8, (_) => chars.codeUnitAt(random.nextInt(chars.length))));
  }

  Future<void> uploadSafetyPosition() async {
    if (safetySessionId == null || currentPosition == null) return;
    final supabase = Supabase.instance.client;
    await supabase.from('safety_positions').insert({
      'session_id': safetySessionId,
      'latitude': currentPosition!.latitude,
      'longitude': currentPosition!.longitude,
    });
  }

  void startSafetyUploadTimer() {
    safetyUploadTimer = Timer.periodic(const Duration(seconds: 15), (timer) async { await uploadSafetyPosition(); });
  }

  Future<void> createSafetySession() async {
    final supabase = Supabase.instance.client;
    final shareCode = generateShareCode();
    final response = await supabase.from('safety_sessions').insert({'share_code': shareCode, 'status': 'in_progress'}).select().single();
    safetySessionId = response['id'];
    safetyShareCode = shareCode;
    safetyUrl = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    startSafetyUploadTimer();
  }

  Future<void> shareSafetyLink() async {
    if (safetyShareCode == null) return;
    final url = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    final message = 'Je démarre une sortie avec Sunday Tracker.\n\nTu peux consulter ma dernière position connue ici :\n\n$url';
    await Share.share(message, subject: 'Sunday Tracker Safety Beacon');
  }

  Future<void> _showExitRideModal() async {
    final screenNavigator = Navigator.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Quitter la sortie ?', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 12),
              const Text('Que souhaitez-vous faire ?', style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 32),
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.of(modalContext).pop(), child: const Text('Continuer', style: TextStyle(color: Color(0xFFD0BCFF), fontSize: 18)))),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    Navigator.of(modalContext).pop();
                    await cancelRide();
                    if (!mounted) return;
                    screenNavigator.pop();
                  },
                  child: const Text('Terminer sans sauvegarder', style: TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.w600)),
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
                    backgroundColor: const Color(0xFFFF5A4F), foregroundColor: Colors.white,
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
    rideTimer = Timer.periodic(const Duration(seconds: 1), (timer) { setState(() { rideDuration = DateTime.now().difference(rideStartTime!); }); });
    await startTracking();
    startSafetyUploadTimer();
    setState(() { rideIsPaused = false; });
    await Supabase.instance.client.from('safety_sessions').update({'status': 'in_progress'}).eq('id', safetySessionId!);
  }

  Future<void> saveRide() async {
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
    await Supabase.instance.client.from('safety_sessions').update({'status': 'finished', 'ended_at': DateTime.now().toIso8601String()}).eq('id', safetySessionId!);
  }

  Future<void> startTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();

    positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: kDebugMode ? 0 : 5),
    ).listen((Position position) {
      currentPosition = position;
      final newPoint = LatLng(position.latitude, position.longitude);

      setState(() {
        gpsIsReady = position.accuracy <= 15;
        latitude = position.latitude.toString();
        longitude = position.longitude.toString();
        altitude = position.altitude.toStringAsFixed(1);
        accuracy = position.accuracy.toStringAsFixed(1);
      });

      if (mapReady) mapController.move(newPoint, 16);
      if (position.accuracy > 20) return;

      if (ridePoints.isNotEmpty) {
        final lastPoint = ridePoints.last;
        final distance = distanceCalculator.as(LengthUnit.Meter, lastPoint, newPoint);
        final dt = (_lastPointTimestamp != null && position.timestamp != null)
            ? position.timestamp!.difference(_lastPointTimestamp!).inSeconds.abs() : 1;
        final maxAllowedDistance = (50.0 * max(dt, 1)) + (position.accuracy * 5);
        if (distance > maxAllowedDistance) return;
        totalDistance += distance;
      }

      ridePoints.add(newPoint);
      _lastPointTimestamp = position.timestamp ?? DateTime.now();
    });
  }

  Future<Map<String, String>> getRideLocationTags() async {
    if (ridePoints.isEmpty) return {'city': '', 'department': '', 'region': ''};
    try {
      final placemarks = await placemarkFromCoordinates(ridePoints.first.latitude, ridePoints.first.longitude);
      if (placemarks.isEmpty) return {'city': '', 'department': '', 'region': ''};
      final place = placemarks.first;
      return {'city': place.locality ?? '', 'department': place.subAdministrativeArea ?? '', 'region': place.administrativeArea ?? ''};
    } catch (e) {
      return {'city': '', 'department': '', 'region': ''};
    }
  }

  String formattedDuration() {
    final h = rideDuration.inHours.toString().padLeft(2, '0');
    final m = (rideDuration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (rideDuration.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String formattedDistance() {
    if (totalDistance < 1000) return '${totalDistance.toStringAsFixed(0)} m';
    return '${(totalDistance / 1000).toStringAsFixed(2)} km';
  }

  Color accuracyColor() {
    final value = double.tryParse(accuracy) ?? 999;
    if (value <= 5) return Colors.green;
    if (value <= 15) return Colors.orange;
    return Colors.red;
  }

  Future<void> handleBackPressed() async {
    if (!rideIsStarted) { Navigator.of(context).pop(); return; }
    await _showExitRideModal();
  }

  // ── Widget helpers ──────────────────────────────────────────────

  // Compact stat column — smaller icons & font for no-scroll layout
  Widget _statColumn(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Column(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 1),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
    );
  }

  // ── Ride status ────────────────────────────────────────────────

  String _rideStatusTitle() {
    if (!rideIsStarted) return 'Nouveau ride';
    if (rideIsPaused) return 'Ride en pause';
    return 'Ride en cours';
  }

  String? _rideStatusSubtitle() {
    if (!rideIsStarted) return null;
    if (rideIsPaused) return 'Suivi suspendu';
    return 'Suivi en direct';
  }

  Color _rideStatusColor() {
    if (!rideIsStarted) return Colors.blue;
    if (rideIsPaused) return Colors.orange;
    return Colors.green;
  }

  // ── GPS badge ──────────────────────────────────────────────────

  Color _gpsBadgeColor() {
    if (rideIsPaused) return Colors.white38;
    final value = double.tryParse(accuracy) ?? 999;
    if (value <= 15) return Colors.green;
    if (value <= 30) return Colors.orange;
    return Colors.red;
  }

  String _gpsBadgeLabel() {
    if (rideIsPaused) return 'GPS off';
    final value = double.tryParse(accuracy) ?? 999;
    if (value <= 15) return 'GPS actif';
    if (value <= 30) return 'GPS moyen';
    return 'GPS faible';
  }

  void _showGpsDetailsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(color: _gpsBadgeColor().withValues(alpha: 0.15), shape: BoxShape.circle),
                    child: Icon(Icons.satellite_alt, color: _gpsBadgeColor(), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Détails GPS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                      Text(_gpsBadgeLabel(), style: TextStyle(fontSize: 12, color: _gpsBadgeColor())),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: Colors.white12),
              const SizedBox(height: 14),
              _gpsRow(Icons.public, 'Latitude', latitude),
              const SizedBox(height: 10),
              _gpsRow(Icons.language, 'Longitude', longitude),
              const SizedBox(height: 10),
              _gpsRow(Icons.terrain, 'Altitude', '$altitude m'),
              const SizedBox(height: 10),
              _gpsRow(Icons.gps_fixed, 'Précision', '$accuracy m', valueColor: _gpsBadgeColor()),
              const SizedBox(height: 16),
              Container(height: 1, color: Colors.white12),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _legendDot(Colors.green, '≤ 15 m'),
                  _legendDot(Colors.orange, '15–30 m'),
                  _legendDot(Colors.red, '> 30 m'),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Fermer', style: TextStyle(color: Color(0xFFD0BCFF))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async { await handleBackPressed(); return false; },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: handleBackPressed),
          title: Column(
            children: [
              Text(_rideStatusTitle(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              if (_rideStatusSubtitle() != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: _rideStatusColor(), shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text(_rideStatusSubtitle()!, style: TextStyle(fontSize: 12, color: _rideStatusColor())),
                  ],
                ),
            ],
          ),
          centerTitle: true,
          actions: [
            if (rideIsStarted)
              IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
          ],
        ),

        body: gpsIsInitializing
            ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 24), Text('Initialisation GPS...', style: TextStyle(fontSize: 18, color: Colors.white))]))
            : !gpsIsReady
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.gps_off, size: 80, color: Colors.orange),
                    const SizedBox(height: 24),
                    const Text('Recherche du signal GPS...', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Text('Précision actuelle : $accuracy m', style: const TextStyle(fontSize: 18)),
                    const SizedBox(height: 32),
                    const CircularProgressIndicator(),
                  ]))
                : Column(
                    children: [

                      // ── CARTE — réduite à 200px ──
                      SizedBox(
                        height: 200,
                        child: FlutterMap(
                          mapController: mapController,
                          options: MapOptions(
                            initialCenter: LatLng(double.tryParse(latitude) ?? 48.8566, double.tryParse(longitude) ?? 2.3522),
                            initialZoom: 15,
                            onMapReady: () { mapReady = true; },
                          ),
                          children: [
                            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.sunday_tracker'),
                            PolylineLayer(polylines: [
                              Polyline(points: ridePoints, strokeWidth: 14, color: Colors.orange.withValues(alpha: 0.25)),
                              Polyline(points: ridePoints, strokeWidth: 6, color: const Color(0xFFFFA726)),
                            ]),
                            MarkerLayer(markers: [
                              Marker(
                                point: LatLng(double.tryParse(latitude) ?? 48.8566, double.tryParse(longitude) ?? 2.3522),
                                width: 24, height: 24,
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.red,
                                    border: Border.all(color: Colors.white, width: 2.5),
                                    boxShadow: [BoxShadow(color: Colors.red.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 1)],
                                  ),
                                ),
                              ),
                              ...rideWaypoints.map((wp) => Marker(
                                point: LatLng(wp['lat'], wp['lng']),
                                width: 36, height: 36,
                                child: const Icon(Icons.place, color: Colors.blue, size: 36),
                              )),
                            ]),
                          ],
                        ),
                      ),

                      // ── CONTENU NON-SCROLLABLE ──
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Column(
                            children: [

                              // ── CARD STATS — compacte ──
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(20)),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.terrain, color: _rideStatusColor(), size: 18),
                                            const SizedBox(width: 6),
                                            Text(_rideStatusTitle(), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                        GestureDetector(
                                          onTap: _showGpsDetailsDialog,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              border: Border.all(color: _gpsBadgeColor()),
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: Row(children: [
                                              Container(width: 5, height: 5, decoration: BoxDecoration(color: _gpsBadgeColor(), shape: BoxShape.circle)),
                                              const SizedBox(width: 3),
                                              Text(_gpsBadgeLabel(), style: TextStyle(fontSize: 10, color: _gpsBadgeColor())),
                                              const SizedBox(width: 3),
                                              Icon(Icons.info_outline, size: 10, color: _gpsBadgeColor()),
                                            ]),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        _statColumn('Distance', formattedDistance(), Icons.route, Colors.orange),
                                        Container(width: 1, height: 50, color: Colors.white12),
                                        _statColumn('Durée', formattedDuration(), Icons.timer, Colors.green),
                                        Container(width: 1, height: 50, color: Colors.white12),
                                        _statColumn('Précision', '${double.tryParse(accuracy)?.toStringAsFixed(0) ?? accuracy} m', Icons.gps_fixed, Colors.blue),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 8),

                              // ── CARD PARTAGER pleine largeur ──
                              if (rideIsStarted)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(16)),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 36, height: 36,
                                            decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.15), shape: BoxShape.circle),
                                            child: const Icon(Icons.share_location, color: Colors.blue, size: 18),
                                          ),
                                          const SizedBox(width: 10),
                                          const Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text('Partager le suivi', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                                Text('Envoie ta position en temps réel', style: TextStyle(fontSize: 10, color: Colors.white54)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: shareSafetyLink,
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(vertical: 7),
                                                decoration: BoxDecoration(
                                                  color: Colors.blue.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: const Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.ios_share, color: Colors.blue, size: 13),
                                                    SizedBox(width: 4),
                                                    Text('Envoyer le lien', style: TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: () async {
                                                if (safetyUrl != null) {
                                                  final uri = Uri.parse(safetyUrl!);
                                                  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                                                }
                                              },
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(vertical: 7),
                                                decoration: BoxDecoration(
                                                  color: Colors.green.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: const Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Icon(Icons.open_in_browser, color: Colors.green, size: 13),
                                                    SizedBox(width: 4),
                                                    Text('Voir le live', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.w600)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),

                              const Spacer(),

                              // ── BOUTONS ──
                              if (!rideIsStarted)
                                GestureDetector(
                                  onTap: startRide,
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(vertical: 18),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFF00C853), Color(0xFF00897B)],
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: [
                                        BoxShadow(color: const Color(0xFF00C853).withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6)),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 36, height: 36,
                                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
                                        ),
                                        const SizedBox(width: 12),
                                        const Text('Démarrer la sortie', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.3)),
                                      ],
                                    ),
                                  ),
                                )
                              else ...[

                                // PAUSE / REPRENDRE
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: rideIsPaused ? Colors.green : Colors.blue,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                    ),
                                    onPressed: togglePauseRide,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 38, height: 38,
                                          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                                          child: Icon(rideIsPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, color: Colors.white, size: 24),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          rideIsPaused ? 'Reprendre' : 'Pause',
                                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 8),

                                // ARRÊTER + WAYPOINT + SOS
                                Row(
                                  children: [

                                    // ARRÊTER
                                    Expanded(
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF1A1A1A),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        ),
                                        onPressed: () async {
                                          await stopTrackingImmediately();
                                          await _showExitRideModal();
                                        },
                                        child: Column(children: [
                                          Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.15), shape: BoxShape.circle), child: const Icon(Icons.stop, color: Colors.red, size: 18)),
                                          const SizedBox(height: 4),
                                          const Text('Arrêter', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        ]),
                                      ),
                                    ),

                                    const SizedBox(width: 8),

                                    // WAYPOINT
                                    Expanded(
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF1A1A1A),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        ),
                                        onPressed: _showAddWaypointModal,
                                        child: Column(children: [
                                          Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.15), shape: BoxShape.circle), child: const Icon(Icons.place, color: Colors.blue, size: 18)),
                                          const SizedBox(height: 4),
                                          const Text('Waypoint', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        ]),
                                      ),
                                    ),

                                    const SizedBox(width: 8),

                                    // SOS
                                    Expanded(
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red,
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        ),
                                        onPressed: () {},
                                        child: Column(children: [
                                          Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle), child: const Icon(Icons.emergency, color: Colors.white, size: 18)),
                                          const SizedBox(height: 4),
                                          const Text('SOS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
                                        ]),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _gpsRow(IconData icon, String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Icon(icon, color: Colors.lightBlue, size: 14),
        const SizedBox(width: 6),
        Text('$label : ', style: const TextStyle(fontSize: 12, color: Colors.white54)),
        Expanded(child: Text(value, style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white70))),
      ],
    );
  }
}