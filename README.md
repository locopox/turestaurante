# TuRestaurante

Plataforma multi-restaurante para pedidos por QR en mesa y para recoger. Fase 1: datos ficticios
(restaurante de demostración **La Piazza**) y pagos simulados.

## Interfaces

| Ruta | Para quién | Qué hace |
|---|---|---|
| `#pedir-la-piazza-mesa-5` | Cliente (QR de mesa) | Carta visual, categorías, carrito, mesa/recogida, pago online o en caja, confirmación con seguimiento en directo |
| `#pedir-la-piazza` | Cliente (para recoger) | Igual, eligiendo hora de recogida |
| `#panel` | Sala / caja | Pedidos con número, productos, importe, estado de pago y de preparación; cobro en caja; cancelación |
| `#cocina` | Cocina | Comandas por columnas (nuevos, en preparación, listos), tiempos y retrasos |
| `#admin` | Plataforma | Alta y configuración de restaurantes, carta (precios, disponibilidad, productos), QR de mesas |

Abre el cliente y el panel/cocina en pestañas distintas: se sincronizan al instante (BroadcastChannel + localStorage).
En modo demo no hay inicio de sesión (actúas como administrador). Con Supabase, panel, cocina y administración piden email y contraseña.

## Puesta en marcha

```bash
npm install
cp .env.example .env
npm run dev
```

`npm run build` genera `dist/`. `npm run build:single` genera un único HTML autocontenido en `dist-single/`.

## Pagos

- En el **modo demo** el pago online usa una pasarela **simulada**: no pide datos de tarjeta ni hace cargos.
  Su mejor resultado es «Pago simulado», nunca un pago verificado.
- Con **Supabase**, el pago online está **desactivado**: solo se ofrece pago en caja. La base de datos lo rechaza
  aunque alguien manipule el navegador, y el personal no puede activarlo desde la app.
- `pagado_verificado` solo lo puede escribir el servidor con la clave `service_role`, y solo a través de
  `payment_record_result` (el futuro webhook del proveedor). Ni el navegador, ni el personal, ni el SQL Editor
  pueden asignarlo.
- Un pedido con pago online pendiente o fallido no llega a cocina.
- El cliente puede pasar de pago online a caja solo si el restaurante está activo, el pedido tiene menos de
  2 horas y **no hay un cobro en curso** en la pasarela (evita el doble cobro).

## Estructura

```
src/
  types.ts                     Modelo de dominio (Restaurant, Product, Order, roles…)
  config.ts                    Lee y valida las variables VITE_* (bloquea claves secretas)
  data/seed.ts                 Datos de demostración del modo demo
  lib/orderRules.ts            Reglas de pedido (las mismas que create_order) y token del cliente
  lib/permissions.ts           Qué ve cada rol en la interfaz (la base de datos decide de verdad)
  services/
    dataService.ts             Interfaz única de datos (la UI solo usa esto)
    mock/mockDataService.ts    Implementación local del modo demo
    supabase/…                 Implementación Supabase (SQL probado en PostgreSQL local; cliente sin probar contra Supabase real)
    payments/                  Pasarela simulada (demo) y esqueleto de Stripe (sin usar)
    index.ts                   Elige implementación según .env
  components/StaffAccess.tsx   Inicio de sesión del personal y pantalla de configuración
  views/customer|staff|kitchen|admin
  __tests__/                   Pruebas Vitest
supabase/
  schema.sql                   Tablas, funciones, RLS, triggers de integridad y tiempo real (repetible)
  seed.sql                     Datos de La Piazza (repetible, sin duplicar)
  tests/                       Pruebas SQL contra un PostgreSQL local
```

## Seguridad con Supabase (resumen)

| Quién | Qué puede hacer |
|---|---|
| Cliente sin cuenta | Leer la carta. Crear pedidos con `create_order`. Leer **solo su pedido** con su token (`get_customer_order`). Pasar de pago online pendiente a caja. Nada más: no puede leer ni modificar tablas de pedidos. |
| `kitchen` | Ver pedidos de su restaurante (sin los de pago online pendiente) y cambiar su preparación. No cobra, no cancela y no toca la carta ni la configuración. |
| `waiter` | Lo de cocina, y además ver todos los pedidos, cobrar en caja y cancelar. |
| `manager` / `owner` | Lo anterior, y además editar la carta y la configuración de su restaurante. |
| Administrador de plataforma | Todo, en todos los restaurantes. Crear restaurantes y asignar personal. |
| Servidor (`service_role`) | Administrar restaurantes, carta y personal. Sobre pedidos y pagos solo **lee**: los cambia únicamente con `payment_checkout_started` y `payment_record_result`. No tiene permisos sobre tablas ajenas a TuRestaurante. |

- **Nadie** puede cambiar el total, las líneas, la referencia de pago ni los datos de un pedido ya creado (trigger).
- Los precios y totales los calcula la base de datos con la carta; el navegador solo envía producto y cantidad.
- **El historial no se pierde.** Un restaurante con pedidos no se puede borrar (se desactiva). Un producto o una
  categoría se pueden borrar: las líneas de pedido conservan nombre, precio y cantidad.
- **El token del cliente** son 64 caracteres aleatorios generados en su navegador. La base de datos guarda
  solo su hash, en un esquema privado. Reenviar el mismo token devuelve el mismo pedido, así que no se duplica.

## Pruebas

