# 🏍️ Sunday Tracker — Synthèse du développement

> **Dernière mise à jour : 2026-07-12**
> Derniers commits couverts — Mobile : `5a4c84a` (11/07) · Web : `270a9fc` (12/07)

Le projet se compose de **deux applications complémentaires** :
- **`sunday_tracker`** — l'app **mobile** Flutter (Android/iOS) qui enregistre les sorties GPS
- **`sunday_tracker_live`** — l'app **web** Flutter (suivi *live* + dashboard admin), hébergée d'abord sur Vercel puis Firebase

---

## 📱 App 1 — Sunday Tracker (mobile Flutter)

### Mai 2026 — Fondations & GPS

**18/05 — Naissance du projet** (plusieurs commits dans la journée)
- Setup Flutter initial : `main.dart`, `home_screen` (28 l.), `ride_screen` (254 l.).
- Stack de départ : **geolocator** (GPS) + **flutter_map** (carte).
- Ajout des **cards distance et précision GPS** sur l'écran de suivi (+317 l.).
- Grosse préparation (+1184 l. sur 9 fichiers) puis mise en place du **foreground service** + **tracking écran verrouillé** (suivi qui continue app fermée/verrouillée).

**20/05 — v0.9, premier gros palier**
- Refonte du `home_screen` (+269 l.) et de `ride_screen` (+144 l.).
- Nouveau widget **`ride_trace_thumbnail`** (110 l.) : miniatures des tracés de sorties.
- Explosion du socle de dépendances : **Hive** + **hive_flutter** (persistance locale), **wakelock_plus** (écran allumé), **flutter_background_service**, **flutter_local_notifications**, **supabase_flutter** (backend cloud), **geocoding** (adresses), **package_info_plus**.
- Création du **README**.

**21/05 — 0.0.9+2 : écran de détail**
- Développement de `ride_detail_screen` (+275 l.) : stats détaillées et visualisation d'une sortie.
- Refonte `ride_screen` (+116 l.).
- Ajout de **intl** (formats date/heure) et **share_plus** (partage).

**22/05 — 0.0.9+3/+4** : ajustements et corrections sur l'écran de détail (+258 l.).

### Juin 2026 — Refonte, robustesse & packaging

**04/06 — 0.0.9+5 : refactor majeur**
- Réécriture allégée de `ride_screen` (1130 l. touchées, solde négatif → simplification) et remaniement du détail (+716 l.).
- Ajout de **path_provider** (accès système de fichiers).

**13/06 — 0.0.9+7**
- Refonte importante des 3 écrans ; sauvegarde d'une version de travail (`ride_screen copy.dart`, 1099 l.).
- Modification du **AndroidManifest** (permissions + déclaration du service en arrière-plan, +36 l.).
- Ajout de **url_launcher** et **image_picker** (sélection de photos).

**15/06 — 0.0.9+8 : la plus grosse itération**
- ~2163 l. touchées sur `ride_screen`, ~1143 sur `ride_detail_screen`, ~501 sur `home_screen`.
- Consolidation complète de l'UI et de la logique de suivi.

