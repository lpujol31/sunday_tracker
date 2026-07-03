# sunday_tracker

## Stack

flutter run → debug → kDebugMode = true / distanceFilter: 0
flutter run --release → release → kDebugMode = false / distanceFilter: 5

### Github
https://github.com/lpujol31/sunday_tracker
git add .
git commit -m "commentaire"
git push


### commandes ADB
lister les devices
adb devices

dir du dossier
adb -s R5CR910WZTX shell run-as com.example.sunday_tracker ls app_flutter
adb -s R5CR910WZTX shell run-as com.example.sunday_tracker ls app_flutter/waypoint_photos

supprimer un fichier
adb -s R5CR910WZTX shell run-as com.example.sunday_tracker rm app_flutter/waypoint_photos/wp_1781214796094.jpg

### Supabase
https://supabase.com/dashboard/org/stxrbgomsaywwrksojfg
https://eltlnrxiuvixjlakjfhz.supabase.co

## Hive
### Structure
| Clé                    | Type probable                     |
| ---------------------- | --------------------------------- |
| `name`                 | `String`                          |
| `startTime`            | `String?` (date ISO8601)          |
| `endTime`              | `String` (date ISO8601)           |
| `durationSeconds`      | `int`                             |
| `distanceMeters`       | `double` ou `int`                 |
| `totalElevationMeters` | `double`                          |
| `totalElevationDown`   | `double`                          |
| `altitudeStart`        | `double?`                         |
| `altitudeEnd`          | `double?`                         |
| `altitudeMax`          | `double?`                         |
| `altitudeMin`          | `double?`                         |
| `movingTimeSeconds`    | `int`                             |
| `maxSpeedKmh`          | `double`                          |
| `avgSpeedKmh`          | `double`                          |
| `maxSlopePercent`      | `double`                          |
| `weatherStart`         | `Map` ou objet sérialisé          |
| `weatherEnd`           | `Map` ou objet sérialisé          |
| `sunriseTime`          | `String?` (date ISO8601)          |
| `sunsetTime`           | `String?` (date ISO8601)          |
| `city`                 | `String?`                         |
| `department`           | `String?`                         |
| `region`               | `String?`                         |
| `safetySessionId`      | `String?`                         |
| `safetyShareCode`      | `String?`                         |
| `points`               | `List` (points GPS avec altitude) |
| `waypoints`            | `List`                            |

### Recherche
Un seul champ de recherche qui cherche dans :
name
note
city (tags)
department (tags)
region (tags)
practice (tags)
startTime / ex : 2026