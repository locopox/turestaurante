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

## Puesta en marcha

```bash
npm install
cp .env.example .env
npm run dev
```

`npm run build` genera `dist/`. `npm run build:single` genera un único HTML autocontenido en `dist-single/`.

## Pagos

- La pasarela de la demo es **simulada**: no pide datos de tarjeta ni hace cargos. Su mejor resultado es el estado
  `simulado` («Pago simulado»), nunca `pagado_verificado`.
- `pagado_verificado` queda reservado al servidor: solo debe asignarlo un webhook firmado del proveedor
  (el esquema SQL incluye un trigger que lo impide desde el cliente).
- Los pedidos con pago online pendiente no aparecen en cocina hasta completar el pago.

## Estructura

```
src/
  types.ts                     Modelo de dominio (Restaurant, Product, Order, estados…)
  config.ts                    Lee las variables VITE_*
  data/seed.ts                 Datos de demostración
  services/
    dataService.ts             Interfaz única de datos (la UI solo usa esto)
    mock/mockDataService.ts    Implementación local (fase 1)
    supabase/…                 Implementación Supabase (fase 2, sin probar aún contra un proyecto real)
    payments/                  PaymentProvider: simulado y esqueleto de Stripe
    index.ts                   Elige implementación según .env
  views/customer|staff|kitchen|admin
supabase/schema.sql            Tablas, RPC create_order, RLS y tiempo real
```

## Conectar Supabase (fase 2)

1. Crear proyecto y ejecutar `supabase/schema.sql`.
2. En `.env`: `VITE_DATA_BACKEND=supabase`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
3. Añadir autenticación para personal (`restaurant_staff`) y administradores (`platform_admins`); hoy las vistas de
   panel, cocina y admin no tienen login.
4. Para que el cliente siga su pedido sin cuenta, exponer una RPC de lectura por id de pedido.

## Conectar un proveedor de pagos

1. Edge Function `create-checkout`: lee el importe del pedido en la base de datos y crea la sesión con la clave secreta.
2. Edge Function `payment-webhook`: verifica la firma y actualiza `payment_status` con la service role.
3. En `.env`: `VITE_PAYMENT_PROVIDER=stripe`. Ver `src/services/payments/stripeProvider.ts`.

## Rutas

Se usan rutas por hash para que funcione en cualquier alojamiento estático. Los QR ya codifican la URL de producción
prevista (`VITE_PUBLIC_BASE_URL/r/<slug>/mesa/<n>`); al pasar a un router con rutas reales, hay que mapearlas a la vista de cliente.
