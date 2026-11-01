-- =====================================================================================
-- Migración 20261103120000 · fase 5: caducidad de solicitudes de soporte (24 h) y registro de
-- intentos de consulta denegados.
-- Se aplica DESPUÉS de 20261102120000_fase4_modo_soporte.sql (rama fase4-modo-soporte, b48fb53).
-- Equivale a los bloques «-- >>> fase5» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos. Añade private.support_denials y funciones, y sustituye algunas
-- funciones del modo soporte. CAMBIO DE RESPUESTA: support_view_* devuelven ahora
-- {ok: true, data} o {ok: false, reason, message} (antes, los datos o un error).
-- Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261103120000_fase5_soporte_caducidad_registro.down.sql
-- =====================================================================================

begin;

-- Intentos DENEGADOS de consulta de soporte. Privada: no es accesible por la API. Sin contraseñas,
-- tokens ni emails (el email se obtiene al leer). Los intentos iguales se AGRUPAN por ventanas de
-- 10 minutos (contador «attempts») para que repetir peticiones no sature el registro.
create table if not exists private.support_denials (
  id bigint generated always as identity primary key,
  window_start timestamptz not null,
  actor_user_id uuid,
  actor_kind text not null check (actor_kind in ('plataforma', 'personal', 'cliente', 'servidor', 'sql_editor')),
  restaurant_id uuid,
  operation text not null check (operation in ('estado', 'pedidos', 'avisos_pago', 'varias')),
  reason text not null check (reason in ('sin_sesion', 'no_es_plataforma', 'restaurante_inexistente', 'sin_solicitud',
    'pendiente', 'solicitud_caducada', 'rechazada', 'revocada', 'cancelada', 'caducada', 'otro_restaurante', 'limite_superado')),
  attempts int not null default 1 check (attempts >= 1),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  constraint support_denials_key unique nulls not distinct (window_start, actor_user_id, restaurant_id, operation, reason)
);
create index if not exists support_denials_restaurant_idx on private.support_denials (restaurant_id, last_at desc);
create index if not exists support_denials_actor_idx on private.support_denials (actor_user_id, window_start);

-- Una solicitud pendiente caduca a las 24 horas de crearse. Fuente única del plazo.
create or replace function private.support_pending_ttl() returns interval
language sql immutable set search_path = '' as $$ select interval '24 hours' $$;

-- Estado efectivo: «solicitud_caducada» (pendiente con más de 24 h) y «caducada» (acceso aprobado
-- cuyas 2 horas ya pasaron). Se calcula siempre a partir de la hora: no depende de tareas programadas.
create or replace function private.support_state(p_status text, p_requested_at timestamptz, p_expires_at timestamptz) returns text
language sql stable set search_path = '' as $$
  select case
    when p_status = 'pendiente' and p_requested_at <= now() - private.support_pending_ttl() then 'solicitud_caducada'
    else private.support_status(p_status, p_expires_at)
  end
$$;

