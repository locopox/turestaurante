-- =====================================================================================
-- Migración 20261113120000 · protección comercial de los pedidos (fase 9, etapa 2 comercial).
-- Se aplica DESPUÉS de 20261112120000_base_comercial.sql (rama fase7-base-comercial, 048a661).
-- Equivale a los bloques «-- >>> fase9» de supabase/schema.sql (generada a partir de ellos).
--
-- NO borra ni modifica datos y NO cambia create_order ni ninguna otra función de pedidos.
-- Añade:
--  * El trigger orders_commercial_guard (ANTES de insertar un pedido): solo se aceptan pedidos NUEVOS de
--    restaurantes «sin_asignar» (los que ya existían), «activa» o «prueba» antes de su fin. «borrador»,
--    «vencida» o sin cuenta comercial: «El restaurante no acepta pedidos en este momento».
--  * platform_set_commercial_status: la plataforma asigna «activa», «vencida» o «prueba» (desde borrador),
--    o amplía una prueba, siempre con motivo y auditado.
--  * «acceptsOrders» en restaurant_commercial_status y el motivo en la auditoría de la cuenta comercial.
-- CAMBIO DE COMPORTAMIENTO: los restaurantes en «borrador» (todos los creados después de la base comercial)
-- dejan de recibir pedidos hasta que la plataforma les asigne una modalidad. Antes de aplicarla, revisa
-- cuáles hay: select * from private.tenant_accounts where status = 'borrador';
-- Se puede ejecutar más de una vez.
-- Para deshacerla: supabase/migrations_down/20261113120000_proteccion_comercial_pedidos.down.sql
-- =====================================================================================

begin;

-- >>> fase9
-- ---------- Protección comercial de los pedidos ----------
-- ¿Permite este estado comercial pedidos NUEVOS en el instante p_at?
--   sin_asignar (restaurantes que ya existían) y activa: sí · prueba: solo ANTES de su fin · borrador y vencida: no.
-- «activa» no caduca sola mientras no haya integración de pagos: la plataforma la cambia a mano.
create or replace function private.commercial_allows_orders(p_status text, p_trial_ends_at timestamptz, p_at timestamptz)
returns boolean language sql immutable set search_path = '' as $$
  select case p_status
    when 'sin_asignar' then true
    when 'activa' then true
    when 'prueba' then p_trial_ends_at is not null and p_at is not null and p_at < p_trial_ends_at
    else false
  end
$$;

-- ¿Puede el restaurante recibir un pedido NUEVO ahora mismo? Sin cuenta comercial: no.
-- Bloquea la cuenta en modo compartido: si alguien está cambiando el estado comercial, espera a que
-- termine y decide con el estado ya confirmado. La hora es clock_timestamp() (la hora real DESPUÉS
-- de esperar), no la del inicio de la transacción: una prueba que termina mientras el pedido espera
-- ya no lo autoriza.
create or replace function private.tenant_order_authorized(p_restaurant_id uuid) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_status text;
  v_trial_ends_at timestamptz;
begin
  select a.status, a.trial_ends_at into v_status, v_trial_ends_at
  from private.tenant_accounts a where a.restaurant_id = p_restaurant_id
  for share;
  if not found then
    return false;
  end if;
  return private.commercial_allows_orders(v_status, v_trial_ends_at, clock_timestamp());
end $$;

-- Trigger ANTES de insertar un pedido: se aplica a TODOS (create_order, el SQL Editor, el servidor y
-- cualquier función futura), así que no se puede saltar desde el navegador ni desde la API. No cambia
-- create_order: un reintento con el mismo código devuelve el pedido ya creado antes de llegar aquí, y
-- los pedidos que ya existen (cocina, cobro, cancelación, pasar a caja) no insertan pedidos.
-- Orden de bloqueo: create_order bloquea el restaurante y después, aquí, la cuenta comercial; quien
-- cambia el estado comercial bloquea en el mismo orden (platform_set_commercial_status).
-- El mensaje es el mismo que el de un restaurante cerrado: no revela nada de su suscripción.
create or replace function private.guard_order_commercial() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.tenant_order_authorized(new.restaurant_id) then
    raise exception 'El restaurante no acepta pedidos en este momento' using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists orders_commercial_guard on public.orders;
create trigger orders_commercial_guard before insert on public.orders
  for each row execute function private.guard_order_commercial();

-- La consulta del estado comercial dice también si ahora mismo acepta pedidos (sin explicar el porqué).
create or replace function private.commercial_json(a private.tenant_accounts) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('restaurantId', a.restaurant_id, 'status', a.status, 'plan', a.plan_code,
    'planName', (select p.name from private.commercial_plans p where p.code = a.plan_code),
    'trialStartedAt', a.trial_started_at, 'trialEndsAt', a.trial_ends_at,
    -- Calculado con la hora de la base de datos: la app no usa el reloj del navegador.
    'trialSecondsLeft', case when a.status = 'prueba' then greatest(0, floor(extract(epoch from a.trial_ends_at - now())))::bigint end,
    'acceptsOrders', private.commercial_allows_orders(a.status, a.trial_ends_at, clock_timestamp()),
    'serverNow', now())
$$;

