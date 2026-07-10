-- =============================================================================
--  Sunday Tracker — Acces admin (magic link Supabase)
--  Complete 2026-07-05_rls_securite.sql. Re-executable.
-- -----------------------------------------------------------------------------
--  L'app admin (sunday_tracker_live/admin) se connecte desormais a Supabase par
--  magic link. Son utilisateur doit figurer dans public.admins pour que
--  is_admin() renvoie true. Ces policies donnent alors a l'admin la lecture (et
--  l'ecriture necessaire au nettoyage) sur les donnees de TOUS les utilisateurs.
--
--  ORDRE : se connecter UNE fois via le magic link AVANT de lancer ce script,
--  pour que le compte existe dans auth.users (section A).
-- =============================================================================

-- ── A. Declarer l'admin ──────────────────────────────────────────────────────
-- NB : depuis 2026-07-10_admin_swap.sql, seul le gmail est admin (l'iCloud est
-- redevenu un compte utilisateur mobile). Liste alignee ci-dessous pour que le
-- re-jeu de ce script ne re-ajoute pas l'iCloud.
insert into public.admins (user_id)
select id from auth.users
where lower(email) in ('lpujol.novadys@gmail.com')
on conflict (user_id) do nothing;

-- ── B. rides : lecture + update admin (le delete admin existe deja) ───────────
drop policy if exists "admin_select" on public.rides;
create policy "admin_select" on public.rides
  for select to public using (public.is_admin());

drop policy if exists "admin_update" on public.rides;
create policy "admin_update" on public.rides
  for update to public using (public.is_admin());

-- ── C. safety_sessions : lecture admin (le delete admin existe deja) ──────────
drop policy if exists "admin_select" on public.safety_sessions;
create policy "admin_select" on public.safety_sessions
  for select to public using (public.is_admin());

-- ── D. safety_positions : lecture admin (delete admin deja via clause is_admin) ─
drop policy if exists "admin_select" on public.safety_positions;
create policy "admin_select" on public.safety_positions
  for select to public using (public.is_admin());

-- ── E. Storage waypoint-photos : lecture + suppression admin ──────────────────
drop policy if exists "waypoint admin select" on storage.objects;
create policy "waypoint admin select" on storage.objects
  for select to public
  using (bucket_id = 'waypoint-photos' and public.is_admin());

drop policy if exists "waypoint admin delete" on storage.objects;
create policy "waypoint admin delete" on storage.objects
  for delete to public
  using (bucket_id = 'waypoint-photos' and public.is_admin());

-- ── Verification ─────────────────────────────────────────────────────────────
-- Connecte en tant qu'admin (via l'app), un select doit renvoyer des lignes :
--   select count(*) from public.rides;            -- > 0 attendu
--   select count(*) from public.safety_sessions;  -- > 0 attendu
-- =============================================================================
