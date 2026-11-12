-- =====================================================================================
-- DESHACER la migración 20261112120000 · base comercial (vuelve al esquema de 886a37c).
--
-- ATENCIÓN, PÉRDIDA DE DATOS: borra las cuentas comerciales (estado, plan y fechas de prueba de cada
-- restaurante) y el catálogo de planes. NO toca restaurantes, carta, pedidos, personal, cuentas,
-- invitaciones, límites de pedidos ni el registro de auditoría (las entradas «comercial.*» se conservan).
-- =====================================================================================

begin;

drop trigger if exists restaurants_tenant_account on public.restaurants;
drop function if exists public.restaurant_commercial_status(uuid);
drop function if exists public.platform_list_commercial_accounts(text, int);
drop function if exists private.commercial_json(private.tenant_accounts);  -- usa el tipo de la tabla: antes que ella
drop table if exists private.tenant_accounts;   -- con sus triggers
drop function if exists private.guard_tenant_accounts();
drop function if exists private.create_tenant_account();
drop function if exists private.audit_tenant_accounts();
drop table if exists private.commercial_plans;

commit;
