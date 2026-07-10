-- =============================================================================
--  Sunday Tracker — Bascule des rôles : admin = gmail, utilisateur = iCloud
--  Rectifie 2026-07-06_admin_access.sql. Re-exécutable.
-- -----------------------------------------------------------------------------
--  Nouveau partage :
--    • lpujol.novadys@gmail.com  → ADMIN (app web sunday_tracker_live/admin)
--    • lpujol31@icloud.com       → utilisateur normal (app mobile Sunday Tracker)
--
--  RAPPEL IMPORTANT : un compte admin voit TOUS les rides (policy admin_select).
--  L'app mobile ne doit donc jamais tourner sur un compte admin. D'où le retrait
--  de l'iCloud de public.admins ci-dessous.
--
--  Prérequis : les deux comptes existent déjà dans auth.users (connectés au
--  moins une fois).
-- =============================================================================

-- ── Retirer l'iCloud des admins (redevient utilisateur normal) ───────────────
delete from public.admins
where user_id in (
  select id from auth.users where lower(email) = 'lpujol31@icloud.com'
);

-- ── S'assurer que le gmail est admin ─────────────────────────────────────────
insert into public.admins (user_id)
select id from auth.users where lower(email) = 'lpujol.novadys@gmail.com'
on conflict (user_id) do nothing;

-- ── Vérification ─────────────────────────────────────────────────────────────
-- select u.email from public.admins a join auth.users u on u.id = a.user_id;
--   → doit lister UNIQUEMENT lpujol.novadys@gmail.com
-- =============================================================================
