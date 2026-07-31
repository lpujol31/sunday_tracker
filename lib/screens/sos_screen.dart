import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/sos_profile.dart';
import '../services/sos_lock_service.dart';

/// Fiche SOS plein écran.
///
/// Elle est pensée pour être lue par **quelqu'un d'autre** que l'utilisateur :
/// un passant, un secouriste. D'où le parti pris graphique — fond noir,
/// contrastes maximum, gros corps de texte, une info par bloc — et l'ordre
/// des blocs : identité, médical, qui appeler, où on est.
class SosScreen extends StatefulWidget {
  final SosProfile profile;

  /// Dernière position GPS connue et son horodatage (heure du fix, pas
  /// l'heure d'affichage). Null tant qu'aucun fix n'est arrivé.
  final double? latitude;
  final double? longitude;
  final DateTime? lastFixAt;

  /// Niveau de batterie en % — un secouriste doit savoir combien de temps
  /// le téléphone (donc le suivi live) va tenir.
  final int? batteryLevel;

  /// Lien de partage live de la sortie, s'il est actif.
  final String? liveUrl;

  const SosScreen({
    super.key,
    required this.profile,
    this.latitude,
    this.longitude,
    this.lastFixAt,
    this.batteryLevel,
    this.liveUrl,
  });

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen>
    with SingleTickerProviderStateMixin {
  static const Color _red = Color(0xFFE53935);
  static const Color _redDark = Color(0xFFB71C1C);

  late final AnimationController _pulse;

  // ── Verrouillage écran (test de faisabilité) ────────────────────
  bool _adminActive = false;
  bool _keyguardLocked = false;
  bool _keyguardSecure = false;
  Timer? _keyguardPoll;
  // L'auto-verrouillage ne se déclenche qu'une fois par ouverture : sinon on
  // reverrouille dans le dos de l'utilisateur dès qu'il déverrouille pour lire.
  bool _autoLockDone = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    // Retour haptique fort : confirme que le SOS est bien parti même si
    // l'écran n'est pas sous les yeux.
    HapticFeedback.heavyImpact();
    _initLockScreen();
  }

  @override
  void dispose() {
    _keyguardPoll?.cancel();
    // Impératif : sans ça toute l'appli resterait affichable par-dessus l'écran
    // de verrouillage après la fermeture de la fiche.
    SosLockService.showOverLockScreen(false);
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _initLockScreen() async {
    // 1. Autoriser l'affichage par-dessus le verrou AVANT de verrouiller,
    //    sinon on se retrouve derrière l'écran de veille.
    await SosLockService.showOverLockScreen(true);
    final admin = await SosLockService.isAdminActive();
    if (!mounted) return;
    setState(() => _adminActive = admin);

    // 2. Sonde l'état du verrou : c'est la preuve visible que le téléphone est
    //    bien verrouillé alors que la fiche reste lisible.
    _keyguardPoll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final st = await SosLockService.keyguardState();
      if (!mounted) return;
      setState(() {
        _keyguardLocked = st.locked;
        _keyguardSecure = st.secure;
      });
    });

