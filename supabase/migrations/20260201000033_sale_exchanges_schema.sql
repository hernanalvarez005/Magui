-- =============================================================================
-- Maguirejuve · 42 · Cambios / Devoluciones — schema (paso 2/3)
-- =============================================================================
-- PASO 0 (auditoría completa entregada al usuario antes de esta migración,
-- con 3 rondas de observaciones cerradas): un cambio NUNCA edita
-- destructivamente la venta original — genera una venta de reemplazo nueva
-- (carrito final completo) vinculada por sales.replaces_sale_id, y la
-- original pasa a status = 'replaced'. El detalle fino del cambio (qué
-- volvió, qué se llevó, a qué valor, la diferencia) vive en sale_exchanges /
-- sale_exchange_items — separado de sale_items, que conserva su único
-- significado actual ("qué hay en el carrito de ESTA venta").

-- ---------------------------------------------------------------------------
-- 1) Trazabilidad física del ledger — necesaria para poder revertir stock de
--    forma exacta cuando una venta tiene, a la vez, un kit y (por separado)
--    uno de sus mismos componentes: hoy fn_create_sale_core agrupa el
--    descuento de stock SOLO por product_id (ver comentario en el próximo
--    archivo de esta migración), así que dos líneas comerciales distintas
--    que requieren el mismo producto físico terminan en una única fila de
--    stock_movements, indistinguible entre sí. source_sale_item_id identifica
--    QUÉ LÍNEA COMERCIAL causó cada movimiento físico (para un kit, apunta al
--    sale_item del kit — no existe un sale_item por componente).
-- ---------------------------------------------------------------------------
alter table public.stock_movements
  add column source_sale_item_id uuid references public.sale_items (id);

comment on column public.stock_movements.source_sale_item_id is
  'Línea comercial (sale_items.id) que causó este movimiento físico. Para un kit, es el '
  'sale_item DEL KIT (no de sus componentes) — un mismo product_id puede tener más de una '
  'fila de stock_movements en la misma venta si se vende como kit Y por separado a la vez. '
  'NULL en filas anteriores a esta migración (histórico) y en movimientos que no se originan '
  'en una línea comercial puntual (TRANSFER/ADJUSTMENT/INITIAL/PURCHASE).';

create index stock_movements_source_sale_item_idx
  on public.stock_movements (source_sale_item_id)
  where source_sale_item_id is not null;

-- ---------------------------------------------------------------------------
-- 2) Encadenamiento de líneas a través de cambios sucesivos — cuando una
--    devolución es PARCIAL (ej. compró 3, devuelve 1), la venta de reemplazo
--    lleva una línea nueva con la cantidad restante (2), al mismo precio
--    histórico. Esa línea nueva NUNCA generó su propio movimiento de stock
--    (el producto físico sigue "afuera" desde la venta original) — así que si
--    más adelante se devuelve parte de ESA cantidad restante, hay que saber a
--    qué sale_item ORIGINAL (raíz) pertenece el ledger real. Se resuelve
--    siempre con coalesce(physical_source_sale_item_id, id) → nunca más de un
--    salto, sin importar cuántos cambios sucesivos haya en la cadena.
-- ---------------------------------------------------------------------------
alter table public.sale_items
  add column physical_source_sale_item_id uuid references public.sale_items (id);

comment on column public.sale_items.physical_source_sale_item_id is
  'NULL en una línea de venta real (fn_create_sale_core): su propio stock_movements.source_sale_item_id '
  'es id. En una línea copiada/trasladada por un cambio (create_sale_exchange), apunta al sale_item '
  'RAÍZ que realmente generó el movimiento de stock — resolver siempre con coalesce(physical_source_sale_item_id, id).';

-- ---------------------------------------------------------------------------
-- 3) Vínculo venta original -> venta de reemplazo. La dirección inversa
--    ("esta venta fue reemplazada por...") se resuelve con un select where
--    replaces_sale_id = :id — no hace falta una columna espejo sincronizada.
-- ---------------------------------------------------------------------------
alter table public.sales
  add column replaces_sale_id uuid references public.sales (id),
  add constraint sales_replaces_not_self check (replaces_sale_id is null or replaces_sale_id <> id);

comment on column public.sales.replaces_sale_id is
  'Si no es null, esta venta es la operación final de un cambio — reemplaza comercialmente a '
  'la venta original (que queda en status=replaced, nunca se borra ni se edita).';

create index sales_replaces_sale_id_idx
  on public.sales (replaces_sale_id)
  where replaces_sale_id is not null;

