# Arquitectura — Maguirejuve Ventas

## 1. Stack

| Capa | Tecnología |
|---|---|
| Frontend | Next.js 16 (App Router), React 19, TypeScript estricto |
| UI | Tailwind CSS v4, shadcn/ui |
| Backend de datos | Supabase (PostgreSQL, Auth, RLS, RPC/Database Functions) |
| Hosting | Vercel (app) + Supabase (DB/Auth) |
| Validación | Zod (frontend y server actions) |
| Tests | Vitest (unit/integration), Playwright (E2E) |
| CI | GitHub Actions |

Zona horaria de negocio: `America/Argentina/Buenos_Aires`. Moneda: ARS. Todo importe es `numeric(14,2)`.

## 2. Principio rector

**El navegador nunca calcula el precio final ni descuenta stock.** El frontend solo muestra una
estimación (llamando al mismo RPC de solo-lectura que usa el backend). La confirmación de una venta
ejecuta `create_sale(...)`, una función `SECURITY DEFINER` en PostgreSQL que:

1. revalida permisos y ubicación del vendedor,
2. vuelve a consultar precios vigentes,
3. vuelve a determinar la condición de precio aplicable,
4. bloquea (`FOR UPDATE`) las filas de inventario involucradas,
5. valida stock (expandiendo kits en sus componentes),
6. escribe venta + detalle + movimientos de stock + comisión,
7. o revierte todo si cualquier paso falla (transacción atómica).

Ninguna cantidad "final" (subtotal, descuento, total, comisión, movimiento de stock) se acepta desde
el cliente. El cliente solo envía: productos + cantidades, medio de pago, sucursal/canal, cliente y
doctora opcionales.

## 3. Modelo de datos (resumen)

Ver el detalle completo (columnas, constraints, índices) en `docs/database.md` y en
`supabase/migrations/`. Los conceptos clave:

- **`stock_locations`**: dónde vive físicamente el stock (Sede 37, Sede 25). No confundir con canal.
- **`sales_channels`**: cómo se originó la venta (Sucursal, Web). Una venta Web indica además
  `location_id` de despacho (`fulfillment_location`).
- **`products`** + **`kit_components`**: catálogo. Los kits (`track_stock = false`) descuentan stock
  de sus componentes, nunca de un contador propio.
- **`price_conditions`** + **`product_prices`**: el motor de precios. Los precios son historizados
  (`valid_from` / `valid_until`); cambiar un precio hoy nunca reescribe una venta pasada porque
  `sale_items` guarda un snapshot.
- **`sales`** + **`sale_items`**: cabecera y detalle de venta. `sale_number` es legible
  (`MJ-<sede>-<fecha>-<secuencia>`).
- **`inventory_balances`**: saldo actual por sede/producto — es una vista materializada del ledger,
  nunca se edita a mano.
- **`stock_movements`**: ledger auditable. Todo cambio de `inventory_balances` proviene de un
  movimiento con signo (`quantity_delta`).
- **`stock_transfers`** + **`stock_transfer_items`**: transferencias atómicas entre sedes.
- **`customers`**, **`doctors`**: opcionales en una venta.
- **`profiles`** + **`profile_locations`**: usuarios y a qué sedes tienen acceso (incluso los admin).
- **`audit_logs`**: bitácora de acciones sensibles.
- **`app_settings`**: parámetros de negocio (fila única).

### Diagrama entidad-relación

