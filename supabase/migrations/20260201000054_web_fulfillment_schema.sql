-- =============================================================================
-- Maguirejuve · 54 · Circuito Ventas Web / Fulfillment / Reservas — BLOQUE B
-- (1/2: schema)
-- =============================================================================
-- Ver informe de auditoría (BLOQUE A) entregado al usuario. Resumen de lo que
-- YA existe y no se toca acá:
--   - WEB ya es sales_channels.code, nunca una stock_location — se mantiene
--     así, sin cambios (20260101000016_web_orders.sql /
--     20260201000028_web_channel_admin_only.sql).
--   - billing_status (facturación) y payment_account_id (cuenta de ingreso)
--     ya existen y son ejes independientes — payment_status (cobro) es un
--     eje NUEVO, no se reutiliza ninguno de los dos.
--   - product_stock_status/kit_availability (disponibilidad hoy: 100%
--     física, sin reservas) no se tocan en este archivo — la vista de
--     disponible-con-reservas se agrega en el archivo de funciones (2/2),
--     sin romper estas dos vistas existentes.
--   - sales.status se queda SIEMPRE en 'confirmed' durante todo el ciclo de
--     vida de un pickup (creado -> pendiente -> entregado). fulfillment_type/
--     fulfillment_status/payment_status son columnas nuevas e independientes
--     — nunca se reutiliza el valor 'draft' del enum sale_status (existe
--     desde la migración inicial pero nunca se usó en ningún lado; mezclarlo
--     acá rompería las guardas de create_sale_exchange/create_sale_return
--     que hoy exigen status = 'confirmed').
--
-- Decisión de nombres (aprobada en la ronda de refinamiento): la columna de
-- la reserva que registra su liberación se llama `released_at` (no
-- `cancelled_at` del pedido original) para que coincida exactamente con el
-- valor del enum de estado `RELEASED` — evita la ambigüedad de tener un
-- estado "RELEASED" con una columna "cancelled_at".
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.sale_fulfillment_type as enum ('PICKUP', 'SHIPPING');

comment on type public.sale_fulfillment_type is
  'Cómo se le entrega el pedido al cliente. Exclusivo del canal Web (sales.sales_channel_id '
  'con code=WEB) — null para cualquier otra venta. PICKUP siempre necesita pickup_location_id '
  '(SED-25 o SED-37, nunca Depósito); SHIPPING siempre sale de Depósito.';

-- Sin READY: no hay ningún paso operativo real entre "creado" y "retirado"
-- para un pickup (se prepara en el momento, no hay picking previo separado)
-- — agregarlo ahora sería un estado sin uso, tal como se pidió evitar.
create type public.sale_fulfillment_status as enum ('PENDING_PICKUP', 'DELIVERED', 'SHIPPED');

comment on type public.sale_fulfillment_status is
  'PENDING_PICKUP/DELIVERED son el ciclo de un PICKUP. SHIPPED se asigna una única vez, en el '
  'momento de crear un pedido SHIPPING (el envío ya salió de Depósito de inmediato) — nunca pasa '
  'por PENDING_PICKUP.';

create type public.sale_payment_status as enum ('PAID', 'PENDING');

comment on type public.sale_payment_status is
  'Eje de COBRO, independiente de billing_status (facturación) y de fulfillment_status (entrega). '
  'Exclusivo del canal Web — toda venta no-Web sigue asumiendo cobro inmediato (columna null, '
  'nunca se le exige valor). Una venta Web puede estar PENDING de cobro y a la vez PENDING_PICKUP '
  'o ya DELIVERED — son dimensiones distintas, nunca se mezclan.';

create type public.stock_reservation_status as enum ('ACTIVE', 'CONSUMED', 'RELEASED');

comment on type public.stock_reservation_status is
  'ACTIVE: compromiso físico vigente, cuenta contra disponible. CONSUMED: se entregó, ya generó '
  'su movimiento SALE real. RELEASED: se liberó sin entregar (venta cancelada antes del retiro) — '
  'nunca vuelve a ACTIVE, nunca se borra la fila (ledger auditable, igual que stock_movements).';

-- ---------------------------------------------------------------------------
-- sales: columnas nuevas de fulfillment/pago. Todas nullable — solo se
-- completan para el canal Web (fn_create_sale_core lo exige/prohíbe según
-- corresponda, ver archivo 2/2). No se puede expresar "obligatorio solo si
-- sales_channel_id = WEB" como CHECK de tabla (necesitaría un join a
-- sales_channels, no permitido en un check constraint) — esa validación
-- queda exclusivamente en el backend (fn_create_sale_core), igual que ya
-- pasa hoy con billing_status (comentario textual de 20260201000024:
-- "Se decide SIEMPRE en el backend... nunca lo elige el frontend").
-- ---------------------------------------------------------------------------
alter table public.sales
  add column fulfillment_type public.sale_fulfillment_type,
  add column fulfillment_status public.sale_fulfillment_status,
  add column payment_status public.sale_payment_status,
  add column pickup_location_id uuid references public.stock_locations (id),
  add column delivered_at timestamptz,
  add column delivered_by uuid references public.profiles (id);

comment on column public.sales.fulfillment_type is
  'PICKUP o SHIPPING. Null para toda venta no-Web (incluida Web histórica previa a esta migración '
  '— backfill imposible/no deseado: no hay forma de saber retroactivamente cómo se entregó).';
