#!/usr/bin/env bash
# Prueba completa OPCIONAL de la recuperación programada (la lanza recovery_test.sh con RECOVERY_E2E=1).
# Uso interno: recovery_e2e.sh <base de datos local> <secreto que hay en Vault>
#
# 1. La tarea (private.invitations_recovery_tick) prepara la petición con el secreto de Vault.
# 2. Como no hay pg_net real, ESTE script reenvía esa petición (URL de prueba, cabeceras y cuerpo
#    tal cual) con curl a la Edge Function REAL «invitations-recovery», ejecutada con Deno.
# 3. La función habla con un servidor local que imita la API de Supabase: las funciones SQL
#    (invitation_delivery_*) se ejecutan de verdad en la base de datos local como service_role, y
#    /auth/v1/invite solo anota la llamada (no se envía ningún correo).
# No sustituye a una prueba con Supabase local: pg_net, Vault, el gateway y Auth reales no intervienen.
set -euo pipefail
DB=$1; SECRET=$2
: "${DENO:?Indica la ruta de deno en DENO}"
cd "$(dirname "$0")/.."
Q() { psql -v ON_ERROR_STOP=1 -q -X -tA -d "$DB" "$@"; }
ok() { echo "OK  [e2e] $1"; }
fallo() { echo "FALLO: [e2e] $1" >&2; [ -f "${TMP:-/x}/fn.log" ] && sed 's/^/    función: /' "$TMP/fn.log" >&2; exit 1; }
PIAZZA=5e5e0000-0000-4000-8000-000000000001
OWNER=a0000000-0000-4000-8000-0000000000a1
TMP=$(mktemp -d); PIDS=()
limpiar() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
nueva() {
  Q -c "insert into private.invitations (restaurant_id, email, role, invited_by, invited_by_kind, created_at, expires_at)
        select '$PIAZZA', '$1', 'waiter', '$OWNER', 'personal', t, t + interval '168 hours' from (select now() - interval '3 minutes' as t) x
        returning id" | head -1
}
estado() { Q -c "select send_status || '/' || send_attempts from private.invitations where id = '$1'"; }

# Servidor que imita la API de Supabase (solo lo que usa la función de recuperación).
cat > "$TMP/api.mjs" <<'EOF'
import http from 'node:http';
import { execFileSync } from 'node:child_process';
const [, , port, db, key] = process.argv;
const invites = [];
const sql = (query, vars) => {
  const args = ['-X', '-tA', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db];
  for (const [k, v] of Object.entries(vars)) args.push('-v', `${k}=${v}`);
  const script = `select set_config('request.jwt.claims', '{"role":"service_role"}', false);\nset role service_role;\n${query}\n`;
  return execFileSync('psql', args, { input: script, encoding: 'utf8' }).trim().split('\n').pop();
};
const RPC = {
  invitation_delivery_claim: (b) => sql(`select coalesce(json_agg(t), '[]') from public.invitation_delivery_claim(:'id'::uuid) t;`, { id: b.p_invitation_id }),
  invitation_delivery_finish: (b) => sql(`select to_json(public.invitation_delivery_finish(:'id'::uuid, :'claim'::uuid, :'result'));`,
    { id: b.p_invitation_id, claim: b.p_claim, result: b.p_result }),
  invitation_delivery_pending: (b) => sql(`select coalesce(json_agg(p), '[]') from public.invitation_delivery_pending(:'n'::int) p;`, { n: b.p_limit }),
};
http.createServer((req, res) => {
  let body = ''; req.on('data', (c) => (body += c)); req.on('end', () => {
    const send = (s, o) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(typeof o === 'string' ? o : JSON.stringify(o)); };
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/__invites') return send(200, invites);
    if (req.headers.apikey !== key || req.headers.authorization !== `Bearer ${key}`) return send(401, { message: 'clave no válida' });
    const fn = url.pathname.replace('/rest/v1/rpc/', '');
    try {
      if (RPC[fn]) return send(200, RPC[fn](JSON.parse(body || '{}')));
      if (url.pathname === '/auth/v1/invite') { invites.push({ ...JSON.parse(body), redirect_to: url.searchParams.get('redirect_to') }); return send(200, { id: 'x' }); }
    } catch (e) { return send(500, { message: String(e.message).slice(0, 200) }); }
    send(404, {});
  });
}).listen(Number(port), '127.0.0.1');
EOF
KEY="clave-de-servicio-de-prueba-$RANDOM"
node "$TMP/api.mjs" 54397 "$DB" "$KEY" & PIDS+=($!)
SUPABASE_URL=http://127.0.0.1:54397 SUPABASE_SERVICE_ROLE_KEY="$KEY" APP_URL=http://localhost:5173/ INVITATIONS_RECOVERY_SECRET="$SECRET" \
  "$DENO" run --allow-net --allow-env functions/invitations-recovery/index.ts > "$TMP/fn.log" 2>&1 & PIDS+=($!)
