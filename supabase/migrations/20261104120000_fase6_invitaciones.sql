-- =====================================================================================
-- Migración 20261104120000 · fase 6: cuentas e invitaciones (base de datos).
-- Se aplica DESPUÉS de 20261103120000_fase5_soporte_caducidad_registro.sql
-- (rama fase5-soporte-caducidad-registro, 55c6837).
-- Equivale a los bloques «-- >>> fase6» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos: no toca restaurantes, carta, pedidos, personal, cuentas, accesos de
-- soporte ni el registro de auditoría. Añade private.invitations, sus funciones y triggers.
-- CAMBIOS DE COMPORTAMIENTO:
--  * Se elimina public.staff_add_member: el alta en un equipo es solo aceptando una invitación.
--  * El servidor (service_role) ya no puede escribir en restaurant_staff ni en platform_admins.
--  * Desde la app, un restaurante no se puede abrir sin propietario ni mientras esté suspendido.
-- Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261104120000_fase6_invitaciones.down.sql
-- =====================================================================================

begin;

-- Invitaciones al equipo de un restaurante. Una invitación NO da ningún permiso: el alta en
-- restaurant_staff solo la hace invitation_accept cuando la persona invitada, con su correo
-- confirmado en Supabase Auth, la acepta. No hay tokens: la prueba de identidad es ese correo
-- confirmado. Privada: no es accesible por la API (solo con las funciones invitation_*).
-- Caduca a los 7 días; no se borra (historial) y una invitación cerrada no se puede reactivar.
create table if not exists private.invitations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete restrict,
  email text not null check (email = lower(btrim(email)) and char_length(email) between 3 and 254
    and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  role public.staff_role not null,
  -- Quien invitó (o reenvió). Pasa a null si se elimina su cuenta: la invitación deja de valer.
  invited_by uuid references auth.users on delete set null,
  invited_by_kind text not null check (invited_by_kind in ('plataforma', 'personal')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'pendiente'
    check (status in ('pendiente', 'aceptada', 'rechazada', 'revocada', 'reemplazada')),
  closed_reason text check (closed_reason in ('manual', 'invitador_sin_permiso')),
  decided_at timestamptz,
  decided_by uuid references auth.users on delete set null,
  -- Reenvío: la nueva invitación sustituye a la anterior (que pasa a «reemplazada»).
  replaces uuid references private.invitations on delete restrict,
  resend_count int not null default 0 check (resend_count between 0 and 3),
  -- Lo anota el servidor (Edge Function) al enviar el correo. «no_necesario»: la persona ya
  -- tiene cuenta y la verá dentro de TuRestaurante.
  send_status text not null default 'sin_enviar' check (send_status in ('sin_enviar', 'enviada', 'fallida', 'no_necesario')),
  last_sent_at timestamptz,
  constraint invitations_seven_days check (expires_at = created_at + interval '168 hours'),
  constraint invitations_resend check ((replaces is null) = (resend_count = 0)),
  constraint invitations_closed check ((status = 'pendiente') = (decided_at is null)),
  constraint invitations_closed_reason check ((status = 'revocada') = (closed_reason is not null))
);
-- Como mucho UNA invitación pendiente por restaurante y correo.
create unique index if not exists invitations_one_pending on private.invitations (restaurant_id, email) where status = 'pendiente';
create index if not exists invitations_restaurant_idx on private.invitations (restaurant_id, created_at desc);
create index if not exists invitations_email_idx on private.invitations (email) where status = 'pendiente';
create index if not exists invitations_inviter_idx on private.invitations (invited_by, created_at);

-- ---------- Invitaciones (fase 6) ----------
-- Alta en un equipo SOLO por invitación aceptada. Ya no existe staff_add_member (alta directa sin
-- consentimiento de la persona).
drop function if exists public.staff_add_member(uuid, text, public.staff_role);

-- Correo normalizado (minúsculas, sin espacios alrededor) o null si no es válido.
create or replace function private.normalize_email(p_email text) returns text
language sql immutable set search_path = '' as $$
  select case when e ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and char_length(e) between 3 and 254 then e end
  from (select lower(btrim(coalesce(p_email, ''))) as e) x
$$;

-- Correo enmascarado para el registro de auditoría: «j***@ejemplo.com».
create or replace function private.mask_email(p_email text) returns text
language sql immutable set search_path = '' as $$
  select left(p_email, 1) || '***@' || split_part(p_email, '@', 2)
$$;

-- ¿Puede quien tiene la función p_inviter invitar a p_target? Misma regla que can_manage_role:
-- owner: manager, waiter, kitchen · manager: waiter, kitchen · resto: nada. Los propietarios
-- solo los invita la plataforma.
create or replace function private.role_can_invite(p_inviter public.staff_role, p_target public.staff_role) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(case p_inviter
    when 'owner' then p_target in ('manager', 'waiter', 'kitchen')
    when 'manager' then p_target in ('waiter', 'kitchen')
    else false end, false)
$$;

-- Estado visible: una invitación pendiente pasada su fecha está «caducada».
create or replace function private.invitation_state(p_status text, p_expires_at timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when p_status = 'pendiente' and p_expires_at <= now() then 'caducada' else p_status end
$$;

-- ¿Quien invitó sigue pudiendo dar esa función? Si no, la invitación ya no se puede aceptar.
create or replace function private.invitation_inviter_ok(p_restaurant_id uuid, p_invited_by uuid, p_kind text,
  p_role public.staff_role) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_invited_by is null then false
    when p_kind = 'plataforma' then exists (select 1 from public.platform_admins pa where pa.user_id = p_invited_by)
    else coalesce((select private.role_can_invite(s.role, p_role) from public.restaurant_staff s
                   where s.restaurant_id = p_restaurant_id and s.user_id = p_invited_by), false)
  end
$$;

-- Correo CONFIRMADO de quien llama (null sin sesión o sin confirmar).
create or replace function private.my_confirmed_email() returns text
language sql stable security definer set search_path = '' as $$
  select lower(u.email::text) from auth.users u
  where u.id = (select auth.uid()) and u.email_confirmed_at is not null
$$;

create or replace function private.invitation_insert(p_restaurant_id uuid, p_email text, p_role public.staff_role,
  p_replaces uuid, p_resend_count int) returns uuid
language sql security definer set search_path = '' as $$
  insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, expires_at, replaces, resend_count)
  values (p_restaurant_id, p_email, p_role, (select auth.uid()),
    case when private.is_platform_admin() then 'plataforma' else 'personal' end,
    now() + interval '168 hours', p_replaces, p_resend_count)
  returning id
$$;

-- Crea una invitación. La respuesta es la MISMA exista o no una cuenta con ese correo, y sea de
-- quien sea: quien invita nunca sabe si la persona tiene cuenta o trabaja en otro restaurante.
create or replace function public.invitation_create(p_restaurant_id uuid, p_email text, p_role public.staff_role)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_email text := private.normalize_email(p_email);
  v_suspended timestamptz;
  v_old private.invitations;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para invitar' using errcode = '42501';
  end if;
  -- Bloquea el restaurante: serializa con los cambios de equipo (mismo orden que staff_*).
  select r.suspended_at into v_suspended from public.restaurants r where r.id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  -- El permiso se comprueba ANTES de mirar el correo.
  if p_role is null or not private.can_manage_role(p_restaurant_id, p_role) then
    raise exception 'No puedes invitar a esa función en este restaurante' using errcode = '42501';
  end if;
  if v_suspended is not null then
    raise exception 'El restaurante está suspendido: no se pueden enviar invitaciones' using errcode = '42501';
  end if;
  if v_email is null then
    raise exception 'El correo electrónico no es válido' using errcode = '22023';
  end if;
  -- Límite por persona, en todos sus restaurantes: 20 invitaciones nuevas por hora.
  perform pg_advisory_xact_lock(hashtextextended('turestaurante.invitaciones:' || v_uid::text, 0));
  if (select count(*) from private.invitations i
      where i.invited_by = v_uid and i.replaces is null and i.created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Has alcanzado el límite de 20 invitaciones por hora. Inténtalo más tarde' using errcode = '54000';
  end if;
  -- Solo se mira el equipo de ESTE restaurante, que quien invita ya ve en su lista.
  if exists (select 1 from public.restaurant_staff s join auth.users u on u.id = s.user_id
             where s.restaurant_id = p_restaurant_id and lower(u.email::text) = v_email) then
    raise exception 'Esa persona ya forma parte del equipo' using errcode = '22023';
  end if;
  select * into v_old from private.invitations i
  where i.restaurant_id = p_restaurant_id and i.email = v_email and i.status = 'pendiente' for update;
  if found then
    if v_old.expires_at > now() then
      raise exception 'Ya hay una invitación pendiente para ese correo. Puedes reenviarla o revocarla' using errcode = '22023';
    end if;
    -- La caducada no se reactiva: queda «reemplazada» por la nueva.
    update private.invitations set status = 'reemplazada', decided_at = now(), decided_by = v_uid where id = v_old.id;
  end if;
  if (select count(*) from private.invitations i
      where i.restaurant_id = p_restaurant_id and i.status = 'pendiente' and i.expires_at > now()) >= 30 then
    raise exception 'El restaurante ya tiene 30 invitaciones pendientes. Revoca alguna antes de crear otra' using errcode = '54000';
  end if;
  return private.invitation_insert(p_restaurant_id, v_email, p_role, null, 0);
end $$;

-- Reenvía una invitación pendiente: la sustituye por otra nueva (7 días más). Como mucho 3 veces
-- y con 5 minutos entre reenvíos. Una caducada no se reenvía: se crea otra.
create or replace function public.invitation_resend(p_invitation_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_inv private.invitations;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para gestionar invitaciones' using errcode = '42501';
  end if;
  perform 1 from public.restaurants r
  where r.id = (select i.restaurant_id from private.invitations i where i.id = p_invitation_id) for update;
  select * into v_inv from private.invitations i where i.id = p_invitation_id for update;
  -- Mismo mensaje si no existe o si no hay permiso sobre esa función.
  if not found or not private.can_manage_role(v_inv.restaurant_id, v_inv.role) then
    raise exception 'No puedes gestionar esa invitación' using errcode = '42501';
  end if;
  if private.invitation_state(v_inv.status, v_inv.expires_at) = 'caducada' then
    raise exception 'La invitación ha caducado. Crea una nueva' using errcode = '22023';
  end if;
  if v_inv.status <> 'pendiente' then
    raise exception 'La invitación ya no está pendiente' using errcode = '22023';
  end if;
  if (select r.suspended_at from public.restaurants r where r.id = v_inv.restaurant_id) is not null then
    raise exception 'El restaurante está suspendido: no se pueden enviar invitaciones' using errcode = '42501';
  end if;
  if v_inv.resend_count >= 3 then
    raise exception 'Esta invitación ya se ha reenviado 3 veces. Revócala y crea una nueva si hace falta' using errcode = '54000';
  end if;
  if v_inv.created_at > now() - interval '5 minutes' then
    raise exception 'Espera al menos 5 minutos entre reenvíos' using errcode = '54000';
  end if;
  update private.invitations set status = 'reemplazada', decided_at = now(), decided_by = v_uid where id = v_inv.id;
  return private.invitation_insert(v_inv.restaurant_id, v_inv.email, v_inv.role, v_inv.id, v_inv.resend_count + 1);
end $$;

create or replace function public.invitation_revoke(p_invitation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_inv private.invitations;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para gestionar invitaciones' using errcode = '42501';
  end if;
  perform 1 from public.restaurants r
  where r.id = (select i.restaurant_id from private.invitations i where i.id = p_invitation_id) for update;
  select * into v_inv from private.invitations i where i.id = p_invitation_id for update;
  if not found or not private.can_manage_role(v_inv.restaurant_id, v_inv.role) then
    raise exception 'No puedes gestionar esa invitación' using errcode = '42501';
  end if;
  if v_inv.status <> 'pendiente' then
    raise exception 'La invitación ya no está pendiente' using errcode = '22023';
  end if;
  update private.invitations
  set status = 'revocada', closed_reason = 'manual', decided_at = now(), decided_by = v_uid
  where id = v_inv.id;
end $$;

-- Invitaciones de un restaurante. Owner y manager ven todas; cada uno gestiona solo las funciones
-- que puede dar (can_manage). La consulta de la plataforma queda registrada.
create or replace function public.invitation_list(p_restaurant_id uuid)
returns table (id uuid, email text, role public.staff_role, state text, created_at timestamptz, expires_at timestamptz,
  invited_by_label text, decided_at timestamptz, resend_count int, can_manage boolean)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'Inicia sesión para ver las invitaciones' using errcode = '42501';
  end if;
  if private.has_role(p_restaurant_id, array['owner', 'manager']::public.staff_role[]) then
    null;
  elsif private.is_platform_admin() then
    perform private.audit_insert(p_restaurant_id, 'plataforma.consulta_invitaciones', 'invitations', null, '{}'::jsonb);
  else
    raise exception 'No tienes acceso a las invitaciones de este restaurante' using errcode = '42501';
  end if;
  return query
    select i.id, i.email, i.role, private.invitation_state(i.status, i.expires_at), i.created_at, i.expires_at,
      case when i.invited_by_kind = 'plataforma' then 'TuRestaurante (plataforma)'
           else coalesce(u.email::text, 'Cuenta eliminada') end,
      i.decided_at, i.resend_count,
      private.invitation_state(i.status, i.expires_at) = 'pendiente' and private.can_manage_role(p_restaurant_id, i.role)
    from private.invitations i left join auth.users u on u.id = i.invited_by
    where i.restaurant_id = p_restaurant_id
    order by i.created_at desc
    limit 200;
end $$;

-- Invitaciones que puede aceptar quien llama: las de SU correo confirmado, pendientes, válidas y
-- de restaurantes donde aún no trabaja. No muestra el correo de quien invitó.
create or replace function public.my_invitations()
returns table (id uuid, restaurant_id uuid, restaurant_name text, role public.staff_role, expires_at timestamptz,
  invited_by_label text)
language sql stable security definer set search_path = '' as $$
  select i.id, i.restaurant_id, r.name, i.role, i.expires_at,
    case when i.invited_by_kind = 'plataforma' then 'TuRestaurante (plataforma)' else 'Equipo de ' || r.name end
  from private.invitations i join public.restaurants r on r.id = i.restaurant_id
  where i.email = private.my_confirmed_email()
    and i.status = 'pendiente' and i.expires_at > now()
    and r.suspended_at is null
    and not private.is_platform_admin()
    and private.invitation_inviter_ok(i.restaurant_id, i.invited_by, i.invited_by_kind, i.role)
    and not exists (select 1 from public.restaurant_staff s
                    where s.restaurant_id = i.restaurant_id and s.user_id = (select auth.uid()))
  order by i.created_at desc
$$;

-- ÚNICA vía de alta en un equipo. La función concedida es la de la invitación (no un parámetro).
create or replace function public.invitation_accept(p_invitation_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_email text;
  v_confirmed timestamptz;
  v_suspended timestamptz;
  v_inv private.invitations;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para aceptar la invitación' using errcode = '42501';
  end if;
  select lower(u.email::text), u.email_confirmed_at into v_email, v_confirmed from auth.users u where u.id = v_uid;
  -- Mismo orden de bloqueo que el resto (restaurante y después invitación): sin interbloqueos.
  select r.suspended_at into v_suspended from public.restaurants r
  where r.id = (select i.restaurant_id from private.invitations i where i.id = p_invitation_id) for update;
  select * into v_inv from private.invitations i where i.id = p_invitation_id for update;
  -- Mismo mensaje si no existe o si es para otro correo: no se puede sondear.
  if not found or v_email is null or v_inv.email <> v_email then
    raise exception 'Esta invitación no existe o no es para tu cuenta' using errcode = '42501';
  end if;
  if v_confirmed is null then
    raise exception 'Confirma tu correo electrónico antes de aceptar la invitación' using errcode = '42501';
  end if;
  if v_inv.status = 'aceptada' then
    raise exception 'Ya aceptaste esta invitación' using errcode = '22023';
  end if;
  if v_inv.status <> 'pendiente' then
    raise exception 'Esta invitación ya no está disponible' using errcode = '22023';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'Esta invitación ha caducado. Pide una nueva a quien te invitó' using errcode = '22023';
  end if;
  if v_suspended is not null then
    raise exception 'El restaurante está suspendido: ahora no se puede aceptar la invitación' using errcode = '42501';
  end if;
  if private.is_platform_admin() then
    raise exception 'Las cuentas de la plataforma no pueden ser personal de un restaurante' using errcode = '42501';
  end if;
  if not private.invitation_inviter_ok(v_inv.restaurant_id, v_inv.invited_by, v_inv.invited_by_kind, v_inv.role) then
    raise exception 'Esta invitación ya no es válida: quien la envió ya no puede dar esa función' using errcode = '42501';
  end if;
  if exists (select 1 from public.restaurant_staff s where s.restaurant_id = v_inv.restaurant_id and s.user_id = v_uid) then
    raise exception 'Ya formas parte de este restaurante' using errcode = '22023';
  end if;
  insert into public.restaurant_staff (restaurant_id, user_id, role) values (v_inv.restaurant_id, v_uid, v_inv.role);
  update private.invitations set status = 'aceptada', decided_at = now(), decided_by = v_uid where id = v_inv.id;
  return v_inv.restaurant_id;
end $$;

create or replace function public.invitation_decline(p_invitation_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_email text;
  v_confirmed timestamptz;
  v_inv private.invitations;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para rechazar la invitación' using errcode = '42501';
  end if;
  select lower(u.email::text), u.email_confirmed_at into v_email, v_confirmed from auth.users u where u.id = v_uid;
  select * into v_inv from private.invitations i where i.id = p_invitation_id for update;
  if not found or v_email is null or v_inv.email <> v_email then
    raise exception 'Esta invitación no existe o no es para tu cuenta' using errcode = '42501';
  end if;
  if v_confirmed is null then
    raise exception 'Confirma tu correo electrónico antes de responder a la invitación' using errcode = '42501';
  end if;
  if v_inv.status <> 'pendiente' then
    raise exception 'Esta invitación ya no está disponible' using errcode = '22023';
  end if;
  if v_inv.expires_at <= now() then
    raise exception 'Esta invitación ha caducado' using errcode = '22023';
  end if;
  update private.invitations set status = 'rechazada', decided_at = now(), decided_by = v_uid where id = v_inv.id;
end $$;

-- La plataforma crea un restaurante (CERRADO) y la invitación de su primer propietario, en una
-- sola transacción. El restaurante no se puede abrir hasta que ese propietario acepte.
create or replace function public.platform_create_restaurant(p_name text, p_slug text, p_owner_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rid uuid;
  v_inv uuid;
begin
  if not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede crear restaurantes' using errcode = '42501';
  end if;
  if private.normalize_email(p_owner_email) is null then
    raise exception 'El correo del propietario no es válido' using errcode = '22023';
  end if;
  insert into public.restaurants (slug, name, active)
  values (lower(btrim(coalesce(p_slug, ''))), btrim(coalesce(p_name, '')), false)
  returning id into v_rid;
  v_inv := public.invitation_create(v_rid, p_owner_email, 'owner');
  return jsonb_build_object('restaurantId', v_rid, 'invitationId', v_inv);
end $$;

-- ---------- Solo para el servidor (Edge Function con la clave secreta) ----------
-- Datos para enviar el correo. «account_exists» y «account_confirmed» solo los ve el servidor:
-- sin cuenta o sin confirmar, la Edge Function envía la invitación de Supabase Auth (que crea la
-- cuenta o reenvía el enlace); confirmada, la persona la verá dentro de la app. Nunca llegan a
-- quien invita.
drop function if exists public.invitation_delivery(uuid);
create or replace function public.invitation_delivery(p_invitation_id uuid)
returns table (email text, role public.staff_role, restaurant_name text, expires_at timestamptz,
  account_exists boolean, account_confirmed boolean, state text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if coalesce(private.request_role(), '') <> 'service_role' then
    raise exception 'Solo el servidor puede preparar el envío de invitaciones' using errcode = '42501';
  end if;
  return query
    select i.email, i.role, r.name, i.expires_at,
      exists (select 1 from auth.users u where lower(u.email::text) = i.email),
      exists (select 1 from auth.users u where lower(u.email::text) = i.email and u.email_confirmed_at is not null),
      private.invitation_state(i.status, i.expires_at)
    from private.invitations i join public.restaurants r on r.id = i.restaurant_id
    where i.id = p_invitation_id;
end $$;

create or replace function public.invitation_mark_sent(p_invitation_id uuid, p_result text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(private.request_role(), '') <> 'service_role' then
    raise exception 'Solo el servidor puede anotar el envío de invitaciones' using errcode = '42501';
  end if;
  if p_result is null or p_result not in ('enviada', 'fallida', 'no_necesario') then
    raise exception 'Resultado de envío no válido' using errcode = '22023';
  end if;
  update private.invitations
  set send_status = p_result, last_sent_at = case when p_result = 'enviada' then now() else last_sent_at end
  where id = p_invitation_id and status = 'pendiente' and expires_at > now();
  if not found then
    raise exception 'La invitación no está pendiente' using errcode = '22023';
  end if;
end $$;

-- ---------- Triggers de las invitaciones ----------
-- Integridad del historial (se aplica a todos, también al SQL Editor): no se borra; nace
-- pendiente; sus datos no cambian; una invitación cerrada no se reactiva; una caducada no se
-- acepta ni se rechaza. Solo pueden pasar a null las referencias a cuentas eliminadas.
create or replace function private.guard_invitations() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'El historial de invitaciones no se puede borrar' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    if new.status <> 'pendiente' or new.decided_at is not null or new.decided_by is not null
       or new.closed_reason is not null or new.send_status <> 'sin_enviar' or new.last_sent_at is not null then
      raise exception 'Una invitación siempre empieza pendiente' using errcode = '42501';
    end if;
    if new.created_at > now() then
      raise exception 'Una invitación no puede tener fecha futura' using errcode = '42501';
    end if;
    return new;
  end if;
  if (new.id, new.restaurant_id, new.email, new.role, new.invited_by_kind, new.created_at, new.expires_at,
      new.replaces, new.resend_count)
     is distinct from (old.id, old.restaurant_id, old.email, old.role, old.invited_by_kind, old.created_at, old.expires_at,
      old.replaces, old.resend_count)
     or (new.invited_by is distinct from old.invited_by and new.invited_by is not null) then
    raise exception 'Los datos de una invitación no se pueden modificar' using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if old.status <> 'pendiente' then
      raise exception 'Una invitación cerrada no se puede reactivar ni cambiar' using errcode = '42501';
    end if;
    if new.status in ('aceptada', 'rechazada') and old.expires_at <= now() then
      raise exception 'La invitación ha caducado: no se puede aceptar ni rechazar' using errcode = '42501';
    end if;
  elsif (new.decided_at, new.closed_reason) is distinct from (old.decided_at, old.closed_reason)
        or (new.decided_by is distinct from old.decided_by and new.decided_by is not null) then
    raise exception 'Los datos de una invitación no se pueden modificar' using errcode = '42501';
  end if;
  if (new.send_status, new.last_sent_at) is distinct from (old.send_status, old.last_sent_at)
     and old.status <> 'pendiente' then
    raise exception 'Solo se puede anotar el envío de una invitación pendiente' using errcode = '42501';
  end if;
  return new;
end $$;

-- Auditoría: el correo se guarda ENMASCARADO.
create or replace function private.audit_invitation_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_details jsonb := jsonb_build_object('invitacion', new.id, 'correo', private.mask_email(new.email), 'funcion', new.role);
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id,
      case when new.replaces is null then 'invitacion.creada' else 'invitacion.reenviada' end,
      'invitations', new.id::text, v_details || jsonb_build_object('caduca', new.expires_at));
  elsif new.status is distinct from old.status and new.status <> 'reemplazada' then
    perform private.audit_insert(new.restaurant_id, 'invitacion.' || new.status, 'invitations', new.id::text,
      v_details || jsonb_strip_nulls(jsonb_build_object('motivo', new.closed_reason)));
  elsif new.send_status = 'fallida' and old.send_status is distinct from 'fallida' then
    -- Sin restaurante: solo lo ve la plataforma. Un envío solo falla si el correo no tenía cuenta
    -- confirmada, así que el propietario no debe verlo (revelaría si la persona tiene cuenta).
    perform private.audit_insert(null, 'invitacion.envio_fallido', 'invitations', new.id::text,
      v_details || jsonb_build_object('restaurante', new.restaurant_id));
  end if;
  return null;
end $$;

-- Si quien invitó deja el equipo o pierde la función necesaria, sus invitaciones pendientes en ese
-- restaurante se revocan (también al eliminar su cuenta).
create or replace function private.invitations_on_staff_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new_role public.staff_role := case when tg_op = 'UPDATE' then new.role end;
begin
  update private.invitations i
  set status = 'revocada', closed_reason = 'invitador_sin_permiso', decided_at = now(), decided_by = null
  where i.restaurant_id = old.restaurant_id and i.invited_by_kind = 'personal' and i.status = 'pendiente'
    and (i.invited_by is null
         or (i.invited_by = old.user_id and (v_new_role is null or not private.role_can_invite(v_new_role, i.role))));
  return null;
end $$;

create or replace function private.invitations_on_platform_removal() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update private.invitations i
  set status = 'revocada', closed_reason = 'invitador_sin_permiso', decided_at = now(), decided_by = null
  where i.invited_by_kind = 'plataforma' and i.status = 'pendiente'
    and (i.invited_by is null or i.invited_by = old.user_id);
  return null;
end $$;

-- Un restaurante no se abre desde la app hasta que tenga propietario, ni mientras esté suspendido.
-- (El SQL Editor y el servidor no pasan por esta regla: por ejemplo, seed.sql.)
create or replace function private.guard_restaurant_activation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.active and (tg_op = 'INSERT' or not old.active)
     and coalesce(private.request_role(), '') in ('anon', 'authenticated') then
    if new.suspended_at is not null then
      raise exception 'Un restaurante suspendido no se puede activar' using errcode = '42501';
    end if;
    if not exists (select 1 from public.restaurant_staff s where s.restaurant_id = new.id and s.role = 'owner') then
      raise exception 'El restaurante no se puede activar hasta que su propietario acepte la invitación' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists invitations_guard on private.invitations;
create trigger invitations_guard before insert or update or delete on private.invitations
  for each row execute function private.guard_invitations();
drop trigger if exists invitations_no_truncate on private.invitations;
create trigger invitations_no_truncate before truncate on private.invitations
  for each statement execute function private.guard_invitations();
drop trigger if exists invitations_audit on private.invitations;
create trigger invitations_audit after insert or update on private.invitations
  for each row execute function private.audit_invitation_changes();
drop trigger if exists restaurant_staff_invitations on public.restaurant_staff;
create trigger restaurant_staff_invitations after update or delete on public.restaurant_staff
  for each row execute function private.invitations_on_staff_change();
drop trigger if exists platform_admins_invitations on public.platform_admins;
create trigger platform_admins_invitations after delete on public.platform_admins
  for each row execute function private.invitations_on_platform_removal();
drop trigger if exists restaurants_activation_guard on public.restaurants;
create trigger restaurants_activation_guard before insert or update on public.restaurants
  for each row execute function private.guard_restaurant_activation();

-- Funciones internas: nadie de la API puede ejecutarlas.
revoke all on function private.normalize_email(text), private.mask_email(text),
  private.role_can_invite(public.staff_role, public.staff_role), private.invitation_state(text, timestamptz),
  private.invitation_inviter_ok(uuid, uuid, text, public.staff_role), private.my_confirmed_email(),
  private.invitation_insert(uuid, text, public.staff_role, uuid, int), private.guard_invitations(),
  private.audit_invitation_changes(), private.invitations_on_staff_change(), private.invitations_on_platform_removal(),
  private.guard_restaurant_activation()
  from public, anon, authenticated, service_role;
revoke all on function public.invitation_create(uuid, text, public.staff_role), public.invitation_resend(uuid),
  public.invitation_revoke(uuid), public.invitation_list(uuid), public.my_invitations(), public.invitation_accept(uuid),
  public.invitation_decline(uuid), public.platform_create_restaurant(text, text, text),
  public.invitation_delivery(uuid), public.invitation_mark_sent(uuid, text)
  from public, anon, authenticated, service_role;
-- Personal y plataforma (cada función comprueba dentro quién llama y qué puede hacer).
grant execute on function public.invitation_create(uuid, text, public.staff_role), public.invitation_resend(uuid),
  public.invitation_revoke(uuid), public.invitation_list(uuid), public.my_invitations(), public.invitation_accept(uuid),
  public.invitation_decline(uuid), public.platform_create_restaurant(text, text, text) to authenticated;
-- Solo el servidor (Edge Function de envío de correos).
grant execute on function public.invitation_delivery(uuid), public.invitation_mark_sent(uuid, text) to service_role;

-- Invitaciones: nadie las lee ni escribe por la API (solo con las funciones invitation_*).
revoke all on private.invitations from public, anon, authenticated, service_role;
alter table private.invitations enable row level security;
-- Nadie entra en un equipo ni en la plataforma sin pasar por las reglas, tampoco el servidor con
-- la clave secreta: el alta en un equipo es solo invitation_accept.
revoke insert, update, delete on public.restaurant_staff, public.platform_admins from service_role;

commit;
