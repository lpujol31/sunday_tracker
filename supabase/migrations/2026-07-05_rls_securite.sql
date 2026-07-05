-- =============================================================================
--  Sunday Tracker — Sécurisation RLS + RPC live + Storage
--  Appliqué le 2026-07-05 sur le projet Supabase eltlnrxiuvixjlakjfhz
-- -----------------------------------------------------------------------------
--  Contexte : l'app tourne avec la clé anon publique (embarquée dans le binaire)
--  + auth anonyme. Avant ce script, les traces GPS de tous les utilisateurs
--  étaient lisibles/supprimables par quiconque possédait la clé anon.
--
--  Ce fichier documente ET permet de rejouer l'état de sécurité. Il est
--  ré-exécutable (create or replace / drop if exists).
--
--  Consommateurs :
--    - app mobile (sunday_tracker)  : auth anonyme, écrit/lit SES propres données
--    - viewer web (sunday_tracker_live) : anon, lit une sortie via RPC + share_code
--    - app admin (sunday_tracker_live/admin) : à venir — login Supabase + is_admin()
-- =============================================================================


-- ── A. Fondation admin ───────────────────────────────────────────────────────
-- Liste blanche d'administrateurs (uid Supabase). Vide au départ : is_admin()
-- renvoie false pour tout le monde tant qu'aucun uid n'y est inséré.
create table if not exists public.admins (
  user_id    uuid primary key,
  note       text,
  created_at timestamptz default now()
);
alter table public.admins enable row level security;
-- Aucune policy => table invisible sauf via fonctions security-definer.

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

grant execute on function public.is_admin() to anon, authenticated;


-- ── B. RPC live : lecture ciblée par share_code ──────────────────────────────
-- Le viewer web n'accède plus aux tables safety_* en direct : il appelle cette
-- fonction, qui (security definer) contourne proprement la RLS et ne renvoie
-- QUE la session correspondant au share_code + ses positions.
create or replace function public.get_live_session(p_share_code text)
returns jsonb
language sql security definer
set search_path = public
as $$
  select jsonb_build_object(
    'session', to_jsonb(s) - 'user_id',
    'positions', coalesce((
      select jsonb_agg(to_jsonb(p))
      from (
        select latitude, longitude, altitude, created_at
        from public.safety_positions
        where session_id = s.id
        order by created_at desc
        limit 2500
      ) p
    ), '[]'::jsonb)
  )
  from public.safety_sessions s
  where s.share_code = p_share_code
  limit 1;
$$;

grant execute on function public.get_live_session(text) to anon, authenticated;


-- ── C. Table rides (store durable) ───────────────────────────────────────────
-- Policy « own rides only » (ALL, auth.uid() = user_id) PRÉ-EXISTANTE, conservée :
-- chacun ne lit/écrit/supprime que ses propres sorties.
--
-- On remplace l'ancienne policy « admin_delete » (qual = true, ouverte à tous)
-- par une version gatée is_admin().
drop policy if exists "admin_delete" on public.rides;
create policy "admin_delete" on public.rides
  for delete to public
  using (public.is_admin());


-- ── D. Table safety_sessions (buffer live + recovery) ────────────────────────
-- Policy « own sessions » (ALL, auth.uid() = user_id) PRÉ-EXISTANTE, conservée.
-- Devenue effective depuis que l'app renseigne user_id à la création de session.
--
-- Suppression du SELECT public global (qual = true) : le viewer passe désormais
-- par la RPC get_live_session, il n'a plus besoin d'un accès direct.
drop policy if exists "public read by share_code" on public.safety_sessions;

-- admin_delete ouvert -> gaté is_admin() (le propriétaire supprime déjà via "own sessions").
drop policy if exists "admin_delete" on public.safety_sessions;
create policy "admin_delete" on public.safety_sessions
  for delete to public
  using (public.is_admin());


-- ── E. Table safety_positions (trace GPS point par point) ────────────────────
-- Avant : RLS DÉSACTIVÉE => lecture/écriture/suppression libres pour l'anon.
-- C'était la fuite principale. On active la RLS et on scope tout par propriétaire
-- (via la session à laquelle la position appartient).
alter table public.safety_positions enable row level security;
drop policy if exists "admin_delete" on public.safety_positions;

drop policy if exists "insert own positions" on public.safety_positions;
create policy "insert own positions" on public.safety_positions
  for insert to public
  with check (exists (
    select 1 from public.safety_sessions s
    where s.id = session_id and s.user_id = auth.uid()
  ));

drop policy if exists "select own positions" on public.safety_positions;
create policy "select own positions" on public.safety_positions
  for select to public
  using (exists (
    select 1 from public.safety_sessions s
    where s.id = session_id and s.user_id = auth.uid()
  ));

drop policy if exists "delete own positions" on public.safety_positions;
create policy "delete own positions" on public.safety_positions
  for delete to public
  using (
    exists (
      select 1 from public.safety_sessions s
      where s.id = session_id and s.user_id = auth.uid()
    ) or public.is_admin()
  );


-- ── F. Storage : bucket waypoint-photos ──────────────────────────────────────
-- Le bucket est public EN LECTURE (affichage des photos via URL publique).
-- L'écriture/liste/suppression via l'API reste soumise à la RLS de storage.objects :
-- chacun ne manipule que son propre dossier {uid}/...
-- Chemin objet côté app : {userId}/{rideId}/{fichier.jpg}
drop policy if exists "waypoint insert own folder" on storage.objects;
create policy "waypoint insert own folder"
  on storage.objects for insert to public
  with check (
    bucket_id = 'waypoint-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "waypoint update own folder" on storage.objects;
create policy "waypoint update own folder"
  on storage.objects for update to public
  using (
    bucket_id = 'waypoint-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "waypoint select own folder" on storage.objects;
create policy "waypoint select own folder"
  on storage.objects for select to public
  using (
    bucket_id = 'waypoint-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "waypoint delete own folder" on storage.objects;
create policy "waypoint delete own folder"
  on storage.objects for delete to public
  using (
    bucket_id = 'waypoint-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- ── Vérification rapide ──────────────────────────────────────────────────────
-- En tant qu'anon, on ne doit plus pouvoir aspirer les positions :
--   set role anon; select count(*) from public.safety_positions; reset role;  -- attendu : 0
-- =============================================================================