    // 3. Verrouillage automatique, laissé le temps de voir la fiche s'ouvrir.
    if (admin && !_autoLockDone) {
      _autoLockDone = true;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      await SosLockService.lockNow();
    }
  }

  Future<void> _lock({required bool turnScreenOn}) async {
    await SosLockService.showOverLockScreen(true, turnScreenOn: turnScreenOn);
    final ok = await SosLockService.lockNow();
    if (ok || !mounted) return;
    await SosLockService.requestAdmin();
  }

  Future<void> _dial(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Impossible de composer le $number')),
      );
    }
  }

  String get _coords {
    final lat = widget.latitude;
    final lng = widget.longitude;
    if (lat == null || lng == null) return 'Position inconnue';
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }

  Future<void> _copyCoords() async {
    if (widget.latitude == null) return;
    await Clipboard.setData(ClipboardData(text: _coords));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coordonnées copiées')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return PopScope(
      // On ne sort pas d'un SOS par un swipe accidentel : seul le bouton
      // « Fermer l'alerte » en bas de page ferme la fiche.
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _header(),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomPad),
                  children: [
                    if (SosLockService.isSupported) ...[
                      _lockStatusChip(),
                      const SizedBox(height: 14),
                    ],
                    _identity(p),
                    const SizedBox(height: 14),
                    if (p.bloodType != null || p.medicalNotes.isNotEmpty)
                      _medical(p),
                    if (p.bloodType != null || p.medicalNotes.isNotEmpty)
                      const SizedBox(height: 14),
                    _emergencyCall(),
                    const SizedBox(height: 14),
                    ...p.contacts.map(_contactTile),
                    const SizedBox(height: 14),
                    _position(),
                    if (SosLockService.isSupported) ...[
                      const SizedBox(height: 14),
                      _lockTestPanel(),
                    ],
                    const SizedBox(height: 24),
                    _closeButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Bandeau haut : clignote pour être vu de loin ────────────────
  Widget _header() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        return Container(
          width: double.infinity,
          color: Color.lerp(_redDark, _red, _pulse.value),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          child: child,
        );
      },
      child: const Column(
        children: [
          Text(
            'SOS',
            style: TextStyle(
              fontSize: 46,
              height: 1,
              fontWeight: FontWeight.w900,
              letterSpacing: 8,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'ALERTE EN COURS · FICHE D\'URGENCE',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  // ── Blocs ───────────────────────────────────────────────────────
  Widget _card({required Widget child, Color? border}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border ?? const Color(0xFF2A2A2A), width: 1.5),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _label(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
          color: Color(0xFF9E9E9E),
        ),
      );

  Widget _identity(SosProfile p) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Identité'),
          const SizedBox(height: 8),
          Text(
            p.fullName,
            style: const TextStyle(
              fontSize: 32,
              height: 1.1,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${p.age} ans',
            style: const TextStyle(fontSize: 19, color: Color(0xFFCFCFCF)),
          ),
          if (p.address != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.home_outlined,
                    size: 19, color: Color(0xFF9E9E9E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.address!,
                    style: const TextStyle(
                        fontSize: 17, color: Color(0xFFCFCFCF), height: 1.3),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _medical(SosProfile p) {
    return _card(
      border: _redDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Informations médicales'),
          const SizedBox(height: 10),
          if (p.bloodType != null)
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _redDark,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    p.bloodType!,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Groupe sanguin',
                  style: TextStyle(fontSize: 17, color: Color(0xFFCFCFCF)),
                ),
              ],
            ),
          for (final note in p.medicalNotes) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Icon(Icons.circle, size: 7, color: _red),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    note,
                    style: const TextStyle(
                        fontSize: 18, color: Colors.white, height: 1.3),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _emergencyCall() {
    return SizedBox(
      height: 66,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _red,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: () => _dial('112'),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.call, color: Colors.white, size: 26),
            SizedBox(width: 12),
            Text(
              'Appeler le 112',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contactTile(SosContact c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _dial(c.dialable),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2A2A2A), width: 1.5),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    color: _redDark,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.phone, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${c.relation} · ${c.pretty}',
                        style: const TextStyle(
                            fontSize: 16, color: Color(0xFFCFCFCF)),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFF9E9E9E)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _position() {
    final at = widget.lastFixAt?.toLocal();
    final time = at == null ? '—' : DateFormat('HH:mm').format(at);
    final battery = widget.batteryLevel;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Dernière position connue'),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.schedule, size: 20, color: Color(0xFF9E9E9E)),
              const SizedBox(width: 10),
              Text(
                time,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              if (battery != null) ...[
                const SizedBox(width: 18),
                Icon(
                  battery <= 20
                      ? Icons.battery_alert
                      : Icons.battery_full,
                  size: 20,
                  color: battery <= 20 ? _red : const Color(0xFF9E9E9E),
                ),
                const SizedBox(width: 6),
                Text(
                  '$battery %',
                  style: const TextStyle(fontSize: 18, color: Color(0xFFCFCFCF)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _copyCoords,
            child: Row(
              children: [
                const Icon(Icons.place_outlined,
                    size: 20, color: Color(0xFF9E9E9E)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _coords,
                    style: const TextStyle(
                      fontSize: 19,
                      color: Colors.white,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (widget.latitude != null)
                  const Icon(Icons.copy, size: 18, color: Color(0xFF9E9E9E)),
              ],
            ),
          ),
          if (widget.liveUrl != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.share_location,
                    size: 20, color: Color(0xFF9E9E9E)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Suivi en direct actif',
                    style: TextStyle(fontSize: 17, color: Color(0xFFCFCFCF)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Test de faisabilité « écran verrouillé » ───────────────────
  // Ce bandeau est la preuve du test : s'il affiche VERROUILLÉ alors que tu
  // lis cette fiche, c'est que l'affichage par-dessus l'écran de veille
  // fonctionne. À retirer une fois la question tranchée.
  Widget _lockStatusChip() {
    final locked = _keyguardLocked;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: locked ? const Color(0xFF11321B) : const Color(0xFF141414),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: locked ? const Color(0xFF2E7D32) : const Color(0xFF2A2A2A),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            locked ? Icons.lock : Icons.lock_open,
            size: 20,
            color: locked ? const Color(0xFF4ADE80) : const Color(0xFF9E9E9E),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              locked
                  ? 'Téléphone VERROUILLÉ · fiche lisible'
                  : 'Téléphone déverrouillé',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: locked ? const Color(0xFF4ADE80) : const Color(0xFF9E9E9E),
              ),
            ),
          ),
          if (!_keyguardSecure)
            const Text(
              'sans code',
              style: TextStyle(fontSize: 13, color: Color(0xFFFFB300)),
            ),
        ],
      ),
    );
  }

  Widget _lockTestPanel() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Test écran verrouillé'),
          const SizedBox(height: 10),
          if (!_adminActive) ...[
            const Text(
              'Le verrouillage automatique demande une autorisation système '
              '(administrateur d\'appareil, droit « verrouiller l\'écran » '
              'uniquement). Sans elle, appuie sur le bouton power : la fiche '
              'doit rester affichée par-dessus l\'écran de veille.',
              style: TextStyle(
                  fontSize: 15, color: Color(0xFFCFCFCF), height: 1.35),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _redDark,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () async {
                  await SosLockService.requestAdmin();
                  final admin = await SosLockService.isAdminActive();
                  if (!mounted) return;
                  setState(() => _adminActive = admin);
                },
                child: const Text(
                  'Autoriser le verrouillage',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ] else ...[
            const Text(
              'Deux variantes à comparer sur l\'appareil : sans rallumage, '
              'l\'écran s\'éteint et il faut appuyer sur power ; avec, l\'écran '
              'doit se rallumer seul sur la fiche.',
              style: TextStyle(
                  fontSize: 15, color: Color(0xFFCFCFCF), height: 1.35),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _lockButton(
                    'Verrouiller',
                    () => _lock(turnScreenOn: false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _lockButton(
                    'Verrouiller + rallumer',
                    () => _lock(turnScreenOn: true),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _lockButton(String label, VoidCallback onPressed) {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFF3A3A3A), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _closeButton() {
    return SizedBox(
      height: 54,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFF3A3A3A), width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(
          'Fermer l\'alerte',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF9E9E9E),
          ),
        ),
      ),
    );
  }
}
