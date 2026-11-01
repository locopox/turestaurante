-- =====================================================================================
-- TuRestaurante · esquema v2 para Supabase (PostgreSQL)
--
-- Cómo usarlo: pegar el archivo COMPLETO en el SQL Editor de un proyecto de Supabase y
-- pulsar Run. Se puede volver a ejecutar: no borra tablas ni datos.
-- Después, opcionalmente, ejecutar supabase/seed.sql (datos de La Piazza).
--
-- Principios de seguridad:
--  * RLS activada en todas las tablas expuestas. Cada restaurante solo ve lo suyo.
--  * Los clientes anónimos NO leen ni escriben tablas: solo llaman a 3 funciones
--    (crear pedido, leer SU pedido con su token, pasar a pagar en caja).
--  * El personal no actualiza pedidos directamente: usa funciones que comprueban su rol.
--  * Precios y totales se calculan aquí, nunca se aceptan del navegador.
--  * Un pago solo puede quedar «pagado_verificado» desde el servidor (service_role), y
--    solo mediante payment_record_result (futuro webhook del proveedor de pagos).
--  * El pago online está desactivado por defecto y el personal no puede activarlo.
--  * El historial no se pierde: un restaurante con pedidos no se puede borrar y las líneas
--    de pedido conservan nombre y precio aunque el producto se retire del catálogo.
-- =====================================================================================

begin;

-- Esquema privado: no lo expone la API de Supabase (solo expone "public").
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- ---------- Tipos ----------
do $$ begin create type public.staff_role as enum ('owner', 'manager', 'waiter', 'kitchen');
exception when duplicate_object then null; end $$;
do $$ begin create type public.order_mode as enum ('mesa', 'recoger');
exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_method as enum ('online', 'caja');
exception when duplicate_object then null; end $$;
-- No existe estado «simulado»: los pagos simulados solo existen en el modo demo del navegador.
do $$ begin create type public.payment_status as enum
  ('pendiente_online', 'pagado_verificado', 'fallido', 'pendiente_caja', 'cobrado_caja');
exception when duplicate_object then null; end $$;
do $$ begin create type public.prep_status as enum ('nuevo', 'en_preparacion', 'listo', 'entregado', 'cancelado');
exception when duplicate_object then null; end $$;

-- ---------- Tablas ----------
create table if not exists public.restaurants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 2 and 40),
  name text not null check (char_length(btrim(name)) between 2 and 80),
  tagline text not null default '' check (char_length(tagline) <= 140),
  address text not null default '' check (char_length(address) <= 200),
  phone text not null default '' check (char_length(phone) <= 30),
  active boolean not null default false,
  tables int not null default 10 check (tables between 0 and 500),
  pickup_enabled boolean not null default true,
  online_payment_enabled boolean not null default false,
  counter_payment_enabled boolean not null default true,
  prep_minutes int not null default 15 check (prep_minutes between 1 and 240),
  created_at timestamptz not null default now()
);

-- >>> fase3
-- Suspensión controlada SOLO por la plataforma (independiente de «active», que es el
-- interruptor de apertura del propio restaurante). Un restaurante suspendido no acepta pedidos
-- aunque su propietario vuelva a activar «active». El MOTIVO no se guarda aquí (esta tabla es
-- pública): queda en el registro de auditoría, que solo leen el propietario y la plataforma.
alter table public.restaurants add column if not exists suspended_at timestamptz;

-- Registro de auditoría: solo se añade, nunca se modifica ni se borra (ver triggers más abajo).
-- Sin clave foránea a restaurantes: el historial sobrevive aunque se borre el restaurante.
create table if not exists private.audit_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  restaurant_id uuid,
  actor_user_id uuid,
  actor_kind text not null check (actor_kind in ('plataforma', 'personal', 'cliente', 'servidor', 'sql_editor')),
  action text not null,
  target_table text,
  target_id text,
  details jsonb not null default '{}'::jsonb
);
create index if not exists audit_log_restaurant_idx on private.audit_log (restaurant_id, created_at desc);
create index if not exists audit_log_actor_idx on private.audit_log (actor_user_id, created_at desc);
-- <<< fase3

-- >>> fase4
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
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase6
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
  -- Entrega del correo (la hace la Edge Function en segundo plano). Es una cola PERSISTENTE dentro
  -- de la propia invitación: si la función se interrumpe, la entrega sigue pendiente y se recupera.
  --   sin_enviar: por enviar (o esperando un reintento hasta send_next_at)
  --   enviando:   reservada por un proceso (send_claim) desde send_claimed_at; si no termina en
  --               10 minutos, la reserva caduca y otro proceso puede retomarla
  --   enviada / no_necesario (cuenta confirmada: la verá en la app) / fallida: definitivos
  -- Como mucho 3 intentos por invitación.
  send_status text not null default 'sin_enviar'
    check (send_status in ('sin_enviar', 'enviando', 'enviada', 'fallida', 'no_necesario')),
  send_attempts int not null default 0 check (send_attempts between 0 and 3),
  send_claim uuid,
  send_claimed_at timestamptz,
  send_next_at timestamptz,
  last_sent_at timestamptz,
  constraint invitations_send_claim check ((send_status = 'enviando') = (send_claim is not null and send_claimed_at is not null)),
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
create index if not exists invitations_delivery_idx on private.invitations (created_at)
  where send_status in ('sin_enviar', 'enviando');
-- <<< fase6

-- Numeración de pedidos por restaurante (privada: no revela el volumen de pedidos).
create table if not exists private.order_counters (
  restaurant_id uuid primary key references public.restaurants on delete cascade,
  last_number int not null default 100
);

create table if not exists public.restaurant_staff (
  restaurant_id uuid not null references public.restaurants on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role public.staff_role not null,
  primary key (restaurant_id, user_id)
);
create index if not exists restaurant_staff_user_idx on public.restaurant_staff (user_id);

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users on delete cascade
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  sort int not null default 0,
  unique (id, restaurant_id)
);
create index if not exists categories_restaurant_idx on public.categories (restaurant_id, sort);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete cascade,
  category_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  description text not null default '' check (char_length(description) <= 300),
  price_cents int not null check (price_cents between 0 and 100000),
  art text not null default 'pizza' check (art in
    ('pizza', 'pasta', 'salad', 'bread', 'dessert', 'soda', 'coffee', 'wine', 'water', 'ramen', 'taco', 'gyoza')),
  image_url text check (image_url is null or image_url ~ '^https://'),
  allergens text[] not null default '{}' check (cardinality(allergens) <= 14),
  tags text[] not null default '{}' check (tags <@ array['vegetariano', 'vegano', 'picante', 'nuevo', 'sin_gluten']),
  available boolean not null default true,
  sort int not null default 0,
  -- La categoría tiene que ser del MISMO restaurante que el producto.
  constraint products_category_same_restaurant
    foreign key (category_id, restaurant_id) references public.categories (id, restaurant_id) on delete cascade
);
create index if not exists products_restaurant_idx on public.products (restaurant_id, sort);
create index if not exists products_category_idx on public.products (category_id, restaurant_id);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  -- restrict: un restaurante con pedidos no se puede borrar (se desactiva). Protege el historial.
  restaurant_id uuid not null references public.restaurants on delete restrict,
  number int not null,
  mode public.order_mode not null,
  table_number int check (table_number between 1 and 500),
  customer_name text check (char_length(customer_name) between 2 and 60),
  customer_phone text check (char_length(customer_phone) <= 20),
  pickup_time text check (pickup_time ~ '^(asap|([01][0-9]|2[0-3]):[0-5][0-9])$'),
  notes text not null default '' check (char_length(notes) <= 200),
  total_cents int not null check (total_cents >= 0),
  payment_method public.payment_method not null,
  payment_status public.payment_status not null,
  payment_ref text check (char_length(payment_ref) <= 200),
  prep_status public.prep_status not null default 'nuevo',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, number),
  constraint orders_mode_data check (
    (mode = 'mesa' and table_number is not null)
    or (mode = 'recoger' and customer_name is not null and pickup_time is not null)),
  constraint orders_payment_coherent check (
    (payment_method = 'online' and payment_status in ('pendiente_online', 'pagado_verificado', 'fallido'))
    or (payment_method = 'caja' and payment_status in ('pendiente_caja', 'cobrado_caja')))
);
create index if not exists orders_restaurant_created_idx on public.orders (restaurant_id, created_at desc);
create index if not exists orders_restaurant_prep_idx on public.orders (restaurant_id, prep_status);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders on delete cascade,
  -- Si el producto se borra del catálogo, la línea queda sin enlace pero conserva nombre y precio.
  product_id uuid references public.products on delete set null,
  name text not null,
  unit_price_cents int not null check (unit_price_cents between 0 and 100000),
  quantity int not null check (quantity between 1 and 20),
  notes text check (char_length(notes) <= 120)
);
create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists order_items_product_idx on public.order_items (product_id);

-- Token de acceso del cliente a su pedido. Solo se guarda el hash SHA-256.
-- Está en el esquema privado: ni el personal ni la API pueden leerlo.
create table if not exists private.order_access (
  order_id uuid primary key references public.orders on delete cascade,
  token_hash bytea not null unique,
  created_at timestamptz not null default now()
);

