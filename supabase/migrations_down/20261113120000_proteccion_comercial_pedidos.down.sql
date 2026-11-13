-- =====================================================================================
-- DESHACER la migración 20261113120000 · protección comercial de los pedidos (vuelve a 048a661).
--
-- NO borra datos: las cuentas comerciales, los pedidos y el registro de auditoría se conservan.
-- Tras deshacerla, el estado comercial vuelve a NO bloquear pedidos y la plataforma ya no puede
-- cambiar modalidades con platform_set_commercial_status.
-- =====================================================================================

begin;

drop trigger if exists orders_commercial_guard on public.orders;
drop function if exists public.platform_set_commercial_status(uuid, text, text, int);

-- Versiones de la base comercial (048a661) de las funciones que esta migración reemplazó.
create or replace function private.commercial_json(a private.tenant_accounts) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('restaurantId', a.restaurant_id, 'status', a.status, 'plan', a.plan_code,
    'planName', (select p.name from private.commercial_plans p where p.code = a.plan_code),
    'trialStartedAt', a.trial_started_at, 'trialEndsAt', a.trial_ends_at,
    -- Calculado con la hora de la base de datos: la app no usa el reloj del navegador.
    'trialSecondsLeft', case when a.status = 'prueba' then greatest(0, floor(extract(epoch from a.trial_ends_at - now())))::bigint end,
    'serverNow', now())
$$;

create or replace function private.audit_tenant_accounts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.audit_insert(new.restaurant_id, 'comercial.alta', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('estado', new.status, 'origen', new.origin));
  elsif (new.status, new.plan_code, new.trial_started_at, new.trial_ends_at)
        is distinct from (old.status, old.plan_code, old.trial_started_at, old.trial_ends_at) then
    perform private.audit_insert(new.restaurant_id, 'comercial.cambio', 'tenant_accounts', new.restaurant_id::text,
      jsonb_build_object('antes', jsonb_build_object('estado', old.status, 'plan', old.plan_code, 'fin_prueba', old.trial_ends_at),
        'despues', jsonb_build_object('estado', new.status, 'plan', new.plan_code, 'fin_prueba', new.trial_ends_at)));
  end if;
  return null;
end $$;

drop function if exists private.guard_order_commercial();
drop function if exists private.tenant_order_authorized(uuid);
drop function if exists private.commercial_allows_orders(text, timestamptz, timestamptz);

commit;
