# sunday_tracker

## Stack

flutter run → debug → kDebugMode = true → distanceFilter: 0
flutter run --release ou build Play Store → kDebugMode = false → distanceFilter: 5

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

## Backlog
### v1

#### Bugs

#### Accueil

#### Ride in progress

#### Détail sortie


### v2


#### Accueil
Preview avec fond de carte

#### Ride in progress

Gérer bouton SOS

#### Détail sortie


### Ideas
Commandes guidon (prise de WP, photos)

