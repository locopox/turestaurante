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
| `kitchen_isolation_test.mjs` | Aislamiento de cocina con una sesión real (ver abajo) |
| `orders_security_test.mjs` | Seguridad de los pedidos de clientes P1–P10 (ver abajo) |
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

## Prueba de aislamiento de cocina (`npm run test:local:isolation`)

Comprueba con una **sesión real** de Supabase Auth que un usuario de cocina asignado solo a un restaurante puede
consultar la cocina de ese restaurante (`kitchen_orders` → 200) y recibe un rechazo en otro (403, código `42501`).

- Solo contra Supabase local y solo con la clave **pública**: no usa `service_role` ni acceso directo a la base de
  datos, y no modifica nada.
- La contraseña se pide en la terminal **sin mostrarse** y no se guarda en ningún archivo.
- Configuración: copia `isolation.env.example` a `supabase/tests/local/.env.local` (ignorado por git) y rellena la
  clave pública y el correo del usuario de cocina.

```bash
npm run test:local:isolation
```

## Seguridad de los pedidos de clientes (`npm run test:local:orders`)

Intenta, por la API real (PostgREST) y **solo con la clave pública**, lo que haría alguien malintencionado:

| | Quién | Intento |
|---|---|---|
| P1 | Cliente anónimo | Enviar precios, nombres y total falsos al crear un pedido |
| P2 | Anónimo y sala | Cambiar el total o los precios de las líneas con `PATCH` |
| P3 | Anónimo y sala | Crear pedidos o líneas directamente en las tablas |
| P4 | Anónimo y cocina | Marcar un pedido como cobrado o pagado |
| P5 | Anónimo y sala | Usar las funciones de pago reservadas al servidor |
| P6 | Anónimo | Consultar un pedido sin su código secreto (o con el de otro) |
| P7 | Anónimo | Pasar a caja el pedido de otro cliente |
| P8 | Anónimo | Cancelar o borrar un pedido |
| P9 | Sala de otro restaurante | Ver pedidos, líneas o la cocina de otro restaurante |
| P10 | Sala de otro restaurante | Cobrar, cancelar o cambiar pedidos de otro restaurante |

Cada rechazo lleva una **comprobación inversa** (el pedido sigue exactamente igual) y al final hay **controles**: lo
legítimo sí funciona (la sala cobra su pedido, el cliente pasa a caja el suyo, la cocina ve su cocina).

Cómo protege los datos:

- **Preparar y limpiar** usan la administración de Supabase LOCAL (base de datos y API de administración de Auth);
  **los ataques no**: la clave de administración se olvida antes de empezarlos, y el script se detiene si una
  petición de ataque lleva credenciales de administración.
- Antes de cualquier operación comprueba que la API y la base de datos son `127.0.0.1` o `localhost` (y no acepta
  `?host=` en `DB_URL` ni variables `PG*` del entorno que puedan llevar a otro servidor).
- Crea sus propios datos: restaurantes «PRUEBA-PEDIDOS A/B ‹marca›», tres cuentas `…‹marca›@pedidos-prueba.test`
  con contraseñas aleatorias (solo en memoria; no se muestran ni se guardan) y pedidos hechos como cliente anónimo.
- Hace una «foto» de solo lectura de todo lo que no es de la prueba (La Piazza, Restaurante Aislamiento PRUEBA…)
  antes y después: si algo cambia, la prueba falla.
- La limpieza borra **solo los identificadores de esta ejecución**, en una única transacción. Si algo no encaja (un
  pedido que no ha creado, personal que no es de prueba, pagos, invitaciones…), **no borra nada** y avisa.
- Con Ctrl+C limpia antes de salir.
- El registro de auditoría está protegido contra borrados (a propósito) y conserva la huella de la prueba.

```bash
eval "$(cd ~/tr-local && supabase status -o env)"   # variables de Supabase LOCAL, solo en esta terminal
npm run test:local:orders
```

Restos de una ejecución interrumpida (muestra lo que borraría y pide escribir `BORRAR`):

```bash
npm run test:local:orders -- --limpiar
```

## Limitaciones conocidas de este entorno de prueba (E4)

- **Realtime no se ha probado**: en el entorno de la E4 (sin IPv6) el contenedor de Realtime no arranca
  (`eafnosupport`); se desactivó **solo** en la copia local desechable (`[realtime] enabled = false`). Las
  invitaciones no usan Realtime; las actualizaciones en vivo de pedidos y carta quedan pendientes de probar en un
  equipo con IPv6 (por ejemplo, Docker Desktop).
- El entorno de la E4 sale a Internet por un proxy: los contenedores lo usaron mediante un reenvío local hacia la red
  de Docker y `HTTPS_PROXY`/`DENO_CERT` en `[edge_runtime.secrets]`. En un equipo normal no hace falta.
- El correo se prueba con Mailpit (SMTP de Supabase local), no con un proveedor SMTP real.
