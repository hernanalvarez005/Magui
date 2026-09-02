-- =============================================================================
-- Maguirejuve · 45 · Devolución de producto — schema (paso 2/3)
-- =============================================================================
-- PASO 0 (auditoría completa entregada al usuario, aprobada con 6 precisiones):
-- CAMBIO (sale_exchanges) = el cliente devuelve producto y se lleva otro —
-- la venta original SIEMPRE queda estructuralmente reemplazada (status =
-- 'replaced'), lo que hace de sale_items.quantity una cota confiable de "lo
-- que queda disponible". DEVOLUCIÓN es un concepto distinto: el cliente
-- devuelve producto y recupera dinero, sin llevarse nada — la venta original
-- tiene que seguir 'confirmed' (sus otras líneas/productos siguen siendo una
-- venta válida) y una misma línea puede devolverse PARCIALMENTE, más de una
-- vez, a lo largo del tiempo. sale_exchanges/sale_exchange_items no sirve
-- para modelar esto (su semántica es "línea que vuelve" + "línea que se
-- lleva", 1:1 con reemplazo estructural) — se crean tablas separadas.
--
-- "Cantidad disponible para devolver" NO puede leerse de una columna fija
-- (a diferencia de Cambios): es un agregado vivo, sale_items.quantity menos
-- la suma de todo lo ya devuelto contra esa línea. create_sale_return
-- serializa esto con `select ... for update` sobre la fila de sale_items
-- (paso 3/3) — dos devoluciones concurrentes sobre la misma línea quedan
-- forzadas a correr en serie.

-- ---------------------------------------------------------------------------
-- 1) Forma de reintegro del dinero. Deliberadamente sin CARD_1/CARD_3: una
--    devolución en efectivo o transferencia es dinero que el negocio entrega
--    de verdad ahora — reversar una tarjeta es un proceso externo (posnet/
--    entidad emisora) fuera del alcance de este módulo.
-- ---------------------------------------------------------------------------
create type public.sale_refund_method as enum ('CASH', 'TRANSFER');

-- ---------------------------------------------------------------------------
-- 2) sale_returns — cabecera de una devolución. sale_return_items — detalle
--    (qué línea, cuánta cantidad, a qué precio históricamente pagado). Nunca
--    se edita ni se borra — es un evento de negocio consumado, igual que
--    sale_exchanges. Sin columna status: a diferencia de una venta o de un
--    cambio, una devolución no tiene un ciclo de vida propio que recorrer
--    después de creada (no hay "pendiente" ni "revertida" — para eso existe
--    la nota de crédito/proceso externo, explícitamente fuera de alcance).
-- ---------------------------------------------------------------------------
create table public.sale_returns (
  id uuid primary key default gen_random_uuid(),
  original_sale_id uuid not null references public.sales (id),
  refund_amount numeric(14, 2) not null check (refund_amount > 0),
  refund_method public.sale_refund_method not null,
  payment_account_id uuid references public.payment_accounts (id),
  notes text,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint sale_returns_account_consistency check (
    (refund_method = 'TRANSFER' and payment_account_id is not null)
    or (refund_method = 'CASH' and payment_account_id is null)
  )
);

comment on table public.sale_returns is
  'Cabecera de una devolución de producto (el cliente devuelve mercadería y recupera dinero, '
  'sin llevarse nada a cambio — a diferencia de sale_exchanges). refund_amount = SIEMPRE la suma '
  'de line_refund_total de sus sale_return_items, calculada por create_sale_return (única vía de '
  'escritura); no hay una constraint cruzada contra las líneas por el mismo motivo que '
  'sales.total no se valida contra sale_items en la base — el cálculo vive en un único punto '
  'de entrada transaccional.';

create index sale_returns_original_sale_id_idx on public.sale_returns (original_sale_id);

create table public.sale_return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.sale_returns (id) on delete cascade,
  sale_item_id uuid not null references public.sale_items (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null check (quantity > 0),
  unit_price_refunded numeric(14, 2) not null check (unit_price_refunded > 0),
  line_refund_total numeric(14, 2) not null check (line_refund_total >= 0),
  constraint sale_return_items_totals_consistency
    check (line_refund_total = round(unit_price_refunded * quantity, 2))
);