```mermaid
erDiagram
    STOCK_LOCATIONS ||--o{ PROFILE_LOCATIONS : "acceso"
    PROFILES ||--o{ PROFILE_LOCATIONS : "tiene"
    PROFILES ||--o{ SALES : "vende"
    STOCK_LOCATIONS ||--o{ SALES : "despacha"
    SALES_CHANNELS ||--o{ SALES : "origina"
    PAYMENT_METHODS ||--o{ SALES : "cobra"
    CUSTOMERS ||--o{ SALES : "compra"
    DOCTORS ||--o{ SALES : "deriva"
    PRICE_CONDITIONS ||--o{ SALES : "aplica"
    SALES ||--|{ SALE_ITEMS : "contiene"
    PRODUCTS ||--o{ SALE_ITEMS : "vendido en"
    PRODUCTS ||--o{ KIT_COMPONENTS : "kit"
    PRODUCTS ||--o{ KIT_COMPONENTS : "componente"
    PRODUCTS ||--o{ PRODUCT_PRICES : "tiene precio"
    PRICE_CONDITIONS ||--o{ PRODUCT_PRICES : "define"
    STOCK_LOCATIONS ||--o{ INVENTORY_BALANCES : "guarda"
    PRODUCTS ||--o{ INVENTORY_BALANCES : "saldo"
    STOCK_LOCATIONS ||--o{ STOCK_MOVEMENTS : "afecta"
    PRODUCTS ||--o{ STOCK_MOVEMENTS : "afecta"
    SALES ||--o{ STOCK_MOVEMENTS : "genera"
    STOCK_TRANSFERS ||--|{ STOCK_TRANSFER_ITEMS : "contiene"
    STOCK_TRANSFERS ||--o{ STOCK_MOVEMENTS : "genera"
    PROFILES ||--o{ AUDIT_LOGS : "actúa"

    STOCK_LOCATIONS {
      uuid id PK
      text code UK
      text short_code
      text name
      text type
      bool active
    }
    SALES_CHANNELS {
      uuid id PK
      text code UK
      text name
      bool active
    }
    PROFILES {
      uuid id PK
      text full_name
      text role
      bool active
      bool can_view_financial_reports
      bool can_adjust_stock
    }
    PROFILE_LOCATIONS {
      uuid profile_id FK
      uuid location_id FK
    }
    PRODUCTS {
      uuid id PK
      text sku UK
      text name
      text product_type
      text category
      text unit
      bool track_stock
      bool commissionable
      bool promo_eligible
      numeric default_min_stock
      bool active
    }
    KIT_COMPONENTS {
      uuid id PK
      uuid kit_product_id FK
      uuid component_product_id FK
      numeric quantity
    }
    PAYMENT_METHODS {
      uuid id PK
      text code UK
      text name
      bool active
      int sort_order
    }
    PRICE_CONDITIONS {
      uuid id PK
      text code UK
      text name
      text rule_type
      uuid payment_method_id FK
      numeric min_units
      numeric discount_percent
      int priority
      bool combinable
      bool active
    }
    PRODUCT_PRICES {
      uuid id PK
      uuid product_id FK
      uuid price_condition_id FK
      numeric amount
      timestamptz valid_from
      timestamptz valid_until
      bool active
    }
    CUSTOMERS {
      uuid id PK
      text dni
      text full_name
      text whatsapp
      text email
      bool active
    }
    DOCTORS {
      uuid id PK
      text code UK
      text full_name
      numeric commission_percent
      bool active
    }
    SALES {
      uuid id PK
      text sale_number UK
      timestamptz sold_at
      uuid location_id FK
      uuid sales_channel_id FK
      uuid seller_id FK
      uuid customer_id FK
      uuid doctor_id FK
      uuid payment_method_id FK
      uuid applied_price_condition_id FK
      numeric subtotal
      numeric discount_total
      numeric total
      numeric commission_total
      text status
      text external_source
      text external_order_id
    }
    SALE_ITEMS {
      uuid id PK
      uuid sale_id FK
      uuid product_id FK
      numeric quantity
      numeric list_unit_price
      numeric sale_unit_price
      numeric line_total
      bool commissionable
    }
    INVENTORY_BALANCES {
      uuid location_id FK
      uuid product_id FK
      numeric quantity
    }
    STOCK_MOVEMENTS {
      uuid id PK
      timestamptz occurred_at
      uuid location_id FK
      uuid product_id FK
      text movement_type
      numeric quantity_delta
      uuid sale_id FK
      uuid transfer_id FK
    }
    STOCK_TRANSFERS {
      uuid id PK
      uuid from_location_id FK
      uuid to_location_id FK
      text status
    }
    STOCK_TRANSFER_ITEMS {
      uuid id PK
      uuid transfer_id FK
      uuid product_id FK
      numeric quantity
    }
    AUDIT_LOGS {
      uuid id PK
      uuid user_id FK
      text action
      text entity_type
      uuid entity_id
      jsonb metadata
    }
```

## 4. Motor de precios (`pricing-engine`)

Implementado **una sola vez, en SQL** (`fn_pricing_quote`, ver `docs/pricing.md`), y expuesto a través
de dos caminos que comparten exactamente la misma función:

- `quote_sale(...)` — RPC de solo lectura, la usa el frontend para mostrar la estimación en tiempo
  real mientras la vendedora arma el carrito.
- `create_sale(...)` — llama internamente a `fn_pricing_quote` y si el resultado es válido, persiste.