```bash
npm test          # reglas de pedido, modo demo, permisos y variables de entorno (Vitest)
npm run test:db   # seguridad del SQL: necesita un PostgreSQL LOCAL (no Supabase)
```

`npm run test:db` crea una base de datos desechable `turestaurante_test` en el PostgreSQL al que apunten
`PGHOST`/`PGPORT`/`PGUSER`, carga `supabase/tests/supabase_shim.sql` (imita los roles de Supabase),
`schema.sql` y `seed.sql`, dos veces cada uno, y ejecuta `supabase/tests/security_test.sql`.

## Conectar Supabase paso a paso

1. Crea un proyecto en https://supabase.com (región en Europa, por ejemplo Frankfurt). Guarda la contraseña de
   la base de datos en un gestor de contraseñas.
2. **SQL Editor → New query**: pega `supabase/schema.sql` completo y pulsa **Run**. Después, en otra consulta,
   `supabase/seed.sql` (La Piazza). Ambos se pueden repetir sin duplicar ni borrar nada.
3. **Authentication → Sign In / Providers**: desactiva «Allow new users to sign up».
4. **Authentication → Users → Add user** (marca «Auto Confirm User»). Copia su **User UID** y, en el SQL Editor:
   ```sql
   insert into public.platform_admins (user_id) values ('PEGA-AQUÍ-EL-UID');
   ```
   Para personal de un restaurante (roles: owner, manager, waiter, kitchen):
   ```sql
   insert into public.restaurant_staff (restaurant_id, user_id, role)
   values ('5e5e0000-0000-4000-8000-000000000001', 'PEGA-AQUÍ-EL-UID', 'kitchen');
   ```
5. **Advisors → Security Advisor**: no debe aparecer ninguna tabla sin RLS.
6. **Project Settings → API**: copia la **Project URL** y la clave **anon / publishable** (nunca `service_role`
   ni `secret`). En tu `.env`: `VITE_DATA_BACKEND=supabase`, `VITE_SUPABASE_URL=…`, `VITE_SUPABASE_ANON_KEY=…`.
   Si te equivocas de clave, la app se niega a arrancar y te lo explica.
7. `npm run dev` y comprueba: un pedido en caja desde una ventana de incógnito (`#pedir-la-piazza-mesa-5`)
   aparece en el panel y en cocina tras iniciar sesión; el cliente ve el cambio de estado en unos segundos.

## Contraseñas del personal

- **¿Has olvidado tu contraseña?** (pantalla de inicio de sesión): envía un correo con un enlace que vuelve a la app.
  Supabase responde igual exista o no el email, así que no revela qué cuentas existen.
- Al abrir el enlace, la app muestra **«Elige una contraseña nueva»**. Hasta guardarla no se puede usar el panel,
  la cocina ni la administración; después se aplican los permisos normales del rol. Un enlace caducado o ya usado
  muestra un aviso y no abre sesión.
- **Contraseña** (junto a «Salir»): cambia la contraseña con la sesión iniciada. Pide la actual y no cierra esta
  sesión; opcionalmente cierra las de otros dispositivos.
- Todo usa Supabase Auth con la sesión del propio usuario y la clave pública. No hace falta `service_role`.

Configuración necesaria en Supabase (**Authentication → URL Configuration**):

- **Site URL**: la dirección de la app (en local, `http://localhost:5173`).
- **Redirect URLs**: añade `http://localhost:5173/**` (y más adelante el dominio real). Si la dirección no está en
  esta lista, Supabase envía el enlace a la Site URL.

El servidor de correo incluido en Supabase limita los envíos por hora: no pidas muchos enlaces seguidos.

## Pagos reales (fase siguiente, no implementada)

La base de datos ya está preparada; falta la pasarela. **Nada en la app llama todavía a estas funciones.**

1. **Edge Function `create-checkout`** (con la clave secreta, guardada como secreto de Supabase, nunca en `VITE_*`):
   lee `total_cents` del pedido, abre el cobro en la pasarela por ese importe y llama a
   `payment_checkout_started(pedido, referencia, importe)`. Si esa llamada falla (por ejemplo, el cliente pasó a
   caja mientras tanto), debe **anular el cobro en la pasarela**.
2. **Edge Function `payment-webhook`**: verifica la **firma** del aviso del proveedor y llama a
   `payment_record_result(id_del_aviso, referencia, 'pagado' | 'fallido' | 'expirado', importe_cobrado)`.
   - El mismo aviso repetido se procesa una sola vez.
   - Solo marca `pagado_verificado` si la referencia es la del cobro vigente, el importe coincide con el total y el
     pedido sigue esperando ese pago.
   - Cualquier otro caso (pedido pasado a caja, cancelado, intento anterior, importe distinto, referencia
     desconocida) queda en `payment_events` como **`requiere_revision`**: hay que revisarlo y, si procede,
     devolver el dinero. Falta una pantalla para que owner y manager vean esas revisiones.
3. Activar `online_payment_enabled` del restaurante desde el SQL Editor (la app no puede) y habilitar la opción
   en `src/config.ts` (`onlinePaymentsAvailable`). `src/services/payments/stripeProvider.ts` es solo un esqueleto.

## Rutas

Se usan rutas por hash para que funcione en cualquier alojamiento estático. Los QR ya codifican la URL de producción
prevista (`VITE_PUBLIC_BASE_URL/r/<slug>/mesa/<n>`); al pasar a un router con rutas reales, hay que mapearlas a la vista de cliente.