comment on table public.sale_return_items is
  'Detalle de una devolución: una fila por sale_item devuelto. unit_price_refunded es SIEMPRE '
  'el snapshot histórico (sale_items.sale_unit_price) de la línea original — nunca precio '
  'actual, nunca Lista, nunca pricing reejecutado. Para una línea con promoción (precio único '
  'por unidad ya prorrateado en sale_unit_price desde fn_apply_promotions), esto ya devuelve '
  'proporcionalmente lo efectivamente pagado sin lógica especial.';

create index sale_return_items_return_id_idx on public.sale_return_items (return_id);
create index sale_return_items_sale_item_id_idx on public.sale_return_items (sale_item_id);

alter table public.sale_returns enable row level security;
alter table public.sale_return_items enable row level security;

-- Mismo criterio que sales_select/sale_exchanges_select: lectura por acceso a
-- sede + (admin/viewer/propio vendedor de la venta original); escritura
-- exclusiva de create_sale_return, sin policy de insert/update/delete acá.
create policy sale_returns_select on public.sale_returns
  for select using (
    exists (
      select 1 from public.sales s
      where s.id = sale_returns.original_sale_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or public.is_viewer() or s.seller_id = auth.uid())
    )
  );

create policy sale_return_items_select on public.sale_return_items
  for select using (
    exists (
      select 1 from public.sale_returns r
      join public.sales s on s.id = r.original_sale_id
      where r.id = sale_return_items.return_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or public.is_viewer() or s.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 3) sale_item_net — vista centralizadora de "bruto menos devuelto", para que
--    ningún reporte tenga que reimplementar esta resta por su cuenta (Bloque
--    D toca dashboard_report / product_revenue_report / doctor_sales_detail /
--    customer_purchase_history / /admin/facturacion contra esta vista, no
--    contra sale_items en crudo). Expone returned_quantity/returned_amount
--    ADEMÁS de net_quantity/net_line_total (precisión #1 del usuario) para
--    que tampoco haga falta recalcular la resta una segunda vez en cada uno.
--    security_invoker = true: la vista respeta el RLS del usuario que
--    consulta (mismo patrón ya usado en kit_availability/product_stock_status,
--    20260101000013_kit_availability_view.sql) — nunca los privilegios del
--    dueño de la vista.
-- ---------------------------------------------------------------------------
create view public.sale_item_net with (security_invoker = true) as
select
  si.id as sale_item_id,
  si.sale_id,
  si.product_id,
  si.quantity as gross_quantity,
  si.sale_unit_price,
  si.line_total as gross_line_total,
  si.commissionable,
  si.applied_promotion_id,
  coalesce(ret.returned_quantity, 0) as returned_quantity,
  coalesce(ret.returned_amount, 0) as returned_amount,
  si.quantity - coalesce(ret.returned_quantity, 0) as net_quantity,
  si.line_total - coalesce(ret.returned_amount, 0) as net_line_total
from public.sale_items si
left join lateral (
  select
    sum(sri.quantity) as returned_quantity,
    sum(sri.line_refund_total) as returned_amount
  from public.sale_return_items sri
  where sri.sale_item_id = si.id
) ret on true;

comment on view public.sale_item_net is
  'Cada sale_item con lo devuelto restado (returned_quantity/returned_amount vía '
  'sale_return_items) y los agregados netos ya calculados (net_quantity/net_line_total). '
  'Punto único de cálculo de "neto de devoluciones" para todos los reportes — nunca '
  'reimplementar esta resta en otro lado. Una venta con status=confirmed puede tener '
  'líneas parcialmente devueltas (net_quantity/net_line_total > 0 pero < bruto): el filtro '
  'status=confirmed NUNCA alcanza solo para excluir lo devuelto, hay que sumar contra esta vista.';

-- Grant explícito (belt-and-suspenders, igual criterio que el resto del
-- esquema): GRANT ... ON ALL TABLES IN SCHEMA / ALTER DEFAULT PRIVILEGES de
-- 20260101000010_rls.sql alcanzan a vistas igual que a tablas en Postgres,
-- pero se deja explícito para que esta vista no dependa silenciosamente de
-- ese detalle.
grant select on public.sale_item_net to authenticated;
