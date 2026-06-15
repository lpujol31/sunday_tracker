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
    const gapLen  = 4.0;
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

class RideScreen extends StatefulWidget {
  const RideScreen({super.key});
  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {

  String latitude  = 'Loading...';
  String longitude = 'Loading...';
  String altitude  = 'Loading...';
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
  bool rideIsPaused  = false;
  bool rideIsStarted = false;
  String? safetySessionId;
  String? safetyShareCode;
  String? safetyUrl;
  Timer? safetyUploadTimer;
  Position? currentPosition;
  bool gpsIsReady        = false;
  bool gpsIsInitializing = true;
  DateTime? _lastPointTimestamp;
  final List<Map<String, dynamic>> rideWaypoints = [];
  final ImagePicker _imagePicker = ImagePicker();

  // ── Notifications ──────────────────────────────────────────────
  int _notificationCount = 0;
  final List<Map<String, dynamic>> _notifications = [];

  // ── Carte ──────────────────────────────────────────────────────
  static const String _prefKeyMapStyle     = 'ride_map_style_index';
  static const String _prefKeyMapCollapsed = 'ride_map_collapsed';
  int  _mapStyleIndex = 0;
  bool _mapFullscreen = false;
  bool _mapCollapsed  = false;
  final List<Map<String, dynamic>> _mapStyles = [
    {'label': 'Satellite', 'icon': Icons.satellite_alt, 'url': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'subdomains': <String>[],            'maxZoom': 19},
    {'label': 'Topo',      'icon': Icons.terrain,       'url': 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',                                              'subdomains': <String>['a','b','c'], 'maxZoom': 17},
    {'label': 'Plan',      'icon': Icons.map,            'url': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',                                                'subdomains': <String>[],            'maxZoom': 19},
  ];

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    final saved     = prefs.getInt(_prefKeyMapStyle) ?? 0;
    final collapsed = prefs.getBool(_prefKeyMapCollapsed) ?? false;
    if (mounted) setState(() {
      _mapStyleIndex = saved.clamp(0, _mapStyles.length - 1);
      _mapCollapsed  = collapsed;
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
  double _speedKmh        = 0;
  double _maxSpeedKmh     = 0;
  double _avgSpeedKmh     = 0;
  double _dPlus           = 0;
  double _slopePercent    = 0;
  double _maxSlopePercent = 0;
  double? _prevAltitude;
  double? _prevDistance;
  int    _speedSamples = 0;
  double _speedSum     = 0;

  void _updateSpeedAndElevation(Position position) {
    final spd = (position.speed * 3.6).clamp(0.0, 200.0);
    _speedKmh = spd;
    if (spd > _maxSpeedKmh) _maxSpeedKmh = spd;
    if (spd > 0.5) { _speedSum += spd; _speedSamples++; }
    _avgSpeedKmh = _speedSamples > 0 ? _speedSum / _speedSamples : 0;

    final alt = position.altitude;
    if (_prevAltitude != null) {
      final dAlt  = alt - _prevAltitude!;
      final dDist = totalDistance - (_prevDistance ?? 0);
      if (dAlt > 0.5) _dPlus += dAlt;
      if (dDist > 1) {
        _slopePercent = (dAlt / dDist * 100).clamp(-45.0, 45.0);
        if (_slopePercent.abs() > _maxSlopePercent) _maxSlopePercent = _slopePercent.abs();
      }
    }
    _prevAltitude = alt;
    _prevDistance = totalDistance;
  }

  Widget _elevRow(String label, String value, double progress, Color color) => Row(children: [
    SizedBox(width: 60, child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38))),
    Expanded(child: ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0,
        backgroundColor: const Color(0xFF2A2A2A),
        color: color,
        minHeight: 3,
      ),
    )),
    const SizedBox(width: 8),
    SizedBox(width: 48, child: Text(value,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
      textAlign: TextAlign.right)),
  ]);

  // ── Météo + Soleil ─────────────────────────────────────────────
  double?   _weatherTemp;
  double?   _weatherWind;
  String?   _weatherWindDir;
  int?      _weatherHumidity;
  String?   _weatherDesc;
  Timer?    _weatherTimer;
  bool      _weatherFetched = false;
  Map<String, dynamic>? _weatherSnapshotStart;
  Map<String, dynamic>? _weatherSnapshotEnd;

  Map<String, dynamic> _currentWeatherSnapshot() => {
    'temp':     _weatherTemp,
    'wind':     _weatherWind,
    'windDir':  _weatherWindDir,
    'humidity': _weatherHumidity,
    'desc':     _weatherDesc,
  };

  DateTime? _sunriseTime;
  DateTime? _sunsetTime;
  bool      _sunFetched    = false;
  int       _sunTimerTicks = 0;
  Timer?    _sunTimer;

  bool get _isNight {
    if (_sunriseTime == null || _sunsetTime == null) return false;
    final now = DateTime.now();
    return now.isBefore(_sunriseTime!) || now.isAfter(_sunsetTime!);
  }

  double _computeSunProgress() {
    if (_sunriseTime == null || _sunsetTime == null) return 0;
    final now = DateTime.now();
    if (!_isNight) {
      final total   = _sunsetTime!.difference(_sunriseTime!).inSeconds.toDouble();
      if (total <= 0) return 0;
      final elapsed = now.difference(_sunriseTime!).inSeconds.toDouble();
      return (elapsed / total).clamp(0.0, 1.0);
    } else {
      final nextSunrise = now.isBefore(_sunriseTime!) ? _sunriseTime! : _sunriseTime!.add(const Duration(days: 1));
      final total   = nextSunrise.difference(_sunsetTime!).inSeconds.toDouble();
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
      final h = rem.inHours; final m = rem.inMinutes % 60;
      return h > 0 ? '${h}h ${m.toString().padLeft(2,'0')} restantes' : '${m}min restantes';
    } else {
      final nextSunrise = now.isBefore(_sunriseTime!) ? _sunriseTime! : _sunriseTime!.add(const Duration(days: 1));
      final rem = nextSunrise.difference(now);
      final h = rem.inHours; final m = rem.inMinutes % 60;
      return 'lever dans ${h}h ${m.toString().padLeft(2,'0')}';
    }
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  Future<void> _fetchSunTimes(double lat, double lng) async {
    try {
      final uri = Uri.parse('https://api.sunrise-sunset.org/json?lat=${lat.toStringAsFixed(6)}&lng=${lng.toStringAsFixed(6)}&formatted=0');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['status'] != 'OK') return;
      final r       = json['results'] as Map<String, dynamic>;
      final sunrise = DateTime.parse(r['sunrise'] as String).toLocal();
      final sunset  = DateTime.parse(r['sunset']  as String).toLocal();
      if (!mounted) return;
      setState(() { _sunriseTime = sunrise; _sunsetTime = sunset; _sunFetched = true; });
    } catch (e) { debugPrint('[SUN] $e'); }
  }

  Future<void> _fetchWeather(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${lat.toStringAsFixed(4)}&longitude=${lng.toStringAsFixed(4)}'
        '&current=temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,weather_code',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final json    = jsonDecode(res.body) as Map<String, dynamic>;
      final current = json['current'] as Map<String, dynamic>;
      final code    = (current['weather_code'] as num).toInt();
      final windDeg = (current['wind_direction_10m'] as num).toDouble();
      if (!mounted) return;
      setState(() {
        _weatherTemp     = (current['temperature_2m']       as num).toDouble();
        _weatherWind     = (current['wind_speed_10m']       as num).toDouble();
        _weatherHumidity = (current['relative_humidity_2m'] as num).toInt();
        _weatherWindDir  = _windDirLabel(windDeg);
        _weatherDesc     = _weatherCodeDesc(code);
        _weatherFetched  = true;
      });
    } catch (e) { debugPrint('[WEATHER] $e'); }
  }

