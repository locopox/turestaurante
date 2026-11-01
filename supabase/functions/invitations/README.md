# Edge Function `invitations` (fase 6 · E2)

Crea invitaciones, crea restaurantes con la invitación de su primer propietario y reenvía
invitaciones. Envía el correo de invitación de Supabase Auth cuando hace falta.

- `handler.ts`: toda la lógica, sin dependencias. Pruebas: `src/__tests__/invitationsFunction.test.ts` (Vitest,
  clientes simulados).
- `index.ts`: punto de entrada para Deno / Supabase Edge Runtime (crea los clientes y lee la configuración).

> **Estado:** no está desplegada ni probada contra Supabase (ni en la nube ni en local). Ver «Lo que falta por
> comprobar» al final.

## Seguridad

| Regla | Cómo se cumple |
|---|---|
| Identidad | El JWT de `Authorization: Bearer …` se verifica con Supabase Auth (`auth.getUser`). Sin JWT válido: 401. Sesiones anónimas: 403. |
| Permisos | **Todos** los decide SQL: `invitation_create`, `platform_create_restaurant` e `invitation_resend` se llaman con la **clave pública + el JWT de quien invita**, así que la base de datos aplica sus permisos (rol, restaurante, límites). La clave secreta no se usa para decidir nada. |
| Clave secreta | Solo en el servidor (variable de la función) y solo para cuatro cosas: `auth.admin.inviteUserByEmail` e `invitation_delivery_claim` / `_finish` / `_pending`. Se usa **después** de que SQL haya aceptado la invitación. |
| No revelar cuentas | Respuesta idéntica (estado, cuerpo y cabeceras) tenga o no cuenta el correo, sea de otro restaurante o de la plataforma. Se responde en cuanto SQL crea la invitación; el correo se envía **después**, en segundo plano (`EdgeRuntime.waitUntil`), así que ni la respuesta ni su duración dependen del envío. El resultado de cada entrega solo lo ve la plataforma en el registro (`invitacion.entrega`, sin restaurante); el propietario no. |
| Redirección | El enlace del correo vuelve siempre a `APP_URL` (secreto de la función, https; http solo en localhost; sin `?` ni `#`). Lo que mande el navegador (`redirectTo`, etc.) se ignora. Sin `APP_URL` válida la función responde 500 y no invita a nadie. |
| Registros | Solo identificadores de invitación, resultados y códigos de error. Nunca correos, JWT ni claves. |
| CORS | Solo los orígenes de `ALLOWED_ORIGINS` (o el de `APP_URL`). |

## Peticiones

`POST /functions/v1/invitations` con `Authorization: Bearer <JWT de la sesión>` y JSON:

```jsonc
{ "action": "create", "restaurantId": "<uuid>", "email": "persona@ejemplo.com", "role": "waiter" }
{ "action": "create_restaurant", "name": "Nuevo Sitio", "slug": "nuevo-sitio", "ownerEmail": "duena@ejemplo.com" }  // solo plataforma
{ "action": "resend", "invitationId": "<uuid>" }
```

Respuesta correcta (siempre la misma forma; `restaurantId` solo al crear restaurante):

```json
{ "ok": true, "invitationId": "<uuid>", "message": "Invitación creada. Si la persona ya tiene cuenta, …" }
```

Errores: `{ "ok": false, "error": "<mensaje>" }` con 400 (datos), 401 (sesión), 403 (permiso), 409 (dirección web
repetida), 429 (límites: 20 invitaciones/hora por persona, 30 pendientes por restaurante, reenvío antes de 5 min o
más de 3 veces), 500 (otros; sin detalles internos).

## Qué pasa con el correo

### Entrega en segundo plano y cola persistente

1. SQL crea la invitación con `send_status = 'sin_enviar'`: **la entrega pendiente ya está guardada** antes de responder.
2. La función responde y, con `EdgeRuntime.waitUntil`, en segundo plano:
   - **reserva** la entrega (`invitation_delivery_claim`). La reserva es atómica: si dos procesos lo intentan a la vez
     (peticiones simultáneas, reenvíos, recuperación), solo uno la obtiene. Cuenta un intento (máximo 3);
   - envía (o no) el correo y **anota** el resultado (`invitation_delivery_finish`) con el identificador de su reserva.
     Un proceso que perdió la reserva no puede sobrescribir el resultado de otro;
   - **recupera** entregas atrasadas o interrumpidas (`invitation_delivery_pending`): como mucho `SWEEP_LIMIT`
     (5, máximo 10) por llamada, primero las interrumpidas. Se detiene si Supabase limita los correos.
