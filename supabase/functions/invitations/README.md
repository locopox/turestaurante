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
| Clave secreta | Solo en el servidor (variable de la función) y solo para tres cosas: `auth.admin.inviteUserByEmail`, `invitation_delivery` e `invitation_mark_sent`. Se usa **después** de que SQL haya aceptado la invitación. |
| No revelar cuentas | Respuesta idéntica (estado, cuerpo y cabeceras) tenga o no cuenta el correo, sea de otro restaurante o de la plataforma, y se envíe o falle el correo. Tiempo mínimo de respuesta (`MIN_RESPONSE_MS`, 1,5 s) para que no se note si hubo envío. Los envíos fallidos solo los ve la plataforma en el registro (el propietario no). |
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

Comportamiento de `inviteUserByEmail` comprobado en el código de Supabase Auth (repositorio `supabase/auth`,
commit `a7e97d6`, `internal/api/invite.go` y `mail.go`):

| Situación del correo | Qué hace la función | `send_status` |
|---|---|---|
| Sin cuenta | `inviteUserByEmail`: Supabase crea la cuenta **sin confirmar** y envía el enlace. Si el envío falla, Supabase deshace todo (no queda cuenta). | `enviada` / `fallida` |
| Cuenta invitada que aún no confirmó | `inviteUserByEmail` otra vez: Supabase **no crea otra cuenta** y envía un enlace nuevo (el anterior deja de valer). | `enviada` / `fallida` |
| Cuenta confirmada (de otro restaurante, de la plataforma o sin restaurante) | No se envía nada ni se toca la cuenta (ni su contraseña). La verá dentro de TuRestaurante. | `no_necesario` |
| Confirmó justo entre la consulta y el envío (`email_exists`) | Igual que la anterior. | `no_necesario` |

Fallos de envío:

- **Temporal** (red o error 5xx de Auth): un reintento tras 0,8 s. Si vuelve a fallar, `fallida`.
- **Límite de correos de Supabase** (429 `over_email_send_rate_limit`), **correo no autorizado** por el SMTP de
  pruebas de Supabase (400 `email_address_not_authorized`) u otro 4xx: sin reintento, `fallida`.
- La invitación **sigue creada** aunque el correo falle; quien invita puede reenviarla pasados 5 minutos (máximo 3
  veces). El fallo queda en el registro de auditoría **solo para la plataforma** (`invitacion.envio_fallido`).
- El registro público sigue desactivado: en Supabase Auth, la desactivación del registro no afecta a
  `/invite` (comprobado en el código: solo se aplica al registro público y a proveedores externos).

## Variables de la función

| Variable | Origen | Valor |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Las pone Supabase en sus Edge Functions | — (no se guardan en el repositorio) |
| `APP_URL` | Secreto de la función | Dirección de la app, p. ej. `https://turestaurante.ejemplo.com/` |
| `ALLOWED_ORIGINS` | Opcional | Orígenes del navegador separados por comas (por defecto, el de `APP_URL`) |
| `MIN_RESPONSE_MS` | Opcional | Tiempo mínimo de respuesta en ms (por defecto 1500) |

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
  invitación queda `fallida`, la respuesta no cambia y la plataforma ve `invitacion.envio_fallido`.
- **Límites** de 20/hora, 30 pendientes, 5 minutos y 3 reenvíos: 429.
- **Permisos**: owner → owner (403), manager → manager (403), otro restaurante (403), sin sesión (401).
- **Redirección**: un `redirectTo` en la petición no cambia el enlace del correo.

## Comprobar el código sin Supabase

```bash
npm test                                             # incluye las pruebas de la función (clientes simulados)
deno check supabase/functions/invitations/index.ts   # si tienes Deno instalado
```

## Lo que falta por comprobar (E4)

- Todo lo anterior contra Supabase Auth real (local con Docker): sobre todo el reenvío a cuentas sin confirmar y la
  vuelta del enlace con `type=invite`. El comportamiento descrito sale del código fuente de Supabase Auth; la versión
  desplegada en Supabase podría diferir.
- Con las claves nuevas de Supabase (`sb_publishable_…` / `sb_secret_…`), confirmar que la función recibe
  `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` y que `verify_jwt` se comporta como se espera.
- Que la app (E3) reconozca `type=invite` y pida la contraseña antes de nada.