  String _windDirLabel(double deg) {
    const dirs = ['N','NE','E','SE','S','SO','O','NO'];
    return dirs[((deg + 22.5) / 45).floor() % 8];
  }

  String _weatherCodeDesc(int code) {
    if (code == 0)  return 'Ciel dégagé';
    if (code <= 2)  return 'Peu nuageux';
    if (code == 3)  return 'Couvert';
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
    if (desc == 'Couvert')      return Icons.cloud;
    if (desc.contains('Pluie') || desc.contains('Averses') || desc.contains('Bruine')) return Icons.grain;
    if (desc.contains('Neige')) return Icons.ac_unit;
    if (desc.contains('Orage')) return Icons.bolt;
    if (desc.contains('Brouillard')) return Icons.blur_on;
    return Icons.wb_sunny;
  }

  Color get _sunColor => _isNight ? const Color(0xFF818cf8) : const Color(0xFFF9A825);

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
      if (mounted) setState(() {});
    });
  }

  // ── GPS ────────────────────────────────────────────────────────
  int _satelliteCount = 0;

  // ── Mode édition (réordonnage) ────────────────────────────────
  bool _editMode = false;

  // ── Blocs collapsibles ─────────────────────────────────────────
  static const String _prefBlocksCollapsed = 'ride_blocks_collapsed';
  static const String _prefBlocksOrder     = 'ride_blocks_order';

  // IDs valides — utilisés pour détecter les ordres obsolètes
  static const Set<String> _validBlockIds = {'duree', 'dist', 'speed', 'weather', 'sun', 'gps', 'sharing'};

  final List<String> _blockIds = ['duree', 'dist', 'speed', 'weather', 'sun', 'gps', 'sharing'];
  final Set<String> _collapsedBlocks = {};

  Future<void> _loadBlockPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final defaultCollapsed = ['gps', 'sharing'];
    final collapsed  = prefs.getStringList(_prefBlocksCollapsed) ?? defaultCollapsed;
    final savedOrder = prefs.getStringList(_prefBlocksOrder);
    if (mounted) setState(() {
      _collapsedBlocks..clear()..addAll(collapsed);
      if (savedOrder != null) {
        // Si l'ordre sauvegardé contient des IDs inconnus (ancienne version), on ignore
        final allKnown = savedOrder.every(_validBlockIds.contains);
        if (allKnown) {
          final ordered = savedOrder.where(_blockIds.contains).toList();
          for (final id in _blockIds) { if (!ordered.contains(id)) ordered.add(id); }
          _blockIds..clear()..addAll(ordered);
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
      // weather et sun sont liés — ils se replient/déplient ensemble
      final linked = id == 'weather' ? ['weather', 'sun']
          : id == 'sun' ? ['weather', 'sun']
          : id == 'duree' ? ['duree', 'dist']
          : id == 'dist'  ? ['duree', 'dist']
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
    // sun et weather partagent le même état collapsed (source : weather)
    final collapsed = _isCollapsed(id == 'sun' ? 'weather' : id == 'dist' ? 'duree' : id);
    return GestureDetector(
      onTap: _editMode ? null : () => _toggleBlock(id),
      onLongPress: () {
        setState(() => _editMode = !_editMode);
        HapticFeedback.mediumImpact();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 10, 14, collapsed ? 10 : 4),
        child: Row(children: [
          Icon(icon, color: iconColor, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: collapsed
              ? Row(children: [
                  Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white54)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(summary, style: TextStyle(fontSize: 11, color: iconColor), overflow: TextOverflow.ellipsis)),
                ])
              : Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white54)),
          ),
          if (draggableIndex != null && _editMode)
            ReorderableDragStartListener(
              index: draggableIndex,
              child: const Padding(
                padding: EdgeInsets.only(left: 4, right: 2),
                child: Icon(Icons.drag_handle, color: Colors.white54, size: 18),
              ),
            ),
          AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.keyboard_arrow_down, color: Colors.white24, size: 18),
          ),
        ]),
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
    final collapsed = _isCollapsed(id == 'sun' ? 'weather' : id == 'dist' ? 'duree' : id);
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
          _blockHeader(id: id, icon: icon, iconColor: iconColor, title: title, summary: summary, draggableIndex: draggableIndex),
          AnimatedCrossFade(
            firstChild:  Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 12), child: body),
            secondChild: const SizedBox.shrink(),
            crossFadeState: collapsed ? CrossFadeState.showSecond : CrossFadeState.showFirst,
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
    if (v <= 5)  return const Color(0xFF4ade80);
    if (v <= 15) return const Color(0xFF86efac);
    if (v <= 30) return Colors.orange;
    return Colors.red;
  }

  String _gpsSignalLabel() {
    if (rideIsPaused) return 'GPS off';
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 5)  return 'Excellent';
    if (v <= 15) return 'Bon';
    if (v <= 30) return 'Moyen';
    return 'Faible';
  }

  int _gpsBarCount() {
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 5)  return 5;
    if (v <= 10) return 4;
    if (v <= 15) return 3;
    if (v <= 30) return 2;
    return 1;
  }

  Widget _gpsStatMini(String label, String value, Color color, {bool small = false}) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.white38)),
        const SizedBox(height: 2),
        Text(value,
          style: TextStyle(fontSize: small ? 10 : 13, fontWeight: FontWeight.bold, color: color),
          overflow: TextOverflow.ellipsis),
      ]),
    ),
  );

  // ═══════════════════════════════════════════════════════════════
  // BLOCS
  // ═══════════════════════════════════════════════════════════════

  // ── Notifications ─────────────────────────────────────────────
  Widget _buildNotificationZone() {
    final hasAlerts = _notificationCount > 0;
    return CustomPaint(
      painter: _DashedBorderPainter(
        color: hasAlerts ? Colors.orange.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.13),
        radius: 12,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(color: const Color(0xFF141414), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: hasAlerts ? Colors.orange.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              hasAlerts ? Icons.notifications_active : Icons.notifications_none,
              color: hasAlerts ? Colors.orange : Colors.white38,
              size: 15,
            ),
          ),
          const SizedBox(width: 10),
          Text('Notifications',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: hasAlerts ? Colors.white : Colors.white38)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hasAlerts ? Colors.orange.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('$_notificationCount',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                color: hasAlerts ? Colors.orange : Colors.white24)),
          ),
          const Spacer(),
          const Icon(Icons.keyboard_arrow_down, color: Colors.white12, size: 16),
        ]),
      ),
    );
  }

  // ── Durée + Distance — 2 colonnes ─────────────────────────────
  Widget _buildStatCard({required String label, required String value, required IconData icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ]),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  // ── Vitesse & dénivelé ────────────────────────────────────────
  Widget _buildSpeedBody() {
    String fmt(double v) => v.toStringAsFixed(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(fmt(_speedKmh), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFF4ade80))),
        const SizedBox(width: 4),
        const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('km/h', style: TextStyle(fontSize: 13, color: Colors.white38))),
        const Spacer(),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('moy. ${fmt(_avgSpeedKmh)} km/h', style: const TextStyle(fontSize: 11, color: Colors.white38)),
          Text('max ${fmt(_maxSpeedKmh)} km/h',  style: const TextStyle(fontSize: 11, color: Colors.white24)),
        ]),
      ]),
      const SizedBox(height: 12),
      _elevRow('D+ cumulé', '+${_dPlus.toStringAsFixed(0)} m', (_dPlus / 500).clamp(0, 1), const Color(0xFFfb923c)),
      const SizedBox(height: 6),
      _elevRow('Pente', '${_slopePercent >= 0 ? '+' : ''}${_slopePercent.toStringAsFixed(1)}%',
        (_slopePercent.abs() / 30).clamp(0, 1), const Color(0xFFa78bfa)),
    ]);
  }

  // ── Météo ────────────────────────────────────────────────────
  Widget _buildWeatherBody() {
    final nightMode = _isNight;
    final color = nightMode ? const Color(0xFF818cf8) : const Color(0xFFF9A825);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(_weatherIcon(_weatherDesc), color: color, size: 24),
        const SizedBox(width: 8),
        Text(_weatherFetched ? '${_weatherTemp!.toStringAsFixed(0)}°' : '--°',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
      ]),
      const SizedBox(height: 4),
      Text(_weatherDesc ?? 'Chargement…',
        style: const TextStyle(fontSize: 10, color: Colors.white38),
        overflow: TextOverflow.ellipsis),
      if (_weatherFetched) ...[
        const SizedBox(height: 3),
        Text('${_weatherWind!.toStringAsFixed(0)} km/h $_weatherWindDir · ${_weatherHumidity}%',
          style: const TextStyle(fontSize: 10, color: Colors.white24),
          overflow: TextOverflow.ellipsis),
      ],
    ]);
  }

  // ── Soleil ───────────────────────────────────────────────────
  Widget _buildSunBody() {
    final accent   = _sunColor;
    final progress = _computeSunProgress();
    return Row(children: [
      Column(children: [
        Text(_fmt(_sunriseTime), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accent)),
        const Text('lever', style: TextStyle(fontSize: 9, color: Colors.white30)),
      ]),
      Expanded(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(children: [
          Text(_sunLabel(), style: const TextStyle(fontSize: 9, color: Colors.white38), textAlign: TextAlign.center),
          const SizedBox(height: 5),
          LayoutBuilder(builder: (ctx, constraints) {
            final w = constraints.maxWidth;
            if (w <= 0) return const SizedBox(height: 12);
            final p = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
            return SizedBox(height: 12, child: Stack(children: [
              Positioned(left: 0, top: 4, right: 0, bottom: 4,
                child: Container(decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(2)))),
              Positioned(left: 0, top: 4, bottom: 4, width: (w * p).clamp(0.0, w),
                child: Container(decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)))),
              Positioned(left: (w * p - 5.5).clamp(0.0, w - 11), top: 0.5,
                child: Container(width: 11, height: 11,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF1A1A1A), width: 2)))),
            ]));
          }),
        ]),
      )),
      Column(children: [
        Text(_fmt(_sunsetTime), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accent)),
        const Text('coucher', style: TextStyle(fontSize: 9, color: Colors.white30)),
      ]),
    ]);
  }

  // ── GPS ──────────────────────────────────────────────────────
  Widget _buildGpsBody() {
    final signalColor = _gpsSignalColor();
    final barCount    = _gpsBarCount();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(5, (i) {
            final active = i < barCount;
            final h = 6.0 + i * 4.0;
            return Container(width: 6, height: h, margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(color: active ? signalColor : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(2)));
          }),
        ),
        const SizedBox(width: 10),
        Text(_gpsSignalLabel(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: signalColor)),
        const Spacer(),
        GestureDetector(
          onTap: _showGpsDetailsDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(20)),
            child: const Row(children: [
              Icon(Icons.info_outline, size: 10, color: Colors.white38),
              SizedBox(width: 3),
              Text('Détails', style: TextStyle(fontSize: 10, color: Colors.white38)),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        _gpsStatMini('Précision', '${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m', signalColor),
        const SizedBox(width: 6),
        _gpsStatMini('Altitude', '$altitude m', Colors.white70),
        const SizedBox(width: 6),
        _gpsStatMini('Lat / Long',
          '${double.tryParse(latitude)?.toStringAsFixed(4) ?? '--'} / ${double.tryParse(longitude)?.toStringAsFixed(4) ?? '--'}',
          Colors.white38, small: true),
      ]),
    ]);
  }

  // ── GPS bloc pré-ride ────────────────────────────────────────
  Widget _buildGpsBlock() {
    final signalColor = _gpsSignalColor();
    final barCount    = _gpsBarCount();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Icon(Icons.satellite_alt, color: signalColor, size: 14),
            const SizedBox(width: 6),
            const Text('Signal GPS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white54)),
          ]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(border: Border.all(color: signalColor), borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              Container(width: 5, height: 5, decoration: BoxDecoration(color: signalColor, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text('${_gpsSignalLabel()} · ${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m',
                style: TextStyle(fontSize: 10, color: signalColor)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(5, (i) {
              final active = i < barCount;
              final h = 6.0 + i * 4.0;
              return Container(width: 6, height: h, margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(color: active ? signalColor : const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(2)));
            }),
          ),
          const SizedBox(width: 12),
          Text(_gpsSignalLabel(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: signalColor)),
          const Spacer(),
          if (!rideIsStarted)
            Text(gpsIsReady ? 'Prêt à démarrer' : 'Acquisition…',
              style: TextStyle(fontSize: 11, color: gpsIsReady ? signalColor : Colors.white38)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _gpsStatMini('Précision', '${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m', signalColor),
          const SizedBox(width: 8),
          _gpsStatMini('Altitude', '$altitude m', Colors.white70),
          const SizedBox(width: 8),
          _gpsStatMini('Lat / Long',
            '${double.tryParse(latitude)?.toStringAsFixed(4) ?? '--'} / ${double.tryParse(longitude)?.toStringAsFixed(4) ?? '--'}',
            Colors.white38, small: true),
        ]),
      ]),
    );
  }

  // ── Mapping id → bloc ─────────────────────────────────────────
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
          body: Text(formattedDuration(),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4ade80))),
        );
      case 'dist':
        return _buildBlock(
          id: 'dist',
          icon: Icons.route_outlined,
          iconColor: const Color(0xFFfb923c),
          title: 'Distance',
          summary: formattedDistance(),
          draggableIndex: index,
          body: Text(formattedDistance(),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFfb923c))),
        );
      case 'speed':
        return _buildBlock(id: 'speed', icon: Icons.show_chart, iconColor: const Color(0xFF4ade80),
          title: 'Vitesse & dénivelé', summary: '${_speedKmh.toStringAsFixed(1)} km/h · D+ ${_dPlus.toStringAsFixed(0)} m',
          body: _buildSpeedBody(), draggableIndex: index);
      case 'weather':
        return _buildBlock(id: 'weather', icon: Icons.wb_sunny_outlined,
          iconColor: _isNight ? const Color(0xFF818cf8) : const Color(0xFFF9A825),
          title: 'Météo',
          summary: _weatherFetched ? '${_weatherTemp!.toStringAsFixed(0)}° · ${_weatherDesc ?? ''}' : 'Chargement…',
          body: _buildWeatherBody(), draggableIndex: index);
      case 'sun':
        return _buildBlock(id: 'sun', icon: Icons.wb_twilight, iconColor: _sunColor,
          title: 'Soleil',
          summary: 'Lever ${_fmt(_sunriseTime)} · Coucher ${_fmt(_sunsetTime)}',
          body: _buildSunBody(), draggableIndex: index); // poignée sur chaque bloc de la paire
      case 'gps':
        return _buildBlock(id: 'gps', icon: Icons.satellite_alt, iconColor: _gpsSignalColor(),
          title: 'Signal GPS',
          summary: '${_gpsSignalLabel()} · ${double.tryParse(accuracy)?.toStringAsFixed(0) ?? '--'} m · $altitude m alt.',
          body: _buildGpsBody(), draggableIndex: index);
      case 'sharing':
        return _buildBlock(id: 'sharing', icon: Icons.share_location, iconColor: Colors.blue,
          title: 'Partager le suivi', summary: 'Lien de suivi actif',
          draggableIndex: index,
          body: Row(children: [
            Expanded(child: GestureDetector(
              onTap: shareSafetyLink,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.send, color: Colors.blue, size: 13),
                  SizedBox(width: 5),
                  Text('Envoyer à mes proches', style: TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600)),
                ]),
              ),
            )),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () async {
                if (safetyUrl != null) {
                  final uri = Uri.parse(safetyUrl!);
                  if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(color: const Color(0xFF242424), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                child: const Icon(Icons.remove_red_eye_outlined, color: Colors.white38, size: 16),
              ),
            ),
          ]));
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GPS INIT
  // ═══════════════════════════════════════════════════════════════
  Future<void> initializeGps() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      setState(() { gpsIsInitializing = false; gpsIsReady = false; accuracy = 'Permission refusée'; });
      return;
    }
    await gpsInitializationStream?.cancel();
    gpsInitializationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
    ).listen((Position position) async {
      currentPosition = position;
      if (!mounted) return;
      setState(() {
        latitude  = position.latitude.toString();
        longitude = position.longitude.toString();
        altitude  = position.altitude.toStringAsFixed(1);
        accuracy  = position.accuracy.toStringAsFixed(1);
        gpsIsInitializing = false;
        gpsIsReady = position.accuracy <= 20;
      });
      if (!_sunFetched) {
        _fetchSunTimes(position.latitude, position.longitude);
        _fetchWeather(position.latitude, position.longitude);
        _startWeatherAndSunTimers();
      }
      // Toujours mettre à jour la carte avant le démarrage
      if (mapReady && !rideIsStarted) {
        mapController.move(LatLng(position.latitude, position.longitude), 16);
      }
      // On ne coupe plus le stream — il continue jusqu'à startRide()
      // Quand le GPS est bon on le signale mais on continue à recevoir les positions
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // RIDE
  // ═══════════════════════════════════════════════════════════════
  Future<void> startRide({bool shareLink = false}) async {
    await gpsInitializationStream?.cancel();
    gpsInitializationStream = null;
    if (_weatherFetched) _weatherSnapshotStart = _currentWeatherSnapshot();
    await startForegroundService();
    await createSafetySession();
    if (shareLink) await shareSafetyLink();
    rideStartTime = DateTime.now().toLocal();
    rideTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() { rideDuration = DateTime.now().difference(rideStartTime!); });
    });
    await startTracking();
    setState(() { rideIsStarted = true; });
  }

  Future<void> _showStartRideSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
          const Text('Démarrer la sortie', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 6),
          const Text('Veux-tu partager ton lien de suivi ?', style: TextStyle(fontSize: 14, color: Colors.white54)),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () async { Navigator.pop(ctx); await startRide(shareLink: true); },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00C853), Color(0xFF00897B)], begin: Alignment.centerLeft, end: Alignment.centerRight),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                  child: const Icon(Icons.share_location, color: Colors.white, size: 18)),
                const SizedBox(width: 14),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Partager et démarrer', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text('Envoie le lien de suivi à tes proches', style: TextStyle(fontSize: 12, color: Colors.white70)),
                ])),
                const Icon(Icons.chevron_right, color: Colors.white54),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () async { Navigator.pop(ctx); await startRide(shareLink: false); },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.blue, size: 20)),
                const SizedBox(width: 14),
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Démarrer sans partager', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                  Text("Le lien reste dispo dans l'écran ride", style: TextStyle(fontSize: 12, color: Colors.white54)),
                ])),
                const Icon(Icons.chevron_right, color: Colors.white24),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> stopTrackingImmediately() async {
    rideTimer?.cancel();
    await positionStream?.cancel(); positionStream = null;
    safetyUploadTimer?.cancel(); safetyUploadTimer = null;
    FlutterBackgroundService().invoke('stopService');
    WakelockPlus.disable();
    setState(() { rideIsPaused = true; });
  }

  Future<void> discardRide() async {
    try {
      safetyUploadTimer?.cancel();
      await positionStream?.cancel();
      rideTimer?.cancel();
      if (safetySessionId != null) {
        final s = Supabase.instance.client;
        await s.from('safety_positions').delete().eq('session_id', safetySessionId!);
        await s.from('safety_sessions').delete().eq('id', safetySessionId!);
      }
    } catch (e) { debugPrint('Erreur abandon ride : $e'); }
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
    initializeGps();
    // Décommenter si besoin de supprimer les préférences
    // _resetPrefs();
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
    final appDir    = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${appDir.path}/waypoint_photos');
    if (!await photosDir.exists()) await photosDir.create(recursive: true);
    final destPath  = '${photosDir.path}/wp_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
      builder: (modalContext) => StatefulBuilder(builder: (ctx, setModalState) => Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Mémoriser un point', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Text('Lat: $latitude  Long: $longitude', style: const TextStyle(fontSize: 12, color: Colors.white38)),
          const SizedBox(height: 20),
          const Text('Note', style: TextStyle(fontSize: 14, color: Colors.white54)),
          const SizedBox(height: 8),
          TextField(
            controller: noteController, style: const TextStyle(color: Colors.white), maxLines: 3,
            decoration: InputDecoration(filled: true, fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              hintText: 'Décris ce point...', hintStyle: const TextStyle(color: Colors.white38)),
          ),
          const SizedBox(height: 20),
          Row(children: [
            const Text('Photos', style: TextStyle(fontSize: 14, color: Colors.white54)),
            const SizedBox(width: 8),
            Text('${selectedPhotoPaths.length}/3', style: const TextStyle(fontSize: 12, color: Colors.white38)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            ...selectedPhotoPaths.map((path) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(File(path), width: 72, height: 72, fit: BoxFit.cover)),
                Positioned(top: 2, right: 2, child: GestureDetector(
                  onTap: () => setModalState(() => selectedPhotoPaths.remove(path)),
                  child: Container(width: 20, height: 20, decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 14, color: Colors.white)),
                )),
              ]),
            )),
            if (selectedPhotoPaths.length < 3)
              GestureDetector(
                onTap: () async {
                  final source = await showModalBottomSheet<ImageSource>(
                    context: ctx, backgroundColor: const Color(0xFF2A2A2A),
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                    builder: (c) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(leading: const Icon(Icons.camera_alt, color: Colors.white), title: const Text('Appareil photo', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(c, ImageSource.camera)),
                      ListTile(leading: const Icon(Icons.photo_library, color: Colors.white), title: const Text('Galerie', style: TextStyle(color: Colors.white)), onTap: () => Navigator.pop(c, ImageSource.gallery)),
                    ])),
                  );
                  if (source == null) return;
                  final picked = await _imagePicker.pickImage(source: source, imageQuality: 80, maxWidth: 1200);
                  if (picked != null) setModalState(() => selectedPhotoPaths.add(picked.path));
                },
                child: Container(width: 72, height: 72,
                  decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white24)),
                  child: const Icon(Icons.add_a_photo, color: Colors.white38, size: 28)),
              ),
          ]),
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32))),
            onPressed: () async {
              final lat = double.tryParse(latitude);
              final lng = double.tryParse(longitude);
              if (lat == null || lng == null) return;
              final List<String> permanentPaths = [];
              for (final path in selectedPhotoPaths) permanentPaths.add(await _copyPhotoToPermanentDir(path));
              setState(() { rideWaypoints.add({'lat': lat, 'lng': lng, 'note': noteController.text.trim(), 'timestamp': DateTime.now().toIso8601String(), 'photos': permanentPaths}); });
              Navigator.of(modalContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Point mémorisé !')));
            },
            icon: const Icon(Icons.place),
            label: const Text('Mémoriser', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          )),
        ]),
      )),
    );
  }

  String generateShareCode() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(Iterable.generate(8, (_) => chars.codeUnitAt(random.nextInt(chars.length))));
  }

  Future<void> uploadSafetyPosition() async {
    if (safetySessionId == null || currentPosition == null) return;
    await Supabase.instance.client.from('safety_positions').insert({'session_id': safetySessionId, 'latitude': currentPosition!.latitude, 'longitude': currentPosition!.longitude});
  }

  void startSafetyUploadTimer() {
    safetyUploadTimer = Timer.periodic(const Duration(seconds: 15), (_) async { await uploadSafetyPosition(); });
  }

  Future<void> createSafetySession() async {
    final shareCode = generateShareCode();
    final response  = await Supabase.instance.client.from('safety_sessions').insert({'share_code': shareCode, 'status': 'in_progress'}).select().single();
    safetySessionId = response['id'];
    safetyShareCode = shareCode;
    safetyUrl       = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    startSafetyUploadTimer();
  }

  Future<void> shareSafetyLink() async {
    if (safetyShareCode == null) return;
    final url     = 'https://sunday-tracker-live.web.app/?code=$safetyShareCode';
    final message = 'Je démarre une sortie avec Sunday Tracker.\n\nTu peux consulter ma dernière position connue ici :\n\n$url';
    await Share.share(message, subject: 'Sunday Tracker Safety Beacon');
  }

  Future<void> _showExitRideModal() async {
    final nav = Navigator.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (modalContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Quitter la sortie ?', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 12),
          const Text('Que souhaitez-vous faire ?', style: TextStyle(fontSize: 16, color: Colors.white70)),
          const SizedBox(height: 32),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.of(modalContext).pop(),
            child: const Text('Continuer', style: TextStyle(color: Color(0xFFD0BCFF), fontSize: 18)))),
          Align(alignment: Alignment.centerRight, child: TextButton(
            onPressed: () async { Navigator.of(modalContext).pop(); await cancelRide(); if (!mounted) return; nav.pop(); },
            child: const Text('Terminer sans sauvegarder', style: TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.w600)),
          )),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: ElevatedButton(
            onPressed: () async { Navigator.of(modalContext).pop(); await saveRide(); if (!mounted) return; nav.pop(); },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF5A4F), foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32))),
            child: const Text('Sauvegarder et quitter', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          )),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  Future<void> cancelRide() async {
    safetyUploadTimer?.cancel();
    await positionStream?.cancel();
    rideTimer?.cancel();
    if (safetySessionId != null) {
      final s = Supabase.instance.client;
      await s.from('safety_positions').delete().eq('session_id', safetySessionId!);
      await s.from('safety_sessions').delete().eq('id', safetySessionId!);
    }
  }

  Future<void> togglePauseRide() async {
    if (!rideIsPaused) {
      await positionStream?.cancel(); positionStream = null;
      rideTimer?.cancel(); safetyUploadTimer?.cancel();
      setState(() { rideIsPaused = true; });
      await Supabase.instance.client.from('safety_sessions').update({'status': 'paused'}).eq('id', safetySessionId!);
      return;
    }
    rideStartTime = DateTime.now().subtract(rideDuration);
    rideTimer = Timer.periodic(const Duration(seconds: 1), (_) { setState(() { rideDuration = DateTime.now().difference(rideStartTime!); }); });
    await startTracking();
    startSafetyUploadTimer();
    setState(() { rideIsPaused = false; });
    await Supabase.instance.client.from('safety_sessions').update({'status': 'in_progress'}).eq('id', safetySessionId!);
  }

  Future<void> saveRide() async {
    if (_weatherFetched) _weatherSnapshotEnd = _currentWeatherSnapshot();
    final box          = await Hive.openBox('rides');
    final locationTags = await getRideLocationTags();
    final start  = (rideStartTime ?? DateTime.now()).toLocal();
    final months = ['jan','fév','mar','avr','mai','juin','juil','aoû','sep','oct','nov','déc'];
    final days   = ['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'];
    final day    = days[start.weekday - 1];
    final hour   = start.hour;
    final moment = hour < 6 ? 'nuit' : hour < 12 ? 'matin' : hour < 14 ? 'midi' : hour < 18 ? 'après-midi' : hour < 21 ? 'soir' : 'nuit';
    final autoName = 'Sortie du $day ${start.day} ${months[start.month - 1]} ${start.year} · $moment';
    await box.add({
      'name':                 autoName,
      'startTime':            rideStartTime?.toIso8601String(),
      'endTime':              DateTime.now().toIso8601String(),
      'durationSeconds':      rideDuration.inSeconds,
      'distanceMeters':       totalDistance,
      'totalElevationMeters': _dPlus,
      'maxSpeedKmh':          _maxSpeedKmh,
      'avgSpeedKmh':          _avgSpeedKmh,
      'maxSlopePercent':      _maxSlopePercent,
      'weatherStart':         _weatherSnapshotStart,
      'weatherEnd':           _weatherSnapshotEnd,
      'sunriseTime':          _sunriseTime?.toIso8601String(),
      'sunsetTime':           _sunsetTime?.toIso8601String(),
      'city':                 locationTags['city'],
      'department':           locationTags['department'],
      'region':               locationTags['region'],
      'safetySessionId':      safetySessionId,
      'safetyShareCode':      safetyShareCode,
      'points':               ridePoints.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      'waypoints':            rideWaypoints,
    });
    await Supabase.instance.client
        .from('safety_sessions')
        .update({'status': 'finished', 'ended_at': DateTime.now().toIso8601String()})
        .eq('id', safetySessionId!);
  }

  Future<void> startTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: kDebugMode ? 0 : 5),
    ).listen((Position position) {
      currentPosition = position;
      final newPoint  = LatLng(position.latitude, position.longitude);
      setState(() {
        gpsIsReady = position.accuracy <= 15;
        latitude   = position.latitude.toString();
        longitude  = position.longitude.toString();
        altitude   = position.altitude.toStringAsFixed(1);
        accuracy   = position.accuracy.toStringAsFixed(1);
        _updateSpeedAndElevation(position);
      });
      if (mapReady) mapController.move(newPoint, 16);
      if (position.accuracy > 20) return;
      if (ridePoints.isNotEmpty) {
        final lastPoint = ridePoints.last;
        final distance  = distanceCalculator.as(LengthUnit.Meter, lastPoint, newPoint);
        final dt        = (_lastPointTimestamp != null && position.timestamp != null) ? position.timestamp!.difference(_lastPointTimestamp!).inSeconds.abs() : 1;
        if (distance > (50.0 * max(dt, 1)) + (position.accuracy * 5)) return;
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
    } catch (_) { return {'city': '', 'department': '', 'region': ''}; }
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

  Future<void> handleBackPressed() async {
    if (!rideIsStarted) { Navigator.of(context).pop(); return; }
    await _showExitRideModal();
  }

  // ── UI helpers ────────────────────────────────────────────────
  String _rideStatusTitle()     { if (!rideIsStarted) return 'Nouveau ride'; if (rideIsPaused) return 'Ride en pause'; return 'Ride en cours'; }
  String? _rideStatusSubtitle() { if (!rideIsStarted) return null; if (rideIsPaused) return 'Suivi suspendu'; return 'Suivi en direct'; }
  Color _rideStatusColor()      { if (!rideIsStarted) return Colors.blue; if (rideIsPaused) return Colors.orange; return Colors.green; }

  Color _gpsBadgeColor() {
    if (rideIsPaused) return Colors.white38;
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 15) return Colors.green; if (v <= 30) return Colors.orange; return Colors.red;
  }
  String _gpsBadgeLabel() {
    if (rideIsPaused) return 'GPS off';
    final v = double.tryParse(accuracy) ?? 999;
    if (v <= 15) return 'GPS actif'; if (v <= 30) return 'GPS moyen'; return 'GPS faible';
  }

  void _showGpsDetailsDialog() {
    showDialog(context: context, builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: _gpsBadgeColor().withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(Icons.satellite_alt, color: _gpsBadgeColor(), size: 18)),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Détails GPS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            Text(_gpsBadgeLabel(), style: TextStyle(fontSize: 12, color: _gpsBadgeColor())),
          ]),
        ]),
        const SizedBox(height: 16),
        Container(height: 1, color: Colors.white12), const SizedBox(height: 14),
        _gpsRow(Icons.public,    'Latitude',  latitude),       const SizedBox(height: 10),
        _gpsRow(Icons.language,  'Longitude', longitude),      const SizedBox(height: 10),
        _gpsRow(Icons.terrain,   'Altitude',  '$altitude m'),  const SizedBox(height: 10),
        _gpsRow(Icons.gps_fixed, 'Précision', '$accuracy m',  valueColor: _gpsBadgeColor()),
        const SizedBox(height: 16),
        Container(height: 1, color: Colors.white12), const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _legendDot(Colors.green,  '≤ 15 m'),
          _legendDot(Colors.orange, '15–30 m'),
          _legendDot(Colors.red,    '> 30 m'),
        ]),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: TextButton(onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Fermer', style: TextStyle(color: Color(0xFFD0BCFF))))),
      ])),
    ));
  }

  Widget _legendDot(Color color, String label) => Row(children: [
    Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
  ]);

  Widget _gpsRow(IconData icon, String label, String value, {Color? valueColor}) => Row(children: [
    Icon(icon, color: Colors.lightBlue, size: 14), const SizedBox(width: 6),
    Text('$label : ', style: const TextStyle(fontSize: 12, color: Colors.white54)),
    Expanded(child: Text(value, style: TextStyle(fontSize: 12, color: valueColor ?? Colors.white70))),
  ]);

  // ── Carte ─────────────────────────────────────────────────────
  Widget _buildFlutterMap() {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: LatLng(double.tryParse(latitude) ?? 48.8566, double.tryParse(longitude) ?? 2.3522),
        initialZoom: rideIsStarted ? 15 : 14,
        onMapReady: () { mapReady = true; },
      ),
      children: [
        TileLayer(
          key: ValueKey(_mapStyleIndex),
          urlTemplate: (_mapStyles[_mapStyleIndex]['url'] ?? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png') as String,
          subdomains: ((_mapStyles[_mapStyleIndex]['subdomains']) as List?)?.cast<String>() ?? const <String>[],
          maxZoom: (((_mapStyles[_mapStyleIndex]['maxZoom']) ?? 19) as num).toDouble(),
          userAgentPackageName: 'com.example.sunday_tracker',
        ),
        if (rideIsStarted) PolylineLayer(polylines: [
          Polyline(points: ridePoints, strokeWidth: 14, color: Colors.orange.withValues(alpha: 0.25)),
          Polyline(points: ridePoints, strokeWidth: 6,  color: const Color(0xFFFFA726)),
        ]),
        MarkerLayer(markers: [
          Marker(
            point: LatLng(double.tryParse(latitude) ?? 48.8566, double.tryParse(longitude) ?? 2.3522),
            width: 24, height: 24,
            child: Container(decoration: BoxDecoration(
              shape: BoxShape.circle, color: Colors.red,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [BoxShadow(color: Colors.red.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 1)],
            )),
          ),
          ...rideWaypoints.map((wp) => Marker(point: LatLng(wp['lat'], wp['lng']), width: 36, height: 36, child: const Icon(Icons.place, color: Colors.blue, size: 36))),
        ]),
      ],
    );
  }

  Widget _buildMapOverlay() {
    return Stack(children: [
      Positioned(top: 8, right: 8,
        child: GestureDetector(
          onTap: _toggleMapCollapsed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_mapCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, color: Colors.white, size: 14),
              const SizedBox(width: 3),
              Text(_mapCollapsed ? 'Agrandir' : 'Réduire', style: const TextStyle(fontSize: 10, color: Colors.white)),
            ]),
          ),
        ),
      ),
      if (!_mapCollapsed) ...[
        Positioned(bottom: 10, left: 10,
          child: Container(
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(20)),
            padding: const EdgeInsets.all(3),
            child: Row(mainAxisSize: MainAxisSize.min, children: List.generate(_mapStyles.length, (i) {
              final style    = _mapStyles[i];
              final isActive = i == _mapStyleIndex;
              return GestureDetector(
                onTap: () { setState(() => _mapStyleIndex = i); _saveMapStyle(i); },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: isActive ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(16)),
                  child: Row(children: [
                    Icon(style['icon'] as IconData, size: 13, color: isActive ? Colors.black : Colors.white70),
                    if (isActive) ...[const SizedBox(width: 4), Text(style['label'] as String, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black))],
                  ]),
                ),
              );
            })),
          ),
        ),
        Positioned(bottom: 10, right: 10,
          child: GestureDetector(
            onTap: () => setState(() => _mapFullscreen = !_mapFullscreen),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(10)),
              child: Icon(_mapFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white, size: 20),
            ),
          ),
        ),
      ],
    ]);
  }

  // ═══════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async { await handleBackPressed(); return false; },
      child: Stack(children: [
        Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D0D0D), elevation: 0,
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: handleBackPressed),
            title: Column(children: [
              Text(_rideStatusTitle(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              if (_rideStatusSubtitle() != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 7, height: 7, decoration: BoxDecoration(color: _rideStatusColor(), shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(_rideStatusSubtitle()!, style: TextStyle(fontSize: 12, color: _rideStatusColor())),
                ]),
            ]),
            centerTitle: true,
            actions: const [],
          ),

          body: gpsIsInitializing
            ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CircularProgressIndicator(), SizedBox(height: 24),
                Text('Initialisation GPS...', style: TextStyle(fontSize: 18, color: Colors.white)),
              ]))
            : Column(children: [

                // ── CARTE ────────────────────────────────────────────
                if (!rideIsStarted)
                  Expanded(child: Stack(clipBehavior: Clip.hardEdge, children: [
                    _buildFlutterMap(),
                    _buildMapOverlay(),
                  ]))
                else
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOut,
                    height: _mapCollapsed ? 32 : 200,
                    child: Stack(clipBehavior: Clip.hardEdge, children: [
                      _buildFlutterMap(),
                      _buildMapOverlay(),
                    ]),
                  ),

                // ── PENDANT LE RIDE ──────────────────────────────────
                if (rideIsStarted)
                  Expanded(child: Stack(children: [
                    Column(children: [
                    Expanded(child: CustomScrollView(slivers: [

                      SliverToBoxAdapter(child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        child: _buildNotificationZone(),
                      )),

                      SliverReorderableList(
                        itemCount: _blockIds.length,
                        onReorder: _onBlockReorder,
                        itemBuilder: (context, index) {
                          final id = _blockIds[index];

                          // 'sun' et 'dist' sont rendus dans leur paire — on les skip
                          if (id == 'sun' || id == 'dist') {
                            return SizedBox.shrink(key: ValueKey(id));
                          }

                          Widget child;

                          // Paire weather/sun
                          if (id == 'weather') {
                            final sunIdx = _blockIds.indexOf('sun');
                            final first  = sunIdx < index ? 'sun' : 'weather';
                            final second = sunIdx < index ? 'weather' : 'sun';
                            child = Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Expanded(child: _buildBlockById(first,  index: index)),
                                const SizedBox(width: 6),
                                Expanded(child: _buildBlockById(second, index: index)),
                              ]),
                            );
                          }
                          // Paire duree/dist
                          else if (id == 'duree') {
                            final distIdx = _blockIds.indexOf('dist');
                            final first  = distIdx < index ? 'dist' : 'duree';
                            final second = distIdx < index ? 'duree' : 'dist';
                            child = Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Expanded(child: _buildBlockById(first,  index: index)),
                                const SizedBox(width: 6),
                                Expanded(child: _buildBlockById(second, index: index)),
                              ]),
                            );
                          }
                          // Blocs simples
                          else {
                            child = Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                              child: _buildBlockById(id, index: index),
                            );
                          }

                          return Material(
                            key: ValueKey(id),
                            color: Colors.transparent,
                            child: child,
                          );
                        },
                      ),

                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    ])),

                    // ── Boutons fixes ──────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(width: double.infinity, child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: rideIsPaused ? Colors.green : Colors.blue,
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          onPressed: togglePauseRide,
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                              child: Icon(rideIsPaused ? Icons.play_arrow_rounded : Icons.pause_rounded, color: Colors.white, size: 22)),
                            const SizedBox(width: 12),
                            Text(rideIsPaused ? 'Reprendre' : 'Pause', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                          ]),
                        )),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A1A1A), padding: const EdgeInsets.symmetric(vertical: 7), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                            onPressed: () async { await stopTrackingImmediately(); await _showExitRideModal(); },
                            child: Column(mainAxisSize: MainAxisSize.min, children: [Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.15), shape: BoxShape.circle), child: const Icon(Icons.stop, color: Colors.red, size: 15)), const SizedBox(height: 3), const Text('Arrêter', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))]),
                          )),
                          const SizedBox(width: 8),
                          Expanded(child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A1A1A), padding: const EdgeInsets.symmetric(vertical: 7), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                            onPressed: _showAddWaypointModal,
                            child: Column(mainAxisSize: MainAxisSize.min, children: [Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.15), shape: BoxShape.circle), child: const Icon(Icons.place, color: Colors.blue, size: 15)), const SizedBox(height: 3), const Text('Waypoint', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))]),
                          )),
                          const SizedBox(width: 8),
                          Expanded(child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 7), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                            onPressed: () {},
                            child: Column(mainAxisSize: MainAxisSize.min, children: [Container(width: 26, height: 26, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle), child: const Icon(Icons.emergency, color: Colors.white, size: 15)), const SizedBox(height: 3), const Text('SOS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white))]),
                          )),
                        ]),
                      ]),
                    ),
                    ]),

                  ])),

                // ── PRÉ-RIDE ─────────────────────────────────────────
                if (!rideIsStarted)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      _buildGpsBlock(),
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: gpsIsReady ? _showStartRideSheet : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: gpsIsReady ? null : const Color(0xFF1A1A1A),
                            gradient: gpsIsReady
                              ? const LinearGradient(colors: [Color(0xFF00C853), Color(0xFF00897B)], begin: Alignment.centerLeft, end: Alignment.centerRight)
                              : null,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                              child: Icon(gpsIsReady ? Icons.play_arrow_rounded : Icons.hourglass_empty, color: Colors.white, size: 24)),
                            const SizedBox(width: 12),
                            Text(gpsIsReady ? 'Démarrer la sortie' : 'Attente du signal GPS…',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                                color: gpsIsReady ? Colors.white : Colors.white38, letterSpacing: 0.3)),
                          ]),
                        ),
                      ),
                    ]),
                  ),
              ]),
        ),

        // ── Fullscreen overlay ────────────────────────────────────
        if (_mapFullscreen)
          Positioned.fill(child: Stack(clipBehavior: Clip.hardEdge, children: [
            _buildFlutterMap(),
            _buildMapOverlay(),
          ])),
      ]),
    );
  }
}