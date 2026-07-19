import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'home_screen.dart';

/// Splash animé « révélation topographique ».
///
/// L'écran final est exactement l'artwork `flutter_splash.png` (affiché en
/// pleine largeur, centré — comme avant). L'animation ne redessine rien : elle
/// découpe cette image en trois bandes (logo / nom+baseline / topo) et les
/// révèle l'une après l'autre. Le logo part du centre de l'écran et remonte à
/// sa place, le nom apparaît en fondu, puis la topo se dévoile de gauche à
/// droite.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _c; // révélation
  late final AnimationController _out; // effacement du splash

  bool _gone = false; // splash retiré : l'accueil reprend la main
  ui.Image? _art;

  late final Animation<double> _rise;
  late final Animation<double> _titleIn;
  late final Animation<double> _taglineIn;
  late final Animation<double> _topo;

  @override
  void initState() {
    super.initState();
    // NB : on ne retire PAS le splash natif ici. Il reste affiché (couvrant le
    // chargement de l'image) jusqu'à ce que la première frame Flutter — logo
    // calé exactement dessus — soit peinte, sinon la montée démarre en coulisse
    // pendant que le natif est encore visible → le logo « saute » au raccord.

    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _out = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );

    Animation<double> seg(double a, double b, Curve curve) =>
        CurvedAnimation(parent: _c, curve: Interval(a, b, curve: curve));

    // Pose du logo (~0,5 s), puis montée longue et douce ; le nom, la baseline
    // et la topo s'enchaînent avec recouvrement pour un rendu continu.
    _rise = seg(0.18, 0.50, Curves.easeInOutCubic);
    _titleIn = seg(0.40, 0.62, Curves.easeOut);
    _taglineIn = seg(0.50, 0.72, Curves.easeOut);
    _topo = seg(0.60, 1.0, Curves.easeOut);

    _loadArt();
  }

  Future<void> _loadArt() async {
    final data = await rootBundle.load('assets/images/flutter_splash.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => _art = frame.image);
    // On attend que la première frame (logo calé sur le splash natif, rise = 0)
    // soit réellement peinte AVANT de lancer la montée : sinon l'animation a
    // déjà progressé quand le splash Flutter devient visible → le logo « saute ».
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  /// L'accueil est construit sous le splash dès le lancement (son premier frame
  /// est lourd) : à la fin, le splash s'efface simplement dessus.
  Future<void> _play() async {
    // La frame Flutter (logo calé sur le natif) vient d'être peinte : on peut
    // retirer le splash natif sans raccord visible.
    FlutterNativeSplash.remove();
    // Courte pose au point de raccord natif avant de démarrer la révélation.
    await Future.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    await _c.forward();
    await Future.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    await _out.forward();
    if (!mounted) return;
    setState(() => _gone = true);
  }

  @override
  void dispose() {
    _c.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // L'accueil se construit dès le lancement, masqué par le splash opaque.
        const HomeScreen(),
        if (!_gone)
          FadeTransition(
            opacity: Tween<double>(
              begin: 1,
              end: 0,
            ).animate(CurvedAnimation(parent: _out, curve: Curves.easeInOut)),
            child: Container(
              color: Colors.black,
              child: _art == null
                  ? null
                  : AnimatedBuilder(
                      animation: _c,
                      builder: (_, _) => CustomPaint(
                        size: Size.infinite,
                        painter: _SplashPainter(
                          art: _art!,
                          rise: _rise.value,
                          title: _titleIn.value,
                          tagline: _taglineIn.value,
                          topo: _topo.value,
                        ),
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

/// Dessine l'artwork bande par bande. Découpe relevée sur le PNG (1254 px) :
/// logo 120→658, nom 692→803, baseline 827→862, topo 902→1224.
class _SplashPainter extends CustomPainter {
  final ui.Image art;
  final double rise, title, tagline, topo;

  const _SplashPainter({
    required this.art,
    required this.rise,
    required this.title,
    required this.tagline,
    required this.topo,
  });

  // Frontières des bandes, en pixels image (à mi-chemin entre les éléments).
  static const double _logoTop = 0;
  static const double _logoBot = 675;
  static const double _titleBot = 812;
  static const double _taglineBot = 884;
  static const double _artH = 1254;

  // Le splash natif (splash.png) affiche le logo un peu plus GROS et plus BAS
  // que sa place dans l'artwork. Pour que le raccord natif→Flutter soit
  // invisible, le logo démarre calé sur ces valeurs (mesurées à l'écran) puis
  // se réduit et remonte jusqu'à sa position finale.
  static const double _logoStartScale = 1.09; // taille native / taille finale
  static const double _logoStartCy = 0.500; // centre vertical natif (frac. écran)
  static const double _logoImgCy = (120 + 658) / 2; // centre du logo dans l'image

  @override
  void paint(Canvas canvas, Size size) {
    final iw = art.width.toDouble(), ih = art.height.toDouble();
    final scale = size.width / iw; // pleine largeur, comme l'image d'origine
    final top = (size.height - ih * scale) / 2; // centrée verticalement

    void band(double y0, double y1, double opacity, {double offsetY = 0}) {
      if (opacity <= 0) return;
      canvas.drawImageRect(
        art,
        Rect.fromLTWH(0, y0, iw, y1 - y0),
        Rect.fromLTWH(
          0,
          top + y0 * scale + offsetY,
          size.width,
          (y1 - y0) * scale,
        ),
        Paint()..color = Colors.white.withValues(alpha: opacity.clamp(0, 1)),
      );
    }

    // Logo : interpolation taille + centre, du raccord natif vers la position
    // finale. On dessine la bande à sa place naturelle, puis on applique une
    // homothétie autour de son centre pour la faire grossir/descendre au début.
    final cx = size.width / 2;
    final cyFinal = top + _logoImgCy * scale;
    final s = ui.lerpDouble(_logoStartScale, 1.0, rise)!;
    final cy = ui.lerpDouble(_logoStartCy * size.height, cyFinal, rise)!;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(s);
    canvas.translate(-cx, -cyFinal);
    band(_logoTop, _logoBot, 1);
    canvas.restore();

    // Nom, puis baseline : fondu + léger glissement vers le haut.
    band(_logoBot, _titleBot, title, offsetY: 10 * (1 - title));
    band(_titleBot, _taglineBot, tagline, offsetY: 8 * (1 - tagline));

    // Topo : fondu doux + léger glissement vers le haut (comme la référence,
    // qui ne « balaie » pas mais révèle la bande d'un bloc en fondu).
    band(_taglineBot, _artH, topo, offsetY: 12 * (1 - topo));
  }

  @override
  bool shouldRepaint(_SplashPainter old) =>
      old.rise != rise ||
      old.title != title ||
      old.tagline != tagline ||
      old.topo != topo ||
      old.art != art;
}
