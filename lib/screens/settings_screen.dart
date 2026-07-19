import 'package:flutter/material.dart';

import '../services/ride_settings_service.dart';

/// Écran « Paramètres » : réglages liés à l'enregistrement des sorties.
///
/// Étape 1 : la carte « Mode automatique » (détection des pauses et reprises)
/// dont l'état est persisté via [RideSettingsService]. Le comportement associé
/// est décrit et branché à l'étape 2.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

const _kBg = Color(0xFF0D0D0D);
const _kCard = Color(0xFF161616);
const _kAccent = Color(0xFFFF8A00);

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoPause = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await RideSettingsService.isAutoPauseEnabled();
    if (!mounted) return;
    setState(() {
      _autoPause = enabled;
      _loading = false;
    });
  }

  Future<void> _toggleAutoPause(bool value) async {
    setState(() => _autoPause = value);
    await RideSettingsService.setAutoPauseEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Paramètres',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kAccent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _sectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionHeader(),
                      const SizedBox(height: 20),
                      _autoModeToggle(),
                      const SizedBox(height: 14),
                      const Text(
                        'Les pauses et reprises sont détectées automatiquement '
                        'pendant l\'enregistrement de votre sortie.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _behaviorRow(
                        icon: Icons.pause_rounded,
                        color: const Color(0xFFF97316),
                        title: 'Pause détectée',
                        subtitle:
                            'Le suivi se met automatiquement en pause dès que '
                            'vous vous arrêtez.',
                      ),
                      const SizedBox(height: 14),
                      _behaviorRow(
                        icon: Icons.play_arrow_rounded,
                        color: const Color(0xFF8B5CF6),
                        title: 'Reprise détectée',
                        subtitle:
                            'Le suivi reprend automatiquement dès que vous '
                            'repartez.',
                      ),
                      const SizedBox(height: 18),
                      _infoFooter(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: child,
    );
  }

  Widget _sectionHeader() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _kAccent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.settings, color: _kAccent, size: 22),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Text(
            'Enregistrement des sorties',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _autoModeToggle() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Mode automatique',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Switch(
          value: _autoPause,
          onChanged: _toggleAutoPause,
          activeThumbColor: Colors.white,
          activeTrackColor: _kAccent,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: const Color(0xFF3A3A3A),
        ),
      ],
    );
  }

  Widget _behaviorRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    // Grisé quand le mode auto est coupé : on garde l'explication visible mais
    // on signale qu'elle est inactive.
    final dim = !_autoPause;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (dim ? Colors.grey : color).withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: dim ? Colors.grey : color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: dim ? Colors.white38 : Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: dim ? Colors.white24 : Colors.white54,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoFooter() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF14121A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline,
              color: Color(0xFF8B5CF6), size: 18),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Vous pouvez toujours ajuster manuellement votre sortie après '
              'l\'enregistrement si besoin.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
