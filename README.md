# sunday_tracker

## Stack

flutter run → debug → kDebugMode = true → distanceFilter: 0
flutter run --release ou build Play Store → kDebugMode = false → distanceFilter: 5

### Github
https://github.com/lpujol31/sunday_tracker
git add .
git commit -m "commentaire"
git push

### Supabase
https://supabase.com/dashboard/org/stxrbgomsaywwrksojfg
https://eltlnrxiuvixjlakjfhz.supabase.co

## Backlog
### v1

#### Bugs
03/06/2026
~~Enregistrement de points incohérents (cf. llança)
~~Soucis affichage Accueil~~

#### Accueil
~~Version / date & heure~~
~~hashtag en minuscule~~
~~Supprimer sortie ne supprime pas les données en BDD~~

#### Ride in progress
~~Gérer séquence d'envoi des infos (whatsapp ? SMS ? autre ?)~~ 
~~Arrêter sans sauvegarder > supprimer données BDD~~

Quand on clique sur Stop que ça arrête le chrono et la prise de position GPS

Comparer Distance avec montre GPS
Gèrer flèche retour
Gérer bouton Start/stop/démarrage chrono
Avoir une zone de message au dessus des boutons
Blinder bouton Reset 

#### Détail sortie
~~Icone Départ/arrivée~~
~~Supprimer (+ données associées supabase)~~


### v2
Logo appli

#### Accueil
Preview avec fond de carte

#### Ride in progress
Prendre photo qui soit associée à un point GPS
Gérer bouton SOS

#### Détail sortie
Partager
Exporter GPX
Détails
Zoom/dézoom VS rotation

### vXXXX
Commandes guidon (prise de WP, photos)