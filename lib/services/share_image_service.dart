import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sunday_tracker/widgets/ride_share_card.dart';

class ShareImageService {
  // Génère l'image de la carte de partage hors-écran via un OverlayEntry,
  // capture le RepaintBoundary et retourne le fichier PNG résultant.
  // Retourne null si la génération échoue (fallback texte seul).
  static Future<File?> generateImage(
    BuildContext context,
    Map<String, dynamic> ride,
    String rideName,
  ) async {
    final repaintKey = GlobalKey();

    // On utilise opacity: 0.01 (non-zéro) pour forcer le paint,
    // positionné hors-écran pour ne pas être visible.
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -2000,
        top:  -2000,
        width:  RideShareCard.kWidth,
        height: RideShareCard.kHeight,
        child: Opacity(
          opacity: 0.01,
          child: RepaintBoundary(
            key: repaintKey,
            child: RideShareCard(ride: ride, rideName: rideName),
          ),
        ),
      ),
    );

    if (!context.mounted) return null;
    Overlay.of(context).insert(entry);

    // Laisse Flutter effectuer un frame complet de layout + paint.
    await Future.delayed(const Duration(milliseconds: 1800));

    File? result;
    try {
      final renderObj = repaintKey.currentContext?.findRenderObject();
      if (renderObj is! RenderRepaintBoundary) return null;
      final image    = await renderObj.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final bytes = byteData.buffer.asUint8List();
      final dir   = await getTemporaryDirectory();
      final file  = File('${dir.path}/sunday_share_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);
      result = file;
    } catch (e) {
      debugPrint('[ShareImageService] $e');
    } finally {
      entry.remove();
    }

    return result;
  }
}