-- Auditoría de la cuenta comercial: incluye el motivo que indica la plataforma (si lo hay).
create or replace function private.audit_tenant_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_motivo text := nullif(current_setting('turestaurante.motivo', true), '');
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'comercial.alta', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('estado', new.status, 'origen', new.origin));
  elsif (new.status, new.plan_code, new.trial_started_at, new.trial_ends_at)
        is distinct from (old.status, old.plan_code, old.trial_started_at, old.trial_ends_at) then
    perform private.audit_insert(new.restaurant_id, 'comercial.cambio', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('antes', jsonb_build_object('estado', old.status, 'plan', old.plan_code, 'fin_prueba', old.trial_ends_at),
        'despues', jsonb_build_object('estado', new.status, 'plan', new.plan_code, 'fin_prueba', new.trial_ends_at))
      || case when v_motivo is null then '{}'::jsonb else jsonb_build_object('motivo', v_motivo) end);
  end if;
  return null;
end $$;

-- Plataforma: cambia la modalidad comercial de un restaurante o amplía su prueba. Siempre con motivo;
-- queda en el registro de auditoría. Además de las reglas de la cuenta comercial (guard_tenant_accounts):
--   * modalidades: «activa» (sin caducidad automática hasta integrar los pagos), «vencida» y «prueba»
--     (solo desde «borrador»: empieza ahora, 14 días, plan Profesional). Nunca «sin_asignar» ni «borrador».
--   * ampliar la prueba (p_extend_days): solo una prueba en curso, de 1 a 30 días cada vez y como mucho
--     60 días en total desde su inicio.
-- Orden de bloqueo: restaurante y después cuenta comercial, el mismo que create_order (sin interbloqueos).
create or replace function public.platform_set_commercial_status(p_restaurant_id uuid, p_status text, p_reason text,
  p_extend_days int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  a private.tenant_accounts;
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then
    raise exception 'Solo la plataforma puede cambiar la modalidad comercial' using errcode = '42501';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 200 then
    raise exception 'Indica el motivo del cambio (de 3 a 200 caracteres)' using errcode = '22023';
  end if;
  perform 1 from public.restaurants r where r.id = p_restaurant_id for update;
  if not found then
    raise exception 'Restaurante no encontrado' using errcode = '22023';
  end if;
  select * into a from private.tenant_accounts t where t.restaurant_id = p_restaurant_id for update;
  if not found then
    raise exception 'El restaurante no tiene cuenta comercial' using errcode = '22023';
  end if;
  -- El trigger de auditoría lee el motivo de esta variable de la transacción.
  perform set_config('turestaurante.motivo', v_reason, true);

  if p_extend_days is not null then
    if p_status is not null and p_status <> 'prueba' then
      raise exception 'Para ampliar la prueba no se puede cambiar a la vez la modalidad' using errcode = '22023';
    end if;
    if a.status <> 'prueba' then
      raise exception 'Solo se puede ampliar una prueba en curso' using errcode = '22023';
    end if;
    if p_extend_days not between 1 and 30 then
      raise exception 'La ampliación debe ser de 1 a 30 días' using errcode = '22023';
    end if;
    if a.trial_ends_at + make_interval(days => p_extend_days) > a.trial_started_at + interval '60 days' then
      raise exception 'Una prueba no puede durar más de 60 días en total' using errcode = '22023';
    end if;
    update private.tenant_accounts t set trial_ends_at = t.trial_ends_at + make_interval(days => p_extend_days)
    where t.restaurant_id = p_restaurant_id returning * into a;
    return private.commercial_json(a);
  end if;

  if p_status in ('sin_asignar', 'borrador') then
    raise exception 'No se puede asignar «%»: solo «activa», «vencida» o «prueba»', p_status using errcode = '22023';
  end if;
  if p_status is null or p_status not in ('activa', 'vencida', 'prueba') then
    raise exception 'Modalidad no válida: «activa», «vencida» o «prueba»' using errcode = '22023';
  end if;
  if p_status = a.status then
    raise exception 'El restaurante ya tiene esa modalidad' using errcode = '22023';
  end if;
  if p_status = 'prueba' then
    -- guard_tenant_accounts exige: desde «borrador», ahora mismo y por 14 días exactos.
    update private.tenant_accounts t set status = 'prueba', plan_code = 'profesional',
      trial_started_at = now(), trial_ends_at = now() + interval '14 days'
    where t.restaurant_id = p_restaurant_id returning * into a;
  else
    update private.tenant_accounts t set status = p_status where t.restaurant_id = p_restaurant_id returning * into a;
  end if;
  return private.commercial_json(a);
end $$;
-- <<< fase9

-- >>> fase9
-- Funciones internas de la protección comercial: nadie de la API puede ejecutarlas.
revoke all on function private.commercial_allows_orders(text, timestamptz, timestamptz),
  private.tenant_order_authorized(uuid), private.guard_order_commercial() from public, anon, authenticated, service_role;
revoke all on function public.platform_set_commercial_status(uuid, text, text, int) from public, anon, authenticated, service_role;
-- La función comprueba dentro que quien llama es de la plataforma.
grant execute on function public.platform_set_commercial_status(uuid, text, text, int) to authenticated;
-- <<< fase9

commit;
