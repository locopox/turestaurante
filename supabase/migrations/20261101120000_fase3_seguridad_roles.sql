-- =====================================================================================
-- Migración 20261101120000 · fase 3: seguridad de roles y permisos
-- Se aplica sobre el esquema de la rama fase2-recuperar-contrasena (commit a5d5a87).
-- Equivale a los bloques «-- >>> fase3» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos: añade la columna restaurants.suspended_at (vacía), la tabla
-- private.audit_log, funciones, triggers, políticas y permisos. Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261101120000_fase3_seguridad_roles.down.sql
--
-- AVISO: después de aplicarla, las cuentas de plataforma (platform_admins) dejan de tener acceso
-- operativo a los restaurantes (pedidos, cocina, carta). Para operar un restaurante hace falta
-- una cuenta de personal (owner, manager, waiter o kitchen) de ese restaurante.
-- =====================================================================================

begin;

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

-- Rol del usuario actual en un restaurante, solo según restaurant_staff.
-- La cuenta de plataforma NO tiene rol operativo en ningún restaurante (modo soporte: fase posterior).
create or replace function private.staff_role_for(rid uuid) returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select s.role from public.restaurant_staff s where s.restaurant_id = rid and s.user_id = (select auth.uid())
$$;

-- Quién puede leer la tabla de pedidos: owner, manager y sala de ese restaurante.
-- Cocina NO lee la tabla (vería teléfonos e importes): usa kitchen_orders(). pstatus se conserva
-- en la firma por compatibilidad con la política orders_select.
create or replace function private.can_view_order(rid uuid, pstatus public.payment_status) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.staff_role_for(rid) in ('owner', 'manager', 'waiter'), false) and pstatus is not null
$$;

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

create or replace function public.my_memberships() returns table (restaurant_id uuid, role public.staff_role)
language sql stable security definer set search_path = '' as $$
  -- Solo los restaurantes donde el usuario es personal. La cuenta de plataforma no aparece como
  -- owner de ninguno: sus funciones de plataforma se comprueban aparte (platform_admins).
  select s.restaurant_id, s.role from public.restaurant_staff s
  where s.user_id = (select auth.uid())
$$;

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

-- El equipo solo se modifica con las funciones staff_* (que aplican las reglas y auditan).
revoke insert, update, delete on public.restaurant_staff from authenticated;
-- El registro de auditoría no es accesible por la API para nadie (se lee con audit_list).
revoke all on private.audit_log from public, anon, authenticated, service_role;

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

commit;
