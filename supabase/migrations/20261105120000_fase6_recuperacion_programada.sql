-- =====================================================================================
-- Migración 20261105120000 · fase 6: recuperación PROGRAMADA de entregas de invitaciones.
-- Se aplica DESPUÉS de 20261104120000_fase6_invitaciones.sql.
--
-- Cada 5 minutos, pg_cron ejecuta private.invitations_recovery_tick(). Si hay entregas atrasadas o
-- interrumpidas, llama con pg_net a la Edge Function «invitations-recovery», que las recupera con
-- las mismas reservas atómicas, intentos y esperas que la función de invitaciones. Si no hay
-- ninguna, no llama a nada (no gasta invocaciones).
--
-- Necesita las extensiones pg_cron y pg_net (Supabase las incluye; esta migración las activa) y
-- Supabase Vault (activado por defecto en Supabase). NO contiene secretos: la URL de la función y
-- el secreto compartido se guardan en Vault DESPUÉS, a mano (ver supabase/functions/invitations/README.md).
-- Sin esos secretos la tarea no llama a nada y lo anota como «sin_configurar».
--
-- NO borra ni modifica datos. Se puede ejecutar más de una vez: la tarea programada tiene nombre
-- fijo y se actualiza en lugar de duplicarse.
-- Para deshacerla: supabase/migrations_down/20261105120000_fase6_recuperacion_programada.down.sql
-- =====================================================================================

begin;

-- ---------- Extensiones ----------
do $$ begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
      raise exception 'Esta migración necesita la extensión pg_cron (en Supabase: Database → Extensions)';
    end if;
    create extension pg_cron;
  end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    if not exists (select 1 from pg_available_extensions where name = 'pg_net') then
      raise exception 'Esta migración necesita la extensión pg_net (en Supabase: Database → Extensions)';
    end if;
    create schema if not exists extensions;
    create extension if not exists pg_net with schema extensions;
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    if not exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
      raise exception 'Esta migración necesita Supabase Vault (extensión supabase_vault)';
    end if;
    create extension if not exists supabase_vault;
  end if;
end $$;

-- ---------- Registro de ejecuciones (para comprobar que la tarea funciona) ----------
-- Una fila por ejecución, 7 días. Sin datos personales ni secretos. La respuesta HTTP de cada
-- llamada (estado y resumen) la guarda pg_net en net._http_response (unas horas).
create table if not exists private.invitations_recovery_runs (
  id bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  outcome text not null check (outcome in ('sin_pendientes', 'solicitada', 'sin_configurar', 'error')),
  request_id bigint,
  detail text check (char_length(detail) <= 300)
);
create index if not exists invitations_recovery_runs_started_idx on private.invitations_recovery_runs (started_at desc);
revoke all on private.invitations_recovery_runs from public, anon, authenticated, service_role;
alter table private.invitations_recovery_runs enable row level security;

-- ---------- Ejecución programada ----------
-- ¿Hay entregas que recuperar? (Mismas condiciones que public.invitation_delivery_pending, más las
-- reservas caducadas que ya no se pueden retomar, para que la función las cierre como «fallida».)
create or replace function private.invitations_recovery_due() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.invitations i
    where i.send_status in ('sin_enviar', 'enviando')
      and ((i.send_status = 'enviando' and i.send_claimed_at <= now() - interval '10 minutes')
           or (i.status = 'pendiente' and i.expires_at > now() and i.send_attempts < 3
               and coalesce(i.send_next_at, i.created_at + interval '2 minutes') <= now())))
$$;

-- La ejecuta pg_cron cada 5 minutos (como el usuario que creó la tarea; nadie de la API puede).
-- Lee de Vault la URL y el secreto, y llama a la Edge Function con pg_net (asíncrono: no espera la
-- respuesta). Nunca lanza un error: lo anota.
create or replace function private.invitations_recovery_tick() returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
  v_request bigint;
