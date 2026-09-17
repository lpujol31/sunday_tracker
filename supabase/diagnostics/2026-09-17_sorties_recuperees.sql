-- =============================================================================
--  Diagnostic — « pourquoi ai-je eu des sorties récupérées pendant mes tests ? »
--  À coller dans l'éditeur SQL Supabase (rôle postgres → la RLS est contournée,
--  donc on voit TOUS les user_id, y compris les comptes anonymes périmés).
--
--  Rappel : il existe TROIS mécanismes distincts qui « récupèrent » une sortie.
--    A. Récupération après arrêt brutal (InterruptedRideService)
--       box Hive `current_ride` non vidée au lancement → dialog « Sortie
--       interrompue ». La sortie créée porte ride_json->>'recovered' = true,
--       un nom « Sortie récupérée du JJ/MM/AAAA », AUCUN safetySessionId et
--       aucun waypoint. C'est du 100 % local : le serveur n'en est que le
--       miroir (upsert best-effort).
--    B. Bouton « Récupérer depuis le cloud » (_recoverFromSupabase)
--       reconstruit UNE sortie PAR safety_session ayant des positions, sans
--       vérifier qu'une sortie couvre déjà la période → générateur de doublons.
--       Nom « Sortie du mar 15 juil 2026 · matin », safetySessionId renseigné,
--       pas de flag 'recovered'.
--    C. Restauration auto au lancement (_autoRestoreFromRidesTable)
--       silencieuse, déclenchée quand la box Hive `rides` est VIDE (réinstall,
--       « vider les données »). Recopie la table `rides` telle quelle.
--
--  Les requêtes ci-dessous servent à savoir lequel s'est déclenché, et pourquoi
--  la sortie d'origine ne s'est pas terminée proprement.
-- =============================================================================


-- ── 0. Garde-fou : vérifier les colonnes réelles avant tout ──────────────────
-- (si started_at / created_at sont en `text` et non `timestamptz`, les calculs
-- de durée plus bas doivent être entourés de ::timestamptz)
select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in ('rides', 'safety_sessions', 'safety_positions')
order by table_name, ordinal_position;


-- ── 1. Les sorties « récupérées » présentes côté serveur ─────────────────────
-- Chemin A (crash) : recuperee_crash = true, session_id vide, waypoints = 0.
-- Chemin B (bouton cloud) : recuperee_crash = false, session_id renseigné,
--                           nom « Sortie du <jour> … · <moment> ».
select
  r.user_id,
  r.started_at,
  r.ride_json->>'name'                                           as nom,
  coalesce((r.ride_json->>'recovered')::bool, false)             as recuperee_crash,
  r.ride_json->>'safetySessionId'                                as session_id,
  jsonb_array_length(coalesce(r.ride_json->'points',    '[]'::jsonb)) as pts,
  jsonb_array_length(coalesce(r.ride_json->'waypoints', '[]'::jsonb)) as waypoints,
  (r.ride_json->>'durationSeconds')::int                         as duree_s,
  round((r.ride_json->>'distanceMeters')::numeric)               as dist_m,
  r.ride_json->>'endTime'                                        as fin
from public.rides r
where coalesce((r.ride_json->>'recovered')::bool, false)
   or r.ride_json->>'name' ilike 'sortie récupérée%'
order by r.started_at desc;


-- ── 2. État de fin de CHAQUE session de test ─────────────────────────────────
-- LA requête à lire en premier. Colonne `verdict` :
--   « tuée en cours »   → status in_progress/paused + pas d'ended_at : l'app n'a
--                          jamais atteint saveRide (batterie, kill Android,
--                          crash). C'est exactement le cas que le chemin A
--                          rattrape → sortie récupérée LÉGITIME.
--   « finie, pas de ride » → status finished mais aucune ligne dans `rides` :
--                          la sortie existe en local mais le sync a échoué
--                          (hors-ligne, ou user_id différent → voir requête 6).
--   « OK »              → session finie ET sortie enregistrée. Si une sortie
--                          récupérée couvre malgré tout cette période, c'est un
--                          BUG de vidage de la box `current_ride` (requête 4).
select
  s.id,
  s.share_code,
  s.status,
  s.started_at,
  s.ended_at,
  p.n_points,
  p.first_pt,
  p.last_pt,
  p.last_battery                                      as batterie_dernier_point,
  round(extract(epoch from (p.last_pt - p.first_pt)) / 60.0, 1) as minutes_de_trace,
  round(extract(epoch from (now() - p.last_pt)) / 3600.0, 1)    as heures_depuis_dernier_pt,
  r.started_at                                        as ride_started_at,
  r.ride_json->>'name'                                as ride_nom,
  case
    when r.started_at is not null and s.status = 'finished' then 'OK'
    when s.ended_at is null and s.status in ('in_progress', 'paused') then 'tuée en cours'
    when r.started_at is null then 'finie, pas de ride'
    else 'à regarder'
  end                                                 as verdict
from public.safety_sessions s
left join lateral (
  select count(*)                                              as n_points,
         min(created_at)                                       as first_pt,
         max(created_at)                                       as last_pt,
         (array_agg(battery_level order by created_at desc))[1] as last_battery
  from public.safety_positions
  where session_id = s.id
) p on true
left join public.rides r
  on r.ride_json->>'safetySessionId' = s.id::text