-- Si este archivo ya se ejecutó con la versión anterior (pedidos borrados en cascada con el
-- restaurante), se corrige la clave foránea. No toca datos.
do $$ begin
  if exists (select 1 from pg_constraint
             where conrelid = 'public.orders'::regclass and conname = 'orders_restaurant_id_fkey' and confdeltype <> 'r') then
    alter table public.orders drop constraint orders_restaurant_id_fkey;
    alter table public.orders add constraint orders_restaurant_id_fkey
      foreign key (restaurant_id) references public.restaurants on delete restrict;
  end if;
end $$;

-- ---------- Pagos online (preparado; la pasarela real aún NO está integrada) ----------
-- Cada cobro abierto en la pasarela. Un pedido puede tener varios si el cliente reintenta
-- tras un fallo; así se reconocen los avisos tardíos de intentos anteriores.
create table if not exists private.payment_sessions (
  payment_ref text primary key check (char_length(payment_ref) between 1 and 200),
  order_id uuid not null references public.orders on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists payment_sessions_order_idx on private.payment_sessions (order_id);

-- Registro de cada aviso recibido del proveedor. Un aviso que no se puede aplicar con
-- seguridad (pedido pasado a caja, cancelado, importe distinto…) queda «requiere_revision»
-- para que una persona lo resuelva (por ejemplo, devolviendo el dinero).
create table if not exists public.payment_events (
  id uuid primary key default gen_random_uuid(),
  provider_event_id text not null unique check (char_length(provider_event_id) between 1 and 200),
  restaurant_id uuid references public.restaurants on delete restrict,
  order_id uuid references public.orders on delete restrict,
  payment_ref text not null check (char_length(payment_ref) between 1 and 200),
  outcome text not null check (outcome in ('pagado', 'fallido', 'expirado')),
  amount_cents int check (amount_cents >= 0),
  resolution text not null check (resolution in ('aplicado', 'ignorado', 'requiere_revision')),
  detail text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists payment_events_restaurant_idx on public.payment_events (restaurant_id, created_at desc);
create index if not exists payment_events_order_idx on public.payment_events (order_id);

-- ---------- Funciones auxiliares de permisos (privadas) ----------
-- >>> fase3
-- Rol del usuario actual en un restaurante, solo según restaurant_staff.
-- La cuenta de plataforma NO tiene rol operativo en ningún restaurante (modo soporte: fase posterior).
create or replace function private.staff_role_for(rid uuid) returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select s.role from public.restaurant_staff s where s.restaurant_id = rid and s.user_id = (select auth.uid())
$$;
-- <<< fase3

create or replace function private.has_role(rid uuid, roles public.staff_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.staff_role_for(rid) = any (roles), false)
$$;

create or replace function private.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_admins pa where pa.user_id = (select auth.uid()))
$$;

-- >>> fase3
-- Quién puede leer la tabla de pedidos: owner, manager y sala de ese restaurante.
-- Cocina NO lee la tabla (vería teléfonos e importes): usa kitchen_orders(). pstatus se conserva
-- en la firma por compatibilidad con la política orders_select.
create or replace function private.can_view_order(rid uuid, pstatus public.payment_status) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.staff_role_for(rid) in ('owner', 'manager', 'waiter'), false) and pstatus is not null
$$;
-- <<< fase3

-- Rol de la petición actual según el JWT: 'anon', 'authenticated', 'service_role', o null si no
-- hay JWT (SQL Editor, migraciones). Es una copia EXACTA de la definición vigente de auth.role()
-- en Supabase Auth (migración 20220224000811_update_auth_functions), función que Supabase marca
-- como obsoleta. No se usa current_user a propósito: dentro de una función SECURITY DEFINER
-- current_user es el propietario, no quien hace la petición.
create or replace function private.request_role() returns text
language sql stable set search_path = '' as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function private.token_hash(token text) returns bytea
language sql immutable set search_path = '' as $$
  select case when token ~ '^[0-9a-f]{64}$' then sha256(convert_to(token, 'UTF8')) end
$$;

-- >>> fase3
-- Quién hace la petición, para el registro de auditoría.
create or replace function private.actor_kind() returns text
language sql stable security definer set search_path = '' as $$
  select case coalesce(private.request_role(), '')
    when 'service_role' then 'servidor'
    when 'anon' then 'cliente'
    when '' then 'sql_editor'
    else case when private.is_platform_admin() then 'plataforma' else 'personal' end
  end
$$;

-- Añade una entrada al registro de auditoría con el usuario y el tipo de quien hace la petición.
create or replace function private.audit_insert(p_restaurant_id uuid, p_action text, p_target_table text,
  p_target_id text, p_details jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into private.audit_log (restaurant_id, actor_user_id, actor_kind, action, target_table, target_id, details)
  values (p_restaurant_id, (select auth.uid()), private.actor_kind(), p_action, p_target_table, p_target_id,
    coalesce(p_details, '{}'::jsonb))
$$;

-- ¿Puede el usuario actual dar, cambiar o quitar el rol «target» en este restaurante?
--   plataforma: cualquier rol (gestiona propietarios) · owner: manager, waiter, kitchen
--   manager: solo waiter y kitchen · waiter y kitchen: nada
create or replace function private.can_manage_role(rid uuid, target public.staff_role) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when private.is_platform_admin() then true
    when private.staff_role_for(rid) = 'owner' then target in ('manager', 'waiter', 'kitchen')
    when private.staff_role_for(rid) = 'manager' then target in ('waiter', 'kitchen')
    else false
  end
$$;
-- <<< fase3

-- Vista del pedido para el cliente: sin teléfono ni referencia de pago.
create or replace function private.customer_order_json(oid uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', o.id, 'restaurantId', o.restaurant_id, 'number', o.number,
    'createdAt', o.created_at, 'updatedAt', o.updated_at,
    'mode', o.mode, 'table', o.table_number, 'customerName', o.customer_name, 'pickupTime', o.pickup_time,
    'notes', o.notes, 'total', o.total_cents,
    'paymentMethod', o.payment_method, 'paymentStatus', o.payment_status, 'prepStatus', o.prep_status,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('productId', i.product_id, 'name', i.name, 'unitPrice', i.unit_price_cents,
        'quantity', i.quantity, 'notes', i.notes) order by i.id)
      from public.order_items i where i.order_id = o.id), '[]'::jsonb))
  from public.orders o where o.id = oid
$$;

-- ---------- Triggers de integridad (se aplican a TODOS, también a la service_role) ----------
-- >>> fase3
create or replace function private.guard_restaurant() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_role text := coalesce(private.request_role(), '');
  -- Peticiones desde la app de una cuenta que no es de plataforma.
  v_app_user boolean := v_role in ('anon', 'authenticated');
begin
  if tg_op = 'UPDATE' and (new.id, new.created_at) is distinct from (old.id, old.created_at) then
    raise exception 'No se puede cambiar el identificador del restaurante' using errcode = '42501';
  end if;
  -- Campos reservados a la plataforma: dirección web (QR) y suspensión.
  if v_app_user and not private.is_platform_admin() then
    if tg_op = 'UPDATE' and (new.slug, new.suspended_at) is distinct from (old.slug, old.suspended_at) then
      raise exception 'Solo la plataforma puede cambiar la dirección web o la suspensión del restaurante' using errcode = '42501';
    end if;
    if tg_op = 'INSERT' and new.suspended_at is not null then
      raise exception 'Solo la plataforma puede suspender restaurantes' using errcode = '42501';
    end if;
  end if;
  -- Activar el pago online solo desde el servidor (SQL Editor o service_role), nunca desde la app,
  -- hasta que exista una integración real con un proveedor de pagos.
  if new.online_payment_enabled
     and (tg_op = 'INSERT' or not old.online_payment_enabled)
     and v_app_user then
    raise exception 'El pago online no se puede activar desde la aplicación todavía' using errcode = '42501';
  end if;
  return new;
end $$;
-- <<< fase3
drop trigger if exists restaurants_guard on public.restaurants;
create trigger restaurants_guard before insert or update on public.restaurants
  for each row execute function private.guard_restaurant();

create or replace function private.guard_order_update() returns trigger
language plpgsql set search_path = '' as $$
declare
  caller text := coalesce(private.request_role(), '');
begin
  -- Datos que nunca cambian tras crear el pedido (incluido el importe).
  if (new.id, new.restaurant_id, new.number, new.created_at, new.mode, new.table_number, new.customer_name,
      new.customer_phone, new.pickup_time, new.notes, new.total_cents)
     is distinct from
     (old.id, old.restaurant_id, old.number, old.created_at, old.mode, old.table_number, old.customer_name,
      old.customer_phone, old.pickup_time, old.notes, old.total_cents) then
    raise exception 'Los datos y el importe de un pedido no se pueden modificar' using errcode = '42501';
  end if;

  if new.payment_ref is distinct from old.payment_ref and caller <> 'service_role' then
    raise exception 'La referencia de pago solo la puede registrar el servidor' using errcode = '42501';
  end if;

  if (new.payment_method, new.payment_status) is distinct from (old.payment_method, old.payment_status) then
    if old.payment_method = 'caja' and new.payment_method = 'caja'
       and old.payment_status = 'pendiente_caja' and new.payment_status = 'cobrado_caja' then
      null; -- el personal registra el cobro en caja
    elsif old.payment_method = 'online' and old.payment_status in ('pendiente_online', 'fallido')
       and new.payment_method = 'caja' and new.payment_status = 'pendiente_caja' then
      null; -- el cliente decide pagar en caja
    elsif caller = 'service_role' and old.payment_method = 'online' and new.payment_method = 'online'
       and old.payment_status in ('pendiente_online', 'fallido') and new.payment_status in ('pagado_verificado', 'fallido') then
      null; -- resultado del proveedor (servidor, vía payment_record_result)
    elsif caller = 'service_role' and old.payment_method = 'online' and new.payment_method = 'online'
       and old.payment_status = 'fallido' and new.payment_status = 'pendiente_online' then
      null; -- nuevo intento de pago tras un fallo (servidor, vía payment_checkout_started)
    else
      raise exception 'Cambio de estado de pago no permitido' using errcode = '42501';
    end if;
  end if;

  if new.prep_status is distinct from old.prep_status
     and new.prep_status <> 'cancelado'
     and new.payment_status in ('pendiente_online', 'fallido') then
    raise exception 'El pedido está pendiente de pago online y no puede pasar a cocina' using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end $$;
