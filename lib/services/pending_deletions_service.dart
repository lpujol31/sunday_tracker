import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'photo_sync_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FILE DE SUPPRESSIONS EN ATTENTE
//
// Problème résolu : une suppression de sortie faite hors-ligne ne nettoyait
// jamais le serveur (les delete() échouaient en silence, sans reprise) et la
// sortie pouvait « ressusciter » au prochain refresh.
//
// Solution : on persiste chaque suppression dans un box Hive dédié, et on rejoue
// le nettoyage serveur (safety_positions → safety_sessions → rides → Storage)
// au premier moment utile : lancement de l'app, pull-to-refresh, ou suppression
// suivante. Idempotent (re-supprimer des lignes déjà parties = no-op) et
// offline-safe (en cas d'échec réseau, l'entrée reste et on retentera).
//
// Clé du box = startTime de la sortie (identité stable, comme partout ailleurs).
// ─────────────────────────────────────────────────────────────────────────────

const String kPendingDeletionsBox = 'pending_deletions';

Future<Box> _openBox() => Hive.openBox(kPendingDeletionsBox);

/// Enregistre une suppression à rejouer côté serveur.
Future<void> enqueueRideDeletion({
  required String startedAt,
  String? userId,
  String? safetySessionId,
}) async {
  final box = await _openBox();
  await box.put(startedAt, {
    'startedAt': startedAt,
    'userId': userId,
    'safetySessionId': safetySessionId,
    'queuedAt': DateTime.now().toIso8601String(),
  });
}

/// Ensemble des startTime encore en attente de suppression serveur.
/// Sert à filtrer le refresh pour éviter toute résurrection.
Set<String> pendingDeletionKeys() {
  if (!Hive.isBoxOpen(kPendingDeletionsBox)) return const {};
  return Hive.box(kPendingDeletionsBox).keys.map((k) => k.toString()).toSet();
}

bool _flushing = false;

/// Rejoue toutes les suppressions serveur en attente.
/// Offline-safe : toute entrée qui échoue est conservée pour le prochain passage.
Future<void> flushPendingDeletions() async {
  if (_flushing) return; // évite les passages concurrents
  _flushing = true;
  try {
    final box = await _openBox();
    if (box.isEmpty) return;

    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id;

    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! Map) {
        await box.delete(key); // entrée corrompue → on jette
        continue;
      }
      final startedAt = raw['startedAt'] as String?;
      if (startedAt == null) {
        await box.delete(key);
        continue;
      }
      final userId = (raw['userId'] as String?) ?? currentUserId;
      final safetySessionId = raw['safetySessionId'] as String?;

      try {
        // Ordre : positions avant sessions (contrainte FK), puis le ride.
        if (safetySessionId != null) {
          await client
              .from('safety_positions')
              .delete()
              .eq('session_id', safetySessionId);
          await client
              .from('safety_sessions')
              .delete()
              .eq('id', safetySessionId);
        }
        var q = client.from('rides').delete().eq('started_at', startedAt);
        if (userId != null) q = q.eq('user_id', userId);
        await q;

        // Un DELETE bloqué par la RLS ne lève PAS d'erreur : il supprime 0 ligne.
        // On vérifie donc que la sortie a bien disparu de `rides` ; si elle est
        // encore là, on garde l'entrée en file pour un prochain passage (elle
        // aboutira une fois la policy « delete own rides » appliquée côté DB).
        var checkQ =
            client.from('rides').select('started_at').eq('started_at', startedAt);
        if (userId != null) checkQ = checkQ.eq('user_id', userId);
        final still = await checkQ.limit(1);
        if ((still as List).isNotEmpty) {
          throw Exception('rides.delete non effectif (RLS ?) pour $startedAt');
        }

        // Storage : purge du dossier du ride (best-effort interne, ne throw pas).
        if (userId != null) {
          await deleteRidePhotosFolder(userId, startedAt);
        }

        // Succès complet → on retire de la file.
        await box.delete(key);
      } catch (e) {
        // Réseau indisponible ou erreur ponctuelle : on garde l'entrée.
        debugPrint('[PENDING_DEL] retry $startedAt: $e');
      }
    }
  } finally {
    _flushing = false;
  }
}
