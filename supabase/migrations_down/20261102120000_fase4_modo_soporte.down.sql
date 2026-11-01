-- =====================================================================================
-- DESHACER la migración 20261102120000 · fase 4 (vuelve al esquema de la fase 3, commit 07348e4)
--
-- ATENCIÓN, PÉRDIDA DE DATOS: borra el historial de solicitudes y accesos de soporte
-- (private.support_grants). Las entradas del registro de auditoría (private.audit_log) se conservan.
-- No toca pedidos, carta, restaurantes ni personal.
-- =====================================================================================

begin;

drop trigger if exists support_grants_audit on private.support_grants;
drop trigger if exists support_grants_guard on private.support_grants;
drop trigger if exists support_grants_no_truncate on private.support_grants;
drop function if exists public.support_request(uuid, text);
drop function if exists public.support_decide(uuid, boolean);
drop function if exists public.support_revoke(uuid);
drop function if exists public.support_cancel(uuid);
drop function if exists public.support_list_for_restaurant(uuid);
drop function if exists public.support_my_requests();
drop function if exists public.support_view_restaurant(uuid);
drop function if exists public.support_view_orders(uuid, int);
drop function if exists public.support_view_payment_events(uuid, int);
drop function if exists private.support_require(uuid, text, jsonb);
drop function if exists private.support_active_grant(uuid);
drop function if exists private.support_status(text, timestamptz);
drop table if exists private.support_grants;
drop function if exists private.guard_support_grants();
drop function if exists private.audit_support_changes();

commit;