Existe además un espejo en TypeScript puro (`lib/pricing/engine.ts`) usado para:
- tests unitarios rápidos sin base de datos (los 12 casos de la sección 41 del prompt),
- tipos compartidos (`PricingInput`, `PricingResult`) entre frontend y backend.

El módulo TypeScript **no decide ventas reales** — es documentación ejecutable de la regla de negocio
y un espejo para test; la fuente de verdad en producción es siempre la función SQL.

Precedencia (configurable vía `price_conditions.priority`, menor número = mayor precedencia):

1. `QTY_3_PLUS` (3+ productos)
2. `QTY_2` (2 productos)
3. `CASH` (efectivo)
4. `TRANSFER` (transferencia)
5. `INSTALLMENTS_3` (3 cuotas)
6. `LIST` (lista — siempre aplica, es el fallback)

Las condiciones **no se acumulan**: se elige la de mayor precedencia cuya regla matchea
(`rule_type = 'QUANTITY'` con `total_qty >= min_units`, o `rule_type = 'PAYMENT_METHOD'` con el medio
de pago elegido, o `rule_type = 'BASE'` que siempre matchea). Una vez elegida la condición, **se
exige** que exista un precio válido, positivo y vigente para *cada* producto del carrito bajo esa
condición exacta — si falta, la venta se rechaza (nunca se sustituye por otra condición ni por $0).

## 5. Inventario

`inventory_balances` es un **caché derivado** del ledger `stock_movements`. Todo movimiento de stock
(venta, cancelación, ajuste, transferencia, ingreso) pasa por `stock_movements` y actualiza el saldo
dentro de la misma transacción. Los kits nunca tienen saldo propio: su disponibilidad se calcula al
vuelo (`fn_kit_buildable_qty`) como el mínimo, entre sus componentes, de `saldo / cantidad requerida`.

## 6. Permisos y RLS

Dos roles (`admin`, `seller`), acceso a sedes vía `profile_locations` (ambos roles pueden estar
restringidos a un subconjunto de sedes). RLS habilitada en toda tabla expuesta al cliente; el
`service_role` nunca llega al navegador. Detalle de policies en `docs/database.md` §RLS.

## 7. Estructura del repositorio

```
app/                        # Next.js App Router
  (auth)/login/
  (app)/dashboard/
  (app)/ventas/[nueva|[id]]
  (app)/stock/[movimientos]
  (app)/clientes/
  (app)/admin/[precios|promociones|doctores|usuarios]
  api/integrations/web-orders/
components/
  ui/                        # shadcn/ui primitives
  sales/ inventory/ dashboard/ shared/
lib/
  supabase/                  # browser/server/proxy clients
  pricing/                   # motor de precios TS (espejo + tests)
  inventory/                 # helpers de expansión de kits, formato
  permissions/
  validation/                # esquemas Zod
  utils/
types/
supabase/
  migrations/
  seed.sql
tests/
docs/
```

## 8. Fases de implementación

Ver checklist en el README. Este documento se actualiza si el esquema cambia.

## 9. Mejoras post-MVP (2026-02)

Segunda ronda de trabajo sobre la app ya en producción, en 12 bloques
incrementales (migraciones `20260201000001` a `20260201000014`), cada uno
commiteado por separado:

1. **Depósito + stock manual admin**: nueva `stock_locations` tipo
   `warehouse` (arquitectura de sedes ya era genérica, no hizo falta
   migrar nada más); RPC `set_stock` — admin fija el stock final de un
   producto, la RPC calcula el diff y lo aplica como un movimiento
   `ADJUSTMENT_SET` auditable (nunca un `UPDATE` ciego sobre
   `inventory_balances`).
2. **Venta sin costo + medio de pago CARD_1**: `sales.is_free_sale` +
   motivo obligatorio (enum `free_sale_reason`), comisión forzada a 0,
   precio de lista solo informativo. `sale_items` relaja su check de
   precio a `>= 0` con un trigger que ata cualquier $0 a una venta
   marcada `is_free_sale` (o, desde el bloque 7, a una unidad gratis de
   promoción 3x2). `CARD_1` es una `price_condition` más — el precio
   nunca queda hardcodeado en el frontend.
3. **Clientes**: DNI normalizado (trigger, solo dígitos) para que el
   índice único detecte duplicados escritos distinto; fix de un bug real
   donde la policy de UPDATE solo dejaba editar al creador (RLS filtraba
   en silencio, sin error); soft-delete exclusivo de admin vía
   `deactivate_customer`. En Nueva Venta, flujo DNI-primero con
   autobúsqueda debounced.
