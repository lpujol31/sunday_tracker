# Temps passé — Projet Sunday Tracker

_Généré le 2026-07-02 — **Actualisé le 2026-07-12**. Sources croisées : captures d'écran (`Pictures\Screenshots`), historique git des 2 repos (`sunday_tracker` mobile + `sunday_tracker_live` web/admin)._

## Estimation globale

| Scénario | Temps |
|---|---|
| Plancher (entre 1ère/dernière capture) | ~53 h |
| **Réaliste (captures +15 min/session)** | **~87 h** |
| Haute (+ tests terrain GPS non capturés) | ~100 h |

**Total mobile + web : ~85-90 h** sur 39 jours actifs (16/05 → 12/07/2026).
Ventilation estimée : **~58 h mobile / ~29 h web**.

## Calendrier jour par jour

| Jour | Temps (h) | Sessions | Captures | Commit mobile | Commit web |
|---|---:|---:|---:|:---:|:---:|
| 2026-05-16 | 1,1 | 2 | 5 |  |  |
| 2026-05-17 | 0,5 | 2 | 2 |  |  |
| 2026-05-18 | 3,4 | 8 | 18 | ✅ |  |
| 2026-05-19 | 0,5 | 2 | 2 |  | ✅ |
| 2026-05-20 | 0,8 | 3 | 4 | ✅ | ✅ |
| 2026-05-21 | 1,5 | 2 | 9 | ✅ |  |
| 2026-05-22 | 1,8 | 4 | 9 | ✅ | ✅ |
| 2026-06-03 | 0,9 | 1 | 3 |  |  |
| 2026-06-04 | 1 | 2 | 11 | ✅ |  |
| 2026-06-05 | 1,5 | 5 | 10 |  |  |
| 2026-06-11 | 0,2 | 1 | 1 |  |  |
| 2026-06-12 | 2,7 | 2 | 15 |  |  |
| 2026-06-13 | 1,5 | 2 | 9 | ✅ |  |
| 2026-06-14 | 5,2 | 4 | 31 |  |  |
| 2026-06-15 | 3,9 | 5 | 32 | ✅ | ✅ |
| 2026-06-16 | 4,4 | 3 | 35 |  |  |
| 2026-06-17 | 1,3 | 4 | 9 |  | ✅ |
| 2026-06-18 | 0,2 | 1 | 1 |  | ✅ |
| 2026-06-19 | 0,2 | 1 | 1 |  |  |
| 2026-06-20 | 1 | 4 | 5 |  | ✅ |
| 2026-06-23 | 1,8 | 5 | 12 | ✅ |  |
| 2026-06-24 | 0,2 | 1 | 1 |  |  |
| 2026-06-25 | 0,2 | 1 | 1 | ✅ | ✅ |
| 2026-06-26 | 1,3 | 3 | 5 |  |  |
| 2026-06-27 | 1,3 | 2 | 21 | ✅ | ✅ |
| 2026-06-28 | 3,6 | 2 | 36 |  |  |
| 2026-06-30 | 0,8 | 3 | 8 |  |  |
| 2026-07-01 | 6,9 | 7 | 76 |  |  |
| 2026-07-02 | 5,6 | 7 | 56 | ✅ |  |
| 2026-07-03 | 3,2 | 2 | 29 | ✅ |  |
| 2026-07-04 | 4,5 | 5 | 35 | ✅ |  |
| 2026-07-05 | 3,7 | 3 | 31 | ✅ | ✅ |
| 2026-07-06 | 4,8 | 6 | 33 | ✅ | ✅ |
| 2026-07-07 | 0,9 | 2 | 5 | ✅ | ✅ |
| 2026-07-08 | 3,5 | 4 | 36 |  | ✅ |
| 2026-07-09 | 1,4 | 2 | 9 |  |  |
| 2026-07-10 | 3,3 | 2 | 37 |  |  |
| 2026-07-11 | 5,6 | 7 | 44 | ✅ | ✅ |
| 2026-07-12 | 0,9 | 1 | 9 |  | ✅ |

**TOTAL : ~87 h** sur 39 jours actifs (16/05 → 12/07/2026) — ~695 captures au total.

> Notes de révision :
> - le **02/07** a été révisé (37 → 56 captures) lors de l'actualisation du 11/07 ;
> - le **11/07** est révisé à son tour (1,7 h → **5,6 h**, 19 → 44 captures) : le fichier avait été généré à 01 h 49, en plein milieu de la journée de travail. Les sessions de l'après-midi et de la soirée n'y figuraient pas ;
> - le **12/07** est un **jour en cours** : le chiffre ne couvre que la nuit (00 h 01 → 00 h 43) et sera revu à la hausse.
>
> Les lignes de mai/juin sont conservées telles quelles (l'estimation d'origine croisait captures + git).

### Ce qui a occupé la période 03→11/07

- **Mobile** : photos des waypoints en **Supabase Storage**, fiabilisation **BDD/RLS** (sécurité live, allègement `ride_json`), horodatage GPS au fix, calcul de l'`endTime` sur la durée active, **identification email OTP** (sauvegarde/récupération des sorties), refonte carte d'accueil + pull-to-refresh.
- **Web (live/admin)** : bascule du viewer sur la **RPC `get_live_session`**, galerie photos des waypoints + pins numérotés cliquables, migration de l'auth admin **Firebase → magic link Supabase**, purge des sessions/rides orphelins, cache-busting + script `deploy.ps1`, aperçu de lien partagé (OpenGraph).

### Ce qui a occupé le 11→12/07

- **Mobile** : **icône de lancement** (correction du raccourci blanc sur Android, puis nouveau design dégradé violet→orange avec logo blanc), **points de passage mémorisés éditables en direct** (note + photos via popup, +343 l.). En cours, non committé au 12/07 : refonte de l'**écran d'accueil** (vignette de tracé), **simplification de l'écran de ride** et retouche du **splash**.
- **Web (live/admin)** : **statistiques dénivelé/vitesse recalculées côté web** (+1560 l., le plus gros commit web depuis la refonte architecturale).

## Notes méthodologiques

- **Sessionnisation** : une coupure de plus de 30 min entre 2 captures = nouvelle session. Chaque session reçoit +15 min de marge (temps hors captures : lancement, réflexion, build).
- **Captures = source du temps** : les screenshots Windows n'ont aucune métadonnée EXIF, le mtime est la seule source (cohérente, aucune anomalie détectée).
- **mtime des .dart inexploitable** : un `git checkout` a réinitialisé les dates → remplacé par le churn git réel.
- **Validation croisée** : chaque jour de commit (mobile ET web) tombe dans une session de captures → les captures couvrent bien les 2 projets.
- **Angles morts** : tests terrain GPS (mobile) sans captures ; churn web du 17/06 (~1,4 M lignes) = artefact de build ignoré.