-- Por qué se deniega una consulta de soporte (para el registro de denegaciones).
create or replace function private.support_denial_reason(rid uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when (select auth.uid()) is null then 'sin_sesion'
    when not private.is_platform_admin() then 'no_es_plataforma'
    when rid is null or not exists (select 1 from public.restaurants r where r.id = rid) then 'restaurante_inexistente'
    else coalesce(
      -- Estado de la solicitud de este usuario para este restaurante cuyo último evento (creación,
      -- decisión o revocación) es el más reciente. greatest() ignora los null.
      (select private.support_state(g.status, g.requested_at, g.expires_at) from private.support_grants g
       where g.restaurant_id = rid and g.requested_by = (select auth.uid())
       order by greatest(g.requested_at, g.decided_at, g.revoked_at) desc limit 1),
      -- Ninguna para este restaurante, pero sí un acceso activo en otro.
      case when exists (select 1 from private.support_grants g
                        where g.requested_by = (select auth.uid()) and g.restaurant_id <> rid
                          and g.status = 'aprobada' and g.expires_at > now())
           then 'otro_restaurante' else 'sin_solicitud' end)
  end
$$;

create or replace function private.support_denial_message(p_reason text) returns text
language sql immutable set search_path = '' as $$
  select case p_reason
    when 'pendiente' then 'La solicitud está pendiente de aprobación del propietario'
    when 'solicitud_caducada' then 'La solicitud caducó sin respuesta (24 horas). Crea una nueva'
    when 'rechazada' then 'El propietario rechazó la solicitud'
    when 'revocada' then 'El propietario revocó el acceso'
    when 'cancelada' then 'La solicitud o el acceso se cancelaron'
    when 'caducada' then 'El acceso de 2 horas ha caducado'
    when 'otro_restaurante' then 'Tu acceso de soporte es para otro restaurante'
    when 'restaurante_inexistente' then 'Restaurante no encontrado'
    when 'no_es_plataforma' then 'Solo la plataforma puede usar el modo soporte'
    else 'No tienes un acceso de soporte activo para este restaurante'
  end
$$;

-- Anota un intento denegado. La llama SOLO el propio servidor (no es ejecutable por la API): el
-- usuario sale de la sesión, no de un parámetro, así que no se puede falsificar. Los intentos iguales
-- en la misma ventana de 10 minutos suman 1 al contador; con más de 50 combinaciones distintas por
-- usuario y ventana, el resto se agrupa en una única fila «limite_superado».
create or replace function private.support_log_denial(p_restaurant_id uuid, p_operation text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  c_max_keys constant int := 50;
  v_uid uuid := (select auth.uid());
  v_window timestamptz := date_bin('10 minutes', now(), timestamptz '2000-01-01 00:00:00+00');
  v_restaurant uuid := p_restaurant_id;
  v_operation text := p_operation;
  v_reason text := p_reason;
begin
  if not exists (select 1 from private.support_denials d
                 where d.window_start = v_window and d.actor_user_id is not distinct from v_uid
                   and d.restaurant_id is not distinct from v_restaurant and d.operation = v_operation and d.reason = v_reason)
     and (select count(*) from private.support_denials d
          where d.window_start = v_window and d.actor_user_id is not distinct from v_uid) >= c_max_keys then
    v_restaurant := null;
    v_operation := 'varias';
    v_reason := 'limite_superado';
  end if;
  insert into private.support_denials (window_start, actor_user_id, actor_kind, restaurant_id, operation, reason)
  values (v_window, v_uid, private.actor_kind(), v_restaurant, v_operation, v_reason)
  on conflict on constraint support_denials_key
  do update set attempts = private.support_denials.attempts + 1, last_at = now();
end $$;

-- Comprueba el acceso vigente. Si existe, registra la consulta y devuelve el id del acceso. Si NO,
-- anota el intento denegado y devuelve null SIN lanzar error: así la anotación se guarda (una
-- excepción desharía también la inserción). Las funciones support_view_* responden {ok: false}.
create or replace function private.support_require(rid uuid, p_query text, p_details jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_grant uuid := private.support_active_grant(rid);
begin
  if v_grant is null then
    perform private.support_log_denial(rid, p_query, private.support_denial_reason(rid));
    return null;
  end if;
  perform private.audit_insert(rid, 'soporte.consulta', 'support_grants', v_grant::text,
    jsonb_build_object('consulta', p_query) || coalesce(p_details, '{}'::jsonb));
  return v_grant;
end $$;

create or replace function public.support_request(p_restaurant_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_reason text := btrim(coalesce(p_reason, ''));
  v_email text;
  v_id uuid;
begin
  if v_uid is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede solicitar acceso de soporte' using errcode = '42501';
  end if;
  if char_length(v_reason) < 10 or char_length(v_reason) > 300 then
    raise exception 'Explica el motivo de la solicitud (de 10 a 300 caracteres)' using errcode = '22023';
  end if;
  perform 1 from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  if exists (select 1 from private.support_grants g
             where g.restaurant_id = p_restaurant_id and g.requested_by = v_uid
               and private.support_state(g.status, g.requested_at, g.expires_at) in ('pendiente', 'aprobada')) then
    raise exception 'Ya tienes una solicitud pendiente o un acceso activo para este restaurante' using errcode = '22023';
  end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason)
  values (p_restaurant_id, v_uid, coalesce(v_email, ''), v_reason)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.support_decide(p_grant_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  g private.support_grants;
  v_email text;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para responder a la solicitud' using errcode = '42501';
  end if;
  select * into g from private.support_grants where id = p_grant_id for update;
  -- Mismo mensaje si no existe o si no es propietario de ese restaurante.
  if not found or private.staff_role_for(g.restaurant_id) is distinct from 'owner'::public.staff_role then
    raise exception 'Solo el propietario del restaurante puede responder a esta solicitud' using errcode = '42501';
  end if;
  if g.requested_by = v_uid or private.is_platform_admin() then
    raise exception 'No puedes aprobar tu propia solicitud de soporte' using errcode = '42501';
  end if;
  if private.support_state(g.status, g.requested_at, g.expires_at) = 'solicitud_caducada' then
    raise exception 'La solicitud caducó sin respuesta (24 horas). La plataforma debe crear una nueva' using errcode = '22023';
  end if;
  if g.status <> 'pendiente' then
    raise exception 'Esta solicitud ya no está pendiente' using errcode = '22023';
  end if;
  if p_approve is null then
    raise exception 'Indica si apruebas o rechazas la solicitud' using errcode = '22023';
  end if;
  if p_approve and not exists (select 1 from public.platform_admins pa where pa.user_id = g.requested_by) then
    raise exception 'Quien lo solicitó ya no es administrador de la plataforma' using errcode = '22023';
  end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  update private.support_grants
  set status = case when p_approve then 'aprobada' else 'rechazada' end,
      decided_at = now(), decided_by = v_uid, decided_by_email = coalesce(v_email, ''),
      expires_at = case when p_approve then now() + interval '2 hours' end
  where id = g.id;
end $$;

create or replace function public.support_cancel(p_grant_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  g private.support_grants;
begin
  select * into g from private.support_grants where id = p_grant_id for update;
  if v_uid is null or not found or g.requested_by <> v_uid then
    raise exception 'Solicitud no encontrada' using errcode = '42501';
  end if;
  if private.support_state(g.status, g.requested_at, g.expires_at) not in ('pendiente', 'aprobada') then
    raise exception 'Esta solicitud ya está cerrada' using errcode = '22023';
  end if;
  update private.support_grants set status = 'cancelada', revoked_at = now(), revoked_by = v_uid where id = g.id;
end $$;

create or replace function public.support_list_for_restaurant(p_restaurant_id uuid)
returns table (id uuid, requested_by_email text, reason text, status text, requested_at timestamptz,
  decided_at timestamptz, decided_by_email text, expires_at timestamptz, revoked_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if private.staff_role_for(p_restaurant_id) is distinct from 'owner'::public.staff_role then
    raise exception 'Solo el propietario puede ver las solicitudes de soporte' using errcode = '42501';
  end if;
  return query
    select g.id, g.requested_by_email, g.reason, private.support_state(g.status, g.requested_at, g.expires_at), g.requested_at,
      g.decided_at, g.decided_by_email, g.expires_at, g.revoked_at
    from private.support_grants g where g.restaurant_id = p_restaurant_id
    order by g.requested_at desc limit 100;
end $$;

create or replace function public.support_my_requests()
returns table (id uuid, restaurant_id uuid, restaurant_name text, reason text, status text, requested_at timestamptz,
  decided_at timestamptz, decided_by_email text, expires_at timestamptz, revoked_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma tiene solicitudes de soporte' using errcode = '42501';
  end if;
  return query
    select g.id, g.restaurant_id, r.name, g.reason, private.support_state(g.status, g.requested_at, g.expires_at), g.requested_at,
      g.decided_at, g.decided_by_email, g.expires_at, g.revoked_at
    from private.support_grants g join public.restaurants r on r.id = g.restaurant_id
    where g.requested_by = (select auth.uid())
    order by g.requested_at desc limit 100;
end $$;

-- Respuesta de una consulta denegada: solo el motivo, nunca datos.
create or replace function private.support_denied_response(rid uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', false, 'reason', private.support_denial_reason(rid),
    'message', private.support_denial_message(private.support_denial_reason(rid)))
$$;

-- Intentos denegados de un restaurante (su owner) o de toda la plataforma (plataforma, con null).
create or replace function public.support_denials_list(p_restaurant_id uuid)
returns table (first_at timestamptz, last_at timestamptz, actor_email text, actor_kind text,
  restaurant_id uuid, operation text, reason text, attempts int)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'Inicia sesión para ver los intentos denegados' using errcode = '42501';
  end if;
  -- coalesce: sin rol, staff_role_for devuelve null y la comparación también; null debe contar como «no».
  if not coalesce(private.is_platform_admin()
          or (p_restaurant_id is not null and private.staff_role_for(p_restaurant_id) = 'owner'::public.staff_role), false) then
    raise exception 'No tienes acceso a estos intentos' using errcode = '42501';
  end if;
  return query
    select d.first_at, d.last_at, u.email::text, d.actor_kind, d.restaurant_id, d.operation, d.reason, d.attempts
    from private.support_denials d left join auth.users u on u.id = d.actor_user_id
    where p_restaurant_id is null or d.restaurant_id = p_restaurant_id
    order by d.last_at desc limit 200;
end $$;

-- Las denegaciones solo se añaden o se cuentan: no se borran ni se reescriben.
create or replace function private.guard_support_denials() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'El registro de intentos denegados no se puede borrar' using errcode = '42501';
  end if;
  if (new.id, new.window_start, new.actor_user_id, new.actor_kind, new.restaurant_id, new.operation, new.reason, new.first_at)
     is distinct from (old.id, old.window_start, old.actor_user_id, old.actor_kind, old.restaurant_id, old.operation, old.reason, old.first_at)
     or new.attempts < old.attempts or new.last_at < old.last_at then
    raise exception 'El registro de intentos denegados no se puede modificar' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists support_denials_guard on private.support_denials;
create trigger support_denials_guard before update or delete on private.support_denials
  for each row execute function private.guard_support_denials();
drop trigger if exists support_denials_no_truncate on private.support_denials;
create trigger support_denials_no_truncate before truncate on private.support_denials
  for each statement execute function private.guard_support_denials();

create or replace function public.support_view_restaurant(p_restaurant_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_grant uuid := private.support_require(p_restaurant_id, 'estado', '{}'::jsonb);
begin
  if v_grant is null then
    return private.support_denied_response(p_restaurant_id);
  end if;
  return jsonb_build_object('ok', true, 'data', jsonb_build_object(
    'expiresAt', (select g.expires_at from private.support_grants g where g.id = v_grant),
    'restaurant', (select jsonb_build_object('name', r.name, 'slug', r.slug, 'active', r.active,
        'suspended', r.suspended_at is not null, 'tables', r.tables, 'pickupEnabled', r.pickup_enabled,
        'onlinePaymentEnabled', r.online_payment_enabled, 'counterPaymentEnabled', r.counter_payment_enabled,
        'prepMinutes', r.prep_minutes)
      from public.restaurants r where r.id = p_restaurant_id),
    'menu', (select jsonb_build_object(
        'categories', (select count(*) from public.categories c where c.restaurant_id = p_restaurant_id),
        'products', count(*), 'unavailable', count(*) filter (where not p.available))
      from public.products p where p.restaurant_id = p_restaurant_id),
    'staff', (select coalesce(jsonb_object_agg(x.role, x.n), '{}'::jsonb)
      from (select s.role::text as role, count(*) as n from public.restaurant_staff s
            where s.restaurant_id = p_restaurant_id group by s.role) x),
    'orders', (select jsonb_build_object(
        'last24h', count(*) filter (where o.created_at > now() - interval '24 hours'),
        'inProgress', count(*) filter (where o.prep_status in ('nuevo', 'en_preparacion', 'listo')),
        'pendingOnline', count(*) filter (where o.payment_status = 'pendiente_online'),
        'pendingCounter', count(*) filter (where o.payment_status = 'pendiente_caja' and o.prep_status <> 'cancelado'),
        'lastOrderAt', max(o.created_at))
      from public.orders o where o.restaurant_id = p_restaurant_id)));
end $$;

create or replace function public.support_view_orders(p_restaurant_id uuid, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if private.support_require(p_restaurant_id, 'pedidos', jsonb_build_object('limite', v_limit)) is null then
    return private.support_denied_response(p_restaurant_id);
  end if;
  return jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(t.obj order by t.created_at desc)
    from (
      select o.created_at, jsonb_build_object(
        'number', o.number, 'createdAt', o.created_at, 'updatedAt', o.updated_at, 'mode', o.mode,
        'table', o.table_number, 'pickupTime', o.pickup_time, 'prepStatus', o.prep_status,
        'paymentMethod', o.payment_method, 'paymentStatus', o.payment_status, 'total', o.total_cents,
        'hasNotes', o.notes <> '', 'hasPaymentRef', o.payment_ref is not null,
        'items', coalesce((
          select jsonb_agg(jsonb_build_object('name', i.name, 'quantity', i.quantity,
            'unitPrice', i.unit_price_cents, 'hasNotes', i.notes is not null) order by i.id)
          from public.order_items i where i.order_id = o.id), '[]'::jsonb)) as obj
      from public.orders o
      where o.restaurant_id = p_restaurant_id
      order by o.created_at desc
      limit v_limit) t), '[]'::jsonb));
end $$;

create or replace function public.support_view_payment_events(p_restaurant_id uuid, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if private.support_require(p_restaurant_id, 'avisos_pago', jsonb_build_object('limite', v_limit)) is null then
    return private.support_denied_response(p_restaurant_id);
  end if;
  return jsonb_build_object('ok', true, 'data', coalesce((
    select jsonb_agg(t.obj order by t.created_at desc)
    from (
      select e.created_at, jsonb_build_object('createdAt', e.created_at, 'outcome', e.outcome,
        'resolution', e.resolution, 'amount', e.amount_cents, 'detail', e.detail, 'orderNumber', o.number) as obj
      from public.payment_events e left join public.orders o on o.id = e.order_id
      where e.restaurant_id = p_restaurant_id
      order by e.created_at desc
      limit v_limit) t), '[]'::jsonb));
end $$;

create or replace function private.guard_support_grants() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'El historial de accesos de soporte no se puede borrar' using errcode = '42501';
  end if;
  -- Toda solicitud nace pendiente: un acceso solo existe si el propietario lo aprueba.
  if tg_op = 'INSERT' then
    if new.status <> 'pendiente' or new.decided_at is not null or new.decided_by is not null
       or new.expires_at is not null or new.revoked_at is not null or new.revoked_by is not null then
      raise exception 'Una solicitud de soporte siempre empieza pendiente de aprobación' using errcode = '42501';
    end if;
    -- Fecha futura = solicitud que no caducaría a su hora.
    if new.requested_at > now() then
      raise exception 'Una solicitud de soporte no puede tener fecha futura' using errcode = '42501';
    end if;
    return new;
  end if;
  if (new.id, new.restaurant_id, new.requested_by, new.requested_by_email, new.reason, new.requested_at)
     is distinct from (old.id, old.restaurant_id, old.requested_by, old.requested_by_email, old.reason, old.requested_at) then
    raise exception 'Los datos de una solicitud de soporte no se pueden modificar' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    -- Una solicitud con más de 24 horas sin respuesta ya no se puede aprobar ni rechazar.
    if old.status = 'pendiente' and new.status in ('aprobada', 'rechazada')
       and old.requested_at <= now() - private.support_pending_ttl() then
      raise exception 'La solicitud caducó sin respuesta (24 horas). La plataforma debe crear una nueva' using errcode = '42501';
    end if;
    if not ((old.status = 'pendiente' and new.status in ('aprobada', 'rechazada', 'cancelada'))
         or (old.status = 'aprobada' and new.status in ('revocada', 'cancelada'))) then
      raise exception 'Cambio de estado de soporte no permitido' using errcode = '42501';
    end if;
    if old.status = 'aprobada'
       and (new.decided_at, new.decided_by, new.expires_at) is distinct from (old.decided_at, old.decided_by, old.expires_at) then
      raise exception 'Un acceso de soporte no se puede ampliar ni modificar' using errcode = '42501';
    end if;
  elsif (new.decided_at, new.decided_by, new.decided_by_email, new.expires_at, new.revoked_at, new.revoked_by)
        is distinct from (old.decided_at, old.decided_by, old.decided_by_email, old.expires_at, old.revoked_at, old.revoked_by) then
    -- Sin cambio de estado, lo único posible es adelantar la caducidad de un acceso aprobado.
    if not (old.status = 'aprobada' and new.expires_at < old.expires_at
            and (new.decided_by, new.decided_by_email, new.revoked_at, new.revoked_by)
                is not distinct from (old.decided_by, old.decided_by_email, old.revoked_at, old.revoked_by)) then
      raise exception 'Un acceso de soporte no se puede ampliar ni modificar' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- Funciones internas: nadie de la API puede ejecutarlas (así nadie puede anotar denegaciones falsas).
revoke all on function private.support_pending_ttl(), private.support_state(text, timestamptz, timestamptz),
  private.support_denial_reason(uuid), private.support_denial_message(text),
  private.support_log_denial(uuid, text, text), private.support_denied_response(uuid), private.guard_support_denials()
  from public, anon, authenticated;
revoke all on function public.support_denials_list(uuid) from public, anon, authenticated;
grant execute on function public.support_denials_list(uuid) to authenticated;

-- Intentos denegados: nadie los lee ni escribe por la API (se leen con support_denials_list).
revoke all on private.support_denials from public, anon, authenticated, service_role;
alter table private.support_denials enable row level security;

commit;
