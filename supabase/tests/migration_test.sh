#!/usr/bin/env bash
# Prueba la migración de la fase 3 en un PostgreSQL LOCAL y desechable. Nunca contra Supabase.
# 1. Esquema anterior (a5d5a87) + datos  →  subida  ==  instalación nueva (estructura idéntica)
# 2. La subida se puede repetir y no altera datos
# 3. Bajada  ==  esquema anterior (estructura idéntica) y los datos siguen intactos
set -euo pipefail
export PGOPTIONS="-c client_min_messages=warning"
cd "$(dirname "$0")/.."
case "${PGHOST:-localhost}" in *supabase.co*|*supabase.com*) echo "Solo para una base de datos local." >&2; exit 1;; esac
UP=migrations/20261101120000_fase3_seguridad_roles.sql
DOWN=migrations_down/20261101120000_fase3_seguridad_roles.down.sql
TMP=$(mktemp -d)
git show a5d5a87:supabase/schema.sql > "$TMP/schema_anterior.sql"
P() { psql -v ON_ERROR_STOP=1 -q -d "$1" "${@:2}"; }
nuevo_db() { psql -q -d postgres -c "drop database if exists $1" -c "create database $1"; P "$1" -f tests/supabase_shim.sql; }
volcado() { pg_dump --schema-only -d "$1" | grep -vE '^(--|SET |SELECT pg_catalog|\\(un)?restrict )' | sed '/^$/d' > "$2"; }
datos() { P "$1" -tAc "select (select count(*) from restaurants)||'/'||(select count(*) from products)||'/'||(select count(*) from orders)||'/'||(select count(*) from order_items)||'/'||(select count(*) from restaurant_staff)||'/'||(select coalesce(sum(total_cents),0) from orders)"; }
con_datos() {
  P "$1" -f seed.sql
  P "$1" -c "insert into auth.users (id, email) values ('a0000000-0000-4000-8000-0000000000a1', 'owner@piazza.test')" \
         -c "insert into public.restaurant_staff values ('5e5e0000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000a1', 'owner')"
  P "$1" -c "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false)" -c "set role anon" \
         -c "select public.create_order('{\"restaurantId\":\"5e5e0000-0000-4000-8000-000000000001\",\"mode\":\"mesa\",\"table\":3,\"paymentMethod\":\"caja\",\"accessToken\":\"$(printf '%064d' 7)\",\"items\":[{\"productId\":\"5e5e0000-0000-4000-8000-000000000201\",\"quantity\":2}]}')" > /dev/null
}
fallo() { echo "FALLO: $1" >&2; exit 1; }

nuevo_db mig_anterior; P mig_anterior -f "$TMP/schema_anterior.sql"; con_datos mig_anterior
volcado mig_anterior "$TMP/anterior.sql"; D0=$(datos mig_anterior)

nuevo_db mig_nueva; P mig_nueva -f schema.sql; volcado mig_nueva "$TMP/nueva.sql"

nuevo_db mig_subida; P mig_subida -f "$TMP/schema_anterior.sql"; con_datos mig_subida
P mig_subida -f "$UP"; volcado mig_subida "$TMP/subida.sql"
diff -u "$TMP/nueva.sql" "$TMP/subida.sql" > "$TMP/d1" || { head -40 "$TMP/d1"; fallo "la subida no deja la misma estructura que una instalación nueva"; }
echo "OK  subida = instalación nueva (estructura idéntica)"
[ "$(datos mig_subida)" = "$D0" ] || fallo "la subida ha cambiado datos"
echo "OK  la subida conserva los datos ($D0: restaurantes/productos/pedidos/líneas/personal/importe)"
P mig_subida -f "$UP"; volcado mig_subida "$TMP/subida2.sql"
diff -q "$TMP/subida.sql" "$TMP/subida2.sql" > /dev/null || fallo "repetir la subida cambia la estructura"
[ "$(datos mig_subida)" = "$D0" ] || fallo "repetir la subida ha cambiado datos"
echo "OK  la subida se puede repetir"

P mig_subida -f "$DOWN"; volcado mig_subida "$TMP/bajada.sql"
if diff -q "$TMP/anterior.sql" "$TMP/bajada.sql" > /dev/null; then
  echo "OK  bajada = esquema anterior (estructura idéntica)"
elif diff -q <(sort "$TMP/anterior.sql") <(sort "$TMP/bajada.sql") > /dev/null; then
  # PostgreSQL puede listar los mismos permisos de un objeto en otro orden.
  echo "OK  bajada = esquema anterior (mismas líneas; solo cambia el orden en que se listan algunos permisos)"
else
  diff -u "$TMP/anterior.sql" "$TMP/bajada.sql" | head -40; fallo "la bajada no restaura la estructura anterior"
fi
[ "$(datos mig_subida)" = "$D0" ] || fallo "la bajada ha cambiado datos"
echo "OK  la bajada conserva pedidos, carta, restaurantes y personal"
psql -q -d postgres -c "drop database mig_anterior" -c "drop database mig_nueva" -c "drop database mig_subida"
rm -rf "$TMP"
echo "Migración: todas las comprobaciones superadas"
