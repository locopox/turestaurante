-- =====================================================================================
-- DESHACER la migración 20261105120000 · recuperación programada de invitaciones.
--
-- Quita la tarea de pg_cron, sus funciones y el registro de ejecuciones (private.invitations_recovery_runs,
-- solo datos de funcionamiento). NO toca invitaciones, entregas, pedidos, personal ni cuentas.
-- NO desactiva pg_cron, pg_net ni Vault (puede que los use otra cosa) ni borra los secretos de Vault:
-- si ya no los quieres, bórralos a mano (ver supabase/functions/invitations/README.md).
-- Las entregas pendientes se seguirán recuperando en cada llamada a la función «invitations».
-- =====================================================================================

begin;

do $$ begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'turestaurante-recuperar-invitaciones';
  end if;
end $$;

drop function if exists public.invitations_recovery_job();
drop function if exists public.invitations_recovery_status(int);
drop function if exists private.invitations_recovery_tick();
drop function if exists private.invitations_recovery_due();
drop function if exists private.try_jsonb(text);
drop table if exists private.invitations_recovery_runs;

commit;
