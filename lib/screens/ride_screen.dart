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
import '../services/share_image_service.dart';
import '../services/photo_sync_service.dart';
import '../utils/date_labels.dart';
import '../utils/geo_labels.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'home_screen.dart';
import 'dart:ui' as ui;

// ── Bordure pointillée pour la zone Notifications ─────────────────
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const dashLen = 6.0;
    const gapLen = 4.0;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      Radius.circular(radius),
    );
    final path = ui.Path()..addRRect(rect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(metric.extractPath(dist, dist + dashLen), paint);
        dist += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// ── Carte isolée — évite que les rebuilds du parent triggent didUpdateWidget ──
class _IsolatedMap extends StatelessWidget {
  final MapController mapController;
  final int mapStyleIndex;
  final List<Map<String, dynamic>> mapStyles;
  final bool rideIsStarted;
  final List<LatLng> ridePoints;
  final List<Map<String, dynamic>> rideWaypoints;
  final String latitude;
  final String longitude;
  final VoidCallback onMapReady;
  final void Function(MapEvent)? onMapEvent;
  final void Function(Map<String, dynamic> wp, int number)? onWaypointTap;

  const _IsolatedMap({
    super.key,
    required this.mapController,
    required this.mapStyleIndex,
    required this.mapStyles,
    required this.rideIsStarted,
    required this.ridePoints,
    required this.rideWaypoints,
    required this.latitude,
    required this.longitude,
    required this.onMapReady,
    this.onMapEvent,
    this.onWaypointTap,
  });

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: LatLng(
          double.tryParse(latitude) ?? 48.8566,
          double.tryParse(longitude) ?? 2.3522,
        ),
        initialZoom: rideIsStarted ? 15 : 14,
        onMapReady: onMapReady,
        onMapEvent: onMapEvent,
      ),
      children: [
        TileLayer(
          key: ValueKey(mapStyleIndex),
          urlTemplate:
              (mapStyles[mapStyleIndex]['url'] ??
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png')
                  as String,
          subdomains:
              ((mapStyles[mapStyleIndex]['subdomains']) as List?)
                  ?.cast<String>() ??
              const <String>[],
          maxZoom: (((mapStyles[mapStyleIndex]['maxZoom']) ?? 19) as num)
              .toDouble(),
          userAgentPackageName: 'com.example.sunday_tracker',
          errorTileCallback: (tile, error, stackTrace) {},
        ),
        if (rideIsStarted)
          PolylineLayer(
            polylines: [
              Polyline(
                points: ridePoints,
                strokeWidth: 14,
                color: Colors.orange.withValues(alpha: 0.25),
              ),
              Polyline(
                points: ridePoints,
                strokeWidth: 6,
                color: const Color(0xFFFFA726),
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
              width: 24,
              height: 24,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red,
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
            // Points de passage : même style que l'écran de détail — pastille
            // numérotée excentrée perpendiculairement à la trace, reliée par un
            // trait de rappel à un point posé sur la vraie position GPS.
            for (final (i, wp) in rideWaypoints.indexed)
              _waypointMarker(wp, i + 1),
          ],
        ),
      ],
    );
  }

  // Barycentre du tracé : sert à décaler les pins vers l'EXTÉRIEUR de la boucle.
  ({double lat, double lng}) _traceCentroid() {
    if (ridePoints.isEmpty) return (lat: 0, lng: 0);
    var sLat = 0.0, sLng = 0.0;
    for (final p in ridePoints) {
      sLat += p.latitude;
      sLng += p.longitude;
    }
    return (lat: sLat / ridePoints.length, lng: sLng / ridePoints.length);
  }

  /// Direction unitaire (repère écran) PERPENDICULAIRE à la trace au niveau du
  /// waypoint [at], pointant vers l'EXTÉRIEUR (loin du barycentre).
  Offset _leaderDirection(LatLng at) {
    final trace = ridePoints;
    if (trace.length < 2) return const Offset(0, -1);
    var nearest = 0;
    var best = double.infinity;
    for (var i = 0; i < trace.length; i++) {
      final dLat = trace[i].latitude - at.latitude;
      final dLng = trace[i].longitude - at.longitude;
      final d = dLat * dLat + dLng * dLng;
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    final a = trace[max(0, nearest - 2)];
    final b = trace[min(trace.length - 1, nearest + 2)];
    final latRad = at.latitude * pi / 180;
    final cosLat = cos(latRad);
    final tx = (b.longitude - a.longitude) * cosLat;
    final ty = -(b.latitude - a.latitude);
    final tlen = sqrt(tx * tx + ty * ty);
    if (tlen < 1e-12) return const Offset(0, -1);
    var px = -ty / tlen;
    var py = tx / tlen;
    final c = _traceCentroid();
    final outX = (at.longitude - c.lng) * cosLat;
    final outY = -(at.latitude - c.lat);
    if (outX * outX + outY * outY > 1e-12) {
      if (px * outX + py * outY < 0) {
        px = -px;
        py = -py;
      }
    } else {
      if (py > 1e-6) {
        px = -px;
        py = -py;
      } else if (py.abs() <= 1e-6 && px < 0) {
        px = -px;
      }
    }
    return Offset(px, py);
  }

  /// Marker waypoint : pin flottant numéroté décalé perpendiculairement à la
  /// trace, relié par une fine ligne à un point posé sur sa vraie position GPS.
  Marker _waypointMarker(Map<String, dynamic> wp, int number) {
    const color = Color(0xFF2563EB);
    const lead = 30.0;
    const box = 120.0;
    const badge = 30.0;
    final at = LatLng((wp['lat'] as num).toDouble(), (wp['lng'] as num).toDouble());
    final dir = _leaderDirection(at);
    final tip = Offset(dir.dx * lead, dir.dy * lead);
    final angle = atan2(tip.dy, tip.dx);
    return Marker(
      point: at,
      width: box,
      height: box,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.translate(
              offset: Offset(tip.dx / 2, tip.dy / 2),
              child: Transform.rotate(
                angle: angle,
                child: Container(
                  width: lead,
                  height: 2,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
            Transform.translate(
              offset: tip,
              child: GestureDetector(
                onTap: onWaypointTap == null
                    ? null
                    : () => onWaypointTap!(wp, number),
                child: Container(
                  width: badge,
                  height: badge,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 4),
                    ],
                  ),
                  child: Text('$number',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: number >= 10 ? 13 : 16,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
  // Clé stable pour _IsolatedMap : permet le reparentage sans démontage/remontage,
  // évitant le setState-during-build quand la carte change de position dans l'arbre.
  final GlobalKey _mapKey = GlobalKey();
  bool mapReady = false;
  final List<LatLng> ridePoints = [];

  // ── Points avec altitude (remplace ridePoints dans saveRide) ──
  final List<Map<String, dynamic>> _pointsWithAlt = [];

  // ── Persistance GPS ───────────────────────────────────────────
  final List<Map<String, dynamic>> _uploadQueue = []; // points en attente d'upload Supabase
  Box? _currentRideBox; // Hive crash-safety

  double totalDistance = 0;
  final Distance distanceCalculator = const Distance();
  String accuracy = '0';
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

  // ── Cheat code debug GPS (5 taps sur le bandeau cockpit) ──────
  bool _showDebugPanel = false;
  int _debugTapCount = 0;
  DateTime? _lastDebugTap;
  int? _debugStorageBytes; // octets utilisés sur le Storage (null = pas encore mesuré)
  int _debugPendingPhotos = 0; // url == null ET fichier local présent → uploadables
  int _debugOrphanPhotos = 0; // url == null ET fichier local absent → irrécupérables
  // Points GPS reçus mais NON enregistrés, par raison :
  int _ignoredAccuracy = 0; // précision > 20 m (signal trop flou)
  int _ignoredOutlier = 0;  // saut GPS impossible (téléportation)
  int _ignoredJitter = 0;   // bougé < max(5 m, précision) → gigue à l'arrêt

  final List<Map<String, dynamic>> rideWaypoints = [];
  final ImagePicker _imagePicker = ImagePicker();

  // ── Pause cockpit ─────────────────────────────────────────────
  DateTime? _pauseStartTime;
  DateTime? _lastGpsUpdateTime;
  String _gpsLabelBeforePause = 'Bon';
  Color _gpsColorBeforePause = const Color(0xFF4ade80);
  final List<double> _speedPoints = [];

  // ── Nom & note personnalisés ───────────────────────────────────
  String? _customRideName;
  String _rideNote = '';

  // ── Pratique choisie au démarrage (null = détection auto) ───────
  String? _selectedPractice;

  // ── Notifications ──────────────────────────────────────────────
  int _notificationCount = 0;
  final List<Map<String, dynamic>> _notifications = [];

  // ── Carte ──────────────────────────────────────────────────────
  static const String _prefKeyMapStyle = 'ride_map_style_index';
  static const String _prefKeyMapCollapsed = 'ride_map_collapsed';
  static const String _prefKeyLastShare = 'ride_last_share_link';
  static const String _prefKeyNotifyProches = 'ride_notify_proches';
  static const String _prefKeyLastPractice = 'ride_last_practice';
  int _mapStyleIndex = 0;
  bool _mapFullscreen = false;
  bool _mapCollapsed = false;
  bool _followPosition = true;
  final List<Map<String, dynamic>> _mapStyles = [
    {
      'label': 'Satellite',
      'icon': Icons.satellite_alt,
      'url':
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'subdomains': <String>[],
      'maxZoom': 19,
    },
    {
      'label': 'Topo',
      'icon': Icons.terrain,
      'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
      'subdomains': <String>['a', 'b', 'c'],
      'maxZoom': 17,
    },
    {
      'label': 'Plan',
      'icon': Icons.map,
      'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      'subdomains': <String>[],
      'maxZoom': 19,
    },
  ];

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_prefKeyMapStyle) ?? 0;
    final collapsed = prefs.getBool(_prefKeyMapCollapsed) ?? false;
    if (mounted)
      setState(() {
        _mapStyleIndex = saved.clamp(0, _mapStyles.length - 1);
        _mapCollapsed = collapsed;
      });
  }

  Future<void> _saveMapStyle(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefKeyMapStyle, index);
  }

  Future<void> _toggleMapCollapsed() async {
    setState(() => _mapCollapsed = !_mapCollapsed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyMapCollapsed, _mapCollapsed);
  }

  // ── Vitesse & dénivelé ─────────────────────────────────────────
  double _speedKmh = 0;
  double _maxSpeedKmh = 0;
  double _avgSpeedKmh = 0;
  double _dPlus = 0;
  double _dMinus = 0; // ← nouveau : D− cumulé
  double _slopePercent = 0;
  double _maxSlopePercent = 0;
  double? _prevAltitude;
  double? _prevDistance;
  int _speedSamples = 0;
  double _speedSum = 0;

  // ── Altitude min/max et altitude de départ ─────────────────────
  double? _altStart;
  double _altMax = -double.infinity;
  double _altMin = double.infinity;

  // ── Temps en mouvement ─────────────────────────────────────────
  Duration _movingTime = Duration.zero;
  DateTime? _lastMovingTick;

  // ── _updateSpeedAndElevation (version complète) ────────────────
  void _updateSpeedAndElevation(Position position) {
    final spd = (position.speed * 3.6).clamp(0.0, 200.0);
    _speedKmh = spd;
    _lastGpsUpdateTime = DateTime.now();
    _speedPoints.add(spd);
    if (spd > _maxSpeedKmh) _maxSpeedKmh = spd;
    if (spd > 0.5) {
      _speedSum += spd;
      _speedSamples++;
      // Cumul temps en mouvement
      final now = DateTime.now();
      if (_lastMovingTick != null) {
        _movingTime += now.difference(_lastMovingTick!);
      }
      _lastMovingTick = now;
    } else {
      _lastMovingTick = null;
    }
    _avgSpeedKmh = _speedSamples > 0 ? _speedSum / _speedSamples : 0;

    final alt = position.altitude;

    // Altitude de départ (première position)
    _altStart ??= alt;

    // Min / Max
    if (alt > _altMax) _altMax = alt;
    if (alt < _altMin) _altMin = alt;

    if (_prevAltitude != null) {
      final dAlt = alt - _prevAltitude!;
      final dDist = totalDistance - (_prevDistance ?? 0);
      if (dAlt > 0.5) _dPlus += dAlt; // D+
      if (dAlt < -0.5) _dMinus += dAlt.abs(); // D−
      if (dDist > 1) {
        _slopePercent = (dAlt / dDist * 100).clamp(-45.0, 45.0);
        if (_slopePercent.abs() > _maxSlopePercent)
          _maxSlopePercent = _slopePercent.abs();
      }
    }
    _prevAltitude = alt;
    _prevDistance = totalDistance;
  }

  Widget _elevRow(String label, String value, double progress, Color color) =>
      Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0,
                backgroundColor: const Color(0xFF2A2A2A),
                color: color,
                minHeight: 3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      );

  // ── Météo + Soleil ─────────────────────────────────────────────
  double? _weatherTemp;
  double? _weatherWind;
  String? _weatherWindDir;
  int? _weatherHumidity;
  String? _weatherDesc;
  Timer? _weatherTimer;
  bool _weatherFetched = false;
  Map<String, dynamic>? _weatherSnapshotStart;
  Map<String, dynamic>? _weatherSnapshotEnd;

  Map<String, dynamic> _currentWeatherSnapshot() => {
    'temp': _weatherTemp,
    'wind': _weatherWind,
    'windDir': _weatherWindDir,
    'humidity': _weatherHumidity,
    'desc': _weatherDesc,
  };

  DateTime? _sunriseTime;
  DateTime? _sunsetTime;
  bool _sunFetched = false;
  int _sunTimerTicks = 0;
  Timer? _sunTimer;

  bool get _isNight {
    if (_sunriseTime == null || _sunsetTime == null) return false;
    final now = DateTime.now();
    return now.isBefore(_sunriseTime!) || now.isAfter(_sunsetTime!);
  }

  double _computeSunProgress() {
    if (_sunriseTime == null || _sunsetTime == null) return 0;
    final now = DateTime.now();
    if (!_isNight) {
      final total = _sunsetTime!.difference(_sunriseTime!).inSeconds.toDouble();
      if (total <= 0) return 0;
      final elapsed = now.difference(_sunriseTime!).inSeconds.toDouble();
      return (elapsed / total).clamp(0.0, 1.0);
    } else {
      final nextSunrise = now.isBefore(_sunriseTime!)
          ? _sunriseTime!
          : _sunriseTime!.add(const Duration(days: 1));
      final total = nextSunrise.difference(_sunsetTime!).inSeconds.toDouble();
      if (total <= 0) return 0;
      final elapsed = now.difference(_sunsetTime!).inSeconds.toDouble();
      return (elapsed / total).clamp(0.0, 1.0);
    }
  }

  String _sunLabel() {
    if (_sunriseTime == null || _sunsetTime == null) return 'Chargement…';
    final now = DateTime.now();
    if (!_isNight) {
      final rem = _sunsetTime!.difference(now);
      final h = rem.inHours;
      final m = rem.inMinutes % 60;
      return h > 0
          ? '${h}h ${m.toString().padLeft(2, '0')} restantes'
          : '${m}min restantes';
    } else {
      final nextSunrise = now.isBefore(_sunriseTime!)
          ? _sunriseTime!
          : _sunriseTime!.add(const Duration(days: 1));
      final rem = nextSunrise.difference(now);
      final h = rem.inHours;
      final m = rem.inMinutes % 60;
      return 'lever dans ${h}h ${m.toString().padLeft(2, '0')}';
    }
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _fetchSunTimes(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://api.sunrise-sunset.org/json?lat=${lat.toStringAsFixed(6)}&lng=${lng.toStringAsFixed(6)}&formatted=0',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['status'] != 'OK') return;
      final r = json['results'] as Map<String, dynamic>;
      final sunrise = DateTime.parse(r['sunrise'] as String).toLocal();
      final sunset = DateTime.parse(r['sunset'] as String).toLocal();
      if (!mounted) return;
      setState(() {
        _sunriseTime = sunrise;
        _sunsetTime = sunset;
        _sunFetched = true;
      });
    } catch (e) {
      debugPrint('[SUN] $e');
    }
  }

  Future<void> _fetchWeather(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${lat.toStringAsFixed(4)}&longitude=${lng.toStringAsFixed(4)}'
        '&current=temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,weather_code',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>;
      final code = (current['weather_code'] as num).toInt();
      final windDeg = (current['wind_direction_10m'] as num).toDouble();
      if (!mounted) return;
      setState(() {
        _weatherTemp = (current['temperature_2m'] as num).toDouble();
        _weatherWind = (current['wind_speed_10m'] as num).toDouble();
        _weatherHumidity = (current['relative_humidity_2m'] as num).toInt();
        _weatherWindDir = _windDirLabel(windDeg);
        _weatherDesc = _weatherCodeDesc(code);
        _weatherFetched = true;
      });
    } catch (e) {
      debugPrint('[WEATHER] $e');
    }
  }

  String _windDirLabel(double deg) {
    const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];
    return dirs[((deg + 22.5) / 45).floor() % 8];
  }

  String _weatherCodeDesc(int code) {
    if (code == 0) return 'Ciel dégagé';
    if (code <= 2) return 'Peu nuageux';
    if (code == 3) return 'Couvert';
    if (code <= 49) return 'Brouillard';
    if (code <= 57) return 'Bruine';
    if (code <= 67) return 'Pluie';
    if (code <= 77) return 'Neige';
    if (code <= 82) return 'Averses';
    if (code <= 99) return 'Orage';
    return 'Inconnu';
  }

  IconData _weatherIcon(String? desc) {
    if (desc == null) return Icons.wb_sunny;
    if (_isNight) {
      if (desc == 'Ciel dégagé') return Icons.nights_stay_outlined;
      return Icons.cloud;
    }
    if (desc == 'Ciel dégagé' || desc == 'Peu nuageux') return Icons.wb_sunny;
    if (desc == 'Couvert') return Icons.cloud;
    if (desc.contains('Pluie') ||
        desc.contains('Averses') ||
        desc.contains('Bruine'))
      return Icons.grain;
    if (desc.contains('Neige')) return Icons.ac_unit;
    if (desc.contains('Orage')) return Icons.bolt;
    if (desc.contains('Brouillard')) return Icons.blur_on;
    return Icons.wb_sunny;
  }

  Color get _sunColor =>
      _isNight ? const Color(0xFF818cf8) : const Color(0xFFF9A825);

  void _startWeatherAndSunTimers() {
    _weatherTimer?.cancel();
    _weatherTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      final lat = double.tryParse(latitude);
      final lng = double.tryParse(longitude);
      if (lat != null && lng != null) _fetchWeather(lat, lng);
    });
    _sunTimer?.cancel();
    _sunTimerTicks = 0;
    _sunTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _sunTimerTicks++;
      if (_sunTimerTicks % 60 == 0) {
        final lat = double.tryParse(latitude);
        final lng = double.tryParse(longitude);
        if (lat != null && lng != null) _fetchSunTimes(lat, lng);
      }
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // ← wrap ici
          if (mounted) setState(() {});
        });
      }
    });
  }

  // ── GPS ────────────────────────────────────────────────────────
  int _satelliteCount = 0;

  // ── Mode édition (réordonnage) ────────────────────────────────
  bool _editMode = false;

  // ── Position bandeau cockpit ──────────────────────────────────
  static const String _prefBannerPosition = 'cockpit_banner_position';
  String _bannerPosition = 'top'; // 'top' | 'bottom' | 'left'
  bool _isBannerDragging = false;
  double _bannerDragDeltaY = 0;
  double _bannerDragDeltaX = 0;
  final GlobalKey _cockpitControlsKey = GlobalKey();

  double get _cockpitControlsHeight {
    final ctx = _cockpitControlsKey.currentContext;
    if (ctx == null) return 210 + MediaQuery.of(context).padding.bottom;
    final box = ctx.findRenderObject() as RenderBox?;
    return box?.size.height ?? 210 + MediaQuery.of(context).padding.bottom;
  }

  // ── Géométrie cockpit : blocs de boutons + cartouche latérale ──
  // Source unique pour aligner boutons et cartouche dans les 2 modes.
  static const double _rightBtnBlockH = 122; // Localiser + Topo (le + grand)
  static const double _bannerGap = 28;       // écart boutons ↔ cartouche

  // Haut des blocs de boutons.
  // - montés (+12) : ils comblent le vide en haut ;
  // - descendus (+92) : uniquement quand la cartouche occupe le haut, pour
  //   laisser la place au bandeau horizontal.
  double _buttonsTopFor({
    required bool raised,
    required bool fullscreen,
    required double topInset,
  }) {
    if (fullscreen) return topInset + (raised ? 12 : 92);
    return raised ? 12 : 108;
  }

  double _cockpitButtonsTop(bool fullscreen, double topInset) {
    // Montés partout sauf quand le bandeau est ancré en haut.
    final raised = _bannerPosition != 'top';
    return _buttonsTopFor(
        raised: raised, fullscreen: fullscreen, topInset: topInset);
  }

  // Cartouche latérale : même hauteur à gauche et à droite (symétrie), calée
  // sous le plus grand des deux blocs de boutons pour ne rien chevaucher.
  // Suppose toujours l'état « boutons montés » : dès qu'elle est à
  // gauche/droite, les boutons sont forcément montés.
  double _sideBannerTop(bool fullscreen, double topInset) =>
      _buttonsTopFor(raised: true, fullscreen: fullscreen, topInset: topInset) +
      _rightBtnBlockH +
      _bannerGap;

  // Estompe et neutralise un overlay pendant le repositionnement de la
  // cartouche : évite tout chevauchement visuel entre les zones cibles et
  // les boutons carte/waypoint.
  Widget _dragFade(Widget child) => IgnorePointer(
        ignoring: _isBannerDragging,
        child: AnimatedOpacity(
          opacity: _isBannerDragging ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: child,
        ),
      );

  // ── Blocs collapsibles ─────────────────────────────────────────
  static const String _prefBlocksCollapsed = 'ride_blocks_collapsed';
  static const String _prefBlocksOrder = 'ride_blocks_order';

  static const Set<String> _validBlockIds = {
    'duree',
    'dist',
    'speed',
    'weather',
    'sun',
    'gps',
    'sharing',
  };

  final List<String> _blockIds = [
    'duree',
    'dist',
    'speed',
    'weather',
    'sun',
    'gps',
    'sharing',
  ];
  final Set<String> _collapsedBlocks = {};

  Future<void> _loadBlockPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final defaultCollapsed = _validBlockIds.toList();
    final collapsed =
        prefs.getStringList(_prefBlocksCollapsed) ?? defaultCollapsed;
    final savedOrder = prefs.getStringList(_prefBlocksOrder);
    if (mounted)
      setState(() {
        _collapsedBlocks
          ..clear()
          ..addAll(collapsed);
        if (savedOrder != null) {
          final allKnown = savedOrder.every(_validBlockIds.contains);
          if (allKnown) {
            final ordered = savedOrder.where(_blockIds.contains).toList();
            for (final id in _blockIds) {
              if (!ordered.contains(id)) ordered.add(id);
            }
            _blockIds
              ..clear()
              ..addAll(ordered);
          }
        }
      });
  }

  Future<void> _saveBlockPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefBlocksCollapsed, _collapsedBlocks.toList());
    await prefs.setStringList(_prefBlocksOrder, _blockIds);
  }

  Future<void> _resetPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefBlocksOrder);
    await prefs.remove(_prefBlocksCollapsed);
  }

  Future<void> _loadBannerPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final pos = prefs.getString(_prefBannerPosition) ?? 'top';
    if (mounted) setState(() => _bannerPosition = pos);
  }

  Future<void> _saveBannerPosition(String pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefBannerPosition, pos);
  }

  void _onBlockReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final id = _blockIds.removeAt(oldIndex);
      _blockIds.insert(newIndex, id);
    });
    _saveBlockPrefs();
  }

  void _toggleBlock(String id) {
    setState(() {
      final linked = id == 'weather'
          ? ['weather', 'sun']
          : id == 'sun'
          ? ['weather', 'sun']
          : id == 'duree'
          ? ['duree', 'dist']
          : id == 'dist'
          ? ['duree', 'dist']
          : [id];
      final willCollapse = !_collapsedBlocks.contains(linked.first);
      for (final lid in linked) {
        if (willCollapse) {
          _collapsedBlocks.add(lid);
        } else {
          _collapsedBlocks.remove(lid);
        }
      }
    });
    _saveBlockPrefs();
  }


  bool _isCollapsed(String id) => _collapsedBlocks.contains(id);

  // ── Header générique avec poignée drag ───────────────────────
  Widget _blockHeader({
    required String id,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String summary,
    int? draggableIndex,
  }) {
    final collapsed = _isCollapsed(
      id == 'sun'
          ? 'weather'
          : id == 'dist'
          ? 'duree'
          : id,
    );
    return GestureDetector(
      onTap: _editMode ? null : () => _toggleBlock(id),
      onLongPress: () {
        setState(() => _editMode = !_editMode);
        HapticFeedback.mediumImpact();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 10, 14, collapsed ? 10 : 4),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: collapsed
                  ? Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.white54,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            summary,
                            style: TextStyle(fontSize: 11, color: iconColor),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white54,
                      ),
                    ),
            ),
            if (draggableIndex != null && _editMode)
              ReorderableDragStartListener(
                index: draggableIndex,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4, right: 2),
                  child: Icon(
                    Icons.drag_handle,
                    color: Colors.white54,
                    size: 18,
                  ),
                ),
              ),
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white24,
                size: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Wrapper bloc ──────────────────────────────────────────────
  Widget _buildBlock({
    required String id,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String summary,
    required Widget body,
    int? draggableIndex,
  }) {
    final collapsed = _isCollapsed(
      id == 'sun'
          ? 'weather'
          : id == 'dist'
          ? 'duree'
          : id,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: _editMode ? Border.all(color: Colors.white12, width: 1) : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _blockHeader(
            id: id,
            icon: icon,
            iconColor: iconColor,
            title: title,
            summary: summary,
            draggableIndex: draggableIndex,
          ),
          AnimatedCrossFade(
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: body,
            ),
            secondChild: const SizedBox.shrink(),
            crossFadeState: collapsed
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
          ),
        ],
      ),
    );
  }

  // ── GPS helpers ───────────────────────────────────────────────
  Color _gpsSignalColor() {
    final v = double.tryParse(accuracy) ?? 999;
    if (rideIsPaused) return Colors.white38;
    if (v <= 5) return const Color(0xFF4ade80);
    if (v <= 15) return const Color(0xFF86efac);
    if (v <= 30) return Colors.orange;
    return Colors.red;
  }

  String _gpsSignalLabel() {
    if (rideIsPaused) return 'GPS off';
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 5) return 'Excellent';
    if (v <= 15) return 'Bon';
    if (v <= 30) return 'Moyen';
    return 'Faible';
  }

  int _gpsBarCount() {
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 5) return 5;
    if (v <= 10) return 4;
    if (v <= 15) return 3;
    if (v <= 30) return 2;
    return 1;
  }

  Widget _gpsStatMini(
    String label,
    String value,
    Color color, {
    bool small = false,
  }) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Colors.white38),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: small ? 10 : 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );

  // ═══════════════════════════════════════════════════════════════
  // BLOCS
  // ═══════════════════════════════════════════════════════════════

  Widget _buildNotificationZone() {
    final hasAlerts = _notificationCount > 0;
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: hasAlerts
            ? Colors.orange.withValues(alpha: 0.5)
            : Colors.white.withValues(alpha: 0.13),
        radius: 12,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: hasAlerts
                        ? Colors.orange.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    hasAlerts
                        ? Icons.notifications_active
                        : Icons.notifications_none,
                    color: hasAlerts ? Colors.orange : Colors.white38,
                    size: 15,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Notifications',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: hasAlerts ? Colors.white : Colors.white38,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: hasAlerts
                        ? Colors.orange.withValues(alpha: 0.18)
                        : Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$_notificationCount',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: hasAlerts ? Colors.orange : Colors.white24,
                    ),
                  ),
                ),
                const Spacer(),
                const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white12,
                  size: 16,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              hasAlerts
                  ? 'Liste des alertes active'
                  : 'Aucune notification pour le moment',
              style: TextStyle(
                fontSize: 12,
                color: hasAlerts ? Colors.white70 : Colors.white38,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Les alertes seront affichées ici pendant ton ride.',
              style: TextStyle(fontSize: 11, color: Colors.white24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 13),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedBody() {
    String fmt(double v) => v.toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              fmt(_speedKmh),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4ade80),
              ),
            ),
            const SizedBox(width: 4),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'km/h',
                style: TextStyle(fontSize: 13, color: Colors.white38),
              ),
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'moy. ${fmt(_avgSpeedKmh)} km/h',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                Text(
                  'max ${fmt(_maxSpeedKmh)} km/h',
                  style: const TextStyle(fontSize: 11, color: Colors.white24),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _elevRow(
          'D+ cumulé',
          '+${_dPlus.toStringAsFixed(0)} m',
          (_dPlus / 500).clamp(0, 1),
          const Color(0xFFfb923c),
        ),
        const SizedBox(height: 6),
        _elevRow(
          'D− cumulé',
          '−${_dMinus.toStringAsFixed(0)} m',
          (_dMinus / 500).clamp(0, 1),
          const Color(0xFFa78bfa),
        ),
        const SizedBox(height: 6),
        _elevRow(
          'Pente',
          '${_slopePercent >= 0 ? '+' : ''}${_slopePercent.toStringAsFixed(1)}%',
          (_slopePercent.abs() / 30).clamp(0, 1),
          const Color(0xFF60a5fa),
        ),
      ],
    );
  }

  Widget _buildWeatherBody() {
    final nightMode = _isNight;
    final color = nightMode ? const Color(0xFF818cf8) : const Color(0xFFF9A825);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(_weatherIcon(_weatherDesc), color: color, size: 24),
            const SizedBox(width: 8),
            Text(
              _weatherFetched ? '${_weatherTemp!.toStringAsFixed(0)}°' : '--°',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _weatherDesc ?? 'Chargement…',
          style: const TextStyle(fontSize: 10, color: Colors.white38),
          overflow: TextOverflow.ellipsis,
        ),
        if (_weatherFetched) ...[
          const SizedBox(height: 3),
          Text(
            '${_weatherWind!.toStringAsFixed(0)} km/h $_weatherWindDir · ${_weatherHumidity}%',
            style: const TextStyle(fontSize: 10, color: Colors.white24),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildSunBody() {
    final accent = _sunColor;
    final progress = _computeSunProgress();
    return Row(
      children: [
        Column(
          children: [
            Text(
              _fmt(_sunriseTime),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const Text(
              'lever',
              style: TextStyle(fontSize: 9, color: Colors.white30),
            ),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                Text(
                  _sunLabel(),
                  style: const TextStyle(fontSize: 9, color: Colors.white38),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 5),
                LayoutBuilder(
                  builder: (ctx, constraints) {
                    final w = constraints.maxWidth;
                    if (w <= 0) return const SizedBox(height: 12);
                    final p = progress.isFinite
                        ? progress.clamp(0.0, 1.0)
                        : 0.0;
                    return SizedBox(
                      height: 12,
                      child: Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 4,
                            right: 0,
                            bottom: 4,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 4,
                            bottom: 4,
                            width: (w * p).clamp(0.0, w),
                            child: Container(
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Positioned(
                            left: (w * p - 5.5).clamp(0.0, w - 11),
                            top: 0.5,
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF1A1A1A),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        Column(
          children: [
            Text(
              _fmt(_sunsetTime),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const Text(
              'coucher',
              style: TextStyle(fontSize: 9, color: Colors.white30),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGpsBody() {
    final signalColor = _gpsSignalColor();
    final barCount = _gpsBarCount();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(5, (i) {
                final active = i < barCount;
                final h = 6.0 + i * 4.0;
                return Container(
                  width: 6,
                  height: h,
                  margin: const EdgeInsets.only(right: 3),
                  decoration: BoxDecoration(
                    color: active ? signalColor : const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
            const SizedBox(width: 10),
            Text(
              _gpsSignalLabel(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: signalColor,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _showGpsDetailsDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 10, color: Colors.white38),
                    SizedBox(width: 3),
                    Text(
                      'Détails',
                      style: TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _gpsStatMini(
              'Précision',
              '${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m',
              signalColor,
            ),
            const SizedBox(width: 6),
            _gpsStatMini('Altitude', '$altitude m', Colors.white70),
            const SizedBox(width: 6),
            _gpsStatMini(
              'Lat / Long',
              '${double.tryParse(latitude)?.toStringAsFixed(4) ?? '--'} / ${double.tryParse(longitude)?.toStringAsFixed(4) ?? '--'}',
              Colors.white38,
              small: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGpsBlock() {
    final signalColor = _gpsSignalColor();
    final barCount = _gpsBarCount();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.satellite_alt, color: signalColor, size: 14),
                  const SizedBox(width: 6),
                  const Text(
                    'Signal GPS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: signalColor),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: signalColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${_gpsSignalLabel()} · ${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m',
                      style: TextStyle(fontSize: 10, color: signalColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(5, (i) {
                  final active = i < barCount;
                  final h = 6.0 + i * 4.0;
                  return Container(
                    width: 6,
                    height: h,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: active ? signalColor : const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
              const SizedBox(width: 12),
              Text(
                _gpsSignalLabel(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: signalColor,
                ),
              ),
              const Spacer(),
              if (!rideIsStarted)
                Text(
                  gpsIsReady ? 'Prêt à démarrer' : 'Acquisition…',
                  style: TextStyle(
                    fontSize: 11,
                    color: gpsIsReady ? signalColor : Colors.white38,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _gpsStatMini(
                'Précision',
                '${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m',
                signalColor,
              ),
              const SizedBox(width: 8),
              _gpsStatMini('Altitude', '$altitude m', Colors.white70),
              const SizedBox(width: 8),
              _gpsStatMini(
                'Lat / Long',
                '${double.tryParse(latitude)?.toStringAsFixed(4) ?? '--'} / ${double.tryParse(longitude)?.toStringAsFixed(4) ?? '--'}',
                Colors.white38,
                small: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBlockById(String id, {int? index}) {
    switch (id) {
      case 'duree':
        return _buildBlock(
          id: 'duree',
          icon: Icons.timer_outlined,
          iconColor: const Color(0xFF4ade80),
          title: 'Durée',
          summary: formattedDuration(),
          draggableIndex: index,
          body: Text(
            formattedDuration(),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF4ade80),
            ),
          ),
        );
      case 'dist':
        return _buildBlock(
          id: 'dist',
          icon: Icons.route_outlined,
          iconColor: const Color(0xFFfb923c),
          title: 'Distance',
          summary: formattedDistance(),
          draggableIndex: index,
          body: Text(
            formattedDistance(),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFFfb923c),
            ),
          ),
        );
      case 'speed':
        return _buildBlock(
          id: 'speed',
          icon: Icons.show_chart,
          iconColor: const Color(0xFF4ade80),
          title: 'Vitesse & dénivelé',
          summary:
              '${_speedKmh.toStringAsFixed(1)} km/h · D+ ${_dPlus.toStringAsFixed(0)} m · D− ${_dMinus.toStringAsFixed(0)} m',
          body: _buildSpeedBody(),
          draggableIndex: index,
        );
      case 'weather':
        return _buildBlock(
          id: 'weather',
          icon: Icons.wb_sunny_outlined,
          iconColor: _isNight
              ? const Color(0xFF818cf8)
              : const Color(0xFFF9A825),
          title: 'Météo',
          summary: _weatherFetched
              ? '${_weatherTemp!.toStringAsFixed(0)}° · ${_weatherDesc ?? ''}'
              : 'Chargement…',
          body: _buildWeatherBody(),
          draggableIndex: index,
        );
      case 'sun':
        return _buildBlock(
          id: 'sun',
          icon: Icons.wb_twilight,
          iconColor: _sunColor,
          title: 'Soleil',
          summary: 'Lever ${_fmt(_sunriseTime)} · Coucher ${_fmt(_sunsetTime)}',
          body: _buildSunBody(),
          draggableIndex: index,
        );
      case 'gps':
        return _buildBlock(
          id: 'gps',
          icon: Icons.satellite_alt,
          iconColor: _gpsSignalColor(),
          title: 'Signal GPS',
          summary:
              '${_gpsSignalLabel()} · ${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m · $altitude m alt.',
          body: _buildGpsBody(),
          draggableIndex: index,
        );
      case 'sharing':
        return _buildBlock(
          id: 'sharing',
          icon: Icons.share_location,
          iconColor: Colors.blue,
          title: 'Partager le suivi',
          summary: 'Lien de suivi actif',
          draggableIndex: index,
          body: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: shareSafetyLink,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.send, color: Colors.blue, size: 13),
                        SizedBox(width: 5),
                        Text(
                          'Envoyer à mes proches',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () async {
                  if (safetyUrl != null) {
                    final uri = Uri.parse(safetyUrl!);
                    if (await canLaunchUrl(uri))
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                  }
                },
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF242424),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Icon(
                    Icons.remove_red_eye_outlined,
                    color: Colors.white38,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GPS INIT
  // ═══════════════════════════════════════════════════════════════
  Future<void> initializeGps() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
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
    gpsInitializationStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
          ),
        ).listen((Position position) async {
          if (rideIsStarted) return;
          currentPosition = position;
          if (!mounted) return;
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              latitude = position.latitude.toString();
              longitude = position.longitude.toString();
              altitude = position.altitude.toStringAsFixed(1);
              accuracy = position.accuracy.toStringAsFixed(1);
              gpsIsInitializing = false;
              gpsIsReady = position.accuracy <= 20;
            });
            if (!_sunFetched) {
              _fetchSunTimes(position.latitude, position.longitude);
              _fetchWeather(position.latitude, position.longitude);
              _startWeatherAndSunTimers();
            }
            if (mapReady && !rideIsStarted && _followPosition) {
              Future.microtask(() {
                if (mounted)
                  mapController.move(
                    LatLng(position.latitude, position.longitude),
                    mapController.camera.zoom,
                  );
              });
            }
          });
        });
  }

  // ═══════════════════════════════════════════════════════════════
  // RIDE
  // ═══════════════════════════════════════════════════════════════
  Future<void> startRide({bool shareLink = false}) async {
    setState(() { rideIsStarted = true; _mapFullscreen = true; });
    await gpsInitializationStream?.cancel();
    gpsInitializationStream = null;
    if (_weatherFetched) _weatherSnapshotStart = _currentWeatherSnapshot();
    await startForegroundService();
    await createSafetySession();
    if (shareLink) await shareSafetyLink();
    rideStartTime = DateTime.now().toLocal();
    rideTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      Future.microtask(() {
        if (mounted)
          setState(() {
            rideDuration = DateTime.now().difference(rideStartTime!);
          });
      });
    });
    await startTracking();
  }

  /// Une option de l'écran « Démarrer la sortie ».
  /// [primary] = true → style vert primaire (dernier choix mémorisé) ;
  /// false → style sombre secondaire.
  Widget _buildStartOption({
    required bool primary,
    required Color accent,
    required IconData icon,
    required double iconSize,
    required String title,
    required String subtitle,
    required bool loading,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: loading ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: loading ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: primary
                ? const LinearGradient(
                    colors: [Color(0xFF00C853), Color(0xFF00897B)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            color: primary ? null : const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: primary
                      ? Colors.white.withValues(alpha: 0.2)
                      : accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon,
                    color: primary ? Colors.white : accent, size: iconSize),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12,
                            color: primary ? Colors.white70 : Colors.white54)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: primary ? Colors.white54 : Colors.white24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _practiceChip({
    required String label,
    required IconData icon,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.18)
                : const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: selected ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: selected ? color : Colors.white54),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? Colors.white : Colors.white54,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _saveLastPractice(String? key, SharedPreferences prefs) async {
    if (key == null) {
      await prefs.remove(_prefKeyLastPractice);
    } else {
      await prefs.setString(_prefKeyLastPractice, key);
    }
  }

  // Métadonnées d'affichage de la pratique courante (null = détection auto).
  (String, IconData, Color) _practiceMeta() {
    final key = _selectedPractice;
    final t = key != null ? kPracticeTypes[key] : null;
    if (t == null) return ('Auto', Icons.auto_awesome, Colors.white70);
    return (t['label'] as String, t['icon'] as IconData, t['color'] as Color);
  }

  // Sélecteur de pratique modifiable en cours de sortie (chip du bandeau).
  Future<void> _showPracticePicker() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 20, 24, 24 + MediaQuery.of(ctx).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pratique',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 4),
            const Text('Auto = détection automatique à la fin de la sortie.',
              style: TextStyle(fontSize: 13, color: Colors.white54)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _practiceChip(
                  label: 'Auto',
                  icon: Icons.auto_awesome,
                  color: Colors.white70,
                  selected: _selectedPractice == null,
                  onTap: () async {
                    setState(() => _selectedPractice = null);
                    await _saveLastPractice(null, prefs);
                    if (mounted) Navigator.pop(ctx);
                  },
                ),
                ...kPracticeTypes.entries.map(
                  (e) => _practiceChip(
                    label: e.value['label'] as String,
                    icon: e.value['icon'] as IconData,
                    color: e.value['color'] as Color,
                    selected: _selectedPractice == e.key,
                    onTap: () async {
                      setState(() => _selectedPractice = e.key);
                      await _saveLastPractice(e.key, prefs);
                      if (mounted) Navigator.pop(ctx);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStartRideSheet() async {
    bool loading = false;
    final prefs = await SharedPreferences.getInstance();
    // Dernière pratique choisie (mémorisée entre sessions ; null = Auto).
    String? selectedPractice =
        _selectedPractice ?? prefs.getString(_prefKeyLastPractice);
    // Dernier choix mémorisé : true = « Partager et démarrer » (défaut).
    final bool sharePrimary = prefs.getBool(_prefKeyLastShare) ?? true;
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, 32 + MediaQuery.of(ctx).padding.bottom),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Démarrer la sortie',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 6),
              const Text(
                'Veux-tu partager ton lien de suivi ?',
                style: TextStyle(fontSize: 14, color: Colors.white54),
              ),
              const SizedBox(height: 20),
              const Text(
                'Pratique',
                style: TextStyle(fontSize: 14, color: Colors.white54),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _practiceChip(
                    label: 'Auto',
                    icon: Icons.auto_awesome,
                    color: Colors.white70,
                    selected: selectedPractice == null,
                    onTap: () => setSheetState(() => selectedPractice = null),
                  ),
                  ...kPracticeTypes.entries.map(
                    (e) => _practiceChip(
                      label: e.value['label'] as String,
                      icon: e.value['icon'] as IconData,
                      color: e.value['color'] as Color,
                      selected: selectedPractice == e.key,
                      onTap: () =>
                          setSheetState(() => selectedPractice = e.key),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildStartOption(
                primary: sharePrimary,
                accent: const Color(0xFF00C853),
                icon: Icons.share_location,
                iconSize: 18,
                title: 'Partager et démarrer',
                subtitle: 'Envoie le lien de suivi à tes proches',
                loading: loading,
                onTap: () async {
                  setSheetState(() => loading = true);
                  _selectedPractice = selectedPractice;
                  await _saveLastPractice(selectedPractice, prefs);
                  Navigator.pop(ctx);
                  await prefs.setBool(_prefKeyLastShare, true);
                  await startRide(shareLink: true);
                },
              ),
              const SizedBox(height: 10),
              _buildStartOption(
                primary: !sharePrimary,
                accent: Colors.blue,
                icon: Icons.play_arrow_rounded,
                iconSize: 20,
                title: 'Démarrer sans partager',
                subtitle: "Le lien reste dispo dans l'écran ride",
                loading: loading,
                onTap: () async {
                  setSheetState(() => loading = true);
                  _selectedPractice = selectedPractice;
                  await _saveLastPractice(selectedPractice, prefs);
                  Navigator.pop(ctx);
                  await prefs.setBool(_prefKeyLastShare, false);
                  await startRide(shareLink: false);
                },
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Future<void> stopTrackingImmediately() async {
    rideTimer?.cancel();
    await positionStream?.cancel();
    positionStream = null;
    safetyUploadTimer?.cancel();
    safetyUploadTimer = null;
    FlutterBackgroundService().invoke('stopService');
    WakelockPlus.disable();
    setState(() {
      rideIsPaused = true;
    });
  }

  Future<void> discardRide() async {
    try {
      safetyUploadTimer?.cancel();
      await positionStream?.cancel();
      rideTimer?.cancel();
      _pointsWithAlt.clear();
      _uploadQueue.clear();
      await _currentRideBox?.clear();
      _currentRideBox = null;
      final sessionId = safetySessionId;
      safetySessionId = null;
      if (sessionId != null) {
        final s = Supabase.instance.client;
        await s.from('safety_positions').delete().eq('session_id', sessionId);
        await s.from('safety_sessions').delete().eq('id', sessionId);
      }
    } catch (e) {
      debugPrint('Erreur abandon ride : $e');
    }
  }

  Future<void> startForegroundService() async {
    final ok = await FlutterBackgroundService().startService();
    debugPrint('FOREGROUND SERVICE STARTED: $ok');
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _loadMapStyle();
    _loadBlockPrefs();
    _loadBannerPosition();
    initializeGps();
  }

  @override
  void dispose() {
    positionStream?.cancel();
    gpsInitializationStream?.cancel();
    rideTimer?.cancel();
    _sunTimer?.cancel();
    _weatherTimer?.cancel();
    safetyUploadTimer?.cancel();
    WakelockPlus.disable();
    FlutterBackgroundService().invoke('stopService');
    super.dispose();
  }

  Future<String> _copyPhotoToPermanentDir(String sourcePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${appDir.path}/waypoint_photos');
    if (!await photosDir.exists()) await photosDir.create(recursive: true);
    final destPath =
        '${photosDir.path}/wp_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  // Ouvre une photo en plein écran avec zoom + bouton de suppression.
  Future<void> _openPhotoViewer({
    required String path,
    required VoidCallback onDelete,
  }) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dctx) => Material(
        type: MaterialType.transparency,
        child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: Image.file(File(path))),
            ),
          ),
          Positioned(
            top: MediaQuery.of(dctx).padding.top + 12,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.of(dctx).pop(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 22),
              ),
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(dctx).padding.bottom + 28,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  Navigator.of(dctx).pop();
                  onDelete();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Supprimer la photo',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      )),
    );
  }

  String _formatWaypointTime(dynamic isoString) {
    if (isoString == null) return '--';
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // Retire une photo d'un point déjà mémorisé (pendant la sortie).
  Future<void> _deletePhotoFromLiveWaypoint(
      Map<String, dynamic> wp, dynamic entry) async {
    final local = photoLocalPath(entry);
    final url = photoUrl(entry);
    final current = (wp['photos'] as List?) ?? const [];
    wp['photos'] = current.where((e) => !identical(e, entry)).toList();
    if (mounted) setState(() {});
    // Nettoyage disque + Storage en arrière-plan (non bloquant).
    () async {
      if (local != null) { try { await File(local).delete(); } catch (_) {} }
      if (url != null) { try { await deletePhotoRemote(url); } catch (_) {} }
    }();
  }

  // Édite la note d'un point déjà mémorisé (tap sur la note dans le popup).
  Future<void> _editWaypointNote(
      Map<String, dynamic> wp, VoidCallback refresh) async {
    final controller = TextEditingController(text: (wp['note'] ?? '').toString());
    final focus = FocusNode();
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
        return Padding(
          padding: EdgeInsets.only(
            left: 24, right: 24, top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom +
                24 + MediaQuery.of(ctx).padding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Note',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                focusNode: focus,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
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
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                  ),
                  onPressed: () {
                    wp['note'] = controller.text.trim();
                    if (mounted) setState(() {});
                    Navigator.of(ctx).pop();
                    refresh();
                  },
                  child: const Text('Enregistrer',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Ajoute une photo (max 3) à un point déjà mémorisé.
  Future<void> _addPhotoToLiveWaypoint(
      Map<String, dynamic> wp, VoidCallback refresh) async {
    final photos = (wp['photos'] as List?) ?? const [];
    if (photos.length >= 3) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF2A2A2A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(c).padding.bottom),
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
      source: source, imageQuality: 80, maxWidth: 1200);
    if (picked == null) return;
    final local = await _copyPhotoToPermanentDir(picked.path);
    final current = (wp['photos'] as List?)?.toList() ?? [];
    current.add({'local': local, 'url': null});
    wp['photos'] = current;
    if (mounted) setState(() {});
    refresh();
  }

  // Visualiseur plein écran (entry = {local, url}) avec bouton Supprimer.
  Future<void> _openWaypointPhotoViewer({
    required dynamic entry,
    required VoidCallback onDelete,
  }) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dctx) => Material(
        type: MaterialType.transparency,
        child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: photoWidget(entry, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(dctx).padding.top + 12,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.of(dctx).pop(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close, color: Colors.white, size: 22),
              ),
            ),
          ),
          Positioned(
            bottom: MediaQuery.of(dctx).padding.bottom + 28,
            left: 0, right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  Navigator.of(dctx).pop();
                  onDelete();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, color: Colors.white, size: 20),
                      SizedBox(width: 8),
                      Text('Supprimer la photo',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, decoration: TextDecoration.none)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      )),
    );
  }

  // Popup d'infos d'un point mémorisé (tap sur la pastille) — même contenu que
  // l'écran de détail : numéro, heure, note, photos, coordonnées.
  void _showWaypointPopup(Map<String, dynamic> wp, int number) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final photos = (wp['photos'] as List?)?.toList() ?? [];
          return Padding(
            padding: EdgeInsets.fromLTRB(
                24, 24, 24, 24 + MediaQuery.of(ctx).padding.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 24, height: 24,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFF2563EB), shape: BoxShape.circle),
                    child: Text('$number',
                      style: const TextStyle(
                        color: Colors.white, fontSize: 13,
                        fontWeight: FontWeight.w800, height: 1)),
                  ),
                  const SizedBox(width: 10),
                  Text('Point mémorisé — ${_formatWaypointTime(wp['timestamp'])}',
                    style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ]),
                const SizedBox(height: 12),
                // Note — modifiable au clic (placeholder si vide, pas de stylo).
                GestureDetector(
                  onTap: () => _editWaypointNote(wp, () => setSheetState(() {})),
                  behavior: HitTestBehavior.opaque,
                  child: (wp['note'] ?? '').toString().isNotEmpty
                      ? Text(wp['note'],
                          style: const TextStyle(fontSize: 15, color: Colors.white70))
                      : const Text('Aucune note',
                          style: TextStyle(fontSize: 15, color: Colors.white38, fontStyle: FontStyle.italic)),
                ),
                const SizedBox(height: 16),
                // Photos (max 3) — tap pour agrandir/supprimer, tuile « + » pour ajouter.
                Row(
                  children: [
                    Text('Photos  ${photos.length}/3',
                      style: const TextStyle(fontSize: 12, color: Colors.white38)),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 120,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final entry in photos)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Stack(
                            children: [
                              GestureDetector(
                                onTap: () => _openWaypointPhotoViewer(
                                  entry: entry,
                                  onDelete: () async {
                                    await _deletePhotoFromLiveWaypoint(wp, entry);
                                    setSheetState(() {});
                                  },
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: photoWidget(entry, width: 120, height: 120),
                                ),
                              ),
                              // Croix de suppression — assez grande pour être visée.
                              Positioned(
                                top: 6, right: 6,
                                child: GestureDetector(
                                  onTap: () async {
                                    await _deletePhotoFromLiveWaypoint(wp, entry);
                                    setSheetState(() {});
                                  },
                                  child: Container(
                                    width: 30, height: 30,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.6),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: const Icon(Icons.close, size: 20, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (photos.length < 3)
                        GestureDetector(
                          onTap: () => _addPhotoToLiveWaypoint(wp, () => setSheetState(() {})),
                          child: Container(
                            width: 120, height: 120,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_a_photo, color: Colors.white38, size: 26),
                                SizedBox(height: 6),
                                Text('Ajouter', style: TextStyle(fontSize: 11, color: Colors.white38)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text('Lat: ${(wp['lat'] as num).toStringAsFixed(6)}  Long: ${(wp['lng'] as num).toStringAsFixed(6)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38)),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showAddWaypointModal() async {
    final noteController = TextEditingController();
    final List<String> selectedPhotoPaths = [];
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(modalContext).viewInsets.bottom +
                24 +
                MediaQuery.of(modalContext).padding.bottom,
          ),
          child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Mémoriser un point',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Lat: $latitude  Long: $longitude',
                style: const TextStyle(fontSize: 12, color: Colors.white38),
              ),
              const SizedBox(height: 20),
              const Text(
                'Note',
                style: TextStyle(fontSize: 14, color: Colors.white54),
              ),
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
              Row(
                children: [
                  const Text(
                    'Photos',
                    style: TextStyle(fontSize: 14, color: Colors.white54),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${selectedPhotoPaths.length}/3',
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  ...selectedPhotoPaths.map(
                    (path) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      // Tap → visualiseur plein écran (avec bouton Supprimer).
                      // Plus de croix sur la vignette : trop petite à viser.
                      child: GestureDetector(
                        onTap: () => _openPhotoViewer(
                          path: path,
                          onDelete: () => setModalState(
                            () => selectedPhotoPaths.remove(path),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(path),
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (selectedPhotoPaths.length < 3)
                    GestureDetector(
                      onTap: () async {
                        final source = await showModalBottomSheet<ImageSource>(
                          context: ctx,
                          backgroundColor: const Color(0xFF2A2A2A),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          builder: (c) => Padding(
                            padding: EdgeInsets.fromLTRB(
                                20, 20, 20, 20 + MediaQuery.of(c).padding.bottom),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(
                                    Icons.camera_alt,
                                    color: Colors.white,
                                  ),
                                  title: const Text(
                                    'Appareil photo',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  onTap: () =>
                                      Navigator.pop(c, ImageSource.camera),
                                ),
                                ListTile(
                                  leading: const Icon(
                                    Icons.photo_library,
                                    color: Colors.white,
                                  ),
                                  title: const Text(
                                    'Galerie',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  onTap: () =>
                                      Navigator.pop(c, ImageSource.gallery),
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
                        if (picked != null)
                          setModalState(
                            () => selectedPhotoPaths.add(picked.path),
                          );
                      },
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Icon(
                          Icons.add_a_photo,
                          color: Colors.white38,
                          size: 28,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(32),
                    ),
                  ),
                  onPressed: () async {
                    final lat = double.tryParse(latitude);
                    final lng = double.tryParse(longitude);
                    if (lat == null || lng == null) return;
                    final List<Map<String, dynamic>> photoEntries = [];
                    for (final path in selectedPhotoPaths) {
                      photoEntries.add({
                        'local': await _copyPhotoToPermanentDir(path),
                        'url': null,
                      });
                    }
                    setState(() {
                      rideWaypoints.add({
                        'lat': lat,
                        'lng': lng,
                        'note': noteController.text.trim(),
                        'timestamp': DateTime.now().toIso8601String(),
                        'photos': photoEntries,
                      });
                    });
                    Navigator.of(modalContext).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Point mémorisé !')),
                    );
                  },
                  icon: const Icon(Icons.place),
                  label: const Text(
                    'Mémoriser',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  String generateShareCode() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(
        8,
        (_) => chars.codeUnitAt(random.nextInt(chars.length)),
      ),
    );
  }

  Future<void> _flushUploadQueue() async {
    if (safetySessionId == null || _uploadQueue.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_uploadQueue);
    _uploadQueue.clear();
    try {
      await Supabase.instance.client.from('safety_positions').insert(
        batch.map((p) => {
          'session_id': safetySessionId,
          'latitude': p['lat'],
          'longitude': p['lng'],
          'altitude': p['alt'],
          if (p['ts'] != null) 'created_at': p['ts'],
        }).toList(),
      );
    } catch (e) {
      _uploadQueue.insertAll(0, batch); // requeue si pas de réseau
      debugPrint('[SAFETY] flush failed, requeued ${batch.length} pts: $e');
    }
  }

  void startSafetyUploadTimer() {
    safetyUploadTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      await _flushUploadQueue();
    });
  }

  Future<void> createSafetySession() async {
    final shareCode = generateShareCode();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final response = await Supabase.instance.client
        .from('safety_sessions')
        .insert({
          'share_code': shareCode,
          'status': 'in_progress',
          'user_id': userId,
        })
        .select()
        .single();
    safetySessionId = response['id'];
    safetyShareCode = shareCode;
    safetyUrl = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    _currentRideBox = await Hive.openBox('current_ride');
    await _currentRideBox!.clear();
    startSafetyUploadTimer();
  }

  Future<void> shareSafetyLink() async {
    if (safetyShareCode == null) return;
    final url = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    final message =
        'Je démarre une sortie avec Sunday Tracker.\n\n'
        'Tu peux suivre ma position en direct ici :\n'
        '$url';
    await Share.share(message, subject: 'Sunday Tracker Live');
  }

  Future<void> _showExitRideModal() async {
    final nav = Navigator.of(context);
    final prefs = await SharedPreferences.getInstance();
    // Dernier état mémorisé (défaut : coché si un lien de suivi est actif).
    bool notifyProches =
        prefs.getBool(_prefKeyNotifyProches) ?? (safetyShareCode != null);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) => StatefulBuilder(
        builder: (modalContext, setSheetState) => SafeArea(
          top: false,
          child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Quitter la sortie ?',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Que souhaitez-vous faire ?',
                style: TextStyle(fontSize: 16, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () {
                  setSheetState(() => notifyProches = !notifyProches);
                  prefs.setBool(_prefKeyNotifyProches, notifyProches);
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: notifyProches ? const Color(0xFF4CAF50) : const Color(0xFF3A3A3A),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: notifyProches
                            ? const Icon(Icons.check, color: Colors.white, size: 22)
                            : null,
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Prévenir mes proches',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Envoie un message indiquant que la sortie est terminée et que tout va bien',
                              style: TextStyle(fontSize: 13, color: Colors.white54),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    await prefs.setBool(_prefKeyNotifyProches, notifyProches);
                    if (notifyProches) await _shareRideEnd();
                    await saveRide();
                    if (!mounted) return;
                    nav.popUntil((route) => route.isFirst);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5A4F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(32),
                    ),
                  ),
                  child: const Text(
                    'Sauvegarder et quitter',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () async {
                    await cancelRide();
                    if (!mounted) return;
                    nav.popUntil((route) => route.isFirst);
                  },
                  child: const Text(
                    'Terminer sans sauvegarder',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () async {
                    Navigator.of(modalContext).pop();
                    await startForegroundService();
                    WakelockPlus.enable();
                    await togglePauseRide();
                  },
                  child: const Text(
                    'Continuer',
                    style: TextStyle(color: Color(0xFFD0BCFF), fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Future<void> _shareRideEnd() async {
    final url = safetyUrl ?? 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    final message =
        'Tout va bien, je suis de retour ! 🙌\n\nLa sortie est terminée — tu peux retrouver la trace ici :\n\n$url';

    final rideSnap = _buildShareRideSnapshot();
    final imageFile = await ShareImageService.generateImage(
      context,
      rideSnap,
      rideSnap['name'] as String,
    );

    if (imageFile != null) {
      await Share.shareXFiles(
        [XFile(imageFile.path)],
        text: message,
        subject: 'Sunday Tracker',
      );
    } else {
      await Share.share(message, subject: 'Sunday Tracker');
    }
  }

  Map<String, dynamic> _buildShareRideSnapshot() {
    final start = (rideStartTime ?? DateTime.now()).toLocal();
    const months = ['jan','fév','mar','avr','mai','juin','juil','aoû','sep','oct','nov','déc'];
    final autoName = 'Sortie du ${kFrDaysShort[start.weekday - 1]} ${start.day} ${months[start.month - 1]}';
    return {
      'name':                    _customRideName ?? autoName,
      'startTime':               rideStartTime?.toUtc().toIso8601String(),
      // Fin = début + durée active (et non l'heure du bouton STOP) : si on met
      // en pause puis on arrête sans reprendre, DateTime.now() décalerait
      // l'« Arrivée » de toute la pause finale. Cf. bug Arrivée faussée.
      'endTime':                 (rideStartTime ?? DateTime.now()).add(rideDuration).toUtc().toIso8601String(),
      'durationSeconds':         rideDuration.inSeconds,
      'distanceMeters':          totalDistance,
      'totalElevationMeters':    _dPlus,
      'totalElevationDown':      _dMinus,
      'altitudeMax':             _altMax.isInfinite ? null : _altMax,
      'altitudeMin':             _altMin.isInfinite ? null : _altMin,
      'points':                  _pointsWithAlt,
      'city':                    null,
      'practice':                null,
    };
  }

  Future<void> cancelRide() async {
    safetyUploadTimer?.cancel();
    await positionStream?.cancel();
    rideTimer?.cancel();
    _pointsWithAlt.clear();
    _uploadQueue.clear();
    await _currentRideBox?.clear();
    _currentRideBox = null;
    final sessionId = safetySessionId;
    safetySessionId = null;
    if (sessionId != null) {
      final s = Supabase.instance.client;
      await s.from('safety_positions').delete().eq('session_id', sessionId);
      await s.from('safety_sessions').delete().eq('id', sessionId);
    }
  }

  Future<void> togglePauseRide() async {
    if (!rideIsPaused) {
      _pauseStartTime = DateTime.now();
      _gpsLabelBeforePause = _gpsSignalLabel();
      _gpsColorBeforePause = _gpsSignalColor();
      await positionStream?.cancel();
      positionStream = null;
      rideTimer?.cancel();
      safetyUploadTimer?.cancel();
      _weatherTimer?.cancel();
      _weatherTimer = null;
      _sunTimer?.cancel();
      _sunTimer = null;
      _lastMovingTick = null;
      setState(() {
        rideIsPaused = true;
      });
      if (safetySessionId != null) {
        await Supabase.instance.client
            .from('safety_sessions')
            .update({'status': 'paused'})
            .eq('id', safetySessionId!);
      }
      return;
    }
    rideStartTime = DateTime.now().subtract(rideDuration);
    rideTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      Future.microtask(() {
        if (mounted)
          setState(() {
            rideDuration = DateTime.now().difference(rideStartTime!);
          });
      });
    });
    await startTracking();
    startSafetyUploadTimer();
    _startWeatherAndSunTimers();
    setState(() {
      rideIsPaused = false;
    });
    if (safetySessionId != null) {
      await Supabase.instance.client
          .from('safety_sessions')
          .update({'status': 'in_progress'})
          .eq('id', safetySessionId!);
    }
  }

  void _syncRideToSupabase(Map<String, dynamic> ride) async {
    final startedAt = ride['startTime'] as String?;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (startedAt == null || userId == null) return;
    try {
      await Supabase.instance.client.from('rides').upsert(
        {'user_id': userId, 'started_at': startedAt, 'ride_json': ride},
        onConflict: 'user_id,started_at',
      );
    } catch (e) {
      debugPrint('[SUPABASE] sync ride: $e');
    }
  }

  // ── saveRide avec toutes les nouvelles clés ───────────────────
  Future<void> saveRide() async {
    safetyUploadTimer?.cancel();
    safetyUploadTimer = null;

    // Garantit que la dernière position connue termine le tracé, même si la
    // porte anti-gigue a filtré les derniers points (arrêt en fin de sortie).
    _appendFinalPosition();

    final progressNotifier = ValueNotifier<_SaveState>(
      const _SaveState('Synchronisation GPS…', 0.0),
    );
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SaveProgressDialog(notifier: progressNotifier),
      );
    }

    // Flush GPS queue vers Supabase
    if (safetySessionId != null && _uploadQueue.isNotEmpty) {
      final total = _uploadQueue.length;
      int sent = 0;
      const chunkSize = 100;
      while (_uploadQueue.isNotEmpty) {
        final chunk = _uploadQueue.take(chunkSize).toList();
        try {
          await Supabase.instance.client.from('safety_positions').insert(
            chunk.map((p) => {
              'session_id': safetySessionId,
              'latitude': p['lat'],
              'longitude': p['lng'],
              'altitude': p['alt'],
              if (p['ts'] != null) 'created_at': p['ts'],
            }).toList(),
          );
          _uploadQueue.removeRange(0, chunk.length);
          sent += chunk.length;
          progressNotifier.value = _SaveState(
            'GPS · $sent / $total points',
            sent / total * 0.5,
          );
        } catch (e) {
          debugPrint('[SAFETY] flush chunk failed: $e');
          break;
        }
      }
    }

    progressNotifier.value = const _SaveState('Sauvegarde locale…', 0.6);

    if (_weatherFetched) _weatherSnapshotEnd = _currentWeatherSnapshot();
    final box = await Hive.openBox('rides');
    final locationTags = await getRideLocationTags();
    final start = (rideStartTime ?? DateTime.now()).toLocal();
    final months = [
      'jan',
      'fév',
      'mar',
      'avr',
      'mai',
      'juin',
      'juil',
      'aoû',
      'sep',
      'oct',
      'nov',
      'déc',
    ];
    final day = kFrDaysShort[start.weekday - 1];
    final hour = start.hour;
    final moment = hour < 6
        ? 'nuit'
        : hour < 12
        ? 'matin'
        : hour < 14
        ? 'midi'
        : hour < 18
        ? 'après-midi'
        : hour < 21
        ? 'soir'
        : 'nuit';
    final autoName =
        'Sortie du $day ${start.day} ${months[start.month - 1]} ${start.year} · $moment';
    final rideData = <String, dynamic>{
      'name': _customRideName ?? autoName,
      'note': _rideNote,
      'startTime': rideStartTime?.toUtc().toIso8601String(),
      // Fin = début + durée active (pas l'heure du STOP) : exclut une pause
      // finale non reprise. Cf. bug Arrivée faussée.
      'endTime': (rideStartTime ?? DateTime.now()).add(rideDuration).toUtc().toIso8601String(),
      'durationSeconds': rideDuration.inSeconds,
      'distanceMeters': totalDistance,
      'totalElevationMeters': _dPlus,
      'totalElevationDown': _dMinus,
      'altitudeStart': _altStart,
      'altitudeEnd': _prevAltitude,
      'altitudeMax': _altMax.isInfinite ? null : _altMax,
      'altitudeMin': _altMin.isInfinite ? null : _altMin,
      'movingTimeSeconds': _movingTime.inSeconds,
      'maxSpeedKmh': _maxSpeedKmh,
      'avgSpeedKmh': _avgSpeedKmh,
      'maxSlopePercent': _maxSlopePercent,
      'weatherStart': _weatherSnapshotStart,
      'weatherEnd': _weatherSnapshotEnd,
      'sunriseTime': _sunriseTime?.toIso8601String(),
      'sunsetTime': _sunsetTime?.toIso8601String(),
      'city': locationTags['city'],
      'department': locationTags['department'],
      'region': locationTags['region'],
      'startCity': locationTags['startCity'],
      'endCity': locationTags['endCity'],
      'safetySessionId': safetySessionId,
      'safetyShareCode': safetyShareCode,
      'points': _pointsWithAlt,
      'waypoints': rideWaypoints,
    };
    // Pratique choisie manuellement au démarrage sinon détection auto.
    rideData['practice'] = _selectedPractice ?? detectPractice(rideData);
    try {
      await box.add(rideData);
    } catch (e) {
      debugPrint('[HIVE] saveRide error: $e');
    }
    await _currentRideBox?.clear();
    _currentRideBox = null;

    progressNotifier.value = const _SaveState('Sync cloud…', 0.8);
    _syncRideToSupabase(rideData);
    // Monte les photos du waypoint sur le Storage en arrière-plan (offline-safe).
    syncPendingPhotos();

    progressNotifier.value = const _SaveState('Finalisation…', 0.9);
    if (safetySessionId != null) {
      await Supabase.instance.client
          .from('safety_sessions')
          .update({
            'status': 'finished',
            'ended_at': DateTime.now().toUtc().toIso8601String(),
            'ride_json': liveSessionRideJson(rideData),
          })
          .eq('id', safetySessionId!);
    }

    progressNotifier.value = const _SaveState('Terminé !', 1.0);
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) Navigator.of(context).pop();
  }

  // ── startTracking avec collecte altitude ──────────────────────
  Future<void> startTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    positionStream =
        Geolocator.getPositionStream(
          locationSettings: LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: kDebugMode ? 0 : 5,
          ),
        ).listen((Position position) {
          if (rideIsPaused) return;
          currentPosition = position;
          final newPoint = LatLng(position.latitude, position.longitude);
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              gpsIsReady = position.accuracy <= 15;
              latitude = position.latitude.toString();
              longitude = position.longitude.toString();
              altitude = position.altitude.toStringAsFixed(1);
              accuracy = position.accuracy.toStringAsFixed(1);
              _updateSpeedAndElevation(position);
            });
          });
          if (mapReady && _followPosition)
            Future.microtask(() {
              if (mounted) mapController.move(newPoint, mapController.camera.zoom);
            });
          if (!kDebugMode && position.accuracy > 20) {
            _ignoredAccuracy++;
            return;
          }
          if (ridePoints.isNotEmpty) {
            final lastPoint = ridePoints.last;
            final distance = distanceCalculator.as(
              LengthUnit.Meter,
              lastPoint,
              newPoint,
            );
            final dt = _lastPointTimestamp != null
                ? position.timestamp
                      .difference(_lastPointTimestamp!)
                      .inSeconds
                      .abs()
                : 1;
            if (!kDebugMode &&
                distance > (50.0 * max(dt, 1)) + (position.accuracy * 5)) {
              _ignoredOutlier++;
              return;
            }
            // Porte anti-gigue : on ne grave pas le point tant qu'on n'a pas
            // bougé au-delà du bruit GPS. Évite le "plat de spaghetti" et la
            // distance gonflée quand on est arrêté / qu'on jardine sur place.
            // currentPosition est déjà à jour ci-dessus → dernière position
            // connue préservée pour l'UI, la notif et le save.
            // NB : active aussi en debug (contrairement aux autres filtres)
            // pour pouvoir valider l'anti-gigue en flutter run sur le terrain.
            if (distance < max(5.0, position.accuracy)) {
              _ignoredJitter++;
              return;
            }
            totalDistance += distance;
          }
          ridePoints.add(newPoint);
          final gpsPoint = {
            'lat': position.latitude,
            'lng': position.longitude,
            'alt': position.altitude,
            // Horodatage du fix GPS : sert de created_at à l'upload pour que
            // l'« Arrivée » du live reflète l'heure réelle du point, pas
            // l'heure d'envoi (cf. reliquat de file vidé au STOP après pause).
            'ts': position.timestamp.toUtc().toIso8601String(),
          };
          _pointsWithAlt.add(gpsPoint);
          _uploadQueue.add(gpsPoint);
          _currentRideBox?.add(gpsPoint);
          _lastPointTimestamp = position.timestamp;
        });
  }

  // ── Cheat code : 5 taps rapides dans le coin haut-gauche ──────
  void _onDebugTap() {
    final now = DateTime.now();
    if (_lastDebugTap == null ||
        now.difference(_lastDebugTap!) > const Duration(seconds: 1)) {
      _debugTapCount = 0;
    }
    _lastDebugTap = now;
    _debugTapCount++;
    if (_debugTapCount >= 5) {
      _debugTapCount = 0;
      setState(() => _showDebugPanel = !_showDebugPanel);
      if (_showDebugPanel) _refreshStorageDebug();
    }
  }

  // Mesure l'espace Storage utilisé (RPC serveur) + compte les photos locales
  // pas encore uploadées. Appelé à l'ouverture du panneau debug.
  Future<void> _refreshStorageDebug() async {
    var pending = 0;
    var orphan = 0;
    try {
      if (Hive.isBoxOpen('rides')) {
        for (final r in Hive.box('rides').values) {
          if (r is! Map) continue;
          for (final wp in (r['waypoints'] as List? ?? const [])) {
            if (wp is! Map) continue;
            for (final p in (wp['photos'] as List? ?? const [])) {
              if (photoUrl(p) != null) continue; // déjà uploadée
              final local = photoLocalPath(p);
              if (local != null && File(local).existsSync()) {
                pending++; // uploadable par le balayeur
              } else {
                orphan++; // fichier local perdu → jamais uploadable
              }
            }
          }
        }
      }
    } catch (_) {}
    int? bytes;
    try {
      final res = await Supabase.instance.client.rpc('waypoint_storage_usage');
      if (res is num) bytes = res.toInt();
      else if (res is String) bytes = int.tryParse(res);
    } catch (e) {
      debugPrint('[DEBUG] storage usage: $e');
    }
    if (mounted) {
      setState(() {
        _debugPendingPhotos = pending;
        _debugOrphanPhotos = orphan;
        _debugStorageBytes = bytes;
      });
    }
  }

  String _fmtMo(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} Mo';

  // Overlay debug : compteurs GPS live. Déclenché par 5 taps rapides sur le
  // bandeau cockpit. Ancré sous les boutons Repère/Danger (zone libre) et en
  // IgnorePointer pour ne bloquer aucun tap de la carte ou des boutons.
  Widget _buildDebugOverlay() {
    if (!_showDebugPanel) return const SizedBox.shrink();
    final safeTop = MediaQuery.of(context).padding.top;
    return Positioned(
      top: safeTop + 96,
      left: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.85),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 15,
              height: 1.5,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('── DEBUG GPS ──'),
                Text('tracé    : ${ridePoints.length}'),
                Text('points   : ${_pointsWithAlt.length}'),
                Text('queue up : ${_uploadQueue.length}'),
                Text('précision: $accuracy m'),
                Text('distance : ${totalDistance.toStringAsFixed(1)} m'),
                Text('pause    : $rideIsPaused'),
                const SizedBox(height: 6),
                const Text('── STOCKAGE ──'),
                Text(_debugStorageBytes == null
                    ? 'utilisé  : … / 1 Go'
                    : 'utilisé  : ${_fmtMo(_debugStorageBytes!)} / 1 Go'),
                if (_debugStorageBytes != null)
                  Text(
                    'libre    : ${_fmtMo(1073741824 - _debugStorageBytes!)} '
                    '(${(_debugStorageBytes! / 1073741824 * 100).toStringAsFixed(1)} % util.)',
                  ),
                Text('à uploader: $_debugPendingPhotos photo(s)'),
                if (_debugOrphanPhotos > 0)
                  Text(
                    'perdues  : $_debugOrphanPhotos (fichier local absent)',
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
                  ),
                const SizedBox(height: 6),
                Text(
                  'ignorés  : '
                  '${_ignoredAccuracy + _ignoredOutlier + _ignoredJitter}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(' · gigue     : $_ignoredJitter'),
                Text(' · précision : $_ignoredAccuracy'),
                Text(' · saut GPS  : $_ignoredOutlier'),
                const SizedBox(height: 6),
                const Text(
                  'Un point est ignoré si :',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const Text(
                  '· gigue : bougé < max(5 m, précision)\n'
                  '· précision : > 20 m (signal flou)\n'
                  '· saut GPS : distance/temps impossible',
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Grave la dernière position connue en fin de sortie ────────
  // La porte anti-gigue a pu filtrer les derniers points (arrêt sur place).
  // On garantit que le tracé se termine sur la position réelle du rider.
  void _appendFinalPosition() {
    final pos = currentPosition;
    if (pos == null) return;
    final newPoint = LatLng(pos.latitude, pos.longitude);
    if (ridePoints.isNotEmpty) {
      final d = distanceCalculator.as(
        LengthUnit.Meter,
        ridePoints.last,
        newPoint,
      );
      if (d < 1.0) return; // déjà gravée
      totalDistance += d;
    }
    ridePoints.add(newPoint);
    final gpsPoint = {
      'lat': pos.latitude,
      'lng': pos.longitude,
      'alt': pos.altitude,
      'ts': pos.timestamp.toUtc().toIso8601String(),
    };
    _pointsWithAlt.add(gpsPoint);
    _uploadQueue.add(gpsPoint);
    _currentRideBox?.add(gpsPoint);
  }

  Future<Map<String, String>> getRideLocationTags() async {
    if (ridePoints.isEmpty) {
      return {'city': '', 'department': '', 'region': '', 'startCity': '', 'endCity': ''};
    }
    try {
      final placemarks = await placemarkFromCoordinates(
        ridePoints.first.latitude,
        ridePoints.first.longitude,
      );
      if (placemarks.isEmpty) {
        return {'city': '', 'department': '', 'region': '', 'startCity': '', 'endCity': ''};
      }
      final place = placemarks.first;
      final startCity = cityFromPlacemark(place);
      // Ville d'arrivée : géocode le dernier point (peut être identique au départ
      // sur une boucle). En cas d'échec on retombe sur la ville de départ.
      String endCity = startCity;
      try {
        final endMarks = await placemarkFromCoordinates(
          ridePoints.last.latitude,
          ridePoints.last.longitude,
        );
        if (endMarks.isNotEmpty) endCity = cityFromPlacemark(endMarks.first);
      } catch (_) {}
      return {
        'city': startCity,
        'department': place.subAdministrativeArea ?? '',
        'region': place.administrativeArea ?? '',
        'startCity': startCity,
        'endCity': endCity,
      };
    } catch (_) {
      return {'city': '', 'department': '', 'region': '', 'startCity': '', 'endCity': ''};
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

  Future<void> _showEditModal({bool focusNote = false}) async {
    final nameController = TextEditingController(text: _customRideName ?? _rideName());
    final noteController = TextEditingController(text: _rideNote);
    final nameFocus = FocusNode();
    final noteFocus = FocusNode();
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (focusNote) noteFocus.requestFocus();
          else nameFocus.requestFocus();
        });
        return Padding(
        padding: EdgeInsets.only(
          left: 24, right: 24, top: 24,
          bottom: MediaQuery.of(modalContext).viewInsets.bottom +
              24 +
              MediaQuery.of(modalContext).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Modifier la sortie',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 24),
            const Text('Nom', style: TextStyle(fontSize: 14, color: Colors.white54)),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              focusNode: nameFocus,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                hintText: 'Nom de la sortie',
                hintStyle: const TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
            const SizedBox(height: 8),
            TextField(
              controller: noteController,
              focusNode: noteFocus,
              style: const TextStyle(color: Colors.white),
              maxLines: 4,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                hintText: 'Ajouter une note...',
                hintStyle: const TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                ),
                onPressed: () {
                  final name = nameController.text.trim();
                  final note = noteController.text.trim();
                  setState(() {
                    _customRideName = name.isEmpty ? null : name;
                    _rideNote = note;
                  });
                  Navigator.of(modalContext).pop();
                },
                child: const Text(
                  'Sauvegarder',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      );
      },
    );
  }

  Future<void> handleBackPressed() async {
    if (!rideIsStarted) {
      Navigator.of(context).pop();
      return;
    }
    await _showExitRideModal();
  }

  String _rideName() {
    final date = rideStartTime?.toLocal() ?? DateTime.now();
    const months = [
      'jan', 'fév', 'mar', 'avr', 'mai', 'juin',
      'juil', 'aoû', 'sep', 'oct', 'nov', 'déc',
    ];
    final day = kFrDaysShort[date.weekday - 1];
    final hour = date.hour;
    final moment = hour < 6
        ? 'nuit'
        : hour < 12
        ? 'matin'
        : hour < 14
        ? 'midi'
        : hour < 18
        ? 'après-midi'
        : hour < 21
        ? 'soir'
        : 'nuit';
    return 'Sortie du $day ${date.day} ${months[date.month - 1]} ${date.year} · $moment';
  }

  String _rideStatusTitle() => _customRideName ?? _rideName();

  String _rideStatusSubtitle() {
    if (!rideIsStarted) return 'Nouveau';
    if (rideIsPaused) return 'En pause';
    return 'En cours';
  }

  Color _rideStatusColor() {
    if (!rideIsStarted) return Colors.blue;
    if (rideIsPaused) return Colors.orange;
    return Colors.green;
  }

  Color _gpsBadgeColor() {
    if (rideIsPaused) return Colors.white38;
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 15) return Colors.green;
    if (v <= 30) return Colors.orange;
    return Colors.red;
  }

  String _gpsBadgeLabel() {
    if (rideIsPaused) return 'GPS off';
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 15) return 'GPS actif';
    if (v <= 30) return 'GPS moyen';
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
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _gpsBadgeColor().withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.satellite_alt,
                      color: _gpsBadgeColor(),
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Détails GPS',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        _gpsBadgeLabel(),
                        style: TextStyle(fontSize: 12, color: _gpsBadgeColor()),
                      ),
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
              _gpsRow(
                Icons.gps_fixed,
                'Précision',
                '$accuracy m',
                valueColor: _gpsBadgeColor(),
              ),
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
                  child: const Text(
                    'Fermer',
                    style: TextStyle(color: Color(0xFFD0BCFF)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
    ],
  );

  Widget _gpsRow(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) => Row(
    children: [
      Icon(icon, color: Colors.lightBlue, size: 14),
      const SizedBox(width: 6),
      Text(
        '$label : ',
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      ),
      Expanded(
        child: Text(
          value,
          style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white70),
        ),
      ),
    ],
  );

  Widget _buildFlutterMap() {
    return _IsolatedMap(
      key: _mapKey,
      mapController: mapController,
      mapStyleIndex: _mapStyleIndex,
      mapStyles: _mapStyles,
      rideIsStarted: rideIsStarted,
      ridePoints: ridePoints,
      rideWaypoints: rideWaypoints,
      latitude: latitude,
      longitude: longitude,
      onMapReady: () {
        if (mounted) setState(() { mapReady = true; });
      },
      onWaypointTap: _showWaypointPopup,
    );
  }

  Widget _buildMapOverlay() {
    // Hauteur approximative des boutons flottants en mode fullscreen
    final bottomOffset = _mapFullscreen
        ? (rideIsStarted ? 150.0 : 108.0) + MediaQuery.of(context).padding.bottom
        : 10.0;

    return Stack(
      children: [
        if (!_mapCollapsed) ...[
          Positioned(
            bottom: bottomOffset,
            left: 10,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(_mapStyles.length, (i) {
                  final style = _mapStyles[i];
                  final isActive = i == _mapStyleIndex;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _mapStyleIndex = i);
                      _saveMapStyle(i);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isActive ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            style['icon'] as IconData,
                            size: 13,
                            color: isActive ? Colors.black : Colors.white70,
                          ),
                          if (isActive) ...[
                            const SizedBox(width: 4),
                            Text(
                              style['label'] as String,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
            ),
          ),
          Positioned(
            bottom: bottomOffset,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    if (_followPosition) {
                      setState(() => _followPosition = false);
                    } else {
                      final lat = double.tryParse(latitude);
                      final lng = double.tryParse(longitude);
                      if (lat != null && lng != null) {
                        mapController.move(LatLng(lat, lng), mapController.camera.zoom);
                      }
                      setState(() => _followPosition = true);
                    }
                  },
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: _followPosition
                          ? const Color(0xFF29B6F6)
                          : Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.my_location,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => setState(() => _mapFullscreen = !_mapFullscreen),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      _mapFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // COCKPIT MODE
  // ═══════════════════════════════════════════════════════════════

  Widget _buildCockpitBanner({double topInset = 0}) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final durationStr = rideDuration.inHours > 0
        ? formattedDuration()
        : '${(rideDuration.inMinutes % 60).toString().padLeft(2, '0')}:'
            '${(rideDuration.inSeconds % 60).toString().padLeft(2, '0')}';

    // DefaultTextStyle peut hériter un soulignement jaune du parent — on coupe ça ici.
    const noUnderline = TextDecoration.none;
    const labelStyle = TextStyle(
      fontSize: 11,
      color: Color(0xFF7A7A7A),
      decoration: noUnderline,
      fontWeight: FontWeight.w400,
    );

    final isEdgeToEdge = topInset > 0;
    return Container(
      padding: EdgeInsets.fromLTRB(16, topInset + 6, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xF2101010),
        borderRadius: isEdgeToEdge
            ? const BorderRadius.vertical(bottom: Radius.circular(20))
            : BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Poignée de déplacement (pill)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white54,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          DefaultTextStyle(
            style: const TextStyle(decoration: noUnderline),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
            // Heure
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeStr,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.0,
                      letterSpacing: -1.0,
                      decoration: noUnderline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('heure', style: labelStyle),
                ],
              ),
            ),

            Container(
              width: 1,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: Colors.white.withValues(alpha: 0.08),
            ),

            // Distance
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formattedDistance(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.0,
                      letterSpacing: -0.5,
                      decoration: noUnderline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('Distance', style: labelStyle, textAlign: TextAlign.center),
                ],
              ),
            ),

            Container(
              width: 1,
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: Colors.white.withValues(alpha: 0.08),
            ),

            // Durée
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    durationStr,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.0,
                      letterSpacing: -0.5,
                      decoration: noUnderline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text('Durée', style: labelStyle),
                ],
              ),
            ),
          ],
        ),
          ),
        ],
      ),
    );
  }

  Widget _buildCockpitBannerVertical() {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final durationStr = rideDuration.inHours > 0
        ? formattedDuration()
        : '${(rideDuration.inMinutes % 60).toString().padLeft(2, '0')}:'
            '${(rideDuration.inSeconds % 60).toString().padLeft(2, '0')}';

    const noUnderline = TextDecoration.none;
    const labelStyle = TextStyle(
      fontSize: 10,
      color: Color(0xFF7A7A7A),
      decoration: noUnderline,
      fontWeight: FontWeight.w400,
    );

    Widget statSection(String value, String label, {double fontSize = 22}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.0,
                letterSpacing: -0.5,
                decoration: noUnderline,
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: labelStyle),
          ],
        );

    return DefaultTextStyle(
      style: const TextStyle(decoration: noUnderline),
      child: Container(
        width: 108,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        decoration: BoxDecoration(
          color: const Color(0xF2101010),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Poignée
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                3,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2.5),
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: Colors.white24,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            statSection(timeStr, 'heure', fontSize: 26),
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.white.withValues(alpha: 0.08),
            ),
            statSection(formattedDistance(), 'Distance'),
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.white.withValues(alpha: 0.08),
            ),
            statSection(durationStr, 'Durée'),
          ],
        ),
      ),
    );
  }

  // Prédit la zone cible selon les deltas courants — logique partagée
  // entre _buildBannerDropZones et onLongPressEnd.
  String _predictBannerPos() {
    final absX = _bannerDragDeltaX.abs();
    final absY = _bannerDragDeltaY.abs();
    if (absX < 30 && absY < 30) return _bannerPosition;
    final isVertical =
        _bannerPosition == 'left' || _bannerPosition == 'right';
    if (isVertical) {
      return absX >= absY
          ? (_bannerDragDeltaY <= 0 ? 'top' : 'bottom')
          : _bannerPosition;
    } else {
      if (absX > absY) {
        return _bannerDragDeltaX < 0 ? 'left' : 'right';
      }
      return _bannerDragDeltaY < 0 ? 'top' : 'bottom';
    }
  }

  List<Widget> _buildBannerDropZones({
    required bool fullscreen,
    double topInset = 0,
  }) {
    if (!_isBannerDragging) return [];
    final controlsH = _cockpitControlsHeight;
    const vW = 110.0; // largeur zones latérales

    final predictedPos = _predictBannerPos();

    // ── Zone horizontale (Haut / Bas) ─────────────────────────────
    Widget hZone({
      required String posId,
      required double? top,
      required double? bottom,
      required String label,
      required IconData icon,
    }) {
      final isTarget = predictedPos == posId;
      const accent = Color(0xFF29B6F6);
      return Positioned(
        top: top,
        bottom: bottom,
        left: 8,
        right: 8,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _bannerPosition = posId;
              _isBannerDragging = false;
              _bannerDragDeltaY = 0;
              _bannerDragDeltaX = 0;
            });
            _saveBannerPosition(posId);
            HapticFeedback.lightImpact();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 72,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isTarget ? 0.40 : 0.22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accent.withValues(alpha: isTarget ? 1.0 : 0.75),
                width: isTarget ? 2.5 : 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    color:
                        accent.withValues(alpha: isTarget ? 1.0 : 0.85),
                    size: isTarget ? 24 : 20),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                      color: accent.withValues(
                          alpha: isTarget ? 1.0 : 0.85),
                      fontSize: isTarget ? 17 : 14,
                      fontWeight: isTarget
                          ? FontWeight.bold
                          : FontWeight.normal,
                      decoration: TextDecoration.none,
                    )),
              ],
            ),
          ),
        ),
      );
    }

    // ── Zone verticale (Gauche / Droite) ──────────────────────────
    Widget vZone({
      required String posId,
      required double? left,
      required double? right,
      required String label,
    }) {
      final isTarget = predictedPos == posId;
      const accent = Color(0xFF29B6F6);
      // Même hauteur à gauche et à droite (voir helpers géométrie)
      final topValue = _sideBannerTop(fullscreen, topInset);
      return Positioned(
        top: topValue,
        left: left,
        right: right,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _bannerPosition = posId;
              _isBannerDragging = false;
              _bannerDragDeltaY = 0;
              _bannerDragDeltaX = 0;
            });
            _saveBannerPosition(posId);
            HapticFeedback.lightImpact();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: vW,
            height: 160,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isTarget ? 0.40 : 0.22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accent.withValues(alpha: isTarget ? 1.0 : 0.75),
                width: isTarget ? 2.5 : 1.5,
              ),
            ),
            child: Center(
              child: Text(label,
                  style: TextStyle(
                    color: accent.withValues(alpha: isTarget ? 1.0 : 0.85),
                    fontSize: isTarget ? 15 : 13,
                    fontWeight:
                        isTarget ? FontWeight.bold : FontWeight.normal,
                    decoration: TextDecoration.none,
                  )),
            ),
          ),
        ),
      );
    }

    return [
      // Barrière transparente : tap hors zone = annuler la sélection
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            setState(() {
              _isBannerDragging = false;
              _bannerDragDeltaY = 0;
              _bannerDragDeltaX = 0;
            });
          },
        ),
      ),
      if (_bannerPosition != 'left')
        vZone(posId: 'left', left: 8, right: null, label: 'Gauche'),
      if (_bannerPosition != 'right')
        vZone(posId: 'right', left: null, right: 8, label: 'Droite'),
      if (_bannerPosition != 'top')
        hZone(
          posId: 'top',
          top: fullscreen ? topInset + 4 : 4,
          bottom: null,
          label: 'Haut',
          icon: Icons.keyboard_arrow_up_rounded,
        ),
      if (_bannerPosition != 'bottom')
        hZone(
          posId: 'bottom',
          top: null,
          bottom: controlsH + 8,
          label: 'Bas',
          icon: Icons.keyboard_arrow_down_rounded,
        ),
    ];
  }

  Widget _buildPositionedBanner({required bool fullscreen, double topInset = 0}) {
    final controlsH = _cockpitControlsHeight;

    final isTop = _bannerPosition == 'top';
    final isLeft = _bannerPosition == 'left';
    final isRight = _bannerPosition == 'right';
    final isVertical = isLeft || isRight;

    // En fullscreen + top non dragging : mode edge-to-edge
    final edgeToEdge = fullscreen && isTop && !_isBannerDragging;
    final effectiveTopInset = edgeToEdge ? topInset : 0.0;
    final side = edgeToEdge ? 0.0 : 12.0;

    // Widget affiché selon la position courante
    Widget bannerContent = isVertical
        ? _buildCockpitBannerVertical()
        : _buildCockpitBanner(topInset: effectiveTopInset);

    final banner = GestureDetector(
      onTap: _onDebugTap, // cheat code : 5 taps → panneau debug GPS
      onLongPressStart: (_) {
        HapticFeedback.mediumImpact();
        setState(() {
          _isBannerDragging = true;
          _bannerDragDeltaY = 0;
          _bannerDragDeltaX = 0;
        });
      },
      onLongPressEnd: (_) {
        // Zones restent visibles : l'utilisateur tape sur la zone cible
      },
      child: AnimatedOpacity(
        opacity: _isBannerDragging ? 0.75 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: bannerContent,
      ),
    );

    // ── Position snappée ─────────────────────────────────────────
    if (isLeft) {
      return Positioned(
        top: _sideBannerTop(fullscreen, topInset),
        left: 12,
        child: banner,
      );
    } else if (isRight) {
      return Positioned(
        top: _sideBannerTop(fullscreen, topInset),
        right: 12,
        child: banner,
      );
    } else if (isTop) {
      return Positioned(
        top: edgeToEdge ? 0 : 12.0,
        left: side,
        right: side,
        child: banner,
      );
    } else {
      return Positioned(
        bottom: controlsH + 4,
        left: 12,
        right: 12,
        child: banner,
      );
    }
  }

  Widget _buildCockpitMapButtons({double topOffset = 108}) {
    return Positioned(
      top: topOffset,
      right: 12,
      child: _dragFade(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              if (_followPosition) {
                setState(() => _followPosition = false);
              } else {
                final lat = double.tryParse(latitude);
                final lng = double.tryParse(longitude);
                if (lat != null && lng != null) {
                  mapController.move(LatLng(lat, lng), mapController.camera.zoom);
                }
                setState(() => _followPosition = true);
              }
            },
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _followPosition
                    ? const Color(0xFF29B6F6)
                    : Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.my_location, color: Colors.white, size: 26),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () {
              final next = (_mapStyleIndex + 1) % _mapStyles.length;
              setState(() => _mapStyleIndex = next);
              _saveMapStyle(next);
            },
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _mapStyles[_mapStyleIndex]['icon'] as IconData,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _mapStyles[_mapStyleIndex]['label'] as String,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      )),
    );
  }

  Widget _buildCockpitControls() {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Bouton flottant « Afficher plus » au-dessus du bandeau (séparé).
        Center(
          child: GestureDetector(
            onTap: _showDetailSheet,
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.keyboard_arrow_up, color: Colors.white70, size: 23),
                  SizedBox(width: 8),
                  Text(
                    'Afficher plus',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Barre d'actions : Stop | Pause | SOS
        Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.9),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(12, 12, 12, 14 + bottomPad),
          child: SizedBox(
            height: 74,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Stop (gauche, compact)
                GestureDetector(
                  onTap: () async {
                    await stopTrackingImmediately();
                    await _showExitRideModal();
                  },
                  child: Container(
                    width: 82,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.stop, color: Colors.red, size: 27),
                        SizedBox(height: 3),
                        Text(
                          'Stop',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Pause (centre, dominant)
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: rideIsPaused ? Colors.green : Colors.blue,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: togglePauseRide,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            rideIsPaused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              rideIsPaused ? 'Reprise' : 'Pause',
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // SOS (droite, compact)
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    width: 82,
                    decoration: BoxDecoration(
                      color: const Color(0xFFB71C1C),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.emergency, color: Colors.white, size: 27),
                        SizedBox(height: 3),
                        Text(
                          'SOS',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // Groupe de boutons d'action ride flottants en haut à gauche de la carte
  Widget _buildWaypointFloatingBtn({double topOffset = 108}) {
    return Positioned(
      top: topOffset,
      left: 12,
      child: _dragFade(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Repère (actif) ──────────────────────────────────────
          GestureDetector(
            onTap: _showAddWaypointModal,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.blue.withValues(alpha: 0.45),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.place, color: Colors.blue, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Repère',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ── Danger (désactivé — fonctionnalité à venir) ─────────
          Opacity(
            opacity: 0.55,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.45),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fmd_bad, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Danger',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      )),
    );
  }

  Map<String, dynamic> _getLivePanelData() {
    final altPoints = _pointsWithAlt
        .map((p) => (p['alt'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
    return {
      'rideIsPaused': rideIsPaused,
      'rideName': _rideStatusTitle(),
      'rideNote': _rideNote,
      'pauseStartTime': _pauseStartTime,
      'rideStartTime': rideStartTime,
      'rideDuration': rideDuration,
      'totalDistance': totalDistance,
      'currentSpeedKmh': _speedKmh,
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'safetyUrl': safetyUrl,
      'dPlus': _dPlus,
      'dMinus': _dMinus,
      'altStart': _altStart,
      'altMin': _altMin.isFinite ? _altMin : null,
      'altMax': _altMax.isFinite ? _altMax : null,
      'avgSpeedKmh': _avgSpeedKmh,
      'maxSpeedKmh': _maxSpeedKmh,
      'movingTime': _movingTime,
      'speedPoints': List<double>.from(_speedPoints),
      'altPoints': altPoints,
      'weatherTemp': _weatherTemp,
      'weatherDesc': _weatherDesc,
      'weatherWind': _weatherWind,
      'weatherWindDir': _weatherWindDir,
      'weatherHumidity': _weatherHumidity,
      'sunriseTime': _sunriseTime,
      'sunsetTime': _sunsetTime,
      'isNight': _isNight,
      'gpsLabel': rideIsPaused ? _gpsLabelBeforePause : _gpsSignalLabel(),
      'gpsColor': rideIsPaused ? _gpsColorBeforePause : _gpsSignalColor(),
      'lastGpsUpdateTime': _lastGpsUpdateTime,
      'notificationCount': _notificationCount,
      'practiceLabel': _practiceMeta().$1,
      'practiceIcon': _practiceMeta().$2,
      'practiceColor': _practiceMeta().$3,
    };
  }

  void _showRideCockpitSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PauseSheetWidget(
        liveGetter: _getLivePanelData,
        onEditTitle: () => _showEditModal(focusNote: false),
        onEditNote: () => _showEditModal(focusNote: true),
        onEditPractice: _showPracticePicker,
        onCopy: () {
          final lat = double.tryParse(latitude);
          final lng = double.tryParse(longitude);
          if (lat != null && lng != null) {
            Clipboard.setData(ClipboardData(
              text: '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
            ));
          }
        },
        onOpen: () async {
          if (safetyUrl != null) {
            final uri = Uri.parse(safetyUrl!);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          }
        },
      ),
    );
  }

  void _showDetailSheet() {
    _showRideCockpitSheet();
  }

  // ═══════════════════════════════════════════════════════════════
  // TOP BAR FLOTTANTE
  // ═══════════════════════════════════════════════════════════════
  String _rideStatusSubtitleFull() {
    if (!rideIsStarted) return 'Prêt à démarrer';
    final start = rideStartTime;
    final t = start != null
        ? '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}'
        : '--:--';
    if (rideIsPaused) return 'En pause · démarré à $t';
    return 'En cours · depuis $t';
  }

  Widget _floatingTopBtn({required VoidCallback onTap, required Widget child, double width = 44}) =>
    GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            width: width,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );

  Widget _buildFloatingTopBar() => SizedBox(
    height: 54,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _floatingTopBtn(
          onTap: handleBackPressed,
          child: const Icon(Icons.arrow_back, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () => _showEditModal(),
            behavior: HitTestBehavior.opaque,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.52),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        gpsIsInitializing ? 'Initialisation GPS…' : _rideStatusTitle(),
                        style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
                          letterSpacing: -0.4,
                          decoration: TextDecoration.none,
                        ),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      if (!gpsIsInitializing) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6, height: 6,
                              decoration: BoxDecoration(
                                color: _rideStatusColor(), shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                _rideStatusSubtitleFull(),
                                style: TextStyle(
                                  fontSize: 12, color: _rideStatusColor(),
                                  decoration: TextDecoration.none,
                                ),
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  // ═══════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    return WillPopScope(
      onWillPop: () async {
        await handleBackPressed();
        return false;
      },
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: Colors.black,

            body: gpsIsInitializing
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 24),
                        Text(
                          'Initialisation GPS...',
                          style: TextStyle(fontSize: 18, color: Colors.white),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      if (!rideIsStarted)
                        Expanded(
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              // ← En plein écran, la carte est rendue uniquement dans le
                              //   Positioned.fill ci-dessous. On ne la monte jamais ici en
                              //   parallèle, sinon deux FlutterMap partageraient le même
                              //   MapController en même temps.
                              if (!_mapFullscreen) _buildFlutterMap(),
                              if (!_mapFullscreen) _buildMapOverlay(),
                            ],
                          ),
                        )
                      else
                        Expanded(
                          child: Stack(
                            children: [
                              if (!_mapFullscreen) Positioned.fill(child: _buildFlutterMap()),
                              _buildCockpitMapButtons(),
                              ..._buildBannerDropZones(fullscreen: false),
                              _buildPositionedBanner(fullscreen: false),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: KeyedSubtree(
                                  key: _cockpitControlsKey,
                                  child: _buildCockpitControls(),
                                ),
                              ),
                              _buildWaypointFloatingBtn(),
                            ],
                          ),
                        ),

                      if (!rideIsStarted && !_mapFullscreen)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                              12, 10, 12, 16 + MediaQuery.of(context).padding.bottom),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildGpsBlock(),
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: gpsIsReady ? _showStartRideSheet : null,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: gpsIsReady
                                        ? null
                                        : const Color(0xFF1A1A1A),
                                    gradient: gpsIsReady
                                        ? const LinearGradient(
                                            colors: [
                                              Color(0xFF00C853),
                                              Color(0xFF00897B),
                                            ],
                                            begin: Alignment.centerLeft,
                                            end: Alignment.centerRight,
                                          )
                                        : null,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 36,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.2,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          gpsIsReady
                                              ? Icons.play_arrow_rounded
                                              : Icons.hourglass_empty,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        gpsIsReady
                                            ? 'Démarrer la sortie'
                                            : 'Attente du signal GPS…',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: gpsIsReady
                                              ? Colors.white
                                              : Colors.white38,
                                          letterSpacing: 0.3,
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

          if (_mapFullscreen)
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                children: [
                  // Seule instance de carte en plein écran.
                  _buildFlutterMap(),

                  if (!rideIsStarted) ...[
                    // Avant le ride : overlay standard + bouton démarrer
                    _buildMapOverlay(),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 16 + MediaQuery.of(context).padding.bottom,
                      child: Material(
                        color: Colors.transparent,
                        child: GestureDetector(
                          onTap: gpsIsReady ? _showStartRideSheet : null,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: gpsIsReady ? null : const Color(0xFF1A1A1A),
                              gradient: gpsIsReady
                                  ? const LinearGradient(
                                      colors: [Color(0xFF00C853), Color(0xFF00897B)],
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                    )
                                  : null,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    gpsIsReady ? Icons.play_arrow_rounded : Icons.hourglass_empty,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  gpsIsReady ? 'Démarrer la sortie' : 'Attente du signal GPS…',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: gpsIsReady ? Colors.white : Colors.white38,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    // Ride en cours : cockpit plein écran
                    _buildCockpitMapButtons(
                      topOffset: _cockpitButtonsTop(
                          true, MediaQuery.of(context).padding.top),
                    ),
                    ..._buildBannerDropZones(
                      fullscreen: true,
                      topInset: MediaQuery.of(context).padding.top,
                    ),
                    _buildPositionedBanner(
                      fullscreen: true,
                      topInset: MediaQuery.of(context).padding.top,
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _buildCockpitControls(),
                    ),
                    _buildWaypointFloatingBtn(
                      topOffset: _cockpitButtonsTop(
                          true, MediaQuery.of(context).padding.top),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Top bar flottante (masquée seulement pendant le ride en plein écran) ──
          if (!_mapFullscreen || !rideIsStarted) ...[
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                height: safeTop + 100,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.72),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: safeTop + 12,
              left: 16, right: 16,
              child: Material(
                type: MaterialType.transparency,
                child: _buildFloatingTopBar(),
              ),
            ),
          ],

          // Cheat code debug GPS : 5 taps dans le coin haut-gauche.
          _buildDebugOverlay(),
        ],
      ),
    );
  }
}

// ── Sauvegarde fin de ride ─────────────────────────────────────────────────

class _SaveState {
  final String label;
  final double value; // 0.0 → 1.0
  const _SaveState(this.label, this.value);
}

class _SaveProgressDialog extends StatelessWidget {
  final ValueNotifier<_SaveState> notifier;
  const _SaveProgressDialog({super.key, required this.notifier});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_SaveState>(
      valueListenable: notifier,
      builder: (_, state, _x) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sauvegarde en cours…',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: state.value,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFF8A00)),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.label,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// PAUSE COCKPIT SHEET
// ════════════════════════════════════════════════════════════════════════════

class _PauseSheetWidget extends StatefulWidget {
  final Map<String, dynamic> Function() liveGetter;
  final VoidCallback onCopy;
  final VoidCallback onOpen;
  final VoidCallback onEditTitle;
  final VoidCallback onEditNote;
  final VoidCallback onEditPractice;

  const _PauseSheetWidget({
    required this.liveGetter,
    required this.onCopy,
    required this.onOpen,
    required this.onEditTitle,
    required this.onEditNote,
    required this.onEditPractice,
  });

  @override
  State<_PauseSheetWidget> createState() => _PauseSheetWidgetState();
}

class _PauseSheetWidgetState extends State<_PauseSheetWidget> {
  Timer? _timer;
  Duration _pauseDuration = Duration.zero;
  late Map<String, dynamic> _live;

  static const double _minSize = 0.35;
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    _live = widget.liveGetter();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() {
      _live = widget.liveGetter();
      final pauseStart = _live['pauseStartTime'] as DateTime?;
      _pauseDuration = pauseStart != null
          ? DateTime.now().difference(pauseStart)
          : Duration.zero;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sheetController.dispose();
    super.dispose();
  }

  String _fmtDur(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _fmtTime(DateTime? dt) {
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _fmtAgo(DateTime? dt) {
    if (dt == null) return '--';
    final diff = DateTime.now().difference(dt).inSeconds;
    if (diff < 60) return 'il y a ${diff} sec';
    final m = diff ~/ 60;
    return 'il y a ${m} min';
  }

  String _fmtDist(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(2)} km';
  }

  String _fmtCompact(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Card shell ────────────────────────────────────────────────────────────
  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
    padding: padding ?? const EdgeInsets.fromLTRB(14, 14, 14, 14),
    decoration: BoxDecoration(
      color: const Color(0xFF131313),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
    ),
    child: child,
  );

  Widget _cardTitle(IconData icon, Color color, String label) => Row(
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 7),
      Text(label, style: const TextStyle(
        fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white,
      )),
    ],
  );

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _statusPill({
    required IconData icon,
    required String label,
    required Color color,
  }) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );

  Widget _buildHeader() {
    final isPaused = _live['rideIsPaused'] as bool;
    final rideColor = isPaused ? const Color(0xFFfb923c) : const Color(0xFF4ade80);
    final rideIcon = isPaused ? Icons.pause_circle_outline : Icons.navigation_outlined;
    final rideLabel = isPaused ? 'En pause' : 'En cours';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: widget.onEditTitle,
                  child: Text(
                    _live['rideName'] as String,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Démarrée à ${_fmtTime(_live['rideStartTime'] as DateTime?)}',
            style: const TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusPill(icon: rideIcon, label: rideLabel, color: rideColor),
              _statusPill(
                icon: Icons.signal_cellular_alt,
                label: 'GPS ${_live['gpsLabel'] as String}',
                color: _live['gpsColor'] as Color,
              ),
              // Pratique — cliquable pour changer le type de sortie à la volée.
              GestureDetector(
                onTap: widget.onEditPractice,
                child: _statusPill(
                  icon: _live['practiceIcon'] as IconData,
                  label: _live['practiceLabel'] as String,
                  color: _live['practiceColor'] as Color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Résumé card ───────────────────────────────────────────────────────────
  Widget _statCell(IconData icon, Color color, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildResumeCard() {
    final isPaused = _live['rideIsPaused'] as bool;
    final sep = Container(height: 1, color: Colors.white.withValues(alpha: 0.06));
    final vsep = Container(width: 1, color: Colors.white.withValues(alpha: 0.06));
    return _card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: _cardTitle(Icons.trending_up, const Color(0xFF4ade80), 'Résumé'),
          ),
          sep,
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(child: _statCell(Icons.timer_outlined, const Color(0xFF4ade80), 'Durée totale', _fmtDur(_live['rideDuration'] as Duration))),
                vsep,
                Expanded(child: _statCell(Icons.route_outlined, const Color(0xFFfb923c), 'Distance', _fmtDist(_live['totalDistance'] as double))),
              ],
            ),
          ),
          sep,
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(child: _statCell(Icons.update, const Color(0xFF60a5fa), 'Dernière MAJ GPS', _fmtAgo(_live['lastGpsUpdateTime'] as DateTime?))),
                vsep,
                if (isPaused)
                  Expanded(child: _statCell(Icons.pause_circle_outline, const Color(0xFFa78bfa), 'Pause actuelle', _fmtDur(_pauseDuration)))
                else
                  Expanded(child: _statCell(Icons.speed_outlined, const Color(0xFFa78bfa), 'Vitesse actuelle', '${(_live['currentSpeedKmh'] as double).toStringAsFixed(1)} km/h')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Position & suivi card ─────────────────────────────────────────────────
  Widget _buildPositionCard() {
    final lat = double.tryParse(_live['latitude'] as String);
    final lng = double.tryParse(_live['longitude'] as String);
    final latStr = lat != null ? '${lat.toStringAsFixed(4)}° N' : '--';
    final lngStr = lng != null ? '${lng.toStringAsFixed(4)}°' : '--';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.location_on_outlined, Colors.blue, 'Position & suivi'),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Dernière position connue',
                      style: TextStyle(fontSize: 11, color: Colors.white38)),
                    const SizedBox(height: 4),
                    Text('$latStr · $lngStr',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 2),
                    Text('Altitude : ${_live['altitude'] as String} m',
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Container(width: 7, height: 7,
                        decoration: const BoxDecoration(color: Color(0xFF4ade80), shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Flexible(child: Text(
                        'Lien de suivi actif · Dernière MAJ ${_fmtAgo(_live['lastGpsUpdateTime'] as DateTime?)}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF4ade80)),
                      )),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _actionBtn(Icons.copy_outlined, 'Copier', Colors.blue, widget.onCopy),
                  const SizedBox(height: 8),
                  _actionBtn(Icons.open_in_new, 'Ouvrir', Colors.blue, widget.onOpen),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );

  // ── Dénivelé card ─────────────────────────────────────────────────────────
  Widget _buildDeniveleCard() {
    final altPoints = _live['altPoints'] as List<double>;
    final altStart = _live['altStart'] as double?;
    final altMin = _live['altMin'] as double?;
    final altMax = _live['altMax'] as double?;
    final dPlus = _live['dPlus'] as double;
    final dMinus = _live['dMinus'] as double;
    final hasChart = altPoints.length >= 2;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.trending_up, const Color(0xFFfb923c), 'Dénivelé'),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SizedBox(
                  height: 160,
                  child: hasChart
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: ColoredBox(
                          color: const Color(0xFF111111),
                          child: CustomPaint(
                            painter: _LiveAltPainter(
                              altPoints,
                              altStart: altStart,
                              altMin: altMin,
                              altMax: altMax,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      )
                    : Center(
                        child: Text('Pas encore de données altitude',
                          style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.30))),
                      ),
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _elevKpi('+${dPlus.toStringAsFixed(0)} m', 'D+', const Color(0xFFfb923c)),
                  const SizedBox(height: 20),
                  _elevKpi('−${dMinus.toStringAsFixed(0)} m', 'D−', const Color(0xFFa78bfa)),
                ],
              ),
            ],
          ),
          if (altStart != null || altMin != null || altMax != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              if (altStart != null) _altBadge('DÉPART', '${altStart.toStringAsFixed(0)} m', Colors.white54),
              if (altMin != null) ...[const SizedBox(width: 8), _altBadge('ALT MIN', '${altMin.toStringAsFixed(0)} m', const Color(0xFF60a5fa))],
              if (altMax != null) ...[const SizedBox(width: 8), _altBadge('ALT MAX', '${altMax.toStringAsFixed(0)} m', const Color(0xFFfb923c))],
            ]),
          ],
        ],
      ),
    );
  }

  Widget _elevKpi(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, letterSpacing: -0.5)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
    ],
  );

  Widget _altBadge(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.25)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 9, color: color.withValues(alpha: 0.7), letterSpacing: 0.5)),
        Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
      ],
    ),
  );

  // ── Vitesse card ──────────────────────────────────────────────────────────
  Widget _buildVitesseCard() {
    final speedPoints = _live['speedPoints'] as List<double>;
    final movingSec = (_live['movingTime'] as Duration).inSeconds;
    final totalSec = (_live['rideDuration'] as Duration).inSeconds;
    final stopSec = (totalSec - movingSec).clamp(0, totalSec);
    final hasChart = speedPoints.length >= 2;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.speed_outlined, const Color(0xFF60a5fa), 'Vitesse'),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('VITESSE MOYENNE',
                    style: TextStyle(fontSize: 10, color: Color(0xFF666666), letterSpacing: 0.5)),
                  const SizedBox(height: 6),
                  Text('${(_live['avgSpeedKmh'] as double).toStringAsFixed(1)} km/h',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800,
                      color: Color(0xFF60a5fa), letterSpacing: -1)),
                ],
              ),
              const SizedBox(width: 14),
              if (hasChart)
                Expanded(
                  child: SizedBox(
                    height: 100,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CustomPaint(
                        painter: _LiveSpeedPainter(speedPoints, _live['maxSpeedKmh'] as double),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (totalSec > 0) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Row(children: [
                Expanded(
                  flex: movingSec.clamp(1, totalSec),
                  child: Container(height: 5, color: const Color(0xFF60a5fa)),
                ),
                if (stopSec > 0)
                  Expanded(
                    flex: stopSec,
                    child: Container(height: 5, color: const Color(0xFF252525)),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          Row(children: [
            Text(_fmtCompact(movingSec),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF60a5fa))),
            const SizedBox(width: 5),
            const Text('en mouvement', style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
            const SizedBox(width: 10),
            Container(width: 1, height: 14, color: const Color(0xFF444444)),
            const SizedBox(width: 10),
            Text(_fmtCompact(stopSec),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFaabbcc))),
            const SizedBox(width: 5),
            const Text('arrêté', style: TextStyle(fontSize: 12, color: Color(0xFF8899aa))),
          ]),
        ],
      ),
    );
  }

  // ── Conditions card ───────────────────────────────────────────────────────
  Widget _buildConditionsCard() {
    final isNight = _live['isNight'] as bool;
    final weatherTemp = _live['weatherTemp'] as double?;
    final sunriseTime = _live['sunriseTime'] as DateTime?;
    final sunsetTime = _live['sunsetTime'] as DateTime?;
    final hasWeather = weatherTemp != null;
    final hasSun = sunriseTime != null && sunsetTime != null;
    if (!hasWeather && !hasSun) return const SizedBox.shrink();

    final accentWeather = isNight ? const Color(0xFF818cf8) : const Color(0xFFF9A825);
    final accentSun = isNight ? const Color(0xFF818cf8) : const Color(0xFFfbbf24);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle(Icons.wb_sunny_outlined, accentWeather, 'Conditions'),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasWeather) Expanded(child: _weatherCol(accentWeather)),
                if (hasWeather && hasSun)
                  Container(width: 1, color: Colors.white.withValues(alpha: 0.08),
                    margin: const EdgeInsets.symmetric(horizontal: 12)),
                if (hasSun) Expanded(child: _sunCol(accentSun)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _weatherCol(Color accent) {
    final weatherTemp = _live['weatherTemp'] as double?;
    final weatherDesc = _live['weatherDesc'] as String?;
    final weatherWind = _live['weatherWind'] as double?;
    final weatherWindDir = _live['weatherWindDir'] as String?;
    final weatherHumidity = _live['weatherHumidity'] as int?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${weatherTemp!.toStringAsFixed(0)}°',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: accent),
        ),
        if (weatherDesc != null) ...[
          const SizedBox(height: 3),
          Text(weatherDesc, style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
        ],
        const SizedBox(height: 6),
        if (weatherWind != null)
          _condRow(Icons.air, '${weatherWind.toStringAsFixed(0)} km/h ${weatherWindDir ?? ''}'),
        if (weatherHumidity != null)
          _condRow(Icons.water_drop_outlined, 'Humidité $weatherHumidity%'),
      ],
    );
  }

  Widget _sunCol(Color accent) {
    final isNight = _live['isNight'] as bool;
    final sunriseTime = _live['sunriseTime'] as DateTime?;
    final sunsetTime = _live['sunsetTime'] as DateTime?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(isNight ? Icons.nights_stay_outlined : Icons.wb_sunny, color: accent, size: 18),
          const SizedBox(width: 6),
          Text(isNight ? 'Nuit' : 'Soleil',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accent)),
        ]),
        const SizedBox(height: 10),
        _sunRow(Icons.wb_twilight, 'Lever', _fmtTime(sunriseTime), const Color(0xFFffa726)),
        const SizedBox(height: 6),
        _sunRow(Icons.nights_stay_outlined, 'Coucher', _fmtTime(sunsetTime), const Color(0xFF818cf8)),
      ],
    );
  }

  Widget _condRow(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(children: [
      Icon(icon, size: 12, color: Colors.white38),
      const SizedBox(width: 5),
      Flexible(child: Text(text, style: const TextStyle(fontSize: 11, color: Color(0xFF888888)))),
    ]),
  );

  Widget _sunRow(IconData icon, String label, String value, Color color) => Row(children: [
    Icon(icon, size: 13, color: color),
    const SizedBox(width: 6),
    Text('$label ', style: const TextStyle(fontSize: 12, color: Color(0xFF888888))),
    Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
  ]);

  // ── Note card ─────────────────────────────────────────────────────────────
  Widget _buildNoteCard() {
    final rideNote = _live['rideNote'] as String;
    final hasNote = rideNote.isNotEmpty;
    return GestureDetector(
      onTap: widget.onEditNote,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF131313),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasNote
                ? Colors.white.withValues(alpha: 0.07)
                : const Color(0xFF2563eb).withValues(alpha: 0.22),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              hasNote ? Icons.notes : Icons.add_circle_outline_rounded,
              color: hasNote ? Colors.white38 : const Color(0xFF60a5fa),
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: hasNote
                  ? Text(
                      rideNote,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.45),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    )
                  : const Text(
                      'Ajouter une note à cette sortie…',
                      style: TextStyle(
                        color: Color(0xFF4d6080),
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertesCard() {
    final hasAlerts = (_live['notificationCount'] as int) > 0;
    final alertColor = hasAlerts ? Colors.orange : Colors.white38;
    return _card(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: alertColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              hasAlerts ? Icons.notifications_active : Icons.notifications_none,
              color: alertColor, size: 17,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Alertes',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: hasAlerts ? Colors.white : Colors.white54)),
                const SizedBox(height: 2),
                Text(
                  hasAlerts
                    ? '${(_live['notificationCount'] as int)} alerte(s) active(s)'
                    : 'Aucune alerte pour le moment',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                const Text(
                  'Les dangers proches, alertes météo et notifications importantes apparaîtront ici.',
                  style: TextStyle(fontSize: 10, color: Colors.white24),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.78,
      maxChildSize: 0.95,
      minChildSize: _minSize,
      expand: false,
      builder: (ctx, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0D0D0D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: CustomScrollView(
          controller: scrollController,
          slivers: [
            // En-tête épinglé : barre de drag + pastille « Réduire les détails »
            const SliverPersistentHeader(
              pinned: true,
              delegate: _SheetTopBarDelegate(),
            ),
            SliverToBoxAdapter(child: _buildHeader()),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildResumeCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildPositionCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildDeniveleCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildVitesseCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildConditionsCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildNoteCard(),
            )),
            SliverToBoxAdapter(child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _buildAlertesCard(),
            )),
            SliverToBoxAdapter(
                child: SizedBox(
                    height: 40 + MediaQuery.of(context).padding.bottom)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// EN-TÊTE ÉPINGLÉ du panneau détails : barre de drag + « Réduire les détails »
// ════════════════════════════════════════════════════════════════════════════
class _SheetTopBarDelegate extends SliverPersistentHeaderDelegate {
  const _SheetTopBarDelegate();

  static const double _height = 26;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        color: const Color(0xFF0D0D0D),
        alignment: Alignment.center,
        // Barre de drag centrée, sur sa propre ligne (agrandir/réduire au doigt)
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _SheetTopBarDelegate oldDelegate) => false;
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil altimétrique live
// ════════════════════════════════════════════════════════════════════════════
class _LiveAltPainter extends CustomPainter {
  final List<double> alts;
  final double? altStart;
  final double? altMin;
  final double? altMax;

  const _LiveAltPainter(this.alts, {this.altStart, this.altMin, this.altMax});

  @override
  void paint(Canvas canvas, Size size) {
    if (alts.length < 2) return;

    final minA = alts.reduce(min);
    final maxA = alts.reduce(max);
    final range = (maxA - minA).clamp(1.0, double.infinity);

    const topPad = 16.0;
    const botPad = 16.0;
    final drawH = size.height - topPad - botPad;

    double xOf(int i) => i / (alts.length - 1) * size.width;
    double yOf(double a) => topPad + drawH - ((a - minA) / range) * drawH;

    final linePath = ui.Path()..moveTo(xOf(0), yOf(alts[0]));
    for (int i = 1; i < alts.length; i++) { linePath.lineTo(xOf(i), yOf(alts[i])); }

    canvas.drawPath(
      ui.Path.from(linePath)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topPad), Offset(0, size.height),
          [const Color(0xFFfb923c).withValues(alpha: 0.38),
           const Color(0xFFfb923c).withValues(alpha: 0.01)],
        )
        ..style = PaintingStyle.fill,
    );

    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFFfb923c)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_LiveAltPainter old) =>
    old.alts != alts || old.altStart != altStart || old.altMin != altMin || old.altMax != altMax;
}

// ════════════════════════════════════════════════════════════════════════════
// PAINTER : profil vitesse live
// ════════════════════════════════════════════════════════════════════════════
class _LiveSpeedPainter extends CustomPainter {
  final List<double> speeds;
  final double maxSpeed;

  const _LiveSpeedPainter(this.speeds, this.maxSpeed);

  List<double> _smooth(List<double> data) {
    const w = 5;
    final out = <double>[];
    for (int i = 0; i < data.length; i++) {
      final lo = (i - w ~/ 2).clamp(0, data.length - 1);
      final hi = (i + w ~/ 2).clamp(0, data.length - 1);
      double sum = 0;
      for (int j = lo; j <= hi; j++) { sum += data[j]; }
      out.add(sum / (hi - lo + 1));
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (speeds.length < 2) return;

    final smoothed = _smooth(speeds);
    final peak = smoothed.reduce(max).clamp(1.0, 300.0);

    const topPad = 40.0;
    const botPad = 4.0;
    final drawH = size.height - topPad - botPad;

    double xOf(int i) => i / (smoothed.length - 1) * size.width;
    double yOf(double s) => topPad + drawH - (s / peak) * drawH;

    final fillPath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (int i = 1; i < smoothed.length; i++) { fillPath.lineTo(xOf(i), yOf(smoothed[i])); }
    fillPath..lineTo(size.width, size.height)..lineTo(0, size.height)..close();

    canvas.drawPath(fillPath, Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, topPad), Offset(0, size.height),
        [const Color(0xFF60a5fa).withValues(alpha: 0.18),
         const Color(0xFF60a5fa).withValues(alpha: 0.01)],
      )
      ..style = PaintingStyle.fill);

    final linePath = ui.Path()..moveTo(xOf(0), yOf(smoothed[0]));
    for (int i = 1; i < smoothed.length; i++) { linePath.lineTo(xOf(i), yOf(smoothed[i])); }
    canvas.drawPath(linePath, Paint()
      ..color = const Color(0xFF60a5fa)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // Badge MAX
    int maxIdx = 0;
    for (int i = 1; i < smoothed.length; i++) {
      if (smoothed[i] > smoothed[maxIdx]) maxIdx = i;
    }
    final px = xOf(maxIdx);
    final py = yOf(smoothed[maxIdx]);

    final valStr = '${maxSpeed.toStringAsFixed(1)} km/h';
    final tpLabel = TextPainter(
      text: const TextSpan(text: 'MAX',
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFbfdbfe), letterSpacing: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    final tpVal = TextPainter(
      text: TextSpan(text: valStr,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout();

    const hP = 8.0; const vP = 5.0; const gap = 2.0;
    final bw = max(tpLabel.width, tpVal.width) + hP * 2;
    final bh = tpLabel.height + gap + tpVal.height + vP * 2;
    const by = 2.0;
    final bx = (px - bw / 2).clamp(2.0, size.width - bw - 2);

    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(7)),
      Paint()..color = const Color(0xFF1e3a8a));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(7)),
      Paint()..color = const Color(0xFF60a5fa)..style = PaintingStyle.stroke..strokeWidth = 1.1);

    tpLabel.paint(canvas, Offset(bx + (bw - tpLabel.width) / 2, by + vP));
    tpVal.paint(canvas, Offset(bx + (bw - tpVal.width) / 2, by + vP + tpLabel.height + gap));

    final connY1 = by + bh + 1;
    final connY2 = py - 4;
    if (connY2 > connY1) {
      canvas.drawLine(Offset(px, connY1), Offset(px, connY2),
        Paint()..color = const Color(0xFF60a5fa).withValues(alpha: 0.6)..strokeWidth = 1.0);
    }
    canvas.drawCircle(Offset(px, py), 4.0, Paint()..color = const Color(0xFF1e3a8a));
    canvas.drawCircle(Offset(px, py), 4.0, Paint()
      ..color = const Color(0xFF93c5fd)..style = PaintingStyle.stroke..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(_LiveSpeedPainter old) => old.speeds != speeds || old.maxSpeed != maxSpeed;
}