drop trigger if exists orders_guard on public.orders;
drop trigger if exists orders_touch on public.orders;
drop trigger if exists orders_guard_payment on public.orders;
create trigger orders_guard before update on public.orders
  for each row execute function private.guard_order_update();

create or replace function private.guard_order_items() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- Única excepción: al borrar un producto del catálogo, PostgreSQL pone product_id a null
  -- («on delete set null»). Se permite solo si el resto de la línea (nombre, precio,
  -- cantidad…) queda exactamente igual.
  if old.product_id is not null and new.product_id is null
     and (new.id, new.order_id, new.name, new.unit_price_cents, new.quantity, new.notes)
         is not distinct from (old.id, old.order_id, old.name, old.unit_price_cents, old.quantity, old.notes) then
    return new;
  end if;
  raise exception 'Las líneas de un pedido no se pueden modificar' using errcode = '42501';
end $$;
drop trigger if exists order_items_guard on public.order_items;
create trigger order_items_guard before update on public.order_items
  for each row execute function private.guard_order_items();

-- ---------- Funciones públicas para clientes (anónimos) ----------

-- Crea un pedido. Valida todo y calcula precios y total con los datos de la carta.
-- payload: { restaurantId, mode, table, customerName, customerPhone, pickupTime, notes,
--            paymentMethod, accessToken, items: [{ productId, quantity, notes }] }
-- accessToken: 64 caracteres hexadecimales aleatorios generados por el navegador. Sirve para
-- leer el pedido después y hace la llamada idempotente: reenviar el mismo token devuelve
-- el mismo pedido en lugar de crear otro.
-- Toda la función es una única transacción: si algo falla, no se guarda nada.
-- >>> fase3
create or replace function public.create_order(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_max_lines constant int := 30;   -- productos distintos por pedido
  c_max_qty   constant int := 20;   -- unidades por producto
  c_max_units constant int := 100;  -- unidades totales
  v_hash bytea;
  v_rid uuid;
  r public.restaurants;
  v_existing uuid;
  v_existing_rid uuid;
  v_mode public.order_mode;
  v_method public.payment_method;
  v_table int;
  v_name text;
  v_phone text;
  v_pickup text;
  v_notes text;
  v_items jsonb;
  v_line jsonb;
  v_qty int;
  v_units int := 0;
  v_pid uuid;
  v_line_notes text;
  p public.products;
  v_total bigint := 0;
  v_lines jsonb := '[]'::jsonb;
  v_order_id uuid := gen_random_uuid();
  v_number int;
begin
  if payload is null or jsonb_typeof(payload) <> 'object' then
    raise exception 'Pedido no válido' using errcode = '22023';
  end if;

  v_hash := private.token_hash(payload ->> 'accessToken');
  if v_hash is null then
    raise exception 'Falta el código de seguimiento del pedido' using errcode = '22023';
  end if;

  begin
    v_rid := (payload ->> 'restaurantId')::uuid;
  exception when invalid_text_representation then
    raise exception 'Restaurante no válido' using errcode = '22023';
  end;

  -- Bloquea el restaurante: serializa sus pedidos (numeración e idempotencia sin carreras).
  select * into r from public.restaurants where id = v_rid for update;
  if not found then
    raise exception 'El restaurante no acepta pedidos en este momento' using errcode = '22023';
  end if;

  -- Reintento con el mismo token: devolver el pedido ya creado.
  select a.order_id, o.restaurant_id into v_existing, v_existing_rid
  from private.order_access a join public.orders o on o.id = a.order_id
  where a.token_hash = v_hash;
  if v_existing is not null then
    if v_existing_rid <> r.id then
      raise exception 'Código de seguimiento no válido' using errcode = '22023';
    end if;
    return private.customer_order_json(v_existing);
  end if;

  -- Cerrado por el restaurante o suspendido por la plataforma.
  if not r.active or r.suspended_at is not null then
    raise exception 'El restaurante no acepta pedidos en este momento' using errcode = '22023';
  end if;

  -- Modo y método de pago
  v_mode := case payload ->> 'mode' when 'mesa' then 'mesa'::public.order_mode when 'recoger' then 'recoger'::public.order_mode end;
  if v_mode is null then
    raise exception 'Elige si el pedido es para mesa o para recoger' using errcode = '22023';
  end if;
  v_method := case payload ->> 'paymentMethod' when 'online' then 'online'::public.payment_method when 'caja' then 'caja'::public.payment_method end;
  if v_method is null then
    raise exception 'Elige un método de pago' using errcode = '22023';
  end if;
  if v_method = 'online' and not r.online_payment_enabled then
    raise exception 'El pago online no está disponible en este restaurante' using errcode = '22023';
  end if;
  if v_method = 'caja' and not r.counter_payment_enabled then
    raise exception 'El pago en caja no está disponible en este restaurante' using errcode = '22023';
  end if;

  if v_mode = 'mesa' then
    if coalesce(payload ->> 'table', '') !~ '^[0-9]{1,4}$' then
      raise exception 'Indica un número de mesa válido' using errcode = '22023';
    end if;
    v_table := (payload ->> 'table')::int;
    if v_table < 1 or v_table > r.tables then
      raise exception 'La mesa % no existe en este restaurante', v_table using errcode = '22023';
    end if;
  else
    if not r.pickup_enabled then
      raise exception 'Este restaurante no acepta pedidos para recoger' using errcode = '22023';
    end if;
    v_name := btrim(coalesce(payload ->> 'customerName', ''));
    if char_length(v_name) < 2 or char_length(v_name) > 60 then
      raise exception 'Indica un nombre de 2 a 60 caracteres para recoger el pedido' using errcode = '22023';
    end if;
    v_phone := nullif(btrim(coalesce(payload ->> 'customerPhone', '')), '');
    if v_phone is not null and v_phone !~ '^[0-9+() -]{6,20}$' then
      raise exception 'El teléfono no es válido' using errcode = '22023';
    end if;
    v_pickup := coalesce(nullif(payload ->> 'pickupTime', ''), 'asap');
    if v_pickup !~ '^(asap|([01][0-9]|2[0-3]):[0-5][0-9])$' then
      raise exception 'La hora de recogida no es válida' using errcode = '22023';
    end if;
  end if;

  v_notes := btrim(coalesce(payload ->> 'notes', ''));
  if char_length(v_notes) > 200 then
    raise exception 'Los comentarios admiten como máximo 200 caracteres' using errcode = '22023';
  end if;

  -- Productos: precio y nombre salen SIEMPRE de la carta
  v_items := payload -> 'items';
  if v_items is null or jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    raise exception 'El carrito está vacío' using errcode = '22023';
  end if;
  if jsonb_array_length(v_items) > c_max_lines then
    raise exception 'Un pedido admite como máximo % productos distintos', c_max_lines using errcode = '22023';
  end if;

  for v_line in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'Producto no válido' using errcode = '22023';
    end if;
    if coalesce(v_line ->> 'quantity', '') !~ '^[0-9]{1,3}$' then
      raise exception 'Cantidad no válida' using errcode = '22023';
    end if;
    v_qty := (v_line ->> 'quantity')::int;
    if v_qty < 1 or v_qty > c_max_qty then
      raise exception 'Cada producto admite entre 1 y % unidades', c_max_qty using errcode = '22023';
    end if;
    v_units := v_units + v_qty;
    if v_units > c_max_units then
      raise exception 'Un pedido admite como máximo % unidades', c_max_units using errcode = '22023';
    end if;
    v_line_notes := nullif(btrim(coalesce(v_line ->> 'notes', '')), '');
    if char_length(v_line_notes) > 120 then
      raise exception 'Las notas de un producto admiten como máximo 120 caracteres' using errcode = '22023';
    end if;
    begin
      v_pid := (v_line ->> 'productId')::uuid;
    exception when invalid_text_representation then
      raise exception 'Producto no válido' using errcode = '22023';
    end;
    select * into p from public.products where id = v_pid and restaurant_id = r.id;
    if not found then
      raise exception 'Algún producto no pertenece a esta carta. Revisa tu carrito.' using errcode = '22023';
    end if;
    if not p.available then
      raise exception '«%» está agotado. Quítalo del carrito para continuar.', p.name using errcode = '22023';
    end if;
    v_total := v_total + p.price_cents::bigint * v_qty;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id', p.id, 'name', p.name, 'unit_price_cents', p.price_cents, 'quantity', v_qty, 'notes', v_line_notes));
  end loop;

  -- Número de pedido
  insert into private.order_counters (restaurant_id) values (r.id) on conflict (restaurant_id) do nothing;
  update private.order_counters set last_number = last_number + 1 where restaurant_id = r.id
  returning last_number into v_number;

  insert into public.orders (id, restaurant_id, number, mode, table_number, customer_name, customer_phone,
    pickup_time, notes, total_cents, payment_method, payment_status)
  values (v_order_id, r.id, v_number, v_mode, v_table, v_name, v_phone, v_pickup, v_notes, v_total::int, v_method,
    case v_method when 'online' then 'pendiente_online'::public.payment_status else 'pendiente_caja'::public.payment_status end);

  insert into public.order_items (order_id, product_id, name, unit_price_cents, quantity, notes)
  select v_order_id, (l ->> 'product_id')::uuid, l ->> 'name', (l ->> 'unit_price_cents')::int, (l ->> 'quantity')::int, l ->> 'notes'
  from jsonb_array_elements(v_lines) as l;

  insert into private.order_access (order_id, token_hash) values (v_order_id, v_hash);

  return private.customer_order_json(v_order_id);
end $$;
-- <<< fase3

-- Lee UN pedido si el token coincide. Si no coincide devuelve null (sin distinguir el motivo).
create or replace function public.get_customer_order(p_order_id uuid, p_token text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select private.customer_order_json(a.order_id)
  from private.order_access a
  where a.order_id = p_order_id and a.token_hash = private.token_hash(p_token)
$$;

-- El cliente abandona el pago online y pagará en caja.
-- Solo si: el token es suyo, el restaurante está activo y acepta caja, el pedido sigue en
-- «nuevo», tiene menos de 2 horas y no hay un cobro en curso en la pasarela.
-- >>> fase3
create or replace function public.customer_switch_to_counter(p_order_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_switch_window constant interval := interval '2 hours';
  o public.orders;
  r public.restaurants;
begin
  select o2.* into o from public.orders o2
  join private.order_access a on a.order_id = o2.id
  where o2.id = p_order_id and a.token_hash = private.token_hash(p_token)
  for update of o2;
  if not found then
    raise exception 'Pedido no encontrado' using errcode = '22023';
  end if;
  select * into r from public.restaurants where id = o.restaurant_id;
  if not r.active or r.suspended_at is not null then
    raise exception 'El restaurante no acepta pedidos en este momento' using errcode = '22023';
  end if;
  if not r.counter_payment_enabled then
    raise exception 'El pago en caja no está disponible en este restaurante' using errcode = '22023';
  end if;
  if o.payment_method <> 'online' or o.payment_status not in ('pendiente_online', 'fallido') or o.prep_status <> 'nuevo' then
    raise exception 'Este pedido ya no puede cambiar de método de pago' using errcode = '22023';
  end if;
  if o.created_at < now() - c_switch_window then
    raise exception 'Este pedido ha caducado. Haz un pedido nuevo.' using errcode = '22023';
  end if;
  -- payment_ref solo lo escribe el servidor al abrir el cobro: si el estado sigue pendiente,
  -- el cliente puede estar pagando ahora mismo y cambiar a caja provocaría un doble cobro.
  if o.payment_status = 'pendiente_online' and o.payment_ref is not null then
    raise exception 'Hay un pago online en curso. Espera a que termine o pide ayuda al personal.' using errcode = '22023';
  end if;
  update public.orders set payment_method = 'caja', payment_status = 'pendiente_caja' where id = o.id;
  return private.customer_order_json(o.id);
end $$;
-- <<< fase3

-- ---------- Funciones para el personal (requieren sesión) ----------

-- Cambia el estado de preparación respetando el rol y las transiciones válidas.
-- >>> fase3
create or replace function public.staff_set_prep_status(p_order_id uuid, p_status public.prep_status) returns void
language plpgsql security definer set search_path = '' as $$
declare
  o public.orders;
  v_role public.staff_role;
begin
  select * into o from public.orders where id = p_order_id for update;
  if found then
    v_role := private.staff_role_for(o.restaurant_id);
  end if;
  -- Cualquier rol del restaurante puede preparar, pero nunca un pedido con pago online pendiente
  -- o fallido (para cocina ni siquiera existe: así no se puede deducir que hay un pedido).
  if not found or v_role is null
     or (v_role = 'kitchen' and o.payment_status in ('pendiente_online', 'fallido')) then
    raise exception 'Pedido no encontrado' using errcode = '42501';
  end if;
  if p_status = 'cancelado' then
    if v_role = 'kitchen' then
      raise exception 'Cocina no puede cancelar pedidos' using errcode = '42501';
    end if;
    if o.prep_status not in ('nuevo', 'en_preparacion', 'listo') then
      raise exception 'Este pedido ya no se puede cancelar' using errcode = '22023';
    end if;
  elsif not ((o.prep_status, p_status) in (
      ('nuevo'::public.prep_status, 'en_preparacion'::public.prep_status),
      ('en_preparacion', 'listo'), ('listo', 'entregado'),
      ('en_preparacion', 'nuevo'), ('listo', 'en_preparacion'))) then
    raise exception 'Cambio de estado no permitido' using errcode = '22023';
  end if;
  update public.orders set prep_status = p_status where id = o.id;
end $$;
-- <<< fase3

-- Registra que el pedido se ha cobrado en caja (owner, manager o waiter).
create or replace function public.staff_mark_paid_at_counter(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  o public.orders;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or not private.has_role(o.restaurant_id, array['owner', 'manager', 'waiter']::public.staff_role[]) then
    raise exception 'Pedido no encontrado' using errcode = '42501';
  end if;
  if o.payment_status <> 'pendiente_caja' or o.prep_status = 'cancelado' then
    raise exception 'Este pedido no está pendiente de cobro en caja' using errcode = '22023';
  end if;
  update public.orders set payment_status = 'cobrado_caja' where id = o.id;
end $$;

-- ---------- Funciones para el servidor de pagos (solo service_role) ----------
-- NO las usa la app. Están preparadas para las Edge Functions de la pasarela real:
--  1. create-checkout: lee el total del pedido (service_role tiene SELECT en orders), abre el
--     cobro en la pasarela por ESE importe y llama a payment_checkout_started con la referencia.
--     Si la función falla (p. ej. el cliente pasó a caja mientras tanto), debe anular el cobro
--     en la pasarela.
--  2. payment-webhook: verifica la FIRMA del aviso del proveedor y llama a
--     payment_record_result con el id del aviso, la referencia, el resultado y el importe cobrado.
-- Ni el SQL Editor ni el personal pueden usarlas: el trigger exige service_role.

-- Registra que se ha abierto un cobro. Devuelve el importe que debe cobrarse.
-- >>> fase3
create or replace function public.payment_checkout_started(p_order_id uuid, p_payment_ref text, p_amount_cents int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.orders;
  r public.restaurants;
begin
  if coalesce(p_payment_ref, '') = '' or char_length(p_payment_ref) > 200 then
    raise exception 'Referencia de pago no válida' using errcode = '22023';
  end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Pedido no encontrado' using errcode = '22023';
  end if;
  if o.payment_ref = p_payment_ref then
    return jsonb_build_object('orderId', o.id, 'amountCents', o.total_cents); -- reintento: sin cambios
  end if;
  if p_amount_cents is distinct from o.total_cents then
    raise exception 'El importe del cobro no coincide con el total del pedido' using errcode = '22023';
  end if;
  select * into r from public.restaurants where id = o.restaurant_id;
  if not r.active or r.suspended_at is not null or not r.online_payment_enabled then
    raise exception 'El pago online no está disponible en este restaurante' using errcode = '22023';
  end if;
  if o.payment_method <> 'online' or o.payment_status not in ('pendiente_online', 'fallido') or o.prep_status <> 'nuevo' then
    raise exception 'Este pedido no admite un pago online' using errcode = '22023';
  end if;
  if o.payment_status = 'pendiente_online' and o.payment_ref is not null then
    raise exception 'Ya hay un pago en curso para este pedido' using errcode = '22023';
  end if;
  insert into private.payment_sessions (payment_ref, order_id) values (p_payment_ref, o.id);
  update public.orders set payment_ref = p_payment_ref, payment_status = 'pendiente_online' where id = o.id;
  return jsonb_build_object('orderId', o.id, 'amountCents', o.total_cents);
end $$;
-- <<< fase3

-- Aplica el resultado de la pasarela. Idempotente por p_provider_event_id.
-- Devuelve 'aplicado', 'ignorado' o 'requiere_revision'. Nunca da por pagado un pedido si
-- el importe no coincide o si el pedido ya no esperaba ese cobro.
create or replace function public.payment_record_result(p_provider_event_id text, p_payment_ref text,
  p_outcome text, p_amount_cents int)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_session private.payment_sessions;
  o public.orders;
  v_previous text;
  v_resolution text;
  v_detail text := '';
begin
  if coalesce(p_provider_event_id, '') = '' or char_length(p_provider_event_id) > 200
     or coalesce(p_payment_ref, '') = '' or char_length(p_payment_ref) > 200 then
    raise exception 'Aviso de pago no válido' using errcode = '22023';
  end if;
  if p_outcome is null or p_outcome not in ('pagado', 'fallido', 'expirado') then
    raise exception 'Resultado de pago no válido' using errcode = '22023';
  end if;
  if p_amount_cents < 0 then
    raise exception 'Importe no válido' using errcode = '22023';
  end if;

  -- El proveedor puede reenviar el mismo aviso, incluso a la vez: se procesa una sola vez.
  perform pg_advisory_xact_lock(hashtextextended('payment_event:' || p_provider_event_id, 0));
  select e.resolution into v_previous from public.payment_events e where e.provider_event_id = p_provider_event_id;
  if found then
    return v_previous;
  end if;

  select * into v_session from private.payment_sessions where payment_ref = p_payment_ref;
  if found then
    select * into o from public.orders where id = v_session.order_id for update;
  end if;

  if o.id is null then
    v_resolution := case when p_outcome = 'pagado' then 'requiere_revision' else 'ignorado' end;
    v_detail := 'Referencia de pago desconocida';
  elsif o.payment_ref is distinct from p_payment_ref then
    v_resolution := case when p_outcome = 'pagado' then 'requiere_revision' else 'ignorado' end;
    v_detail := 'Aviso de un intento de pago anterior';
  elsif p_outcome = 'pagado' then
    if p_amount_cents is distinct from o.total_cents then
      v_resolution := 'requiere_revision';
      v_detail := format('Importe cobrado (%s) distinto del total del pedido (%s)', p_amount_cents, o.total_cents);
    elsif o.payment_method = 'online' and o.payment_status in ('pendiente_online', 'fallido') then
      update public.orders set payment_status = 'pagado_verificado' where id = o.id;
      if o.prep_status = 'cancelado' then
        v_resolution := 'requiere_revision';
        v_detail := 'Pedido cancelado y cobrado: hay que devolver el importe';
      else
        v_resolution := 'aplicado';
      end if;
    else
      v_resolution := 'requiere_revision';
      v_detail := 'Cobro recibido para un pedido que ya no lo esperaba (pasó a caja o ya estaba pagado)';
    end if;
  else
    if o.payment_method = 'online' and o.payment_status = 'pendiente_online' then
      update public.orders set payment_status = 'fallido' where id = o.id;
      v_resolution := 'aplicado';
    else
      v_resolution := 'ignorado';
      v_detail := 'El pedido no estaba pendiente de pago online';
    end if;
  end if;

  insert into public.payment_events (provider_event_id, restaurant_id, order_id, payment_ref, outcome, amount_cents, resolution, detail)
  values (p_provider_event_id, o.restaurant_id, o.id, p_payment_ref, p_outcome, p_amount_cents, v_resolution, v_detail);
  return v_resolution;
end $$;

-- >>> fase3
-- ---------- Equipo del restaurante (sin escritura directa en restaurant_staff) ----------
-- Reglas comunes: hay que haber iniciado sesión; nadie cambia ni quita su propio acceso;
-- la plataforma gestiona cualquier función, el owner gestiona manager/waiter/kitchen y el
-- manager solo waiter/kitchen; siempre queda al menos un owner; una cuenta de plataforma no
-- puede ser personal de un restaurante. Cada cambio queda en el registro de auditoría.

-- Lista del equipo con sus emails. Si la consulta la hace la plataforma, queda registrada.
create or replace function public.staff_list(p_restaurant_id uuid)
returns table (user_id uuid, email text, role public.staff_role, is_me boolean)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'Inicia sesión para ver el equipo' using errcode = '42501';
  end if;
  if private.has_role(p_restaurant_id, array['owner', 'manager']::public.staff_role[]) then
    null;
  elsif private.is_platform_admin() then
    perform private.audit_insert(p_restaurant_id, 'plataforma.consulta_equipo', 'restaurant_staff', null, '{}'::jsonb);
  else
    raise exception 'No tienes acceso al equipo de este restaurante' using errcode = '42501';
  end if;
  return query
    select s.user_id, u.email::text, s.role, s.user_id = (select auth.uid())
    from public.restaurant_staff s join auth.users u on u.id = s.user_id
    where s.restaurant_id = p_restaurant_id
    order by s.role, u.email;
end $$;

create or replace function public.staff_change_role(p_restaurant_id uuid, p_user_id uuid, p_role public.staff_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_old public.staff_role;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para gestionar el equipo' using errcode = '42501';
  end if;
  perform 1 from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  if p_user_id = v_uid then
    raise exception 'No puedes cambiar tu propio acceso' using errcode = '42501';
  end if;
  select s.role into v_old from public.restaurant_staff s
  where s.restaurant_id = p_restaurant_id and s.user_id = p_user_id for update;
  -- Mismo mensaje si no existe o si no hay permiso sobre su función actual.
  if v_old is null or not private.can_manage_role(p_restaurant_id, v_old) then
    raise exception 'No puedes gestionar a esa persona en este restaurante' using errcode = '42501';
  end if;
  if p_role is null or not private.can_manage_role(p_restaurant_id, p_role) then
    raise exception 'No puedes asignar esa función en este restaurante' using errcode = '42501';
  end if;
  if v_old = p_role then
    return;
  end if;
  if v_old = 'owner' and (select count(*) from public.restaurant_staff s
                          where s.restaurant_id = p_restaurant_id and s.role = 'owner') <= 1 then
    raise exception 'El restaurante debe tener siempre al menos un propietario' using errcode = '22023';
  end if;
  update public.restaurant_staff set role = p_role where restaurant_id = p_restaurant_id and user_id = p_user_id;
end $$;

create or replace function public.staff_remove_member(p_restaurant_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_old public.staff_role;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para gestionar el equipo' using errcode = '42501';
  end if;
  perform 1 from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  if p_user_id = v_uid then
    raise exception 'No puedes cambiar tu propio acceso' using errcode = '42501';
  end if;
  select s.role into v_old from public.restaurant_staff s
  where s.restaurant_id = p_restaurant_id and s.user_id = p_user_id for update;
  if v_old is null or not private.can_manage_role(p_restaurant_id, v_old) then
    raise exception 'No puedes gestionar a esa persona en este restaurante' using errcode = '42501';
  end if;
  if v_old = 'owner' and (select count(*) from public.restaurant_staff s
                          where s.restaurant_id = p_restaurant_id and s.role = 'owner') <= 1 then
    raise exception 'El restaurante debe tener siempre al menos un propietario' using errcode = '22023';
  end if;
  delete from public.restaurant_staff where restaurant_id = p_restaurant_id and user_id = p_user_id;
end $$;

-- ---------- Cocina: solo lo necesario para preparar ----------
-- Sin teléfono, importes ni datos de pago. El nombre solo en pedidos para recoger (para
-- identificar la bolsa). Excluye pedidos con pago online pendiente o fallido.
create or replace function public.kitchen_orders(p_restaurant_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or private.staff_role_for(p_restaurant_id) is null then
    raise exception 'No tienes acceso a la cocina de este restaurante' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', o.id, 'number', o.number, 'createdAt', o.created_at, 'mode', o.mode, 'table', o.table_number,
      'customerName', case when o.mode = 'recoger' then o.customer_name end,
      'pickupTime', o.pickup_time, 'notes', o.notes, 'prepStatus', o.prep_status,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('name', i.name, 'quantity', i.quantity, 'notes', i.notes) order by i.id)
        from public.order_items i where i.order_id = o.id), '[]'::jsonb)
    ) order by o.created_at)
    from public.orders o
    where o.restaurant_id = p_restaurant_id
      and o.prep_status in ('nuevo', 'en_preparacion', 'listo')
      and o.payment_status not in ('pendiente_online', 'fallido')
  ), '[]'::jsonb);
end $$;

-- ---------- Registro de auditoría ----------
-- Owner: su restaurante. Plataforma: cualquier restaurante (su consulta también queda registrada)
-- o, con p_restaurant_id null, todo el registro.
create or replace function public.audit_list(p_restaurant_id uuid, p_limit int default 100)
returns table (created_at timestamptz, action text, actor_email text, actor_kind text,
  target_table text, target_id text, details jsonb)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if (select auth.uid()) is null then
    raise exception 'Inicia sesión para ver el registro' using errcode = '42501';
  end if;
  if p_restaurant_id is not null and private.has_role(p_restaurant_id, array['owner']::public.staff_role[]) then
    null;
  elsif private.is_platform_admin() then
    perform private.audit_insert(p_restaurant_id, 'plataforma.consulta_registro', 'audit_log', null, '{}'::jsonb);
  else
    raise exception 'No tienes acceso a este registro' using errcode = '42501';
  end if;
  return query
    select a.created_at, a.action, u.email::text, a.actor_kind, a.target_table, a.target_id, a.details
    from private.audit_log a left join auth.users u on u.id = a.actor_user_id
    where p_restaurant_id is null or a.restaurant_id = p_restaurant_id
    order by a.id desc
    limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;

-- ---------- Plataforma ----------
-- Suspende o reactiva un restaurante. El motivo queda en el registro de auditoría.
create or replace function public.platform_set_suspension(p_restaurant_id uuid, p_suspended boolean, p_reason text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede suspender o reactivar restaurantes' using errcode = '42501';
  end if;
  if p_suspended is null then
    raise exception 'Indica si el restaurante queda suspendido' using errcode = '22023';
  end if;
  if p_suspended and char_length(v_reason) < 3 then
    raise exception 'Indica el motivo de la suspensión' using errcode = '22023';
  end if;
  if char_length(v_reason) > 200 then
    raise exception 'El motivo admite como máximo 200 caracteres' using errcode = '22023';
  end if;
  -- El trigger de auditoría lee el motivo de esta variable de la transacción.
  perform set_config('turestaurante.motivo', v_reason, true);
  update public.restaurants
  set suspended_at = case when p_suspended then coalesce(suspended_at, now()) end
  where id = p_restaurant_id;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
end $$;

-- ---------- Triggers: separación plataforma/restaurantes y auditoría ----------
create or replace function private.guard_staff_not_platform() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.platform_admins pa where pa.user_id = new.user_id) then
    raise exception 'Las cuentas de la plataforma no pueden ser personal de un restaurante' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function private.guard_platform_not_staff() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.restaurant_staff s where s.user_id = new.user_id) then
    raise exception 'Esta cuenta es personal de un restaurante. Usa una cuenta distinta para la plataforma.' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function private.audit_log_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'El registro de auditoría no se puede modificar ni borrar' using errcode = '42501';