begin
  delete from private.invitations_recovery_runs where started_at < now() - interval '7 days';
  if not private.invitations_recovery_due() then
    insert into private.invitations_recovery_runs (outcome) values ('sin_pendientes');
    return null;
  end if;
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'turestaurante_recovery_url';
  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'turestaurante_recovery_secret';
  -- Solo se envía el secreto a la función de recuperación: por https, o por http únicamente dentro
  -- de Supabase local (localhost, host.docker.internal o el contenedor kong).
  if v_url is null or v_url !~ ('^(https://[a-z0-9.-]+(:[0-9]+)?'
       || '|http://(localhost|127\.0\.0\.1|host\.docker\.internal|[a-z0-9_.-]*kong[a-z0-9_.-]*)(:[0-9]+)?)'
       || '/functions/v1/invitations-recovery$') then
    insert into private.invitations_recovery_runs (outcome, detail)
    values ('sin_configurar', 'Falta o no es válida la URL de la función en Vault (turestaurante_recovery_url)');
    return null;
  end if;
  if v_secret is null or char_length(v_secret) < 32 then
    insert into private.invitations_recovery_runs (outcome, detail)
    values ('sin_configurar', 'Falta o es demasiado corto el secreto en Vault (turestaurante_recovery_secret, mínimo 32 caracteres)');
    return null;
  end if;
  begin
    select net.http_post(
      url := v_url,
      body := jsonb_build_object('action', 'recover'),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-turestaurante-recovery', v_secret),
      timeout_milliseconds := 30000
    ) into v_request;
  exception when others then
    insert into private.invitations_recovery_runs (outcome, detail) values ('error', left(sqlerrm, 300));
    return null;
  end;
  insert into private.invitations_recovery_runs (outcome, request_id) values ('solicitada', v_request);
  return v_request;
end $$;

-- ---------- Comprobar que funciona (solo la plataforma) ----------
create or replace function private.try_jsonb(p_text text) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  return p_text::jsonb;
exception when others then
  return null;
end $$;

-- Últimas ejecuciones con la respuesta de la función (estado HTTP y resumen, sin datos personales).
create or replace function public.invitations_recovery_status(p_limit int default 20)
returns table (started_at timestamptz, outcome text, detail text, http_status int, timed_out boolean, http_error text,
  summary jsonb)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede ver la recuperación de invitaciones' using errcode = '42501';
  end if;
  return query
    select r.started_at, r.outcome, r.detail, h.status_code, h.timed_out, h.error_msg, private.try_jsonb(h.content)
    from private.invitations_recovery_runs r left join net._http_response h on h.id = r.request_id
    order by r.id desc
    limit greatest(1, least(coalesce(p_limit, 20), 200));
end $$;

-- La tarea programada: frecuencia, si está activa y su última ejecución en pg_cron.
create or replace function public.invitations_recovery_job()
returns table (jobname text, schedule text, active boolean, last_status text, last_start timestamptz, last_message text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede ver la recuperación de invitaciones' using errcode = '42501';
  end if;
  return query
    select j.jobname::text, j.schedule::text, j.active, d.status::text, d.start_time, left(d.return_message, 300)
    from cron.job j
    left join lateral (select x.status, x.start_time, x.return_message from cron.job_run_details x
                       where x.jobid = j.jobid order by x.runid desc limit 1) d on true
    where j.jobname = 'turestaurante-recuperar-invitaciones';
end $$;

revoke all on function private.invitations_recovery_due(), private.invitations_recovery_tick(), private.try_jsonb(text)
  from public, anon, authenticated, service_role;
revoke all on function public.invitations_recovery_status(int), public.invitations_recovery_job()
  from public, anon, authenticated, service_role;
grant execute on function public.invitations_recovery_status(int), public.invitations_recovery_job() to authenticated;

-- ---------- La tarea (cada 5 minutos) ----------
-- cron.schedule con nombre CREA o ACTUALIZA la tarea de ese nombre: repetir la migración no la
-- duplica. Si existieran copias (versiones antiguas de pg_cron), se quitan y queda una.
do $$
declare
  v_keep bigint;
begin
  v_keep := cron.schedule('turestaurante-recuperar-invitaciones', '*/5 * * * *',
    'select private.invitations_recovery_tick()');
  perform cron.unschedule(j.jobid) from cron.job j
  where j.jobname = 'turestaurante-recuperar-invitaciones' and j.jobid <> v_keep;
end $$;

commit;