ARRIBA=0; for _ in $(seq 120); do curl -s -o /dev/null http://127.0.0.1:8000/ && { ARRIBA=1; break; }; sleep 0.5; done
[ "$ARRIBA" = 1 ] || fallo "la Edge Function no arrancó en 60 s"

A=$(nueva e2e-uno@x.test); B=$(nueva e2e-dos@x.test)
REQ=$(Q -c "select private.invitations_recovery_tick()")
[ -n "$REQ" ] || fallo "la tarea no preparó ninguna petición"
HDR=$(Q -c "select headers ->> 'x-turestaurante-recovery' from net.stub_requests where id = $REQ")
BODY=$(Q -c "select body::text from net.stub_requests where id = $REQ")

# Sin el secreto (o con otro): 401 y la cola no se toca
for H in "" "x-turestaurante-recovery: otro-secreto-de-mas-de-32-caracteres-xxxx"; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8000/ -H 'content-type: application/json' ${H:+-H "$H"} -d "$BODY")
  [ "$CODE" = 401 ] || fallo "petición sin el secreto correcto: $CODE (debía ser 401)"
done
[ "$(estado "$A")" = sin_enviar/0 ] || fallo "una petición no autorizada ha tocado la cola"
ok "sin el secreto de Vault, la función real responde 401 y no toca la cola"

# Con la petición que preparó la tarea
RESP=$(curl -s -X POST http://127.0.0.1:8000/ -H 'content-type: application/json' -H "x-turestaurante-recovery: $HDR" -d "$BODY")
echo "$RESP" | grep -q '"ok":true' || fallo "respuesta inesperada: $RESP"
[ "$(estado "$A"),$(estado "$B")" = "enviada/1,enviada/1" ] || fallo "estado tras la recuperación: $(estado "$A"),$(estado "$B")"
ok "la función real recupera las entregas pendientes sin nuevas invitaciones (reserva, envío y anotación en la base de datos): $RESP"
INV=$(curl -s http://127.0.0.1:54397/__invites)
echo "$INV" | grep -q '"email":"e2e-uno@x.test"' && echo "$INV" | grep -q '"redirect_to":"http://localhost:5173/"' || fallo "invitaciones enviadas: $INV"
ok "envía con la dirección de vuelta fija (APP_URL)"
RESP2=$(curl -s -X POST http://127.0.0.1:8000/ -H 'content-type: application/json' -H "x-turestaurante-recovery: $HDR" -d "$BODY")
[ "$(curl -s http://127.0.0.1:54397/__invites | grep -o '"email"' | wc -l)" = 2 ] || fallo "una segunda ejecución ha reenviado correos"
ok "una segunda ejecución no reenvía lo ya enviado: $RESP2"
grep -q "$SECRET" "$TMP/fn.log" && fallo "el registro de la función contiene el secreto"
grep -q '@' "$TMP/fn.log" && fallo "el registro de la función contiene correos"
ok "los registros de la función no contienen el secreto ni correos"
