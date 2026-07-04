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
