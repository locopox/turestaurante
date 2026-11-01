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
  lib/authRedirect.ts          Enlaces de recuperación de contraseña y reglas de contraseña
  lib/audit.ts                 Textos del registro de auditoría
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
  migrations/                  Migraciones versionadas (fase 3) · migrations_down/: cómo deshacerlas
  tests/                       Pruebas SQL contra un PostgreSQL local
```

## Seguridad con Supabase (resumen)

| Quién | Qué puede hacer |
|---|---|
| Cliente sin cuenta | Leer la carta. Crear pedidos con `create_order`. Leer **solo su pedido** con su token (`get_customer_order`). Pasar de pago online pendiente a caja. Nada más. |
| `kitchen` (cocina) | Ver las comandas de su restaurante con `kitchen_orders` (**sin teléfono, importes ni pagos**; nombre solo en pedidos para recoger) y cambiar su preparación. No lee la tabla de pedidos, no cobra, no cancela, no toca la carta, la configuración ni el equipo. |
| `waiter` (sala) | Ver los pedidos de su restaurante (con el teléfono para avisar al cliente), cambiar la preparación, cobrar en caja y cancelar. |
| `manager` (encargado) | Lo de sala, más la carta y los precios, y el equipo de **sala y cocina** (alta, cambio de función, baja). No toca propietarios ni encargados, ni la configuración del restaurante. |
| `owner` (propietario) | Todo lo anterior en **su** restaurante, la configuración del restaurante, los encargados y el registro de auditoría. No nombra propietarios. |
| Plataforma (`platform_admins`) | Crear restaurantes, cambiar su dirección web, suspenderlos y reactivarlos, gestionar propietarios y leer el registro (sus consultas quedan registradas). **No tiene acceso operativo**: no ve pedidos, cocina ni avisos de pago, ni edita la carta. Una cuenta de plataforma no puede ser personal de ningún restaurante. |
| Servidor (`service_role`) | Administrar restaurantes y carta (desde la fase 6 **no** escribe en `restaurant_staff` ni en `platform_admins`). Sobre pedidos y pagos solo **lee**: los cambia únicamente con `payment_checkout_started` y `payment_record_result`. No tiene permisos sobre tablas ajenas a TuRestaurante. |

- **Equipo**: nadie escribe directamente en `restaurant_staff`. Desde la fase 6 **solo se entra aceptando una
  invitación** (`invitation_accept`); los cambios y bajas siguen con `staff_change_role` y `staff_remove_member`.
  Nadie cambia ni quita su propio acceso, y siempre queda al menos un propietario.
- **Suspensión**: `restaurants.suspended_at` solo lo cambia la plataforma (`platform_set_suspension`). Un restaurante
  suspendido no acepta pedidos aunque su propietario lo marque como abierto; el personal puede terminar los ya hechos.
  El motivo se guarda en el registro, no en la tabla pública de restaurantes.
- **Dirección web (`slug`)**: solo la plataforma puede cambiarla, porque invalida los QR impresos.
- **Registro de auditoría** (`private.audit_log`, solo se añade): altas, cambios y bajas de personal, precios,
  productos, cancelaciones, cobros, pagos verificados, suspensiones, dirección web, apertura y consultas de la
  plataforma. Guarda quién (usuario y tipo), cuándo y qué. Lo leen el propietario (su restaurante) y la plataforma
  con `audit_list`.
- **Modo soporte** (ver abajo): la plataforma solo puede **leer** un restaurante si su propietario lo aprueba,
  durante 2 horas, y cada consulta queda registrada.

### Modo soporte

1. La cuenta de plataforma pide acceso a **un** restaurante con un motivo (Administración → Soporte).
2. **Solo el propietario** de ese restaurante puede aprobarlo o rechazarlo (Administración → Soporte; también ve
   un aviso). Ni la plataforma, ni el encargado, ni el propietario de otro restaurante pueden aprobar.
3. El acceso es de **solo lectura** y dura **exactamente 2 horas** desde la aprobación. El propietario puede
   revocarlo en cualquier momento y quien lo pidió puede terminarlo antes. Nadie puede ampliarlo.
4. Durante el acceso, la plataforma consulta con tres funciones: `support_view_restaurant` (estado, carta y
   equipo por funciones, sin emails), `support_view_orders` (pedidos **sin nombre, teléfono, notas ni referencia
   de pago** del cliente) y `support_view_payment_events`. Cada función comprueba el acceso **en cada llamada**: la
   caducidad, la revocación o dejar de ser plataforma lo cortan al instante, aunque la sesión siga abierta.
5. No hay lectura directa de tablas ni ningún permiso de escritura: la plataforma sigue sin poder cambiar pedidos,
   precios, cobros, productos, equipo ni configuración.
6. Queda registrado quién pide, quién aprueba o rechaza, inicio y caducidad, cada consulta (qué datos), y quién
   revoca o cancela. El propietario lo ve en Administración → Registro. El historial de accesos no se puede borrar.
7. **Una solicitud sin respuesta caduca a las 24 horas** de crearse («Caducada sin respuesta (24 h)»). Ya no se
   puede aprobar, rechazar ni reactivar (lo impide también un trigger, incluso desde el SQL Editor); la plataforma
   tiene que pedir otra. Un acceso aprobado sigue durando 2 horas desde la aprobación y se puede revocar al momento.
8. **Los intentos de consulta denegados quedan registrados** (sin acceso, solicitud pendiente o caducada, acceso
   revocado/caducado, otro restaurante…): quién, qué restaurante, cuándo, qué consulta y el motivo. Las funciones
   `support_view_*` no lanzan error al denegar: devuelven `{ok: false, reason, message}`, así la anotación no se
   deshace. No se guardan contraseñas, tokens ni datos de clientes. Los intentos iguales en 10 minutos se agrupan
   en una fila con un contador, y cada cuenta tiene un máximo de 50 filas por ventana (el resto se suma en una fila
   «Demasiados intentos»), para que nadie pueda llenar la tabla. Nadie puede escribir, modificar ni borrar el
   registro directamente (está en el esquema `private` y protegido por trigger). Lo ven el propietario (solo su
   restaurante, en Administración → Soporte) y la plataforma (`support_denials_list`). Las llamadas sin sesión
   (`anon`) no llegan a ejecutarse, así que no se anotan.

En el modo demo el soporte no está disponible: necesita cuentas reales de plataforma y de propietario separadas.

### Invitaciones (fase 6 · E1 base de datos y E2 Edge Function)

Hechas la base de datos (E1) y la Edge Function `invitations` (E2, ver
[`supabase/functions/invitations/README.md`](supabase/functions/invitations/README.md)), sin desplegar. Las
pantallas (E3) llegarán después: **mientras tanto, «Añadir al equipo» de la app no funciona con Supabase** (ya no
existe `staff_add_member`).

- **Nadie tiene permisos antes de aceptar.** La invitación vive en `private.invitations` (no accesible por la API)
  y ninguna comprobación de permisos la lee. El único alta en un equipo es `invitation_accept(id)`, que exige:
  sesión, el **correo confirmado** de la cuenta igual al de la invitación, pendiente y sin caducar, restaurante no
  suspendido, no ser cuenta de plataforma, no estar ya en el equipo y que **quien invitó siga pudiendo dar esa
  función**. La función concedida es la de la invitación, nunca un parámetro.
- **Quién invita a quién** (`invitation_create`): la plataforma, a cualquier función (los propietarios y
  copropietarios, **solo** ella); el owner, a encargados, sala y cocina; el encargado, a sala y cocina. El manager ve
  todas las invitaciones de su restaurante y gestiona solo las de sala y cocina.
- **Restaurante nuevo** (`platform_create_restaurant`): se crea **cerrado** junto con la invitación de su
  propietario. Desde la app no se puede abrir sin propietario ni mientras esté suspendido.
- **No se revela nada a quien invita**: la respuesta es la misma tenga o no cuenta el correo, y sea de otro
  restaurante o de la plataforma. Si ya tiene cuenta, la verá dentro de TuRestaurante (`my_invitations`) y no se toca
  su contraseña. Una persona puede estar en varios restaurantes con permisos independientes; al salir de uno pierde
  ese acceso al instante y conserva su cuenta y los demás.
- **Caducan a los 7 días.** Una caducada no se acepta, rechaza, reenvía ni reactiva: se crea otra (la antigua queda
  «reemplazada»). Reenviar (`invitation_resend`) crea una nueva con 7 días más: como mucho 3 veces y con 5 minutos
  entre reenvíos. También se pueden **rechazar** (`invitation_decline`) y **revocar** (`invitation_revoke`).
- Si quien invitó pierde la función, deja el equipo o se elimina su cuenta, sus invitaciones pendientes se revocan.
- **Límites**: 20 invitaciones nuevas por hora y persona, 30 pendientes por restaurante.
- **Integridad** (también desde el SQL Editor): el historial no se borra, sus datos no cambian, una invitación
  cerrada no se reactiva y una caducada no se acepta. Auditoría de crear, reenviar, aceptar, rechazar, revocar y
  envíos fallidos, con el **correo enmascarado** (`j***@ejemplo.com`).
- **Entrega de correos** (solo el servidor): cola persistente dentro de cada invitación. `invitation_delivery_claim`
  reserva la entrega de forma atómica (sin duplicados; dice si el correo tiene cuenta y si está confirmada, datos que
  nunca llegan a quien invita), `invitation_delivery_finish` anota el resultado con esa reserva e
  `invitation_delivery_pending` devuelve las atrasadas o interrumpidas. Máximo 3 intentos con espera (5 y 30 min);
  una reserva caduca a los 10 min. El resultado de cada entrega queda en el registro sin restaurante: solo lo ve la
  plataforma (al propietario le revelaría si la persona tenía cuenta).
- **Edge Function `invitations`**: verifica el JWT, deja que SQL decida los permisos con el JWT de quien invita y
  responde en cuanto se crea la invitación. El correo se envía después, en segundo plano (`EdgeRuntime.waitUntil`),
  con la clave secreta solo en el servidor; cada llamada recupera además hasta 5 entregas pendientes. La respuesta es
  la misma tenga o no cuenta el correo. El enlace vuelve siempre a `APP_URL`.
- **Recuperación programada** (`pg_cron` + `pg_net` + Vault, migración `20261105120000`): cada 5 minutos, si hay
  entregas atrasadas o interrumpidas, la base de datos llama a la Edge Function `invitations-recovery` con un secreto
  propio guardado en Vault. Configuración, verificación, desactivación y borrado: ver el README de la función.
- **Nadie** puede cambiar el total, las líneas, la referencia de pago ni los datos de un pedido ya creado (trigger).
- Los precios y totales los calcula la base de datos con la carta; el navegador solo envía producto y cantidad.
- **El historial no se pierde.** Un restaurante con pedidos no se puede borrar (se desactiva). Un producto o una
  categoría se pueden borrar: las líneas de pedido conservan nombre, precio y cantidad.
- **El token del cliente** son 64 caracteres aleatorios generados en su navegador. La base de datos guarda
  solo su hash, en un esquema privado. Reenviar el mismo token devuelve el mismo pedido, así que no se duplica.

## Pruebas

```bash
npm test          # reglas de pedido, modo demo, permisos y variables de entorno (Vitest)
npm run test:db         # seguridad del SQL y entregas simultáneas: necesita un PostgreSQL LOCAL (no Supabase)
npm run test:migration  # migraciones fases 3 a 6: subida, repetición y bajada (PostgreSQL LOCAL)
npm run test:recovery   # recuperación programada: necesita pg_cron en el PostgreSQL LOCAL (si no, se omite)
```

`npm run test:db` crea una base de datos desechable `turestaurante_test` en el PostgreSQL al que apunten
`PGHOST`/`PGPORT`/`PGUSER`, carga `supabase/tests/supabase_shim.sql` (imita los roles de Supabase),
`schema.sql` y `seed.sql`, dos veces cada uno, y ejecuta `supabase/tests/security_test.sql`.

## Migraciones

- `supabase/schema.sql` es el esquema completo (instalación nueva; se puede repetir).
- `supabase/migrations/20261101120000_fase3_seguridad_roles.sql` actualiza una base que ya tiene el esquema
  de la rama `fase2-recuperar-contrasena`. No borra datos.
- `supabase/migrations/20261102120000_fase4_modo_soporte.sql` (después de la anterior) añade el modo soporte.
  No borra datos ni modifica objetos existentes.
- `supabase/migrations/20261103120000_fase5_soporte_caducidad_registro.sql` (después de la anterior) añade la
  caducidad de 24 h de las solicitudes y el registro de consultas denegadas. No borra datos. **Cambia la respuesta
  de `support_view_*`** a `{ok, data}`: hay que desplegar a la vez la versión de la app de esta rama.
- `supabase/migrations/20261104120000_fase6_invitaciones.sql` (después de la anterior) añade las invitaciones. No
  borra ni modifica datos ni cuentas. **Elimina `staff_add_member`** y quita al servidor la escritura en
  `restaurant_staff` y `platform_admins`.
- `supabase/migrations/20261105120000_fase6_recuperacion_programada.sql` (después de la anterior, **solo en
  Supabase**: necesita pg_cron, pg_net y Vault) crea la tarea programada de recuperación. No contiene secretos.
- `supabase/migrations_down/` las deshace (primero la de la recuperación programada; después la de la fase 6, que **borra el historial de invitaciones**,
  también las pendientes, y conserva a quien ya aceptó; después la de la fase 5, que **borra el registro de consultas
  denegadas**). La de la fase 4 **borra el historial de
  accesos de soporte** (el registro de auditoría se conserva); la de la fase 3 **borra el registro de auditoría y
  las suspensiones**.
- `npm run test:migration` comprueba en local la cadena completa: fase 2 → fase 3 → fase 4 → fase 5 → fase 6 es idéntica a una
  instalación nueva, las subidas se pueden repetir, cada bajada restaura la versión anterior y los datos no cambian.

Tras la fase 3, una cuenta de plataforma **no** puede operar restaurantes. Para usar el panel o la cocina de La Piazza
hace falta una cuenta de personal distinta (por ejemplo, un propietario). Desde la fase 6 se invita
(`invitation_create` y la persona la acepta); en una emergencia, desde el SQL Editor:

```sql
insert into public.restaurant_staff (restaurant_id, user_id, role)
select '5e5e0000-0000-4000-8000-000000000001', id, 'owner' from auth.users where email = 'propietario@ejemplo.com';
```

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