comment on column public.sales.fulfillment_status is
  'Ver sale_fulfillment_status. Null para toda venta no-Web.';
comment on column public.sales.payment_status is
  'PAID o PENDING. Null para toda venta no-Web (esas siempre se asumen cobradas de inmediato, '
  'como siempre funcionó). NUNCA depende de billing_status/invoiced_at — son ejes distintos.';
comment on column public.sales.pickup_location_id is
  'Sede de retiro (SED-25/SED-37) para un PICKUP. Igual a location_id en ese caso — se guarda '
  'aparte, explícito, para que la bandeja de Notificaciones filtre por esta columna sin tener que '
  'repetir la condición fulfillment_type=PICKUP en cada consulta. Null para SHIPPING y para toda '
  'venta no-Web.';
comment on column public.sales.delivered_at is 'Momento de la entrega física real de un PICKUP. Null hasta entonces.';
comment on column public.sales.delivered_by is 'Quién ejecutó deliver_web_pickup(). Null hasta la entrega.';

alter table public.sales
  add constraint sales_fulfillment_consistency check (
    (fulfillment_type is null and fulfillment_status is null and payment_status is null and pickup_location_id is null)
    or (
      fulfillment_type = 'PICKUP'
      and fulfillment_status in ('PENDING_PICKUP', 'DELIVERED')
      and payment_status is not null
      and pickup_location_id is not null
    )
    or (
      fulfillment_type = 'SHIPPING'
      and fulfillment_status = 'SHIPPED'
      and payment_status is not null
      and pickup_location_id is null
    )
  ),
  add constraint sales_delivered_consistency check (
    (fulfillment_status = 'DELIVERED' and delivered_at is not null and delivered_by is not null)
    or (fulfillment_status is distinct from 'DELIVERED' and delivered_at is null and delivered_by is null)
  );

-- Cubre la bandeja de Notificaciones (BLOQUE D, todavía no implementado):
-- "pedidos PENDING_PICKUP de mi sede", filtrado y ordenado igual que
-- sales_billing_pending_idx ya hace para facturación.
create index sales_pickup_pending_idx
  on public.sales (pickup_location_id, sold_at)
  where status = 'confirmed' and fulfillment_status = 'PENDING_PICKUP';

comment on index public.sales_pickup_pending_idx is
  'Cubre la futura consulta de Notificaciones: status=confirmed AND fulfillment_status='
  'PENDING_PICKUP, filtrado por sede (pickup_location_id) y ordenado por sold_at.';

-- ---------------------------------------------------------------------------
-- sale_stock_reservations: compromiso físico exacto al momento de crear el
-- pedido. Para un kit: una fila POR COMPONENTE FÍSICO (nunca una fila
-- "kit") — mismo criterio ya usado en stock_movements/sale_items para no
-- depender jamás de kit_components vigente (ver 20260201000052/053: la
-- composición histórica real es la única fuente de verdad).
-- ---------------------------------------------------------------------------
create table public.sale_stock_reservations (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales (id),
  sale_item_id uuid not null references public.sale_items (id),
  location_id uuid not null references public.stock_locations (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null check (quantity > 0),
  status public.stock_reservation_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id),
  consumed_at timestamptz,
  released_at timestamptz,
  constraint sale_stock_reservations_status_consistency check (
    (status = 'ACTIVE' and consumed_at is null and released_at is null)
    or (status = 'CONSUMED' and consumed_at is not null and released_at is null)
    or (status = 'RELEASED' and released_at is not null and consumed_at is null)
  )
);

comment on table public.sale_stock_reservations is
  'Ledger de compromisos físicos de stock por PICKUP web. Nunca se borra ni se reescribe una fila '
  '(igual criterio que stock_movements) — el ciclo de vida completo (ACTIVE -> CONSUMED/RELEASED) '
  'queda siempre auditable. quantity es SIEMPRE el snapshot físico resuelto al momento de crear el '
  'pedido (para un kit: composición histórica real, nunca kit_components vigente) — deliver_web_pickup '
  'y cancel_sale nunca recalculan cuánto correspondía, solo leen estas filas.';
comment on column public.sale_stock_reservations.sale_item_id is
  'La línea comercial que originó esta reserva — para un kit, apunta al sale_item DEL KIT (no '
  'existe un sale_item por componente), igual convención que stock_movements.source_sale_item_id.';

-- "Disponible = físico - reservado" necesita sumar rápido las reservas
-- ACTIVE de un (location_id, product_id) — índice parcial, exactamente lo
-- que fn_check_available_stock/fn_reserve_stock consultan bajo lock.
create index sale_stock_reservations_active_idx
  on public.sale_stock_reservations (location_id, product_id)
  where status = 'ACTIVE';

-- Para deliver_web_pickup / cancel_sale: todas las reservas de una venta.
create index sale_stock_reservations_sale_idx
  on public.sale_stock_reservations (sale_id);

alter table public.sale_stock_reservations enable row level security;

-- Mismo patrón que stock_movements/inventory_balances (20260101000010_rls.sql):
-- lectura por acceso a sede, escritura EXCLUSIVA de las RPC (sin policy de
-- insert/update/delete — solo las funciones security definer pueden tocarla).
create policy sale_stock_reservations_select on public.sale_stock_reservations
  for select using (public.is_active_profile() and public.has_location_access(location_id));