4. **CRUD de productos** (`/admin/productos`): alta/edición completa,
   nunca hard-delete (no hay policy de DELETE en `products`, ni la hubo).
5. **CRUD de kits** (`/admin/kits`, nueva ruta): alta/edición del
   producto-kit + composición dinámica de `kit_components` en el mismo
   formulario. El stock del kit sigue derivándose de sus componentes
   (`fn_kit_buildable_qty`), nunca un contador propio.
6. **Administración de usuarios**: edición de nombre/email (el email
   vive en `auth.users`, se sincroniza vía Auth Admin API con la service
   role key) y reset de contraseña (contraseña provisoria generada
   server-side, nunca persistida, se muestra una sola vez). Bug de
   seguridad real encontrado y corregido: la policy de auto-edición de
   `profiles` no restringía columnas — cualquier usuario podía
   auto-promoverse a admin llamando a la tabla directo. Trigger
   `fn_prevent_self_privilege_escalation` lo bloquea (exceptúa
   service_role y sesiones sin JWT de usuario final).
7. **Motor de promociones** (`/admin/promociones` — el nombre viejo con
   `price_conditions` se movió a `/admin/condiciones-precio`): tablas
   nuevas `promotions`/`promotion_products`. Tres tipos — `THREE_FOR_TWO`
   (generalizado: cada N unidades, la más barata gratis, ranking cruzando
   productos), `DUO_PERCENT` (% en un par específico) y `KIT_PERCENT` (%
   en un kit). Se evalúan en `fn_apply_promotions`, después de resolver
   el precio por `price_conditions`, nunca antes. Un producto pertenece a
   lo sumo a una promoción activa a la vez — esa regla de diseño le da a
   `stackable` una semántica simple: una no-combinable que matchea gana
   sola, si no matchea ninguna se aplican todas las combinables (nunca se
   pisan). Snapshot en `sale_items.applied_promotion_id` — editar o
   desactivar una promoción no cambia ventas ya confirmadas.
8. **Reportes**: `product_revenue_report` (facturación completa por
   producto/kit, un kit se atribuye a sí mismo, no a sus componentes) y
   `doctor_sales_detail` (drill-down de "Ventas por médica" — resumen,
   productos, listado de operaciones — usando `sales.commission_total`
   ya persistido, nunca recalculado con el % actual de la doctora).
9. **Fix de bug**: alertas de stock bajo falsas para vendedoras de Sede
   25 — `product_stock_status`/`kit_availability` son vistas sin filtro
   de sede propio; un `CROSS JOIN` con sedes inaccesibles + `LEFT JOIN`
   contra `inventory_balances` (bloqueado por RLS) producía filas
   fantasma con `quantity = 0`. Se agregó `.in("location_id", ...)` en
   los 4 call sites que consultan esas vistas desde el cliente.
10. **Auditoría extendida + confirmaciones**: `fn_audit_table_change`
    (genérica INSERT/UPDATE/DELETE) cablea auditoría a alta de productos,
    clientes, `kit_components` y promociones — huecos reales que
    quedaban tras la auditoría original (solo UPDATE en 4 tablas). Cambio
    de email y reset de contraseña se auditan explícitamente desde el
    Server Action (viven en `auth.users`, fuera del alcance de cualquier
    trigger nuestro). Desactivar un producto/kit/promoción/usuario pide
    confirmación antes de aplicarse.
11. **Responsive**: el botón flotante del carrito de Nueva Venta se
    solapaba con el final del formulario en mobile (padding insuficiente);
    la variante `bottom` de `Sheet` no tenía en cuenta
    `env(safe-area-inset-bottom)`; `DialogContent` no tenía
    `max-h`/`overflow-y-auto` a nivel base — un dialog con contenido
    largo se salía de la pantalla en vez de scrollear. Los tres, corregidos.
12. Rename del título visible "Dashboard" a "Magui Rejuve".

Migraciones nuevas de este trabajo, en orden: `20260201000001`
(Depósito) · `000002`–`000003` (enum + RPC `set_stock`) · `000004`–`000006`
(venta sin costo) · `000007` (CARD_1) · `000008` (clientes: DNI + fix RLS +
`deactivate_customer`) · `000009` (fix autoescalada de privilegios) ·
`000010`–`000012` (promociones: esquema, columnas de snapshot en
`sale_items`, motor) · `000013` (reportes) · `000014` (auditoría
extendida).
