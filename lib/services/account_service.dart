import 'package:supabase_flutter/supabase_flutter.dart';

/// Encapsule l'identification « la plus simple » : rattacher le compte anonyme
/// courant à un email (via code OTP, natif Supabase, gratuit) puis pouvoir le
/// récupérer après une réinstallation / un changement de téléphone.
///
/// Deux flux distincts :
///  • SAUVEGARDER (Flow A) : le compte anonyme courant contient les données.
///    `updateUser(email)` → `verifyOTP(emailChange)`. Le `user_id` NE CHANGE PAS,
///    les sorties déjà créées restent attachées.
///  • RÉCUPÉRER (Flow B) : un nouvel install a créé un compte anonyme neuf.
///    `signInWithOtp(email)` → `verifyOTP(email)`. La session bascule sur
///    l'ANCIEN `user_id` → l'historique redevient accessible.
class AccountStatus {
  const AccountStatus({required this.isSaved, this.email});

  /// `true` si le compte courant est rattaché à un email (plus anonyme).
  final bool isSaved;

  /// Email rattaché, `null` tant que le compte est anonyme.
  final String? email;
}

/// Message d'erreur lisible remonté à l'UI, après traduction FR.
class AccountException implements Exception {
  AccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountService {
  AccountService([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  /// État courant du compte (lié ou anonyme).
  AccountStatus currentStatus() {
    final u = _auth.currentUser;
    final email = u?.email;
    final isSaved = u != null && u.isAnonymous != true && email != null && email.isNotEmpty;
    return AccountStatus(isSaved: isSaved, email: isSaved ? email : null);
  }

  // --- Flow A : sauvegarder (lier l'email au compte anonyme) -----------------

  /// Envoie un code OTP pour rattacher [email] au compte anonyme courant.
  Future<void> sendSaveCode(String email) async {
    final normalized = _normalizeEmail(email);
    try {
      await _auth.updateUser(UserAttributes(email: normalized));
    } on AuthException catch (e) {
      throw _translate(e, saving: true);
    } catch (e) {
      throw _translateGeneric(e);
    }
  }

  /// Vérifie le code reçu par email et finalise le rattachement (Flow A).
  Future<void> confirmSaveCode(String email, String code) async {
    try {
      await _auth.verifyOTP(
        email: _normalizeEmail(email),
        token: code.trim(),
        type: OtpType.emailChange,
      );
    } on AuthException catch (e) {
      throw _translate(e, saving: true);
    } catch (e) {
      throw _translateGeneric(e);
    }
  }

  // --- Flow B : récupérer (se reconnecter à un compte email existant) --------

  /// Envoie un code OTP de connexion vers un compte email déjà rattaché.
  Future<void> sendRecoverCode(String email) async {
    try {
      await _auth.signInWithOtp(email: _normalizeEmail(email));
    } on AuthException catch (e) {
      throw _translate(e, saving: false);
    } catch (e) {
      throw _translateGeneric(e);
    }
  }

  /// Vérifie le code et bascule la session sur le compte récupéré (Flow B).
  Future<void> confirmRecoverCode(String email, String code) async {
    try {
      await _auth.verifyOTP(
        email: _normalizeEmail(email),
        token: code.trim(),
        type: OtpType.email,
      );
    } on AuthException catch (e) {
      throw _translate(e, saving: false);
    } catch (e) {
      throw _translateGeneric(e);
    }
  }

  // --- Helpers ---------------------------------------------------------------

  String _normalizeEmail(String email) => email.trim().toLowerCase();

  /// Validation basique d'un email côté client.
  static bool isValidEmail(String email) {
    final e = email.trim();
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);
  }

  AccountException _translate(AuthException e, {required bool saving}) {
    final msg = e.message.toLowerCase();
    final status = e.statusCode;

    if (status == '429' || msg.contains('rate limit') || msg.contains('too many')) {
      return AccountException('Trop de tentatives, réessaie dans ~1h.');
    }
    if (msg.contains('expired') || msg.contains('invalid') || msg.contains('otp')) {
      return AccountException('Code invalide ou expiré, redemande un code.');
    }
    if (saving && (msg.contains('already') || msg.contains('registered') ||
        msg.contains('exists') || msg.contains('taken'))) {
      return AccountException(
          'Cet email est déjà lié à un compte. Utilise plutôt « Me reconnecter ».');
    }
    // Repli : message d'origine, déjà court côté Supabase.
    return AccountException(e.message);
  }

  AccountException _translateGeneric(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socket') || s.contains('network') ||
        s.contains('failed host') || s.contains('connection')) {
      return AccountException('Connexion impossible (hors ligne ?).');
    }
    return AccountException('Une erreur est survenue, réessaie.');
  }
}
