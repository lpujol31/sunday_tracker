// MODÈLE — copier ce fichier en `sos_profile_local.dart` (même dossier) et y
// mettre ses vraies informations. La copie est ignorée par Git : elle ne partira
// jamais sur le dépôt public.
//
//   copy lib\models\sos_profile_local.example.dart lib\models\sos_profile_local.dart
//
// Sans cette copie, le projet ne compile pas (ride_screen.dart importe
// `kSosProfileDemo`) — c'est volontaire : une absence bruyante vaut mieux
// qu'une fiche SOS silencieusement vide le jour où elle sert.

import 'sos_profile.dart';

/// Profil affiché par la fiche SOS.
const SosProfile kSosProfileDemo = SosProfile(
  fullName: 'Prénom Nom',
  age: 40,
  address: '1 rue de l\'Exemple, 31000',
  bloodType: 'A+',
  medicalNotes: [
    'Aucune allergie connue',
    'Aucun traitement en cours',
  ],
  contacts: [
    SosContact(
      name: 'Contact 1',
      relation: 'Conjoint',
      phone: '0600000001',
    ),
    SosContact(
      name: 'Contact 2',
      relation: 'Enfant',
      phone: '0600000002',
    ),
  ],
);
