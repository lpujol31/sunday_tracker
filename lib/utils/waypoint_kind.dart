// Nature des points de passage : l'enum, le rendu de pastille et la règle de
// masquage des pauses auto courtes vivent dans le package partagé `sunday_core`
// (source unique avec le viewer live). Ne reste ici que l'extraction des champs
// depuis un waypoint mobile, dont la forme (`note` / `timestamp`) diffère de
// celle du live (`comment` / `created_at`).
import 'package:sunday_core/waypoint_kind.dart';
export 'package:sunday_core/waypoint_kind.dart';

/// Nature d'un waypoint mobile stocké (Hive / `ride_json`).
WaypointKind waypointKindOf(Map wp) =>
    waypointKindFromFields(kind: wp['kind'], note: wp['note']?.toString());

/// Durée d'une pause auto mobile : `resumedAt − timestamp`.
Duration? autoPauseDuration(Map wp) => autoPauseDurationFromFields(
      start: wp['timestamp']?.toString(),
      end: wp['resumedAt']?.toString(),
    );

/// Vrai si [wp] est une pause auto assez brève pour être masquée sur la carte.
bool isShortAutoPause(Map wp,
        {Duration threshold = kShortAutoPauseHideThreshold}) =>
    isShortAutoPauseFromFields(
      kind: wp['kind'],
      note: wp['note']?.toString(),
      start: wp['timestamp']?.toString(),
      end: wp['resumedAt']?.toString(),
      threshold: threshold,
    );