end $$;

create or replace function private.audit_staff_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'personal.alta', 'restaurant_staff', new.user_id::text,
      jsonb_build_object('funcion', new.role));
  elsif tg_op = 'UPDATE' then
    if new.role is distinct from old.role then
      perform private.audit_insert(new.restaurant_id, 'personal.cambio_funcion', 'restaurant_staff', new.user_id::text,
        jsonb_build_object('antes', old.role, 'despues', new.role));
    end if;
  else
    perform private.audit_insert(old.restaurant_id, 'personal.baja', 'restaurant_staff', old.user_id::text,
      jsonb_build_object('funcion', old.role));
  end if;
  return null;
end $$;

create or replace function private.audit_product_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'carta.alta_producto', 'products', new.id::text,
      jsonb_build_object('producto', new.name, 'precio', new.price_cents));
  elsif tg_op = 'UPDATE' then
    if new.price_cents is distinct from old.price_cents then
      perform private.audit_insert(new.restaurant_id, 'carta.precio', 'products', new.id::text,
        jsonb_build_object('producto', new.name, 'antes', old.price_cents, 'despues', new.price_cents));
    end if;
  else
    perform private.audit_insert(old.restaurant_id, 'carta.baja_producto', 'products', old.id::text,
      jsonb_build_object('producto', old.name, 'precio', old.price_cents));
  end if;
  return null;
