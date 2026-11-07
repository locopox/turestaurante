-- =====================================================================================
-- Migración 20261108120000 · límites de pedidos sin pagar (capa A contra pedidos anónimos masivos).
-- Se aplica DESPUÉS de las migraciones de la fase 6 (rama fase6-invitaciones, ad26da1).
-- Equivale a los bloques «-- >>> fase7» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos: no toca restaurantes, carta, pedidos (ni sus estados, importes o
-- fechas), personal, cuentas, invitaciones, accesos de soporte ni el registro de auditoría.
-- Añade private.order_limits, private.order_limit_hits, un índice y sus funciones.
-- CAMBIOS DE COMPORTAMIENTO:
--  * create_order y customer_switch_to_counter rechazan el pedido (o el cambio a caja) si el restaurante
--    supera sus límites de pedidos SIN PAGAR creados en los últimos 30 minutos (por defecto: 8 por mesa,
--    15 para recoger, 40 en todo el restaurante, 30 online pendientes). El rechazo NO es un error de
--    PostgreSQL: es una respuesta { rejected: true, code: 'TR429', reason, message } sin «id», y por la
--    API llega con el estado HTTP 429 (la app la recibe como error con ese mensaje).
--  * customer_switch_to_counter bloquea ahora el restaurante antes que el pedido (mismo orden que create_order).
--  * Nada se cancela ni se borra automáticamente: los pedidos antiguos solo dejan de contar.
-- Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261108120000_limites_pedidos.down.sql
-- =====================================================================================

begin;

