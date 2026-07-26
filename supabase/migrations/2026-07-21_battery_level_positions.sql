-- =============================================================================
--  Sunday Tracker — Niveau de batterie du téléphone sur les positions live
-- -----------------------------------------------------------------------------
--  Objectif : le suiveur (sunday_tracker_live) voit l'autonomie restante du
--  téléphone dans l'encart « Dernière position ». Utile pour interpréter un
--  live qui s'arrête : batterie à 4 % ≠ chute.
--
--  L'app renseigne `battery_level` (0-100) sur chaque position envoyée ; la
--  valeur vient du relevé batterie rafraîchi toutes les 60 s pendant la sortie.
--  Colonne nullable : les anciennes positions et les plateformes sans info
--  batterie (émulateur) restent à NULL.
--
--  Ré-exécutable.
-- =============================================================================

alter table public.safety_positions
  add column if not exists battery_level smallint;

comment on column public.safety_positions.battery_level is
  'Niveau de batterie du téléphone (0-100 %) au moment du point GPS. NULL si inconnu.';

-- Le viewer web passe par la RPC : il faut y exposer la nouvelle colonne.
-- (Reprise à l'identique de 2026-07-05_rls_securite.sql, + battery_level.)
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
        select latitude, longitude, altitude, created_at, battery_level
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