end $$;

create or replace function private.audit_order_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.prep_status = 'cancelado' and old.prep_status <> 'cancelado' then
    perform private.audit_insert(new.restaurant_id, 'pedido.cancelacion', 'orders', new.id::text,
      jsonb_build_object('numero', new.number, 'estado_anterior', old.prep_status, 'pago', new.payment_status));
  end if;
  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'cobrado_caja' then
      perform private.audit_insert(new.restaurant_id, 'pedido.cobro_caja', 'orders', new.id::text,
        jsonb_build_object('numero', new.number, 'importe', new.total_cents));
    elsif new.payment_status = 'pagado_verificado' then
      perform private.audit_insert(new.restaurant_id, 'pago.verificado', 'orders', new.id::text,
        jsonb_build_object('numero', new.number, 'importe', new.total_cents));
    elsif new.payment_method = 'caja' and old.payment_method = 'online' then
      perform private.audit_insert(new.restaurant_id, 'pedido.pasa_a_caja', 'orders', new.id::text,
        jsonb_build_object('numero', new.number));
    end if;
  end if;
  return null;
end $$;

create or replace function private.audit_restaurant_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.id, 'restaurante.alta', 'restaurants', new.id::text,
      jsonb_build_object('nombre', new.name, 'slug', new.slug));
    return null;
  end if;
  if new.suspended_at is not null and old.suspended_at is null then
    perform private.audit_insert(new.id, 'restaurante.suspension', 'restaurants', new.id::text,
      jsonb_build_object('motivo', coalesce(current_setting('turestaurante.motivo', true), '')));
  elsif new.suspended_at is null and old.suspended_at is not null then
    perform private.audit_insert(new.id, 'restaurante.reactivacion', 'restaurants', new.id::text,
      jsonb_build_object('motivo', coalesce(current_setting('turestaurante.motivo', true), '')));
  end if;
  if new.slug is distinct from old.slug then
    perform private.audit_insert(new.id, 'restaurante.slug', 'restaurants', new.id::text,
      jsonb_build_object('antes', old.slug, 'despues', new.slug));
  end if;
  if new.active is distinct from old.active then
    perform private.audit_insert(new.id, 'restaurante.apertura', 'restaurants', new.id::text,
      jsonb_build_object('acepta_pedidos', new.active));
  end if;
  if new.online_payment_enabled is distinct from old.online_payment_enabled then
    perform private.audit_insert(new.id, 'restaurante.pago_online', 'restaurants', new.id::text,
      jsonb_build_object('activo', new.online_payment_enabled));
  end if;
  return null;