**23/06 — Identité visuelle & packaging**
- Ajout des **splash screens** (versions jour/nuit, toutes densités d'écran), **icônes de lancement**, config `build.gradle.kts` (102 fichiers, surtout des assets binaires).

**25/06** — Bump de version (0.0.9+25062026).

**27/06 — 1.0.0 : mode cockpit**
- Préparation du **mode cockpit** (affichage type tableau de bord pendant la sortie).
- **Réécriture complète de `ride_screen`** (1212 l. touchées).

### Juillet 2026 — Sortie 1.0.0

**02/07 — 1.0.0, livraison majeure**
- Nouveau widget **`ride_share_card`** (539 l.) + service **`share_image_service`** (65 l.) : génération d'une **image de partage** stylée d'une sortie.
- Refonte massive de `ride_detail_screen` (~2179 l.) et de `ride_screen` (~1001 l.).
- Ajout de **http**, **shared_preferences**, **flutter_native_splash** ; montée de **supabase** (2.8 → 2.14).
- **Merge final du foreground service** dans `main` : finalisation du suivi GPS en arrière-plan.

**03/07 — 1.0.0+2026070301** : grosse itération (+1488 l. sur 5 fichiers) consolidant la version 1.0.0.

**04/07 — Photos des waypoints & accueil**
- **Stockage des photos de waypoint sur Supabase Storage** + panneau de debug stockage (+639 l.).
- Nouvelle **carte de sortie** sur l'accueil (proposition 2) avec miniature relief, fix de suppression de photo.
- **Pull-to-refresh** de la liste des sorties.

**05/07 — 1.0.0+2026070501 : fiabilisation BDD/sécurité**
- Grosse livraison (+977 l.) + **allègement de `safety_sessions.ride_json`** (BDD étape 5) et UI d'accueil responsive.
- **Sécurité live** : rattachement de la session au `user_id` dès la création.
- **Versionnage de la migration RLS** (RPC live + policies + storage, +173 l.).
- Correction de la réécriture d'URL sur les listes de photos ancien format.

**06/07 — Robustesse photos & horodatage GPS**
- Re-push de `ride_json` après upload photo, rafraîchissement de session pour les photos déjà uploadées.
- **Positions horodatées au fix GPS** (`created_at`) et non à l'envoi (corrige l'heure d'arrivée faussée après une pause).

**07/07 — Fix durée** : `endTime` = début + **durée active** (et non l'heure d'appui sur STOP).

**11/07 — v1.1, Point 2 : identification email OTP** 🔑
- Grosse fonctionnalité (+2143 l. sur 14 fichiers) : **identification par email + code OTP** permettant de **sauvegarder et récupérer ses sorties** (issue #46).
- **Points de passage mémorisés éditables en direct** : popup permettant de modifier la note et les photos d'un waypoint sans quitter la sortie (+343 l.).
- **Icône de lancement** : correction du raccourci blanc sur Android (le foreground opaque sur fond blanc était en cause), puis nouveau design **dégradé violet→orange + logo blanc**.

**12/07 — En cours (non committé)**
- Refonte de l'**écran d'accueil** avec vignette de tracé, **simplification de l'écran de ride**, retouches du **splash** et du `photo_sync_service`.

---

## 🌐 App 2 — Sunday Tracker Live (web Flutter)

### Mai 2026 — Mise en ligne

**19/05 — Création + déploiement**
- Commit initial (130 fichiers, `main.dart` 201 l.).
- Stack : **supabase_flutter** + **flutter_map** + **url_launcher**.
- Config **web** (`index.html`, `manifest.json`) et mise en place du déploiement **Vercel** (config + fix du routing Flutter Web à 2 reprises).

**20/05 — v0.9**
- Ajout de **Firebase** (`firebase.json`) et grosse évolution de `main.dart` (+191 l.).
- Fonctionnalités **« actualisation & statut »** : mise à jour temps réel de l'affichage (467 l. touchées).

**22/05 — 0.0.9+4**
- Deux gros commits sur `main.dart` (1127 l. puis 729 l. touchées) : montée en puissance de la page live (à ce stade tout est encore dans `main.dart`).

### Juin 2026 — Architecture, auth & admin

**15/06 — 0.0.9+5** : nouvelle grosse itération sur `main.dart` (+1186 l.).

**17/06 — 0.0.9+6** : commit énorme (9309 fichiers) — vraisemblablement l'ajout de dépendances/build web ou node_modules versionnés par erreur.

**18/06 — 0.0.9 : refonte architecturale complète** 🏗️
- Passage d'un `main.dart` monolithique à une **architecture structurée** :
  - `core/auth/auth_service.dart` — service d'authentification
  - `core/router/app_router.dart` — routage via **go_router**
  - `core/theme/admin_theme.dart` — thème admin
  - `features/admin/` — **dashboard admin** : `admin_shell_page`, `admin_sidebar`, sections `cleanup_section` (nettoyage de données) et `placeholder_sections`
  - `features/auth/` — pages **login** et **link_sent** (auth par lien magique)
  - `features/live/live_page.dart` — la page de suivi live isolée (+496 l.)
- L'ancien `main.dart.LIVE` (1377 l.) est supprimé au profit de cette structure.
- Deux commits de suivi le même jour : sauvegarde/test autour du **rollback de l'auth avant intégration Gmail**.

**20/06 — 0.0.9+20062026** : gros travail sur `cleanup_section` (+261 l.) — outils d'administration/nettoyage.

**25/06 — 0.0.9+25062026** : forte évolution de `live_page.dart` (833 l. touchées) + config `firebase.json`.

### Juin (fin) — 1.0.0

**27/06 — 1.0.0** (deux commits)
- Enrichissement de `live_page.dart` (+455 puis +71 l.), ajustements `admin_sidebar` et `cleanup_section`.
- Mise à jour `web/index.html` + `manifest.json` (PWA).

### Juillet 2026 — Viewer temps réel, déploiement & auth admin

**05/07 — Viewer RPC & assainissement du cache web**
- Bascule du **viewer sur la RPC `get_live_session`** (trace via `ride_json`) — le web lit désormais les données via une fonction serveur dédiée.
- **Suppression du service worker** (app 100 % en ligne), correction du cache SW figé + bouton « Forcer la mise à jour », **cache-busting `?v=<build>`** et garde-fou de déploiement.

**06/07 — Waypoints, déploiement & migration auth admin** 🏗️
- Script **`deploy.ps1`** (build + déploiement web en une commande).
- **Galerie photos des waypoints** dans le live, WP affichés au-dessus des markers puis en **pin décalé perpendiculairement à la trace** ; point rouge retiré sur ride terminé (+635 l. cumulées).
- **Migration de l'auth admin : Firebase → magic link Supabase** pour débloquer l'accès aux données (−113 l. Firebase).
- **Outils de purge admin** : rides orphelins par identité (`user_id`, +391 l.) et sessions sans propriétaire (`user_id` NULL, +182 l.).

**07/07 — Aperçu de lien partagé** : titre + slogan **OpenGraph** (aperçu enrichi lors du partage d'un lien).

**08/07 — Affinages du live**
- Affichage des **secondes** dans l'heure de départ (HH:MM:SS).
- **Pins numérotés plus grands** + aperçu de partage enrichi.

**11/07 — v1.1 : points de passage interactifs**
- **Points de passage cliquables** avec **pastilles numérotées** dans le viewer live (+253 l.).

**12/07 — Statistiques recalculées côté web** 📊
- **Dénivelé et vitesse recalculés côté web** à partir de la trace, au lieu d'être repris tels quels (+1560 l. sur 5 fichiers) — le plus gros commit web depuis la refonte architecturale de juin.

**Stack finale web** : Supabase (+ **magic link auth**, en remplacement de Firebase), **flutter_map**, **go_router**, **google_fonts**, **intl**, `flutter_web_plugins` avec **PathUrlStrategy** (URLs propres sans `#`).

---

## 🔎 Vue d'ensemble

| | **Mobile (`sunday_tracker`)** | **Web (`sunday_tracker_live`)** |
|---|---|---|
| **Rôle** | Enregistre les sorties GPS | Suivi *live* + admin |
| **Trajectoire** | Tracker GPS → persistance Hive + arrière-plan → détail & partage image → cockpit → 1.0.0 → photos Storage + BDD/RLS → **v1.1 (email OTP, waypoints éditables, nouvelle icône)** | Page live sur Vercel → Firebase + refonte architecturale → 1.0.0 → viewer RPC + auth Supabase → **v1.1 (waypoints interactifs, stats recalculées)** |
| **Backend commun** | **Supabase** (les deux apps partagent la base) | **Supabase** (auth **magic link**, Firebase retiré le 06/07) |
| **Cartographie** | flutter_map | flutter_map |

Les deux projets ont avancé **en parallèle** (jalons synchronisés : v0.9 le 20/05, 0.0.9+4 le 22/05, 25/06, **1.0.0 le 27/06–02/07**, puis **v1.1 le 11/07**), l'app mobile alimentant Supabase et l'app web l'exploitant en temps réel.

**Points forts de la période juillet (03→12/07)** : côté mobile, passage des **photos de waypoints sur Supabase Storage**, gros travail de **fiabilisation BDD/RLS** (sécurité live, allègement `ride_json`, horodatage GPS), arrivée de l'**identification email OTP**, **waypoints éditables en direct** et **nouvelle icône** (v1.1). Côté web, bascule du viewer sur une **RPC serveur**, **galerie de waypoints interactifs**, **migration de l'auth admin de Firebase vers Supabase magic link**, outillage de **déploiement/purge** et **recalcul des statistiques dénivelé/vitesse côté client** (v1.1).

**Chantier en cours au 12/07** : refonte de l'écran d'accueil (vignette de tracé) et simplification de l'écran de ride, côté mobile.