-- ---------------------------------------------------------------------------
-- 4) Estado de acreditación de la DIFERENCIA de un cambio — deliberadamente
--    un enum propio y neutral, NO sale_billing_status: una diferencia puede
--    ser a favor del negocio (cobrar) o a favor del cliente (devolver
--    dinero), y "INVOICED" describe solo el primer caso. SETTLED sirve para
--    ambos sin forzar semántica de facturación.
-- ---------------------------------------------------------------------------
create type public.sale_settlement_status as enum ('NOT_REQUIRED', 'PENDING', 'SETTLED');

create type public.sale_exchange_direction as enum ('CUSTOMER_PAYS', 'BUSINESS_REFUNDS', 'NONE');

-- ---------------------------------------------------------------------------
-- 5) sale_exchanges — cabecera de un cambio. sale_exchange_items — detalle
--    (qué volvió, qué se llevó). Nunca se borra ni se edita salvo el estado
--    de acreditación de la diferencia (mark_exchange_difference_settled/pending).
-- ---------------------------------------------------------------------------
create table public.sale_exchanges (
  id uuid primary key default gen_random_uuid(),
  original_sale_id uuid not null references public.sales (id),
  replacement_sale_id uuid not null unique references public.sales (id),
  difference_amount numeric(14, 2) not null,
  difference_direction public.sale_exchange_direction not null,
  difference_settlement_status public.sale_settlement_status not null default 'NOT_REQUIRED',
  settled_at timestamptz,
  settled_by uuid references public.profiles (id),
  notes text,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint sale_exchanges_difference_direction_consistency check (
    (difference_direction = 'NONE' and difference_amount = 0)
    or (difference_direction = 'CUSTOMER_PAYS' and difference_amount > 0)
    or (difference_direction = 'BUSINESS_REFUNDS' and difference_amount < 0)
  ),
  constraint sale_exchanges_settled_consistency check (
    (difference_settlement_status = 'SETTLED' and settled_at is not null and settled_by is not null)
    or (difference_settlement_status <> 'SETTLED' and settled_at is null and settled_by is null)
  )
);

comment on table public.sale_exchanges is
  'Cabecera de un cambio de producto. difference_amount = precio_nuevo - valor_reconocido_devuelto '
  '(negativo = el negocio devuelve dinero). Nunca representa el total comercial de la venta de '
  'reemplazo (eso vive en sales.total) — solo el flujo incremental de dinero de ESTE cambio.';

create table public.sale_exchange_items (
  id uuid primary key default gen_random_uuid(),
  exchange_id uuid not null references public.sale_exchanges (id) on delete cascade,
  direction text not null check (direction in ('RETURNED', 'ADDED')),
  source_sale_item_id uuid references public.sale_items (id),
  product_id uuid not null references public.products (id),
  quantity numeric(14, 2) not null check (quantity > 0),
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  constraint sale_exchange_items_returned_requires_source
    check (direction <> 'RETURNED' or source_sale_item_id is not null),
  constraint sale_exchange_items_added_no_source
    check (direction <> 'ADDED' or source_sale_item_id is null)
);

comment on table public.sale_exchange_items is
  'Detalle de un cambio: una fila RETURNED (el producto que el cliente devuelve, valuado al precio '
  'realmente pagado histórico) y una o más filas ADDED (lo que se lleva, valuado a precio vigente '
  'bajo la misma forma de pago). source_sale_item_id en RETURNED es la línea puntual referenciada '
  'en este cambio (puede ser ella misma una línea trasladada por un cambio anterior).';

create index sale_exchange_items_exchange_id_idx on public.sale_exchange_items (exchange_id);

alter table public.sale_exchanges enable row level security;
alter table public.sale_exchange_items enable row level security;

-- Mismo criterio que sales_select/sale_items_select: lectura por acceso a
-- sede + (admin/viewer/propio vendedor); escritura exclusiva de las RPC
-- (create_sale_exchange / mark_exchange_difference_settled / _pending), sin
-- policy de insert/update/delete acá.
create policy sale_exchanges_select on public.sale_exchanges
  for select using (
    exists (
      select 1 from public.sales s
      where s.id = sale_exchanges.replacement_sale_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or public.is_viewer() or s.seller_id = auth.uid())
    )
  );

create policy sale_exchange_items_select on public.sale_exchange_items
  for select using (
    exists (
      select 1 from public.sale_exchanges e
      join public.sales s on s.id = e.replacement_sale_id
      where e.id = sale_exchange_items.exchange_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or public.is_viewer() or s.seller_id = auth.uid())
    )
  );