end $$;

create or replace function private.audit_platform_admin_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(null, 'plataforma.alta_admin', 'platform_admins', new.user_id::text, '{}'::jsonb);
  else
    perform private.audit_insert(null, 'plataforma.baja_admin', 'platform_admins', old.user_id::text, '{}'::jsonb);
  end if;
  return null;
end $$;

drop trigger if exists restaurant_staff_not_platform on public.restaurant_staff;
create trigger restaurant_staff_not_platform before insert or update on public.restaurant_staff
  for each row execute function private.guard_staff_not_platform();
drop trigger if exists platform_admins_not_staff on public.platform_admins;
create trigger platform_admins_not_staff before insert or update on public.platform_admins
  for each row execute function private.guard_platform_not_staff();
drop trigger if exists audit_log_no_update on private.audit_log;
create trigger audit_log_no_update before update or delete on private.audit_log
  for each row execute function private.audit_log_immutable();
drop trigger if exists audit_log_no_truncate on private.audit_log;
create trigger audit_log_no_truncate before truncate on private.audit_log
  for each statement execute function private.audit_log_immutable();
drop trigger if exists restaurant_staff_audit on public.restaurant_staff;
create trigger restaurant_staff_audit after insert or update or delete on public.restaurant_staff
  for each row execute function private.audit_staff_changes();
drop trigger if exists products_audit on public.products;
create trigger products_audit after insert or update or delete on public.products
  for each row execute function private.audit_product_changes();
drop trigger if exists orders_audit on public.orders;
create trigger orders_audit after update on public.orders
  for each row execute function private.audit_order_changes();
drop trigger if exists restaurants_audit on public.restaurants;
create trigger restaurants_audit after insert or update on public.restaurants
  for each row execute function private.audit_restaurant_changes();
drop trigger if exists platform_admins_audit on public.platform_admins;
create trigger platform_admins_audit after insert or delete on public.platform_admins
  for each row execute function private.audit_platform_admin_changes();
-- <<< fase3

