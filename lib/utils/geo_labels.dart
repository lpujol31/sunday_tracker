import 'package:geocoding/geocoding.dart';

/// Nom de ville « lisible » depuis un placemark de géocodage inverse.
///
/// `locality` est souvent vide en zone rurale (petites communes, hameaux) :
/// on retombe alors en cascade sur des champs plus grossiers pour toujours
/// avoir quelque chose à afficher.
String cityFromPlacemark(Placemark p) {
  final candidates = [
    p.locality,
    p.subLocality,
    p.subAdministrativeArea,
    p.administrativeArea,
  ];
  for (final c in candidates) {
    if (c != null && c.trim().isNotEmpty) return c.trim();
  }
  return '';
}

/// Sous-titre géographique affiché sous la ville : « Haute-Loire (43) ».
///
/// `subAdministrativeArea` = le département en France (sinon la région).
/// Le numéro vient du code postal (2 premiers chiffres, 3 en outre-mer) ; hors
/// de France le code postal n'a pas ce sens, donc on n'affiche que le nom.
String areaFromPlacemark(Placemark p) {
  final name = [p.subAdministrativeArea, p.administrativeArea]
      .map((v) => v?.trim() ?? '')
      .firstWhere((v) => v.isNotEmpty, orElse: () => '');
  if (name.isEmpty) return '';
  final code = _departmentCode(p);
  return code == null ? name : '$name ($code)';
}

/// Numéro de département depuis le code postal, uniquement en France
/// métropolitaine + DOM (5 chiffres). Renvoie null ailleurs.
String? _departmentCode(Placemark p) {
  final country = (p.isoCountryCode ?? '').trim().toUpperCase();
  if (country.isNotEmpty && country != 'FR') return null;
  final zip = (p.postalCode ?? '').trim().replaceAll(' ', '');
  if (!RegExp(r'^\d{5}$').hasMatch(zip)) return null;
  // 97x / 98x = outre-mer → le département tient sur 3 chiffres.
  return zip.startsWith('97') || zip.startsWith('98')
      ? zip.substring(0, 3)
      : zip.substring(0, 2);
}
