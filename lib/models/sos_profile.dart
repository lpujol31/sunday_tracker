/// Fiche d'urgence affichée par l'écran SOS.
///
/// Ce fichier ne contient que les *structures*, jamais de données réelles : le
/// dépôt est public, et une fiche SOS est par nature un concentré de données
/// personnelles (adresse, groupe sanguin, allergies, proches). Le profil réel
/// vit dans `sos_profile_local.dart`, ignoré par Git.
///
/// À terme ces champs viendront des Paramètres (saisis par l'utilisateur,
/// stockés en local) et le fichier local disparaîtra ; l'écran, lui, n'aura
/// pas à changer.
class SosContact {
  final String name;
  final String relation; // « épouse », « fils »… affiché sous le nom
  final String phone;

  const SosContact({
    required this.name,
    required this.relation,
    required this.phone,
  });

  /// Numéro « composable » : on retire espaces et points pour le lien tel:.
  String get dialable => phone.replaceAll(RegExp(r'[^\d+]'), '');

  /// Numéro lisible : 06 12 34 56 78 plutôt que 0612345678.
  String get pretty {
    final d = dialable;
    if (d.length != 10 || !d.startsWith('0')) return phone;
    return [for (var i = 0; i < 10; i += 2) d.substring(i, i + 2)].join(' ');
  }
}

class SosProfile {
  final String fullName;
  final int age;

  /// Adresse du domicile. Optionnelle : la fiche SOS devient publique dès
  /// qu'on tend le téléphone à un inconnu, chacun choisit s'il l'expose.
  final String? address;

  final String? bloodType;

  /// L'essentiel médical, court : allergies, traitement, antécédent.
  /// Une ligne par item, lisible en 3 secondes par un secouriste.
  final List<String> medicalNotes;

  final List<SosContact> contacts;

  const SosProfile({
    required this.fullName,
    required this.age,
    this.address,
    this.bloodType,
    this.medicalNotes = const [],
    this.contacts = const [],
  });
}
