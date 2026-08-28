# Maguirejuve · Sistema de Ventas, Precios y Stock

Aplicación de producción para gestionar ventas, precios, stock y comisiones de Maguirejuve
(cosmética/estética). Reemplaza la base en Excel/AppSheet por una arquitectura relacional
transaccional, con el precio y el stock **siempre recalculados en el servidor**.

> Ver `docs/architecture.md` para el diseño completo (con diagrama ER), `docs/database.md` para el
> esquema y RLS, `docs/pricing.md` para el motor de precios y `docs/inventory.md` para el modelo de
> stock.

## Stack

- **Next.js 16** (App Router) + **React 19** + **TypeScript estricto**
- **Tailwind CSS v4** + componentes estilo shadcn/ui (escritos a mano en `components/ui/`, sin
  dependencia de la CLI de shadcn)
- **Supabase**: PostgreSQL + Auth + Row Level Security + Database Functions (RPC transaccionales)
- **Vercel** para el deploy de la app
- **Zod** para validación de inputs
- Zona horaria de negocio: `America/Argentina/Buenos_Aires`. Moneda: ARS. Todo importe:
  `numeric(14,2)`.

## Principio no negociable

El navegador **nunca** calcula el precio final ni descuenta stock. `create_sale(...)` (una función
SQL `SECURITY DEFINER`) recalcula todo dentro de una única transacción atómica: precio vigente,
condición aplicable, stock disponible (expandiendo kits), comisión. Si algo falla, no queda nada
guardado a medias. Ver `docs/pricing.md` y `docs/inventory.md`.

## Estructura del repositorio

```
app/                    # Next.js App Router
  login/                 # Login (público)
  (app)/                 # Rutas protegidas (requieren sesión — ver proxy.ts)
    ventas/nueva/         # Pantalla más importante: registrar una venta
    ventas/[id]/           # Detalle + cancelación
    stock/                 # Stock actual + movimientos
    clientes/
    admin/                 # Precios, promociones, doctoras, usuarios (solo admin)
    dashboard/             # KPIs y gráficos (solo admin)
  api/integrations/web-orders/  # Endpoint idempotente para pedidos externos
components/
  ui/                    # Primitivos estilo shadcn/ui (Button, Card, Dialog, Select, ...)
  auth/ sales/ inventory/ dashboard/ layout/ shared/
lib/
  supabase/              # Clientes browser/server/service-role + refresh de sesión (proxy.ts)
  pricing/               # Espejo TS del motor de precios (solo para tests/tipos)
  validation/            # Esquemas Zod
  utils.ts
types/database.ts        # Tipos de la base (escritos a mano, ver nota abajo)
supabase/
  migrations/            # Todo el esquema, versionado y numerado (reconstruible desde cero)
  seed.sql / migrations/..._seed_data.sql   # Datos iniciales reales, idempotentes
  tests/database/         # Tests pgTAP (RLS + RPC de negocio)
docs/                    # architecture.md, database.md, pricing.md, inventory.md
tests/                   # Vitest: motor de precios (espejo TS)
```

## Desarrollo local

### 1. Requisitos

- Node.js 20.9+
- [Supabase CLI](https://supabase.com/docs/guides/cli) + Docker (para correr Supabase local)

### 2. Instalar dependencias

```bash
npm install
```

### 3. Levantar Supabase local y aplicar el esquema

```bash
supabase start          # levanta Postgres/Auth/Studio local con Docker
supabase db reset        # aplica supabase/migrations/*.sql desde cero (incluye el seed)
```

`supabase db reset` corre las migraciones en orden y deja cargados: sedes, canales, medios de pago,
condiciones de precio, catálogo completo, kits, lista de precios inicial, doctoras y el stock inicial
migrado (incluyendo el movimiento histórico de +20 Vitamina C en Sede 25 del 25/08/2026). Es
idempotente: correrlo de nuevo no duplica nada.

Después de `supabase start`, copiá la URL y la publishable key que imprime a `.env.local` (ver
`.env.example`).

### 4. Crear tu primer usuario admin

1. Registrate desde `/login` → "¿No tenés cuenta?" (o creá el usuario desde Supabase Studio →
   Authentication). El trigger `handle_new_auth_user` crea automáticamente un `profiles` con
   `role = 'seller'` y `active = false`.
2. Como superusuario (Supabase Studio → SQL Editor), activate y asigná rol admin + acceso a ambas
   sedes:
   ```sql
   update public.profiles set role = 'admin', active = true,
     can_view_financial_reports = true, can_adjust_stock = true
   where id = '<tu-user-id>';

   insert into public.profile_locations (profile_id, location_id)
   select '<tu-user-id>', id from public.stock_locations;
   ```

### 5. Correr la app

```bash
npm run dev
```

## Tests

```bash
npm run test        # Vitest: motor de precios (espejo TS), los 12 casos del prompt maestro
supabase test db     # pgTAP: RPC de negocio (create_sale/cancel_sale) + RLS, contra Supabase local
```

## Calidad

```bash
npm run lint
npm run typecheck
npm run build
```

CI (`.github/workflows/ci.yml`) corre install → lint → typecheck → test → build en cada Pull
Request.

## Deployment

- **Vercel**: conectar el repo, branch `main` = producción, Pull Requests = Preview Deployments.
  Variables de entorno (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`,
  `SUPABASE_SERVICE_ROLE_KEY`) configuradas por ambiente (Development/Preview/Production) — nunca en
  el repo.
- **Supabase**: `supabase link --project-ref <ref>` y `supabase db push` para aplicar las migraciones
  al proyecto de producción. Configurar las Redirect URLs de Auth (localhost, preview de Vercel,
  dominio de producción) en Authentication → URL Configuration.

## Datos: qué es seed y qué es transaccional

- **Seed (versionado en Git, `supabase/migrations/..._seed_data.sql`)**: sedes, canales, medios de
  pago, condiciones de precio, catálogo de productos/kits, lista de precios inicial, doctoras, y la
  migración de stock inicial + el movimiento histórico conocido (Sede 25, +20 Vitamina C). Es
  idempotente — correrlo de nuevo no duplica ni pisa precios ya versionados por un admin.
- **Transaccional (vive solo en la base, nunca en Git)**: ventas, movimientos de stock posteriores,
  clientes, ajustes, transferencias, cambios de precio hechos desde `/admin/precios`.

## Nota sobre `types/database.ts`

Está escrito a mano a partir del esquema SQL (no hay proyecto Supabase en producción todavía para
correr `supabase gen types`). Cuando el proyecto esté linkeado, reemplazar por:

```bash
supabase gen types typescript --linked > types/database.ts
```

y volver a agregar los tipos de `PricingItemInput` / `PricingQuoteResult` / `CreateSaleResult` que
usa `lib/pricing`.

## Decisiones de negocio por defecto

Documentadas en `docs/architecture.md` y `docs/pricing.md`: Web es un canal (no un depósito) y
siempre indica sede de despacho; stock negativo no permitido por defecto; descuentos no acumulables
(precedencia configurable vía `price_conditions.priority`); comisión solo sobre líneas
`commissionable`; cancelación repone stock automáticamente; precio histórico inmutable; costos de
producto fuera del alcance del MVP (arquitectura preparada para incorporarlos).