3. `waitUntil` **no garantiza** que la tarea termine (la función se detiene al agotar su tiempo o si se reinicia).
   Por eso todo el estado está en la base de datos:
   - interrumpida **antes** de reservar: sigue `sin_enviar`; la recuperación la toma pasados 2 minutos;
   - interrumpida **después** de reservar: la reserva caduca a los **10 minutos** (más que el tiempo máximo de una
     Edge Function) y la recuperación la retoma como nuevo intento;
   - interrumpida en el 3.er intento: la recuperación la cierra como `fallida` (no queda reservada para siempre).

| `send_status` | Significado |
|---|---|
| `sin_enviar` | Por enviar, o esperando un reintento hasta `send_next_at` |
| `enviando` | Reservada por un proceso (`send_claim`) desde `send_claimed_at` |
| `enviada` | Supabase Auth envió el correo |
| `no_necesario` | La cuenta ya estaba confirmada: la verá dentro de TuRestaurante |
| `fallida` | Fallo definitivo o 3 intentos sin éxito |

### Según la cuenta

Comportamiento de `inviteUserByEmail` comprobado en el código de Supabase Auth (repositorio `supabase/auth`,
commit `a7e97d6`, `internal/api/invite.go` y `mail.go`):

| Situación del correo | Qué hace la función | Resultado |
|---|---|---|
| Sin cuenta | `inviteUserByEmail`: Supabase crea la cuenta **sin confirmar** y envía el enlace. Si el envío falla, Supabase deshace todo (no queda cuenta). | `enviada` |
| Cuenta invitada que aún no confirmó | `inviteUserByEmail` otra vez: Supabase **no crea otra cuenta** y envía un enlace nuevo (el anterior deja de valer). | `enviada` |
| Cuenta confirmada (de otro restaurante, de la plataforma o sin restaurante) | No se envía nada ni se toca la cuenta (ni su contraseña). | `no_necesario` |
| Confirmó justo entre la reserva y el envío (`email_exists`) | Igual que la anterior. | `no_necesario` |

### Fallos y reintentos

| Respuesta de Supabase Auth | Resultado |
|---|---|
| Fallo temporal (red o 5xx) | Reintento: espera **5 min** tras el 1.er intento y **30 min** tras el 2.º. Tras el 3.º, `fallida`. |
| Límite de correos (429 `over_email_send_rate_limit`) | Igual (reintento con espera) y la recuperación de esa llamada **se detiene**. |
| Otro 4xx (p. ej. 400 `email_address_not_authorized` del SMTP de pruebas) | `fallida`, sin reintentos. |

Límites contra el envío masivo: 3 intentos por invitación con esperas, como mucho 10 recuperaciones por llamada, y
los límites de SQL (20 invitaciones nuevas por hora y persona, 30 pendientes por restaurante, 3 reenvíos con 5
minutos de espera). Un reenvío crea una invitación nueva: la anterior queda «reemplazada» y ya no se envía.

Duplicados: la reserva atómica impide que dos procesos envíen a la vez. El único caso posible es que el proceso se
detenga **después** de que Supabase envíe el correo y **antes** de anotarlo: al recuperarla se enviaría otro enlace
(el anterior deja de valer). Está acotado a 3 intentos.

El registro público sigue desactivado: en Supabase Auth, la desactivación del registro no afecta a `/invite`
(comprobado en el código: solo se aplica al registro público y a proveedores externos).

## Variables de la función

| Variable | Origen | Valor |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Las pone Supabase en sus Edge Functions | — (no se guardan en el repositorio) |
| `APP_URL` | Secreto de la función | Dirección de la app, p. ej. `https://turestaurante.ejemplo.com/` |
| `ALLOWED_ORIGINS` | Opcional | Orígenes del navegador separados por comas (por defecto, el de `APP_URL`) |
| `SWEEP_LIMIT` | Opcional | Entregas atrasadas que recupera cada llamada (1-10, por defecto 5) |