order by s.started_at desc nulls last;


-- ── 3. Pourquoi ça s'est coupé : la fin de trace d'UNE session ───────────────
-- Remplacer le share_code. À lire :
--   batterie qui descend jusqu'à ~5 % puis plus rien  → extinction batterie
--     (à 5 % l'app déclenche normalement la sauvegarde auto : si elle n'a pas
--      eu lieu, le téléphone s'est éteint avant, ou le service a été tué)
--   batterie à 60 % et coupure nette                   → kill Android / crash
--   gap_s qui explose puis reprend                     → flux GPS interrompu
--     (doze, permission, ou la sortie a simplement continué après un trou)
with pts as (
  select p.created_at,
         p.battery_level,
         round(extract(epoch from p.created_at
               - lag(p.created_at) over (order by p.created_at))) as gap_s
  from public.safety_positions p
  join public.safety_sessions s on s.id = p.session_id
  where s.share_code = 'REMPLACER'
)
select * from pts order by created_at desc limit 40;


-- ── 4. Doublons : une sortie récupérée qui recouvre une sortie déjà sauvée ───
-- Tout résultat ici = récupération EN TROP (la sortie existait déjà).
-- Chemin A : la box `current_ride` n'avait pas été vidée par saveRide.
-- Chemin B : le bouton cloud a recréé une sortie déjà présente.
with r as (
  select user_id,
         started_at                                                       as s0,
         started_at + make_interval(secs =>
           coalesce((ride_json->>'durationSeconds')::int, 0))             as s1,
         coalesce((ride_json->>'recovered')::bool, false)                 as rec,
         ride_json->>'name'                                               as nom,
         ride_json->>'safetySessionId'                                    as session_id
  from public.rides
)
select a.nom  as recuperee,     a.s0 as rec_debut, a.s1 as rec_fin,
       b.nom  as deja_presente, b.s0 as ini_debut, b.s1 as ini_fin,
       b.session_id
from r a
join r b
  on a.user_id = b.user_id
 and a.s0 <> b.s0
 and a.rec and not b.rec
 and a.s0 < b.s1 and b.s0 < a.s1   -- chevauchement temporel
order by a.s0 desc;


-- ── 5. Ce que le bouton « Récupérer depuis le cloud » recréerait AUJOURD'HUI ──
-- Une ligne = une sortie que le bouton ajouterait. Les lignes avec
-- deja_dans_rides = true seraient des DOUBLONS purs.
select
  s.id,
  s.share_code,
  s.status,
  s.started_at,
  count(p.*)                                                as positions,
  (r.started_at is not null)                                as deja_dans_rides
from public.safety_sessions s
join public.safety_positions p on p.session_id = s.id
left join public.rides r on r.ride_json->>'safetySessionId' = s.id::text
group by s.id, s.share_code, s.status, s.started_at, r.started_at
having count(p.*) > 0
order by s.started_at desc;


-- ── 6. Churn de l'auth anonyme (cause classique des données « perdues ») ─────
-- Chaque réinstall / vidage de données crée un NOUVEAU compte anonyme. Les
-- sorties de l'ancien uid restent sur le serveur mais deviennent invisibles
-- pour l'app (RLS) → au lancement suivant la box Hive est vide, donc
-- _autoRestoreFromRidesTable ne restaure QUE les sorties du nouvel uid.
select
  u.id,
  u.created_at,
  u.last_sign_in_at,
  u.is_anonymous,
  u.email,
  (select count(*) from public.rides r            where r.user_id = u.id) as rides,
  (select count(*) from public.safety_sessions s  where s.user_id = u.id) as sessions
from auth.users u
order by u.created_at desc;

-- Sessions/positions orphelines (user_id NULL ou uid disparu) : invisibles pour
-- l'app, jamais récupérables autrement qu'ici.
select s.id, s.share_code, s.status, s.started_at, s.user_id,
       (select count(*) from public.safety_positions p where p.session_id = s.id) as positions
from public.safety_sessions s
left join auth.users u on u.id = s.user_id
where s.user_id is null or u.id is null
order by s.started_at desc;


-- ── 7. Timeline unifiée de la période de test ────────────────────────────────
-- Remet tout dans l'ordre chronologique : ouverture de session, fin de session,
-- sortie enregistrée, sortie récupérée. Ajuster la fenêtre de dates.
with ev as (
  select s.started_at as t, 'session ouverte' as quoi,
         coalesce(s.share_code, '?') || ' · ' || s.status as detail, s.user_id
  from public.safety_sessions s
  union all
  select s.ended_at, 'session fermée',
         coalesce(s.share_code, '?') || ' · ' || s.status, s.user_id
  from public.safety_sessions s where s.ended_at is not null
  union all
  select r.started_at,
         case when coalesce((r.ride_json->>'recovered')::bool, false)
              then 'SORTIE RÉCUPÉRÉE' else 'sortie enregistrée' end,
         r.ride_json->>'name', r.user_id
  from public.rides r
)
select * from ev
where t >= now() - interval '30 days'
order by t;