-- >>> fase4
-- ---------- Modo soporte ----------
-- Estado visible: un acceso aprobado cuya hora ya pasó aparece como «caducada».
create or replace function private.support_status(p_status text, p_expires_at timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when p_status = 'aprobada' and p_expires_at <= now() then 'caducada' else p_status end
$$;

-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

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

-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- La plataforma solicita acceso de solo lectura a un restaurante, con un motivo.
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- El PROPIETARIO del restaurante aprueba (2 horas exactas desde ahora) o rechaza.
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

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
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Solicitudes de un restaurante (para su propietario).
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Solicitudes propias (para la cuenta de plataforma).
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Consulta de soporte: estado general del restaurante. Sin datos personales (el equipo, solo
-- cuántas personas hay por función).
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Consulta de soporte: últimos pedidos. Sin nombre, teléfono, notas ni referencia de pago del
-- cliente (solo si existen).
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Consulta de soporte: avisos de la pasarela de pago (para incidencias de cobro).
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

-- Integridad del historial de accesos: no se borra, no cambian sus datos, solo transiciones
-- válidas y un acceso aprobado solo se puede ACORTAR, nunca ampliar. Se aplica a todos.
-- <<< fase4
-- >>> fase5
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
-- <<< fase5
-- >>> fase4

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
-- <<< fase4

-- >>> fase6
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

-- ---------- Entrega de correos: solo para el servidor (Edge Function con la clave secreta) ----------
-- Ciclo: invitation_delivery_claim (reserva) → envío → invitation_delivery_finish (resultado).
-- invitation_delivery_pending devuelve las entregas atrasadas o interrumpidas para recuperarlas.
-- «account_exists» y «account_confirmed» solo los ve el servidor; nunca llegan a quien invita.
drop function if exists public.invitation_delivery(uuid);
drop function if exists public.invitation_mark_sent(uuid, text);

create or replace function private.require_service_role(p_what text) returns void
language plpgsql stable set search_path = '' as $$
begin
  if coalesce(private.request_role(), '') <> 'service_role' then
    raise exception 'Solo el servidor puede %', p_what using errcode = '42501';
  end if;
end $$;

-- Reserva la entrega de UNA invitación. Es atómica: si dos procesos lo intentan a la vez (peticiones
-- simultáneas, reintentos o recuperación), solo uno la obtiene; el otro no recibe nada. Se puede
-- reservar si está pendiente y sin caducar, quedan intentos y: está por enviar (y ya pasó la espera
-- del reintento) o su reserva anterior caducó (el proceso se interrumpió).
create or replace function public.invitation_delivery_claim(p_invitation_id uuid)
returns table (claim uuid, attempt int, email text, role public.staff_role, restaurant_name text,
  account_exists boolean, account_confirmed boolean)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_claim uuid := gen_random_uuid();
begin
  perform private.require_service_role('enviar invitaciones');
  update private.invitations i
  set send_status = 'enviando', send_claim = v_claim, send_claimed_at = now(), send_attempts = i.send_attempts + 1
  where i.id = p_invitation_id and i.status = 'pendiente' and i.expires_at > now() and i.send_attempts < 3
    and ((i.send_status = 'sin_enviar' and (i.send_next_at is null or i.send_next_at <= now()))
         or (i.send_status = 'enviando' and i.send_claimed_at <= now() - interval '10 minutes'));
  if not found then
    return;
  end if;
  return query
    select v_claim, i.send_attempts, i.email, i.role, r.name,
      exists (select 1 from auth.users u where lower(u.email::text) = i.email),
      exists (select 1 from auth.users u where lower(u.email::text) = i.email and u.email_confirmed_at is not null)
    from private.invitations i join public.restaurants r on r.id = i.restaurant_id
    where i.id = p_invitation_id;
end $$;

-- Anota el resultado. Solo vale con la reserva vigente (p_claim): un proceso que perdió su reserva
-- no puede sobrescribir el resultado de otro. «reintentar»: vuelve a «sin_enviar» con espera
-- (5 min tras el 1.er intento, 30 min tras el 2.º); tras el 3.º, «fallida».
create or replace function public.invitation_delivery_finish(p_invitation_id uuid, p_claim uuid, p_result text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_service_role('anotar envíos de invitaciones');
  if p_result is null or p_result not in ('enviada', 'no_necesario', 'reintentar', 'fallida') then
    raise exception 'Resultado de envío no válido' using errcode = '22023';
  end if;
  update private.invitations i
  set send_status = case
        when p_result <> 'reintentar' then p_result
        when i.send_attempts >= 3 or i.status <> 'pendiente' then 'fallida'
        else 'sin_enviar' end,
      send_next_at = case
        when p_result = 'reintentar' and i.send_attempts < 3
          then now() + case i.send_attempts when 1 then interval '5 minutes' else interval '30 minutes' end
        else i.send_next_at end,
      last_sent_at = case when p_result = 'enviada' then now() else i.last_sent_at end,
      send_claim = null, send_claimed_at = null
  where i.id = p_invitation_id and i.send_status = 'enviando' and i.send_claim = p_claim;
  return found;
end $$;

-- Entregas para recuperar (como mucho 10 por llamada, para no enviar correos en masa): por enviar
-- desde hace más de 2 minutos (su proceso original no llegó a reservarla) o con la espera del
-- reintento cumplida, y reservas caducadas (proceso interrumpido). Antes cierra como «fallida» las
-- reservas caducadas que ya no se pueden retomar (sin intentos, cerrada o caducada).
create or replace function public.invitation_delivery_pending(p_limit int default 5)
returns setof uuid language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_service_role('recuperar envíos de invitaciones');
  update private.invitations i
  set send_status = 'fallida', send_claim = null, send_claimed_at = null
  where i.send_status = 'enviando' and i.send_claimed_at <= now() - interval '10 minutes'
    and (i.send_attempts >= 3 or i.status <> 'pendiente' or i.expires_at <= now());
  return query
    select i.id from private.invitations i
    where i.status = 'pendiente' and i.expires_at > now() and i.send_attempts < 3
      and ((i.send_status = 'sin_enviar' and coalesce(i.send_next_at, i.created_at + interval '2 minutes') <= now())
           or (i.send_status = 'enviando' and i.send_claimed_at <= now() - interval '10 minutes'))
    -- Primero las interrumpidas; después, por antigüedad (las que más esperan).
    order by (i.send_status = 'enviando') desc, coalesce(i.send_next_at, i.created_at)
    limit greatest(1, least(coalesce(p_limit, 5), 10));
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
       or new.closed_reason is not null or new.send_status <> 'sin_enviar' or new.last_sent_at is not null
       or new.send_attempts <> 0 or new.send_claim is not null or new.send_claimed_at is not null or new.send_next_at is not null then
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
  if (new.send_status, new.send_attempts, new.send_claim, new.send_claimed_at, new.send_next_at, new.last_sent_at)
     is distinct from (old.send_status, old.send_attempts, old.send_claim, old.send_claimed_at, old.send_next_at, old.last_sent_at) then
    -- Solo una invitación pendiente se reserva; una reserva en curso se puede cerrar aunque la
    -- invitación se haya cerrado mientras tanto. Un resultado definitivo no cambia.
    if old.status <> 'pendiente' and old.send_status <> 'enviando' then
      raise exception 'Solo se puede anotar el envío de una invitación pendiente' using errcode = '42501';
    end if;
    if old.send_status in ('enviada', 'no_necesario', 'fallida') then
      raise exception 'El resultado de un envío no se puede cambiar' using errcode = '42501';
    end if;
    if new.send_attempts < old.send_attempts then
      raise exception 'Los intentos de envío no se pueden reducir' using errcode = '42501';
    end if;
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
  elsif old.send_status = 'enviando' and new.send_status <> 'enviando' then
    -- Resultado de cada intento de entrega. SIN restaurante: solo lo ve la plataforma. Que se envíe
    -- o no un correo depende de si la persona ya tenía cuenta confirmada, así que el propietario no
    -- debe verlo.
    perform private.audit_insert(null, 'invitacion.entrega', 'invitations', new.id::text,
      v_details || jsonb_build_object('restaurante', new.restaurant_id, 'intento', new.send_attempts,
        'resultado', case new.send_status when 'sin_enviar' then 'reintento' else new.send_status end));
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
-- <<< fase6

-- Restaurantes y rol del usuario actual (para la app del personal).
-- >>> fase3
create or replace function public.my_memberships() returns table (restaurant_id uuid, role public.staff_role)
language sql stable security definer set search_path = '' as $$
  -- Solo los restaurantes donde el usuario es personal. La cuenta de plataforma no aparece como
  -- owner de ninguno: sus funciones de plataforma se comprueban aparte (platform_admins).
  select s.restaurant_id, s.role from public.restaurant_staff s
  where s.user_id = (select auth.uid())
$$;
-- <<< fase3

-- ---------- Permisos de ejecución ----------
-- PostgreSQL y Supabase dan EXECUTE a todos por defecto: lo quitamos y concedemos lo justo.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.staff_role_for(uuid), private.has_role(uuid, public.staff_role[]),
  private.is_platform_admin(), private.can_view_order(uuid, public.payment_status) to authenticated;
-- La usan los triggers, que se ejecutan con el rol de quien modifica la tabla.
grant execute on function private.request_role() to authenticated, service_role;

revoke all on function public.create_order(jsonb), public.get_customer_order(uuid, text),
  public.customer_switch_to_counter(uuid, text), public.staff_set_prep_status(uuid, public.prep_status),
  public.staff_mark_paid_at_counter(uuid), public.my_memberships() from public, anon, authenticated;
grant execute on function public.create_order(jsonb), public.get_customer_order(uuid, text),
  public.customer_switch_to_counter(uuid, text) to anon, authenticated;
grant execute on function public.staff_set_prep_status(uuid, public.prep_status),
  public.staff_mark_paid_at_counter(uuid), public.my_memberships() to authenticated;
revoke all on function public.payment_checkout_started(uuid, text, int),
  public.payment_record_result(text, text, text, int) from public, anon, authenticated;
grant execute on function public.payment_checkout_started(uuid, text, int),
  public.payment_record_result(text, text, text, int) to service_role;
-- >>> fase3
revoke all on function private.actor_kind(), private.audit_insert(uuid, text, text, text, jsonb),
  private.can_manage_role(uuid, public.staff_role), private.guard_staff_not_platform(),
  private.guard_platform_not_staff(), private.audit_log_immutable(), private.audit_staff_changes(),
  private.audit_product_changes(), private.audit_order_changes(), private.audit_restaurant_changes(),
  private.audit_platform_admin_changes() from public, anon, authenticated;
-- guard_restaurant (trigger) comprueba si quien modifica es de la plataforma, también con service_role.
grant execute on function private.is_platform_admin() to service_role;
revoke all on function public.staff_list(uuid),
  public.staff_change_role(uuid, uuid, public.staff_role), public.staff_remove_member(uuid, uuid),
  public.kitchen_orders(uuid), public.audit_list(uuid, int), public.platform_set_suspension(uuid, boolean, text)
  from public, anon, authenticated;
-- Cada función comprueba dentro quién llama (rol en el restaurante o plataforma).
grant execute on function public.staff_list(uuid),
  public.staff_change_role(uuid, uuid, public.staff_role), public.staff_remove_member(uuid, uuid),
  public.kitchen_orders(uuid), public.audit_list(uuid, int), public.platform_set_suspension(uuid, boolean, text)
  to authenticated;
-- <<< fase3
-- >>> fase4
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
-- <<< fase4
-- >>> fase5
-- Funciones internas: nadie de la API puede ejecutarlas (así nadie puede anotar denegaciones falsas).
revoke all on function private.support_pending_ttl(), private.support_state(text, timestamptz, timestamptz),
  private.support_denial_reason(uuid), private.support_denial_message(text),
  private.support_log_denial(uuid, text, text), private.support_denied_response(uuid), private.guard_support_denials()
  from public, anon, authenticated;
revoke all on function public.support_denials_list(uuid) from public, anon, authenticated;
grant execute on function public.support_denials_list(uuid) to authenticated;
-- <<< fase5
-- >>> fase6
-- Funciones internas: nadie de la API puede ejecutarlas.
revoke all on function private.normalize_email(text), private.mask_email(text),
  private.role_can_invite(public.staff_role, public.staff_role), private.invitation_state(text, timestamptz),
  private.invitation_inviter_ok(uuid, uuid, text, public.staff_role), private.my_confirmed_email(),
  private.invitation_insert(uuid, text, public.staff_role, uuid, int), private.guard_invitations(),
  private.audit_invitation_changes(), private.invitations_on_staff_change(), private.invitations_on_platform_removal(),
  private.guard_restaurant_activation(), private.require_service_role(text)
  from public, anon, authenticated, service_role;
revoke all on function public.invitation_create(uuid, text, public.staff_role), public.invitation_resend(uuid),
  public.invitation_revoke(uuid), public.invitation_list(uuid), public.my_invitations(), public.invitation_accept(uuid),
  public.invitation_decline(uuid), public.platform_create_restaurant(text, text, text),
  public.invitation_delivery_claim(uuid), public.invitation_delivery_finish(uuid, uuid, text),
  public.invitation_delivery_pending(int)
  from public, anon, authenticated, service_role;
-- Personal y plataforma (cada función comprueba dentro quién llama y qué puede hacer).
grant execute on function public.invitation_create(uuid, text, public.staff_role), public.invitation_resend(uuid),
  public.invitation_revoke(uuid), public.invitation_list(uuid), public.my_invitations(), public.invitation_accept(uuid),
  public.invitation_decline(uuid), public.platform_create_restaurant(text, text, text) to authenticated;
-- Solo el servidor (Edge Function de envío de correos).
grant execute on function public.invitation_delivery_claim(uuid), public.invitation_delivery_finish(uuid, uuid, text),
  public.invitation_delivery_pending(int) to service_role;
-- <<< fase6

-- ---------- Permisos sobre tablas + RLS ----------
revoke all on all tables in schema private from public, anon, authenticated;

-- Nadie escribe pedidos directamente desde la API: solo mediante las funciones de arriba.
revoke all on public.orders, public.order_items, public.payment_events from anon, authenticated;
grant select on public.orders, public.order_items, public.payment_events to authenticated;
revoke all on public.restaurant_staff, public.platform_admins from anon;
revoke insert, update, delete, truncate, references, trigger on public.platform_admins from authenticated;
revoke insert, update, delete, truncate, references, trigger on public.restaurants, public.categories, public.products from anon;
revoke truncate, references, trigger on public.restaurants, public.categories, public.products, public.restaurant_staff from authenticated;
-- Permisos explícitos (no dependemos de los que Supabase concede por defecto). RLS filtra las filas.
grant select on public.restaurants, public.categories, public.products to anon, authenticated;
grant insert, update on public.restaurants to authenticated;
grant insert, update, delete on public.categories, public.products to authenticated;
grant select on public.restaurant_staff to authenticated;
grant select on public.platform_admins to authenticated;
-- Servidor (Edge Functions con la clave secreta): solo las tablas de TuRestaurante.
-- Puede administrar restaurantes, carta y personal. Sobre pedidos y pagos solo LEE: los cambia
-- únicamente a través de payment_checkout_started y payment_record_result.
revoke all on public.restaurants, public.categories, public.products, public.restaurant_staff,
  public.platform_admins, public.orders, public.order_items, public.payment_events from service_role;
grant select, insert, update, delete on public.restaurants, public.categories, public.products,
  public.restaurant_staff, public.platform_admins to service_role;
grant select on public.orders, public.order_items, public.payment_events to service_role;
-- >>> fase3
-- El equipo solo se modifica con las funciones staff_* (que aplican las reglas y auditan).
revoke insert, update, delete on public.restaurant_staff from authenticated;
-- El registro de auditoría no es accesible por la API para nadie (se lee con audit_list).
revoke all on private.audit_log from public, anon, authenticated, service_role;
-- <<< fase3
-- >>> fase4
-- Accesos de soporte: nadie los lee ni escribe por la API (solo con las funciones support_*).
revoke all on private.support_grants from public, anon, authenticated, service_role;
alter table private.support_grants enable row level security;
-- <<< fase4
-- >>> fase5
-- Intentos denegados: nadie los lee ni escribe por la API (se leen con support_denials_list).
revoke all on private.support_denials from public, anon, authenticated, service_role;
alter table private.support_denials enable row level security;
-- <<< fase5
-- >>> fase6
-- Invitaciones: nadie las lee ni escribe por la API (solo con las funciones invitation_*).
revoke all on private.invitations from public, anon, authenticated, service_role;
alter table private.invitations enable row level security;
-- Nadie entra en un equipo ni en la plataforma sin pasar por las reglas, tampoco el servidor con
-- la clave secreta: el alta en un equipo es solo invitation_accept.
revoke insert, update, delete on public.restaurant_staff, public.platform_admins from service_role;
-- <<< fase6

alter table public.restaurants enable row level security;
alter table public.restaurant_staff enable row level security;
alter table public.platform_admins enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table private.order_counters enable row level security;
alter table private.order_access enable row level security;
alter table private.payment_sessions enable row level security;
alter table public.payment_events enable row level security;

-- Elimina SOLO las políticas de este proyecto (para poder recrearlas) y las de la versión 1.
-- Las políticas que añadas tú con otros nombres se conservan.
drop policy if exists restaurants_select on public.restaurants;
drop policy if exists restaurants_insert on public.restaurants;
drop policy if exists restaurants_update on public.restaurants;
drop policy if exists staff_select on public.restaurant_staff;
drop policy if exists staff_insert on public.restaurant_staff;
drop policy if exists staff_update on public.restaurant_staff;
drop policy if exists staff_delete on public.restaurant_staff;
drop policy if exists platform_admins_select on public.platform_admins;
drop policy if exists categories_select on public.categories;
drop policy if exists categories_write on public.categories;
drop policy if exists products_select on public.products;
drop policy if exists products_write on public.products;
drop policy if exists orders_select on public.orders;
drop policy if exists order_items_select on public.order_items;
drop policy if exists payment_events_select on public.payment_events;
-- Nombres de la versión 1
drop policy if exists "carta pública restaurantes" on public.restaurants;
drop policy if exists "staff edita restaurante" on public.restaurants;
drop policy if exists "admin crea restaurantes" on public.restaurants;
drop policy if exists "carta pública categorías" on public.categories;
drop policy if exists "staff gestiona categorías" on public.categories;
drop policy if exists "carta pública productos" on public.products;
drop policy if exists "staff gestiona productos" on public.products;
drop policy if exists "staff ve pedidos" on public.orders;
drop policy if exists "staff actualiza pedidos" on public.orders;
drop policy if exists "staff ve líneas" on public.order_items;

-- Restaurantes: la carta es pública; crear, solo la plataforma.
create policy restaurants_select on public.restaurants for select to anon, authenticated using (true);
create policy restaurants_insert on public.restaurants for insert to authenticated
  with check (private.is_platform_admin());

-- >>> fase3
-- Configuración del restaurante: su owner y la plataforma (el manager ya no). La dirección web y
-- la suspensión solo las cambia la plataforma (trigger guard_restaurant).
drop policy if exists restaurants_update on public.restaurants;
create policy restaurants_update on public.restaurants for update to authenticated
  using (private.is_platform_admin() or private.has_role(id, array['owner']::public.staff_role[]))
  with check (private.is_platform_admin() or private.has_role(id, array['owner']::public.staff_role[]));

-- Personal: cada uno ve su fila; owner y manager ven el equipo de su restaurante; la plataforma
-- ve todos. Nadie escribe directamente: altas solo con invitation_accept (fase 6), cambios y
-- bajas con staff_change_role y staff_remove_member.
drop policy if exists staff_select on public.restaurant_staff;
drop policy if exists staff_insert on public.restaurant_staff;
drop policy if exists staff_update on public.restaurant_staff;
drop policy if exists staff_delete on public.restaurant_staff;
create policy staff_select on public.restaurant_staff for select to authenticated
  using (user_id = (select auth.uid())
         or private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[])
         or private.is_platform_admin());
-- <<< fase3

create policy platform_admins_select on public.platform_admins for select to authenticated
  using (user_id = (select auth.uid()));

-- Carta: lectura pública; cambios solo owner/manager del restaurante (cocina y sala no).
create policy categories_select on public.categories for select to anon, authenticated using (true);
create policy categories_write on public.categories for all to authenticated
  using (private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[]))
  with check (private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[]));
create policy products_select on public.products for select to anon, authenticated using (true);
create policy products_write on public.products for all to authenticated
  using (private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[]))
  with check (private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[]));

-- Pedidos: solo lectura para owner, manager y sala del restaurante. Cocina usa kitchen_orders().
create policy orders_select on public.orders for select to authenticated
  using (private.can_view_order(restaurant_id, payment_status));
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_items.order_id));

-- Avisos de pago: los ven owner y manager de su restaurante (para resolver las revisiones).
create policy payment_events_select on public.payment_events for select to authenticated
  using (private.has_role(restaurant_id, array['owner', 'manager']::public.staff_role[]));

-- ---------- Tiempo real (panel y cocina; respeta RLS) ----------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders') then
      alter publication supabase_realtime add table public.orders;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'products') then
      alter publication supabase_realtime add table public.products;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'restaurants') then
      alter publication supabase_realtime add table public.restaurants;
    end if;
  end if;
end $$;

commit;