-- >>> fase7
-- Límites de pedidos SIN PAGAR de cada restaurante (protección contra pedidos anónimos masivos).
-- Sin fila = valores por defecto: 8 por mesa, 15 para recoger, 40 en todo el restaurante, 30 online
-- pendientes de pago y una ventana de 30 minutos. Privada: solo la plataforma los cambia, con
-- platform_set_order_limits. Los límites solo CUENTAN pedidos: nunca cancelan ni borran ninguno.
create table if not exists private.order_limits (
  restaurant_id uuid primary key references public.restaurants on delete cascade,
  per_table int not null default 8 check (per_table between 1 and 500),
  pickup int not null default 15 check (pickup between 1 and 500),
  per_restaurant int not null default 40 check (per_restaurant between 1 and 1000),
  online_pending int not null default 30 check (online_pending between 1 and 1000),
  window_minutes int not null default 30 check (window_minutes between 1 and 240),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- Intentos frenados por los límites, agrupados por restaurante, límite, mesa (0 si no es de mesa) y
-- tramo de 10 minutos: los intentos repetidos suman 1 al contador, así el registro no crece sin
-- control. Privada: owner y manager de su restaurante (y la plataforma) la leen con order_limit_hits_list.
create table if not exists private.order_limit_hits (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants on delete cascade,
  window_start timestamptz not null,
  limit_kind text not null check (limit_kind in ('mesa', 'recoger', 'restaurante', 'online')),
  table_number int not null default 0 check (table_number between 0 and 500),
  attempts int not null default 1 check (attempts >= 1),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  constraint order_limit_hits_key unique (restaurant_id, window_start, limit_kind, table_number)
);
create index if not exists order_limit_hits_restaurant_idx on private.order_limit_hits (restaurant_id, last_at desc);

-- Para contar rápido los pedidos sin pagar y sin terminar de un restaurante.
create index if not exists orders_unpaid_open_idx on public.orders (restaurant_id, created_at)
  where payment_status in ('pendiente_caja', 'pendiente_online', 'fallido')
    and prep_status in ('nuevo', 'en_preparacion', 'listo');
-- <<< fase7

-- >>> fase7
-- ---------- Límites de pedidos sin pagar (capa A contra pedidos anónimos masivos) ----------
-- Límites en vigor de un restaurante: los que fijó la plataforma o, si no hay, los de por defecto.
create or replace function private.order_limits_effective(p_restaurant_id uuid) returns private.order_limits
language plpgsql stable security definer set search_path = '' as $$
declare
  l private.order_limits;
begin
  select * into l from private.order_limits where restaurant_id = p_restaurant_id;
  if not found then
    l.restaurant_id := p_restaurant_id;
    l.per_table := 8;
    l.pickup := 15;
    l.per_restaurant := 40;
    l.online_pending := 30;
    l.window_minutes := 30;
  end if;
  return l;
end $$;

create or replace function private.order_limits_json(l private.order_limits, p_is_default boolean) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('restaurantId', l.restaurant_id, 'perTable', l.per_table, 'pickup', l.pickup,
    'perRestaurant', l.per_restaurant, 'onlinePending', l.online_pending, 'windowMinutes', l.window_minutes,
    'isDefault', p_is_default, 'updatedAt', l.updated_at)
$$;

-- ¿Supera un pedido nuevo (o un cambio a caja) algún límite? Devuelve el límite superado
-- ('mesa', 'recoger', 'restaurante' u 'online') o null. Cuenta los pedidos SIN PAGAR y SIN TERMINAR
-- creados dentro de la ventana:
--   caja:   pago pendiente_caja (por mesa, para recoger y en todo el restaurante)
--   online: pago pendiente_online o fallido
--   y en los dos casos, preparación nuevo, en_preparacion o listo. Marcar un pedido «en preparación» o
--   «listo» NO libera hueco (el personal no puede saber si es falso); lo liberan pagarlo, entregarlo,
--   cancelarlo o que pase la ventana. La fecha de creación no se puede cambiar (guard_order_update).
-- Solo cuenta: no cambia ningún pedido. Quien la llama debe tener bloqueado el restaurante
-- (select … for update) para que el recuento sea exacto con peticiones simultáneas.
create or replace function private.order_limit_exceeded(p_restaurant_id uuid, p_mode public.order_mode,
  p_method public.payment_method, p_table int) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  l private.order_limits := private.order_limits_effective(p_restaurant_id);
  v_since timestamptz := now() - make_interval(mins => l.window_minutes);
  n_table int;
  n_pickup int;
  n_all int;
begin
  if p_method = 'online' then
    select count(*) into n_all from public.orders o
    where o.restaurant_id = p_restaurant_id and o.created_at > v_since
      and o.payment_status in ('pendiente_online', 'fallido')
      and o.prep_status in ('nuevo', 'en_preparacion', 'listo');
    return case when n_all >= l.online_pending then 'online' end;
  end if;
  select count(*) filter (where o.mode = 'mesa' and o.table_number = p_table),
         count(*) filter (where o.mode = 'recoger'),
         count(*)
    into n_table, n_pickup, n_all
  from public.orders o
  where o.restaurant_id = p_restaurant_id and o.created_at > v_since
    and o.payment_status = 'pendiente_caja'
    and o.prep_status in ('nuevo', 'en_preparacion', 'listo');
  if p_mode = 'mesa' and n_table >= l.per_table then
    return 'mesa';
  end if;
  if p_mode = 'recoger' and n_pickup >= l.pickup then
    return 'recoger';
  end if;
  if n_all >= l.per_restaurant then
    return 'restaurante';
  end if;
  return null;
end $$;

-- Anota un intento frenado y devuelve la respuesta de rechazo. Los intentos del mismo restaurante,
-- límite y mesa en el mismo tramo de 10 minutos suman 1 al contador.
-- La respuesta NO es un pedido: no tiene «id» y lleva rejected = true. Por la API llega con el estado
-- HTTP 429 (response.status), así que la app la recibe como un ERROR con este mensaje y nunca como un
-- pedido creado. No se lanza una excepción a propósito: deshacería también la anotación.
create or replace function private.order_limit_reject(p_restaurant_id uuid, p_kind text, p_table int) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into private.order_limit_hits (restaurant_id, window_start, limit_kind, table_number)
  values (p_restaurant_id, date_bin('10 minutes', now(), timestamptz '2000-01-01 00:00:00+00'), p_kind,
    case when p_kind = 'mesa' then coalesce(p_table, 0) else 0 end)
  on conflict on constraint order_limit_hits_key
  do update set attempts = private.order_limit_hits.attempts + 1, last_at = now();
  perform set_config('response.status', '429', true);
  return jsonb_build_object('rejected', true, 'code', 'TR429', 'reason', p_kind,
    'message', case p_kind
      when 'mesa' then 'Hay muchos pedidos pendientes en esta mesa. Avisa al personal.'
      when 'recoger' then 'Hay muchos pedidos para recoger pendientes. Avisa al personal o inténtalo en unos minutos.'
      when 'online' then 'Hay muchos pedidos pendientes de pago online. Inténtalo en unos minutos o avisa al personal.'
      else 'El restaurante tiene muchos pedidos pendientes ahora mismo. Avisa al personal o inténtalo en unos minutos.'
    end,
    'details', null, 'hint', null);
end $$;
-- <<< fase7

-- >>> fase7 (create_order: límites de pedidos sin pagar)
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
  v_limit text; -- fase7
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

  -- >>> fase7
  -- Límites de pedidos sin pagar. Van DESPUÉS de reconocer los reintentos (un reintento con el mismo
  -- código devuelve el pedido ya creado y nunca se frena) y con el restaurante ya bloqueado (recuento
  -- exacto). Si se supera uno, responde con un rechazo (sin «id»; HTTP 429 por la API) y no crea nada.
  v_limit := private.order_limit_exceeded(r.id, v_mode, v_method, v_table);
  if v_limit is not null then
    return private.order_limit_reject(r.id, v_limit, v_table);
  end if;
  -- <<< fase7

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
-- <<< fase7

-- >>> fase7 (customer_switch_to_counter: bloqueo del restaurante y límites de caja)
create or replace function public.customer_switch_to_counter(p_order_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_switch_window constant interval := interval '2 hours';
  o public.orders;
  r public.restaurants;
  v_rid uuid;   -- fase7
  v_limit text; -- fase7
begin
  -- >>> fase7
  -- Primero se bloquea el restaurante y después el pedido (el mismo orden que create_order): así el
  -- recuento de los límites es exacto aunque lleguen pedidos nuevos y cambios a caja a la vez.
  select o2.restaurant_id into v_rid from public.orders o2
  join private.order_access a on a.order_id = o2.id
  where o2.id = p_order_id and a.token_hash = private.token_hash(p_token);
  if not found then
    raise exception 'Pedido no encontrado' using errcode = '22023';
  end if;
  select * into r from public.restaurants where id = v_rid for update;
  select o2.* into o from public.orders o2 where o2.id = p_order_id for update;
  -- <<< fase7
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
  -- >>> fase7
  -- Al pasar a caja el pedido llega a cocina: se aplican los mismos límites de caja que a un pedido
  -- nuevo. Si se supera uno, el pedido NO cambia (sigue siendo online pendiente).
  v_limit := private.order_limit_exceeded(r.id, o.mode, 'caja', o.table_number);
  if v_limit is not null then
    return private.order_limit_reject(r.id, v_limit, o.table_number);
  end if;
  -- <<< fase7
  update public.orders set payment_method = 'caja', payment_status = 'pendiente_caja' where id = o.id;
  return private.customer_order_json(o.id);
end $$;
-- <<< fase7

-- >>> fase7
-- ---------- Límites de pedidos: plataforma y consulta de intentos frenados ----------
-- Límites en vigor de un restaurante. Solo la plataforma.
create or replace function public.platform_get_order_limits(p_restaurant_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede consultar los límites de pedidos' using errcode = '42501';
  end if;
  if not exists (select 1 from public.restaurants where id = p_restaurant_id) then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  return private.order_limits_json(private.order_limits_effective(p_restaurant_id),
    not exists (select 1 from private.order_limits where restaurant_id = p_restaurant_id));
end $$;

-- Cambia los límites de un restaurante. Solo la plataforma; queda en el registro de auditoría.
create or replace function public.platform_set_order_limits(p_restaurant_id uuid, p_per_table int, p_pickup int,
  p_per_restaurant int, p_online_pending int, p_window_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_before jsonb;
  l private.order_limits;
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede cambiar los límites de pedidos' using errcode = '42501';
  end if;
  -- Bloquea el restaurante: el cambio no se cruza con un recuento a medias.
  perform 1 from public.restaurants where id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  if p_per_table is null or p_per_table not between 1 and 500 then
    raise exception 'El límite por mesa debe estar entre 1 y 500' using errcode = '22023';
  end if;
  if p_pickup is null or p_pickup not between 1 and 500 then
    raise exception 'El límite para recoger debe estar entre 1 y 500' using errcode = '22023';
  end if;
  if p_per_restaurant is null or p_per_restaurant not between 1 and 1000 then
    raise exception 'El límite del restaurante debe estar entre 1 y 1000' using errcode = '22023';
  end if;
  if p_online_pending is null or p_online_pending not between 1 and 1000 then
    raise exception 'El límite de pedidos online pendientes debe estar entre 1 y 1000' using errcode = '22023';
  end if;
  if p_window_minutes is null or p_window_minutes not between 1 and 240 then
    raise exception 'La ventana debe estar entre 1 y 240 minutos' using errcode = '22023';
  end if;
  v_before := private.order_limits_json(private.order_limits_effective(p_restaurant_id),
    not exists (select 1 from private.order_limits where restaurant_id = p_restaurant_id));
  insert into private.order_limits (restaurant_id, per_table, pickup, per_restaurant, online_pending, window_minutes,
    updated_at, updated_by)
  values (p_restaurant_id, p_per_table, p_pickup, p_per_restaurant, p_online_pending, p_window_minutes, now(), (select auth.uid()))
  on conflict (restaurant_id) do update set per_table = excluded.per_table, pickup = excluded.pickup,
    per_restaurant = excluded.per_restaurant, online_pending = excluded.online_pending,
    window_minutes = excluded.window_minutes, updated_at = excluded.updated_at, updated_by = excluded.updated_by
  returning * into l;
  perform private.audit_insert(p_restaurant_id, 'plataforma.limites_pedidos', 'order_limits', p_restaurant_id::text,
    jsonb_build_object('antes', v_before - 'restaurantId' - 'updatedAt',
      'despues', private.order_limits_json(l, false) - 'restaurantId' - 'updatedAt'));
  return private.order_limits_json(l, false);
end $$;

-- Intentos frenados por los límites en un restaurante (los más recientes primero). Los pueden ver el
-- owner y el manager de ESE restaurante, y la plataforma (su consulta queda en el registro de
-- auditoría). Solo lectura: no permite cambiar límites ni intentos.
create or replace function public.order_limit_hits_list(p_restaurant_id uuid, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_platform boolean := private.is_platform_admin();
begin
  if (select auth.uid()) is null
     or not (v_platform or private.has_role(p_restaurant_id, array['owner', 'manager']::public.staff_role[])) then
    raise exception 'No tienes acceso a los intentos bloqueados de este restaurante' using errcode = '42501';
  end if;
  if v_platform then
    perform private.audit_insert(p_restaurant_id, 'plataforma.consulta_limites_pedidos', 'order_limit_hits', null, '{}'::jsonb);
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('windowStart', h.window_start, 'limit', h.limit_kind,
      'table', nullif(h.table_number, 0), 'attempts', h.attempts, 'firstAt', h.first_at, 'lastAt', h.last_at)
      order by h.last_at desc, h.id desc)
    from (select * from private.order_limit_hits x where x.restaurant_id = p_restaurant_id
          order by x.last_at desc, x.id desc limit greatest(1, least(coalesce(p_limit, 100), 500))) h
  ), '[]'::jsonb);
end $$;
-- <<< fase7

-- >>> fase7
-- Funciones internas de los límites: nadie de la API puede ejecutarlas (así nadie puede anotar
-- intentos falsos ni leer recuentos).
revoke all on function private.order_limits_effective(uuid), private.order_limits_json(private.order_limits, boolean),
  private.order_limit_exceeded(uuid, public.order_mode, public.payment_method, int),
  private.order_limit_reject(uuid, text, int) from public, anon, authenticated, service_role;
revoke all on function public.platform_get_order_limits(uuid),
  public.platform_set_order_limits(uuid, int, int, int, int, int), public.order_limit_hits_list(uuid, int)
  from public, anon, authenticated, service_role;
-- Cada función comprueba dentro quién llama: plataforma (límites) u owner/manager del restaurante
-- (intentos frenados).
grant execute on function public.platform_get_order_limits(uuid),
  public.platform_set_order_limits(uuid, int, int, int, int, int), public.order_limit_hits_list(uuid, int)
  to authenticated;
-- <<< fase7

-- >>> fase7
-- Límites e intentos frenados: nadie los lee ni escribe por la API (solo con sus funciones).
revoke all on private.order_limits, private.order_limit_hits from public, anon, authenticated, service_role;
alter table private.order_limits enable row level security;
alter table private.order_limit_hits enable row level security;
-- <<< fase7

commit;
