-- =====================================================================================
-- Migración 20261102120000 · fase 4: modo soporte (solo lectura, aprobado por el propietario)
-- Se aplica DESPUÉS de 20261101120000_fase3_seguridad_roles.sql (rama fase3-seguridad-roles, 07348e4).
-- Equivale a los bloques «-- >>> fase4» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos ni objetos existentes: solo añade la tabla private.support_grants,
-- sus funciones, triggers y permisos. Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261102120000_fase4_modo_soporte.down.sql
-- =====================================================================================

begin;

-- Modo soporte: accesos de SOLO LECTURA de una cuenta de plataforma a UN restaurante, aprobados
-- por su propietario y válidos exactamente 2 horas. Tabla privada: no es accesible por la API.
-- Las consultas se hacen solo con las funciones support_view_* (comprueban y registran cada una).
create table if not exists private.support_grants (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete restrict,
  requested_by uuid not null,
  requested_by_email text not null,
  reason text not null check (char_length(btrim(reason)) between 10 and 300),
  status text not null default 'pendiente'
    check (status in ('pendiente', 'aprobada', 'rechazada', 'revocada', 'cancelada')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  decided_by_email text,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  -- La duración es SIEMPRE 2 horas desde la aprobación (se puede acortar, nunca ampliar: ver trigger).
  constraint support_grants_two_hours check (expires_at is null or expires_at <= decided_at + interval '2 hours'),
  constraint support_grants_decided check (status in ('pendiente', 'cancelada') or decided_at is not null),
  constraint support_grants_approved_expiry check (status <> 'aprobada' or expires_at is not null)
);
create index if not exists support_grants_restaurant_idx on private.support_grants (restaurant_id, requested_at desc);
create index if not exists support_grants_requester_idx on private.support_grants (requested_by, requested_at desc);

-- ---------- Modo soporte ----------
-- Estado visible: un acceso aprobado cuya hora ya pasó aparece como «caducada».
create or replace function private.support_status(p_status text, p_expires_at timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when p_status = 'aprobada' and p_expires_at <= now() then 'caducada' else p_status end
$$;

-- Acceso de soporte vigente del usuario actual para ese restaurante, o null. Se evalúa en CADA
-- consulta: la caducidad, la revocación o dejar de ser plataforma cortan el acceso al momento.
create or replace function private.support_active_grant(rid uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select g.id from private.support_grants g
  where g.restaurant_id = rid and g.requested_by = (select auth.uid())
    and g.status = 'aprobada' and g.expires_at > now()
    and private.is_platform_admin()
  order by g.decided_at desc
  limit 1
$$;

-- Exige un acceso vigente y registra la consulta (qué se ha consultado y con qué acceso).
create or replace function private.support_require(rid uuid, p_query text, p_details jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_grant uuid := private.support_active_grant(rid);
begin
  if v_grant is null then
    raise exception 'No tienes un acceso de soporte activo para este restaurante' using errcode = '42501';
  end if;
  perform private.audit_insert(rid, 'soporte.consulta', 'support_grants', v_grant::text,
    jsonb_build_object('consulta', p_query) || coalesce(p_details, '{}'::jsonb));
  return v_grant;
end $$;

-- La plataforma solicita acceso de solo lectura a un restaurante, con un motivo.
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
               and (g.status = 'pendiente' or (g.status = 'aprobada' and g.expires_at > now()))) then
    raise exception 'Ya tienes una solicitud pendiente o un acceso activo para este restaurante' using errcode = '22023';
  end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  insert into private.support_grants (restaurant_id, requested_by, requested_by_email, reason)
  values (p_restaurant_id, v_uid, coalesce(v_email, ''), v_reason)
  returning id into v_id;
  return v_id;
end $$;

-- El PROPIETARIO del restaurante aprueba (2 horas exactas desde ahora) o rechaza.
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

-- El propietario retira un acceso activo. Efecto inmediato.
create or replace function public.support_revoke(p_grant_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  g private.support_grants;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para revocar el acceso' using errcode = '42501';
  end if;
  select * into g from private.support_grants where id = p_grant_id for update;
  if not found or private.staff_role_for(g.restaurant_id) is distinct from 'owner'::public.staff_role then
    raise exception 'Solo el propietario del restaurante puede revocar este acceso' using errcode = '42501';
  end if;
  if private.support_status(g.status, g.expires_at) <> 'aprobada' then
    raise exception 'Este acceso ya no está activo' using errcode = '22023';
  end if;
  update private.support_grants set status = 'revocada', revoked_at = now(), revoked_by = v_uid where id = g.id;
end $$;

-- Quien lo solicitó retira su solicitud o termina antes su acceso.
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
  if private.support_status(g.status, g.expires_at) not in ('pendiente', 'aprobada') then
    raise exception 'Esta solicitud ya está cerrada' using errcode = '22023';
  end if;
  update private.support_grants set status = 'cancelada', revoked_at = now(), revoked_by = v_uid where id = g.id;
end $$;

-- Solicitudes de un restaurante (para su propietario).
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
    select g.id, g.requested_by_email, g.reason, private.support_status(g.status, g.expires_at), g.requested_at,
      g.decided_at, g.decided_by_email, g.expires_at, g.revoked_at
    from private.support_grants g where g.restaurant_id = p_restaurant_id
    order by g.requested_at desc limit 100;
end $$;

-- Solicitudes propias (para la cuenta de plataforma).
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
    select g.id, g.restaurant_id, r.name, g.reason, private.support_status(g.status, g.expires_at), g.requested_at,
      g.decided_at, g.decided_by_email, g.expires_at, g.revoked_at
    from private.support_grants g join public.restaurants r on r.id = g.restaurant_id
    where g.requested_by = (select auth.uid())
    order by g.requested_at desc limit 100;
end $$;

-- Consulta de soporte: estado general del restaurante. Sin datos personales (el equipo, solo
-- cuántas personas hay por función).
create or replace function public.support_view_restaurant(p_restaurant_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_grant uuid := private.support_require(p_restaurant_id, 'estado', '{}'::jsonb);
begin
  return jsonb_build_object(
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
      from public.orders o where o.restaurant_id = p_restaurant_id));
end $$;

-- Consulta de soporte: últimos pedidos. Sin nombre, teléfono, notas ni referencia de pago del
-- cliente (solo si existen).
create or replace function public.support_view_orders(p_restaurant_id uuid, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  perform private.support_require(p_restaurant_id, 'pedidos', jsonb_build_object('limite', v_limit));
  return coalesce((
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
      limit v_limit) t), '[]'::jsonb);
end $$;

-- Consulta de soporte: avisos de la pasarela de pago (para incidencias de cobro).
create or replace function public.support_view_payment_events(p_restaurant_id uuid, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  perform private.support_require(p_restaurant_id, 'avisos_pago', jsonb_build_object('limite', v_limit));
  return coalesce((
    select jsonb_agg(t.obj order by t.created_at desc)
    from (
      select e.created_at, jsonb_build_object('createdAt', e.created_at, 'outcome', e.outcome,
        'resolution', e.resolution, 'amount', e.amount_cents, 'detail', e.detail, 'orderNumber', o.number) as obj
      from public.payment_events e left join public.orders o on o.id = e.order_id
      where e.restaurant_id = p_restaurant_id
      order by e.created_at desc
      limit v_limit) t), '[]'::jsonb);
end $$;

-- Integridad del historial de accesos: no se borra, no cambian sus datos, solo transiciones
-- válidas y un acceso aprobado solo se puede ACORTAR, nunca ampliar. Se aplica a todos.
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
    return new;
  end if;
  if (new.id, new.restaurant_id, new.requested_by, new.requested_by_email, new.reason, new.requested_at)
     is distinct from (old.id, old.restaurant_id, old.requested_by, old.requested_by_email, old.reason, old.requested_at) then
    raise exception 'Los datos de una solicitud de soporte no se pueden modificar' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
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

create or replace function private.audit_support_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'soporte.solicitud', 'support_grants', new.id::text,
      jsonb_build_object('solicitante', new.requested_by_email, 'motivo', new.reason));
  elsif new.status is distinct from old.status then
    perform private.audit_insert(new.restaurant_id,
      case new.status when 'aprobada' then 'soporte.aprobacion' when 'rechazada' then 'soporte.rechazo'
        when 'revocada' then 'soporte.revocacion' else 'soporte.cancelacion' end,
      'support_grants', new.id::text,
      jsonb_strip_nulls(jsonb_build_object('solicitante', new.requested_by_email, 'inicio', new.decided_at,
        'caduca', new.expires_at, 'fin', new.revoked_at)));
  elsif new.expires_at is distinct from old.expires_at then
    perform private.audit_insert(new.restaurant_id, 'soporte.caducidad_adelantada', 'support_grants', new.id::text,
      jsonb_build_object('antes', old.expires_at, 'despues', new.expires_at));
  end if;
  return null;
end $$;

drop trigger if exists support_grants_guard on private.support_grants;
create trigger support_grants_guard before insert or update or delete on private.support_grants
  for each row execute function private.guard_support_grants();
drop trigger if exists support_grants_no_truncate on private.support_grants;
create trigger support_grants_no_truncate before truncate on private.support_grants
  for each statement execute function private.guard_support_grants();
drop trigger if exists support_grants_audit on private.support_grants;
create trigger support_grants_audit after insert or update on private.support_grants
  for each row execute function private.audit_support_changes();

revoke all on function private.support_status(text, timestamptz), private.support_active_grant(uuid),
  private.support_require(uuid, text, jsonb), private.guard_support_grants(), private.audit_support_changes()
  from public, anon, authenticated;
revoke all on function public.support_request(uuid, text), public.support_decide(uuid, boolean),
  public.support_revoke(uuid), public.support_cancel(uuid), public.support_list_for_restaurant(uuid),
  public.support_my_requests(), public.support_view_restaurant(uuid), public.support_view_orders(uuid, int),
  public.support_view_payment_events(uuid, int) from public, anon, authenticated;
-- Cada función comprueba dentro quién llama: plataforma (solicitar, cancelar, consultar) u owner
-- del restaurante (ver, aprobar, rechazar, revocar).
grant execute on function public.support_request(uuid, text), public.support_decide(uuid, boolean),
  public.support_revoke(uuid), public.support_cancel(uuid), public.support_list_for_restaurant(uuid),
  public.support_my_requests(), public.support_view_restaurant(uuid), public.support_view_orders(uuid, int),
  public.support_view_payment_events(uuid, int) to authenticated;

-- Accesos de soporte: nadie los lee ni escribe por la API (solo con las funciones support_*).
revoke all on private.support_grants from public, anon, authenticated, service_role;
alter table private.support_grants enable row level security;

commit;
