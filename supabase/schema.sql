-- TuRestaurante · esquema inicial para Supabase (Postgres)
-- Ejecutar en el SQL Editor de Supabase. Revisar las políticas RLS antes de producción.

create extension if not exists "pgcrypto";

-- Restaurantes (multi-tenant)
create table public.restaurants (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  tagline text default '',
  address text default '',
  phone text default '',
  active boolean not null default false,
  tables int not null default 10 check (tables between 0 and 500),
  pickup_enabled boolean not null default true,
  online_payment_enabled boolean not null default true,
  counter_payment_enabled boolean not null default true,
  prep_minutes int not null default 15,
  order_counter int not null default 100,
  created_at timestamptz not null default now()
);

-- Personal de cada restaurante (relación con auth.users)
create type public.staff_role as enum ('owner', 'manager', 'waiter', 'kitchen');
create table public.restaurant_staff (
  restaurant_id uuid references public.restaurants on delete cascade,
  user_id uuid references auth.users on delete cascade,
  role public.staff_role not null,
  primary key (restaurant_id, user_id)
);
-- Administradores de la plataforma (pueden gestionar todos los restaurantes)
create table public.platform_admins (user_id uuid primary key references auth.users on delete cascade);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete cascade,
  name text not null,
  sort int not null default 0
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete cascade,
  category_id uuid not null references public.categories on delete cascade,
  name text not null,
  description text default '',
  price_cents int not null check (price_cents >= 0),
  art text not null default 'pizza',
  image_url text,
  allergens text[] not null default '{}',
  tags text[] not null default '{}',
  available boolean not null default true,
  sort int not null default 0
);

create type public.order_mode as enum ('mesa', 'recoger');
create type public.payment_method as enum ('online', 'caja');
create type public.payment_status as enum
  ('pendiente_online', 'simulado', 'pagado_verificado', 'pendiente_caja', 'cobrado_caja', 'fallido');
create type public.prep_status as enum ('nuevo', 'en_preparacion', 'listo', 'entregado', 'cancelado');

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants on delete cascade,
  number int not null,
  mode public.order_mode not null,
  table_number int,
  customer_name text,
  customer_phone text,
  pickup_time text,
  notes text default '',
  total_cents int not null,
  payment_method public.payment_method not null,
  payment_status public.payment_status not null,
  payment_ref text,
  prep_status public.prep_status not null default 'nuevo',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, number)
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders on delete cascade,
  product_id uuid references public.products on delete set null,
  name text not null,
  unit_price_cents int not null,
  quantity int not null check (quantity > 0),
  notes text
);

create index on public.orders (restaurant_id, created_at desc);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

-- Crea un pedido calculando precios en el servidor. Devuelve el id.
create or replace function public.create_order(payload jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  r public.restaurants;
  new_id uuid := gen_random_uuid();
  n int;
  total int := 0;
  line jsonb;
  p public.products;
  method public.payment_method := (payload->>'paymentMethod')::public.payment_method;
begin
  select * into r from public.restaurants where id = (payload->>'restaurantId')::uuid and active for update;
  if not found then raise exception 'El restaurante no acepta pedidos'; end if;
  if jsonb_array_length(payload->'items') = 0 then raise exception 'El pedido está vacío'; end if;

  update public.restaurants set order_counter = order_counter + 1 where id = r.id returning order_counter into n;

  insert into public.orders (id, restaurant_id, number, mode, table_number, customer_name, customer_phone,
    pickup_time, notes, total_cents, payment_method, payment_status)
  values (new_id, r.id, n, (payload->>'mode')::public.order_mode, nullif(payload->>'table','')::int,
    payload->>'customerName', payload->>'customerPhone', payload->>'pickupTime', coalesce(payload->>'notes',''),
    0, method, case when method = 'online' then 'pendiente_online' else 'pendiente_caja' end::public.payment_status);

  for line in select * from jsonb_array_elements(payload->'items') loop
    select * into p from public.products where id = (line->>'productId')::uuid and restaurant_id = r.id and available;
    if not found then raise exception 'Producto no disponible'; end if;
    insert into public.order_items (order_id, product_id, name, unit_price_cents, quantity, notes)
    values (new_id, p.id, p.name, p.price_cents, greatest(1, (line->>'quantity')::int), line->>'notes');
    total := total + p.price_cents * greatest(1, (line->>'quantity')::int);
  end loop;

  update public.orders set total_cents = total where id = new_id;
  return new_id;
end $$;

-- ===== Seguridad (RLS) =====
alter table public.restaurants enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.restaurant_staff enable row level security;
alter table public.platform_admins enable row level security;

create or replace function public.is_staff(rid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from restaurant_staff where restaurant_id = rid and user_id = auth.uid())
      or exists (select 1 from platform_admins where user_id = auth.uid());
$$;
create or replace function public.is_platform_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

-- Carta pública (clientes anónimos)
create policy "carta pública restaurantes" on public.restaurants for select using (true);
create policy "carta pública categorías" on public.categories for select using (true);
create policy "carta pública productos" on public.products for select using (true);

-- Gestión de carta y restaurante: personal y administradores
create policy "staff edita restaurante" on public.restaurants for update using (public.is_staff(id));
create policy "admin crea restaurantes" on public.restaurants for insert with check (public.is_platform_admin());
create policy "staff gestiona categorías" on public.categories for all using (public.is_staff(restaurant_id)) with check (public.is_staff(restaurant_id));
create policy "staff gestiona productos" on public.products for all using (public.is_staff(restaurant_id)) with check (public.is_staff(restaurant_id));

-- Pedidos: los clientes crean vía create_order (security definer).
-- Para que el cliente siga su pedido sin cuenta, exponer una vista/RPC por id (uuid no adivinable).
create policy "staff ve pedidos" on public.orders for select using (public.is_staff(restaurant_id));
create policy "staff actualiza pedidos" on public.orders for update using (public.is_staff(restaurant_id));
create policy "staff ve líneas" on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and public.is_staff(o.restaurant_id)));

-- Importante: 'pagado_verificado' solo debe escribirlo la Edge Function del webhook (service role).
-- Añadir un trigger que impida a usuarios autenticados fijar ese valor.
create or replace function public.guard_payment_status() returns trigger language plpgsql as $$
begin
  if new.payment_status = 'pagado_verificado' and old.payment_status is distinct from 'pagado_verificado'
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Solo el servidor puede marcar un pago como verificado';
  end if;
  return new;
end $$;
create trigger orders_guard_payment before update on public.orders for each row execute function public.guard_payment_status();

grant execute on function public.create_order(jsonb) to anon, authenticated;

-- Tiempo real
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.products;
alter publication supabase_realtime add table public.restaurants;
