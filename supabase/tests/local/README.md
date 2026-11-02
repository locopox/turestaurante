# Pruebas de integración con Supabase LOCAL (fase 6 · E4)

Pruebas reales contra Supabase local (CLI + Docker): base de datos, Supabase Auth, buzón Mailpit, las Edge
Functions `invitations` e `invitations-recovery` en el Edge Runtime de Supabase, `pg_cron`, `pg_net`, Vault y la app
React en el navegador. **Nunca contra un proyecto remoto**: los scripts y la configuración de Playwright se niegan a
funcionar si las URL no son locales.

No hay credenciales en el repositorio: cada ejecución crea sus cuentas (correos `*.e4.test`) con contraseñas
aleatorias. Las claves que usa son las de desarrollo local que imprime `supabase status`.

## Archivos

| Archivo | Qué prueba |
|---|---|
| `lib.mjs` | Utilidades comunes (Auth, PostgREST, Edge Functions, Mailpit, psql) y la comprobación de que todo es local |
| `integration_test.mjs` | Invitaciones de extremo a extremo por API (80 comprobaciones) |
| `recovery_integration_test.mjs` | Recuperación programada con `pg_cron`, `pg_net` y Vault reales, y fallos de entrega reales |
| `../../../e2e/invitations.local.e2e.ts` | Recorridos principales en el navegador (Playwright) |
| `../../../e2e/demo.e2e.ts` | El modo demo sigue funcionando |

## Preparación (una vez)

1. Docker en marcha y la [CLI de Supabase](https://supabase.com/docs/guides/local-development) (probado con 2.54.11).
   En Windows: Docker Desktop con WSL 2.
2. Carpeta de trabajo **aparte** (las migraciones del repositorio empiezan en la fase 3 y no sirven para una base
   vacía):

   ```bash
   mkdir -p ~/tr-local && cd ~/tr-local && supabase init
   cp -r /ruta/a/turestaurante/supabase/functions/{_shared,invitations,invitations-recovery} supabase/functions/
   ```

3. En `~/tr-local/supabase/config.toml` (solo esta copia local):

   ```toml
   [auth]
   site_url = "http://127.0.0.1:5173"
   additional_redirect_urls = ["http://127.0.0.1:5173/", "http://localhost:5173/"]
   enable_signup = false          # registro público cerrado

   [auth.email]
   enable_signup = true           # ¡NO lo pongas a false! Desactivaría el inicio de sesión por correo

   [edge_runtime.secrets]
   APP_URL = "http://127.0.0.1:5173/"
   ALLOWED_ORIGINS = "http://127.0.0.1:5173,http://localhost:5173"
   INVITATIONS_RECOVERY_SECRET = "<openssl rand -hex 32>"   # solo en esta copia local

   [functions.invitations]
   verify_jwt = true

   [functions.invitations-recovery]
   verify_jwt = false
   ```

4. Arranca y carga los datos (base de datos LOCAL):

   ```bash
   supabase start
   eval "$(supabase status -o env)"
   psql "$DB_URL" -f /ruta/a/turestaurante/supabase/schema.sql        # instalación nueva
   psql "$DB_URL" -f /ruta/a/turestaurante/supabase/seed.sql
   psql "$DB_URL" -f /ruta/a/turestaurante/supabase/migrations/20261105120000_fase6_recuperacion_programada.sql
   ```

   Para probar la **actualización** desde la fase 5 (como la haría el proyecto real): carga el `schema.sql` del commit
   `55c6837` y `seed.sql`, añade datos, y aplica `20261104120000_fase6_invitaciones.sql` y
   `20261105120000_fase6_recuperacion_programada.sql`.

5. Para la recuperación programada, guarda en Vault la URL de la función **vista desde la base de datos** y el mismo
   secreto (lo hace también `recovery_integration_test.mjs`):

   ```sql
   select vault.create_secret('http://supabase_kong_tr-local:8000/functions/v1/invitations-recovery', 'turestaurante_recovery_url');
   select vault.create_secret('<el mismo secreto>', 'turestaurante_recovery_secret');
   ```

## Ejecutar

Desde la carpeta del repositorio, con las variables de `supabase status -o env` cargadas:

```bash
eval "$(cd ~/tr-local && supabase status -o env)"
npm run test:local:integration                       # API: invitaciones, Auth, correo, permisos, límites, concurrencia
RECOVERY_SECRET=<secreto> RECOVERY_URL=http://supabase_kong_tr-local:8000/functions/v1/invitations-recovery \
  node supabase/tests/local/recovery_integration_test.mjs normal          # pg_cron + pg_net + Vault (espera ≤ 5 min)
npm run test:e2e:local                               # navegador contra Supabase local
npm run test:e2e:demo                                # navegador, modo demo
```

Fallo de entrega real (opcional):

```bash
docker stop supabase_inbucket_tr-local
RECOVERY_SECRET=… RECOVERY_URL=… node supabase/tests/local/recovery_integration_test.mjs sin-correo
docker start supabase_inbucket_tr-local
RECOVERY_SECRET=… RECOVERY_URL=… node supabase/tests/local/recovery_integration_test.mjs tras-sin-correo
```

En Supabase local la CLI **no aplica** `[auth.rate_limit] email_sent` (fija un límite muy alto), por eso el fallo de
entrega se provoca parando el servidor de correo.

## Limitaciones conocidas de este entorno de prueba (E4)

- **Realtime no se ha probado**: en el entorno de la E4 (sin IPv6) el contenedor de Realtime no arranca
  (`eafnosupport`); se desactivó **solo** en la copia local desechable (`[realtime] enabled = false`). Las
  invitaciones no usan Realtime; las actualizaciones en vivo de pedidos y carta quedan pendientes de probar en un
  equipo con IPv6 (por ejemplo, Docker Desktop).
- El entorno de la E4 sale a Internet por un proxy: los contenedores lo usaron mediante un reenvío local hacia la red
  de Docker y `HTTPS_PROXY`/`DENO_CERT` en `[edge_runtime.secrets]`. En un equipo normal no hace falta.
- El correo se prueba con Mailpit (SMTP de Supabase local), no con un proveedor SMTP real.
