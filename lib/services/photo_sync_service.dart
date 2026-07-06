import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Nom du bucket Supabase Storage (public) qui héberge les photos de waypoint.
const String kWaypointPhotosBucket = 'waypoint-photos';

// ─────────────────────────────────────────────────────────────────────────────
// MODÈLE PHOTO
//
// Une photo de waypoint est une map { 'local': <chemin fichier>, 'url': <http> }.
//   • 'local' : chemin du fichier sur CE téléphone (peut être mort après restore).
//   • 'url'   : URL publique Supabase (null tant que pas encore uploadée).
//
// Migration douce : l'ancien format était un simple String (chemin local).
// [normalizePhoto] absorbe les deux formats, donc rien ne casse.
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> normalizePhoto(dynamic p) {
  if (p is String) return {'local': p, 'url': null};
  if (p is Map) return Map<String, dynamic>.from(p);
  return {'local': null, 'url': null};
}

String? photoLocalPath(dynamic p) => normalizePhoto(p)['local'] as String?;
String? photoUrl(dynamic p) => normalizePhoto(p)['url'] as String?;

/// Fournit l'ImageProvider adapté : le fichier local s'il existe (rapide, 0 data),
/// sinon l'URL distante (cas d'une sortie restaurée sur un autre téléphone).
ImageProvider? photoImageProvider(dynamic p) {
  final n = normalizePhoto(p);
  final local = n['local'] as String?;
  final url = n['url'] as String?;
  if (local != null && File(local).existsSync()) return FileImage(File(local));
  if (url != null) return NetworkImage(url);
  if (local != null) return FileImage(File(local)); // dernier recours
  return null;
}

/// Widget d'affichage d'une photo, avec fallback local ↔ réseau centralisé.
Widget photoWidget(dynamic entry,
    {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  final provider = photoImageProvider(entry);
  if (provider == null) {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF2A2A2A),
      child: const Icon(Icons.broken_image, color: Colors.white24),
    );
  }
  return Image(
    image: provider,
    width: width,
    height: height,
    fit: fit,
    loadingBuilder: (ctx, child, progress) {
      if (progress == null) return child;
      return Container(
        width: width,
        height: height,
        color: const Color(0xFF2A2A2A),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
        ),
      );
    },
    errorBuilder: (ctx, err, stack) => Container(
      width: width,
      height: height,
      color: const Color(0xFF2A2A2A),
      child: const Icon(Icons.broken_image, color: Colors.white24),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// UPLOAD / STORAGE
// ─────────────────────────────────────────────────────────────────────────────

String _sanitize(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

/// Uploade un fichier local vers le Storage et renvoie son URL publique.
/// Chemin déterministe + upsert → idempotent (retentable sans doublon).
Future<String?> _uploadOne(String userId, String rideId, String localPath) async {
  final file = File(localPath);
  if (!await file.exists()) return null;
  final fileName = localPath.split(RegExp(r'[\\/]')).last;
  final objectPath = '$userId/${_sanitize(rideId)}/$fileName';
  final storage = Supabase.instance.client.storage.from(kWaypointPhotosBucket);
  await storage.upload(
    objectPath,
    file,
    fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
  );
  return storage.getPublicUrl(objectPath);
}

/// Supprime une photo du Storage à partir de son URL publique.
Future<void> deletePhotoRemote(String url) async {
  final marker = '/$kWaypointPhotosBucket/';
  final idx = url.indexOf(marker);
  if (idx == -1) return;
  final objectPath = url.substring(idx + marker.length);
  await Supabase.instance.client.storage
      .from(kWaypointPhotosBucket)
      .remove([objectPath]);
}

/// Purge tout le dossier Storage d'un ride (`$userId/$rideId/`).
///
/// Plus robuste que la suppression photo-par-photo via URL : attrape aussi les
/// fichiers orphelins (upload réussi mais URL jamais persistée dans Hive).
/// Best-effort : toute erreur est avalée (hors-ligne, dossier déjà vide…).
Future<void> deleteRidePhotosFolder(String userId, String rideId) async {
  try {
    final storage = Supabase.instance.client.storage.from(kWaypointPhotosBucket);
    final prefix = '$userId/${_sanitize(rideId)}';
    final objects = await storage.list(path: prefix);
    if (objects.isEmpty) return;
    final paths = objects.map((o) => '$prefix/${o.name}').toList();
    await storage.remove(paths);
  } catch (e) {
    debugPrint('[PHOTO_SYNC] deleteRidePhotosFolder $rideId: $e');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BALAYEUR
//
// Parcourt tous les rides du box Hive et uploade les photos non encore
// synchronisées (url == null) dont le fichier local existe encore.
// Sûr hors-ligne : toute erreur est avalée, on retentera au prochain passage.
// Idempotent : une photo déjà uploadée est ignorée.
// ─────────────────────────────────────────────────────────────────────────────

bool _running = false;

Future<void> syncPendingPhotos() async {
  if (_running) return; // évite les passages concurrents
  _running = true;
  try {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    if (!Hive.isBoxOpen('rides')) return;
    final box = Hive.box('rides');

    for (final key in box.keys.toList()) {
      final ride = box.get(key);
      if (ride is! Map) continue;
      final rideId = ride['startTime'] as String?;
      if (rideId == null) continue;
      final waypoints = (ride['waypoints'] as List?) ?? const [];
      var changed = false;

      for (final wp in waypoints) {
        if (wp is! Map) continue;
        final rawPhotos = wp['photos'] as List?;
        if (rawPhotos == null) continue;
        // Normalise toute la liste (l'ancien format stockait des String) : on ne
        // peut pas réécrire une Map dans une List<String> figée par Hive, donc on
        // travaille sur une liste neuve de maps qu'on réaffecte à la fin.
        final photos = rawPhotos.map(normalizePhoto).toList();
        var wpChanged = false;
        for (final n in photos) {
          if (n['url'] != null) continue; // déjà uploadée
          final local = n['local'] as String?;
          if (local == null || !File(local).existsSync()) continue; // rien à envoyer
          try {
            final url = await _uploadOne(userId, rideId, local);
            if (url != null) {
              n['url'] = url;
              wpChanged = true;
            }
          } catch (e) {
            debugPrint('[PHOTO_SYNC] upload $local: $e');
            // on continue, on retentera plus tard
          }
        }
        if (wpChanged) {
          wp['photos'] = photos; // remplace par la liste normalisée (List<Map>)
          changed = true;
        }
      }

      if (changed) {
        await box.put(key, ride);
        try {
          await client.from('rides').upsert(
            {'user_id': userId, 'started_at': rideId, 'ride_json': ride},
            onConflict: 'user_id,started_at',
          );
          // Re-pousse la charge live allégée : sans ça, safety_sessions.ride_json
          // reste figé à sa valeur du finish (photos `url: null`) et les photos
          // fraîchement uploadées n'atteignent JAMAIS le viewer web (qui ne lit
          // que la session, pas la table `rides`). Miroir de liveSessionRideJson().
          final sessionId = ride['safetySessionId'] as String?;
          if (sessionId != null) {
            await client.from('safety_sessions').update({
              'ride_json': {
                'points': ride['points'],
                'waypoints': ride['waypoints'],
                'distanceMeters': ride['distanceMeters'],
                'durationSeconds': ride['durationSeconds'],
              },
            }).eq('id', sessionId);
          }
        } catch (e) {
          debugPrint('[PHOTO_SYNC] upsert ride $rideId: $e');
        }
      }
    }
  } finally {
    _running = false;
  }
}
