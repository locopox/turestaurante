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

-- Añade al equipo una cuenta que YA existe (las invitaciones por correo son de una fase posterior).
create or replace function public.staff_add_member(p_restaurant_id uuid, p_email text, p_role public.staff_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_target uuid;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para gestionar el equipo' using errcode = '42501';
  end if;
  -- Serializa los cambios de equipo de este restaurante (regla del último owner sin carreras).
  perform 1 from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  -- El permiso se comprueba ANTES de buscar el email: sin permiso no se puede saber si existe.
  if p_role is null or not private.can_manage_role(p_restaurant_id, p_role) then
    raise exception 'No puedes asignar esa función en este restaurante' using errcode = '42501';
  end if;
  select u.id into v_target from auth.users u where lower(u.email) = lower(btrim(coalesce(p_email, '')));
  if v_target is null then
    raise exception 'No hay ninguna cuenta con ese email. Por ahora hay que crearla en Supabase (Authentication → Users).' using errcode = '22023';
  end if;
  if v_target = v_uid then
    raise exception 'No puedes cambiar tu propio acceso' using errcode = '42501';
  end if;
  if exists (select 1 from public.platform_admins pa where pa.user_id = v_target) then
    raise exception 'Las cuentas de la plataforma no pueden ser personal de un restaurante' using errcode = '42501';
  end if;
  if exists (select 1 from public.restaurant_staff s where s.restaurant_id = p_restaurant_id and s.user_id = v_target) then
    raise exception 'Esa persona ya forma parte del equipo. Cambia su función en su lugar.' using errcode = '22023';
  end if;
  insert into public.restaurant_staff (restaurant_id, user_id, role) values (p_restaurant_id, v_target, p_role);
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
revoke all on function public.staff_list(uuid), public.staff_add_member(uuid, text, public.staff_role),
  public.staff_change_role(uuid, uuid, public.staff_role), public.staff_remove_member(uuid, uuid),
  public.kitchen_orders(uuid), public.audit_list(uuid, int), public.platform_set_suspension(uuid, boolean, text)
  from public, anon, authenticated;
-- Cada función comprueba dentro quién llama (rol en el restaurante o plataforma).
grant execute on function public.staff_list(uuid), public.staff_add_member(uuid, text, public.staff_role),
  public.staff_change_role(uuid, uuid, public.staff_role), public.staff_remove_member(uuid, uuid),
  public.kitchen_orders(uuid), public.audit_list(uuid, int), public.platform_set_suspension(uuid, boolean, text)
  to authenticated;
-- <<< fase3

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
-- ve todos. Nadie escribe directamente: altas, cambios y bajas con staff_add_member,
-- staff_change_role y staff_remove_member.
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