Plantilla sin secretos: `supabase/functions/.env.example`. Copia local: `supabase/functions/.env.local` (ignorada
por git).

## Configuración de Supabase Auth necesaria

1. **Registro público desactivado** (Authentication → Sign In / Providers → «Allow new users to sign up»: off).
2. **Site URL** y **Redirect URLs**: incluir exactamente `APP_URL`.
3. Plantilla **«Invite user»** en español (Authentication → Emails). El enlace usa `{{ .ConfirmationURL }}`.
4. **SMTP propio** antes de invitar a personas reales: el SMTP de Supabase solo entrega a los correos del equipo del
   proyecto y muy pocos por hora (fase posterior, decisión 11).
5. «Secure email change» activado (para que nadie cambie su correo al de otra persona sin confirmarlo).
6. Caducidad del enlace del correo (Email OTP expiration): es independiente de los 7 días de la invitación. Si el
   enlace caduca, se reenvía la invitación.

## Probar con Supabase local (Docker) — guion para la E4

> No se ha podido ejecutar en este entorno: Docker funciona, pero la red no permite descargar las imágenes de
> Supabase. Comprueba los nombres de las opciones de `config.toml` con tu versión de la CLI.

1. Requisitos: Docker y la [CLI de Supabase](https://supabase.com/docs/guides/local-development).
2. Usa una carpeta de trabajo **aparte** (las migraciones de `supabase/migrations` empiezan en la fase 3 y no sirven
   para una base vacía):

   ```bash
   mkdir -p ~/tr-local && cd ~/tr-local && supabase init
   mkdir -p supabase/functions && cp -r /ruta/a/turestaurante/supabase/functions/invitations supabase/functions/
   ```

3. En `~/tr-local/supabase/config.toml`:

   ```toml
   [auth]
   site_url = "http://localhost:5173"
   additional_redirect_urls = ["http://localhost:5173/"]
   enable_signup = false

   [auth.email]
   enable_signup = false

   [functions.invitations]
   verify_jwt = true
   ```

4. Arranca y carga el esquema y La Piazza (base de datos LOCAL de Docker, nunca la del proyecto real):

   ```bash
   supabase start          # muestra API URL, claves locales y la URL del buzón de pruebas (Mailpit/Inbucket)
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f /ruta/a/turestaurante/supabase/schema.sql
   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f /ruta/a/turestaurante/supabase/seed.sql
   ```

5. Sirve la función con `APP_URL` local (copia `.env.example` a `.env.local`):

   ```bash
   supabase functions serve invitations --env-file /ruta/a/turestaurante/supabase/functions/.env.local
   ```

6. Cuenta de plataforma: en el Studio local (Authentication → Add user, «Auto confirm») y después
   `insert into public.platform_admins (user_id) select id from auth.users where email = 'admin@local.test';`.
7. JWT de esa cuenta (clave pública LOCAL que muestra `supabase start`):

   ```bash
   curl -s "http://127.0.0.1:54321/auth/v1/token?grant_type=password" -H "apikey: <clave pública local>" \
     -H "content-type: application/json" -d '{"email":"admin@local.test","password":"<contraseña>"}'
   ```

8. Llamadas (con el `access_token` anterior):

   ```bash
   curl -s http://127.0.0.1:54321/functions/v1/invitations -H "authorization: Bearer <access_token>" \
     -H "content-type: application/json" \
     -d '{"action":"create_restaurant","name":"Tercer Sitio","slug":"tercer-sitio","ownerEmail":"duena@local.test"}'
   ```

Casos a comprobar en la E4 (dos restaurantes, cuentas distintas):

- **Cuenta nueva**: llega el correo al buzón local; el enlace vuelve a `APP_URL` con `type=invite`; tras elegir
  contraseña, `my_invitations` la muestra y `invitation_accept` funciona.
- **Cuenta invitada sin confirmar**: reenviar (pasados 5 min, o con una segunda invitación de otro restaurante)
  manda un enlace nuevo; el anterior deja de valer; no se crea otra cuenta.
- **Cuenta existente confirmada** (de otro restaurante y de la plataforma): no llega correo; la respuesta es idéntica.
- **Fallo de envío**: con el límite de correos a 0 (`[auth.rate_limit] email_sent = 0`) Supabase responde 429; la
  entrega queda `sin_enviar` con espera y, tras 3 intentos, `fallida`; la respuesta no cambia y la plataforma ve
  `invitacion.entrega`.
- **Interrupción**: detener `supabase functions serve` mientras envía; al volver, otra invitación (pasados 2 o 10
  minutos) recupera la entrega.
- **Segundo plano**: la respuesta llega antes que el correo.
- **Límites** de 20/hora, 30 pendientes, 5 minutos y 3 reenvíos: 429.
- **Permisos**: owner → owner (403), manager → manager (403), otro restaurante (403), sin sesión (401).
- **Redirección**: un `redirectTo` en la petición no cambia el enlace del correo.

## Comprobar el código sin Supabase

```bash
npm test                                             # incluye las pruebas de la función (clientes simulados)
deno check supabase/functions/invitations/index.ts   # si tienes Deno instalado
```

## Recuperación programada (pg_cron + pg_net + Vault)

Además de la recuperación en cada llamada, una **tarea programada** revisa la cola cada 5 minutos, aunque nadie
invite a nadie. Archivos:

- `supabase/migrations/20261105120000_fase6_recuperacion_programada.sql` (y su bajada en `migrations_down/`).
- Edge Function `supabase/functions/invitations-recovery/index.ts` (lógica en `_shared/invitations.ts`).

### Cómo funciona

1. `pg_cron` ejecuta `private.invitations_recovery_tick()` cada 5 minutos (tarea
   `turestaurante-recuperar-invitaciones`).
2. Si **no** hay entregas atrasadas o interrumpidas, no llama a nada (anota `sin_pendientes`): no gasta invocaciones.
3. Si las hay, lee de **Vault** la URL de la función y el secreto compartido, y llama con **pg_net**
   (`POST`, asíncrono) a `invitations-recovery` con la cabecera `x-turestaurante-recovery: <secreto>`.
4. La función comprueba el secreto y recupera como mucho 10 entregas con las **mismas** reservas atómicas, intentos
   (máx. 3), esperas (5 y 30 min) y parada ante el límite de correos que la función de invitaciones. Dos ejecuciones
   a la vez nunca reservan la misma entrega.
5. Todo queda anotado: cada ejecución en `private.invitations_recovery_runs` (7 días), la respuesta HTTP (estado y
   resumen sin datos personales) en `net._http_response` (pg_net la guarda unas horas) y la ejecución de la tarea en
   `cron.job_run_details`.

### Autenticación de servidor

- La acción de recuperación es **otra** Edge Function: no acepta JWT de usuarios ni peticiones de navegador (con
  `Origin`), solo `POST` con la cabecera `x-turestaurante-recovery`.
- El secreto es **propio** (no es la clave secreta de Supabase), de al menos 32 caracteres, y se compara en tiempo
  constante. La función lo lee de su secreto `INVITATIONS_RECOVERY_SECRET`; la base de datos, de Vault. Sin él, la
  función no hace nada (500) y la tarea no llama (`sin_configurar`).
- La tarea solo envía el secreto a una URL `https://…/functions/v1/invitations-recovery` (o `http://` dentro de
  Supabase local: localhost, host.docker.internal o el contenedor kong).
- Nadie de la API (anon, authenticated, service_role) puede lanzar la tarea, leer su registro, crear tareas de
  pg_cron ni leer Vault. El estado lo ven solo las cuentas de plataforma (`invitations_recovery_status` e
  `invitations_recovery_job`).
- La función se despliega con `verify_jwt = false` (la tarea no tiene sesión): su protección es el secreto.

### Configurar (cuando se autorice el despliegue)

1. Genera un secreto (por ejemplo `openssl rand -hex 32`). No lo guardes en el repositorio.
2. Secretos de la función (CLI): `supabase secrets set INVITATIONS_RECOVERY_SECRET=<secreto>` (y `APP_URL`, que ya
   usa «invitations»). Despliega `invitations-recovery` con `verify_jwt = false`:

   ```toml
   [functions.invitations-recovery]
   verify_jwt = false
   ```

3. Aplica la migración (activa pg_cron y pg_net si no lo están y crea la tarea).
4. Guarda en Vault la URL y el **mismo** secreto (SQL Editor):

   ```sql
   select vault.create_secret('https://<ref>.supabase.co/functions/v1/invitations-recovery', 'turestaurante_recovery_url',
     'URL de la recuperación de invitaciones');
   select vault.create_secret('<secreto>', 'turestaurante_recovery_secret', 'Secreto de la recuperación de invitaciones');
   ```

   En Supabase local, la URL vista desde la base de datos suele ser
   `http://host.docker.internal:54321/functions/v1/invitations-recovery`.

### Verificar que funciona

```sql
-- Como cuenta de plataforma (desde la app) o en el SQL Editor:
select * from public.invitations_recovery_job();       -- frecuencia, activa, última ejecución en pg_cron
select * from public.invitations_recovery_status(20);  -- últimas ejecuciones, estado HTTP y resumen
-- Solo en el SQL Editor:
select * from cron.job where jobname = 'turestaurante-recuperar-invitaciones';
select * from cron.job_run_details where command = 'select private.invitations_recovery_tick()' order by runid desc limit 10;
```

Qué mirar: `sin_pendientes` cada 5 minutos (la tarea corre), `solicitada` con `http_status` 200 y su resumen
(`procesadas`, `resultados`); `sin_configurar` (faltan secretos en Vault), `error` (pg_net no pudo encolar), 401 (el
secreto de Vault y el de la función no coinciden), 500 (falta configurar la función).

### Desactivar, reactivar, eliminar y rotar el secreto

```sql
-- Desactivar (la tarea queda, pero no se ejecuta):
select cron.alter_job((select jobid from cron.job where jobname = 'turestaurante-recuperar-invitaciones'), active := false);
-- Reactivar:
select cron.alter_job((select jobid from cron.job where jobname = 'turestaurante-recuperar-invitaciones'), active := true);
-- Eliminar solo la tarea:
select cron.unschedule('turestaurante-recuperar-invitaciones');
-- Rotar el secreto: cámbialo a la vez en la función (supabase secrets set …) y en Vault:
select vault.update_secret((select id from vault.secrets where name = 'turestaurante_recovery_secret'), '<nuevo secreto>');
-- Borrar los secretos de Vault (si ya no se usan):
delete from vault.secrets where name in ('turestaurante_recovery_url', 'turestaurante_recovery_secret');
```

Eliminarlo todo: aplica `supabase/migrations_down/20261105120000_fase6_recuperacion_programada.down.sql` (quita la
tarea, sus funciones y su registro; no desactiva extensiones ni borra los secretos de Vault). Sin la tarea, las
entregas pendientes se siguen recuperando en cada llamada a «invitations».

### Pruebas

- `npm run test:recovery`: necesita un PostgreSQL local con **pg_cron real** (`shared_preload_libraries = 'pg_cron'`,
  `cron.database_name = 'turestaurante_cron'`, `cron.use_background_workers = on`); si no, se omite y lo dice. Si
  el servidor no tiene pg_net y Vault, usa `supabase/tests/pg_net_vault_stub.sql`, un **sustituto que no es
  equivalente** (no hace HTTP ni cifra): sirve para probar nuestro SQL, no las extensiones.
- `RECOVERY_E2E=1 DENO=<ruta a deno> npm run test:recovery` añade una prueba con la Edge Function real en Deno: se le
  reenvía la petición que preparó la tarea, contra un servidor que imita la API de Supabase y ejecuta las funciones
  SQL en la base de datos local.
- Pendiente con Supabase (local o remoto): pg_net enviando de verdad, Vault real, el gateway con `verify_jwt = false`
  y la ejecución cada 5 minutos en el propio Supabase.

## Lo que falta por comprobar (E4)

- Todo lo anterior contra Supabase Auth real (local con Docker): sobre todo el reenvío a cuentas sin confirmar, la
  vuelta del enlace con `type=invite` y que `EdgeRuntime.waitUntil` sigue ejecutando el envío después de responder. El comportamiento descrito sale del código fuente de Supabase Auth; la versión
  desplegada en Supabase podría diferir.
- Con las claves nuevas de Supabase (`sb_publishable_…` / `sb_secret_…`), confirmar que la función recibe
  `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` y que `verify_jwt` se comporta como se espera.
- Que la app (E3) reconozca `type=invite` y pida la contraseña antes de nada.
- La recuperación programada con pg_cron, pg_net y Vault reales (ver «Pruebas» en la sección anterior).
