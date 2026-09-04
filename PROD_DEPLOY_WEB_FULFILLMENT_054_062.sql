-- =============================================================================
-- PROD_DEPLOY_WEB_FULFILLMENT_054_062.sql
-- =============================================================================
-- Deploy manual consolidado a producción — Circuito Ventas Web (BLOQUES B-G).
-- Generado concatenando, EXACTAMENTE y sin ninguna modificación de lógica,
-- el contenido vigente de las 9 migraciones individuales del repo, en este
-- orden:
--
--   054_web_fulfillment_schema
--   055_web_fulfillment_functions
--   056_web_payment_status_metrics_filter
--   057_web_fulfillment_permissions_and_billing_fix
--   058_web_admin_delivery_bypass_and_stock_availability
--   059_web_pending_pickups
--   060_web_order_history
--   061_stock_available_transversal
--   062_shipping_pending_v1_semantics
--
-- Este archivo es SOLO para el deploy manual a producción — no reemplaza ni
-- modifica las migraciones individuales en supabase/migrations/, que siguen
-- siendo la fuente de verdad del repo (y las que corre `supabase db push`
-- normalmente). No lo agregues a supabase/migrations/.
--
-- Requisito de esta base ANTES de correr este archivo: tiene que estar en el
-- estado exacto de `main` al momento de este deploy — es decir, con TODAS
-- las migraciones hasta 20260201000053_reversal_qty_guard_fix.sql inclusive
-- ya aplicadas, y NINGUNA de 054 en adelante. Este archivo NO incluye 053 ni
-- ninguna anterior — si tu base no tiene 053 aplicada, corré esa primero,
-- por separado, antes de este archivo.
--
-- Todo el archivo corre dentro de UNA sola transacción (BEGIN ... COMMIT):
-- si cualquier sentencia falla, Postgres aborta la transacción completa —
-- nada de lo que sigue se aplica, y nada de lo ya ejecutado en este mismo
-- archivo queda a medio aplicar. No hay forma de que continúe "en silencio"
-- después de un error: cualquier sentencia posterior a un error dentro de la
-- misma transacción abortada también va a fallar (con el mensaje
-- "current transaction is aborted"), y el COMMIT final no va a aplicar nada.
-- Si eso pasa, copiá el mensaje de error completo antes de reintentar nada.
--
-- No hace falta ejecutar ningún otro archivo antes ni después de este para
-- que 054-062 queden aplicadas — es autocontenido.
-- =============================================================================

begin;

-- =============================================================================
-- MIGRACIÓN 054_web_fulfillment_schema
-- Fuente: supabase/migrations/20260201000054_web_fulfillment_schema.sql (contenido exacto, sin cambios)
-- =============================================================================

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

-- =============================================================================
-- MIGRACIÓN 055_web_fulfillment_functions
-- Fuente: supabase/migrations/20260201000055_web_fulfillment_functions.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 55 · Circuito Ventas Web / Fulfillment / Reservas — BLOQUE B
-- (2/2: funciones)
-- =============================================================================
-- Diseño (ver informe BLOQUE B entregado al usuario para el detalle
-- completo de cada decisión):
--
--   - fn_create_sale_core gana 2 parámetros nuevos, AL FINAL de la lista,
--     ambos default null: p_fulfillment_type, p_payment_status. Mientras
--     sean null (el 100% de los llamados existentes: create_web_order y
--     cualquier create_sale que no sea un pickup/shipping Web) el
--     comportamiento es IDÉNTICO al de hoy, byte a byte, salvo por UNA cosa
--     nueva que aplica a TODA venta sin excepción (sección 5 del pedido):
--     antes de cada fn_apply_stock_movement se valida disponible
--     (físico - reservado), no solo físico. Con cero reservas existentes
--     hoy (no hay ninguna hasta que se cree el primer pickup), esa validación
--     es un no-op para todo lo que no sea Web — mismo resultado de siempre.
--   - pickup_location_id NO es un parámetro de la RPC: se deriva siempre de
--     p_location_id cuando fulfillment_type='PICKUP' (evita el riesgo de
--     que un caller mande dos ubicaciones inconsistentes).
--   - create_web_order (integración externa, service_role) NO se toca —
--     nunca pasa los parámetros nuevos, su comportamiento es exactamente el
--     de siempre.
--   - create_sale gana los mismos 2 parámetros nuevos, al final, default
--     null — incluye la validación "fulfillment_type solo con canal WEB".
--     IMPORTANTE (riesgo, ver informe): esto NO exige todavía que TODO
--     canal WEB traiga fulfillment_type — si algún día se quiere cerrar esa
--     puerta a nivel backend (y no solo ocultar el selector en la UI, BLOQUE
--     C) hace falta otra migración explícita, después de que la UI nueva
--     esté desplegada (si se agregara esa exigencia ahora, un admin usando
--     la pantalla de Nueva Venta ACTUAL —que todavía no manda estos
--     parámetros— dejaría de poder cargar ventas Web de un día para el otro).
--   - billing_status/payment_account_id: cuando payment_status='PENDING',
--     se permite NO tener payment_account_id todavía aunque el medio de
--     pago sea de los que normalmente lo exigen (TRANSFER/CARD_1/CARD_3) —
--     no se puede saber en qué cuenta entró un cobro que todavía no pasó.
--     Se completa después, al cobrar (mark_web_order_paid). Cuando
--     payment_status is null o = 'PAID', el comportamiento de
--     facturación/cuenta es exactamente el de siempre, sin cambios.
--   - commission_total: se sigue calculando y persistiendo EXACTAMENTE
--     igual que hoy, para toda venta, sin excepción — nunca se anula ni se
--     recalcula acá por payment_status. La exclusión de comisión operativa
--     para pedidos PENDING de cobro es una decisión de REPORTING (qué
--     consultas suman commission_total), no de qué se graba — se presenta
--     el plan concreto en el informe, sin tocar los reportes todavía (pedido
--     explícito: "no cambies las 13 queries sin presentar antes").

-- ---------------------------------------------------------------------------
-- 1) fn_check_available_stock: valida "disponible" (físico - reservas
--    ACTIVE), lockeando la fila de inventory_balances para serializar contra
--    cualquier otra reserva/venta concurrente del mismo (location, product)
--    — mismo patrón exacto que ya usa fn_apply_stock_movement para el chequeo
--    físico (insert...on conflict do nothing + select...for update), así que
--    dos transacciones concurrentes SIEMPRE se serializan en esa fila: la
--    segunda espera a que la primera termine (commit o rollback) antes de
--    poder leer/validar, nunca puede haber doble-reserva de la misma unidad.
--    No es security definer (igual que fn_apply_stock_movement) — se llama
--    siempre desde dentro de otra función security definer.
-- ---------------------------------------------------------------------------
create or replace function public.fn_check_available_stock(
  p_location_id uuid,
  p_product_id uuid,
  p_required_qty numeric,
  p_allow_negative boolean default false
)
returns void
language plpgsql
as $$
declare
  v_physical numeric(14, 2);
  v_reserved numeric(14, 2);
  v_available numeric(14, 2);
  v_product_name text;
begin
  insert into public.inventory_balances (location_id, product_id, quantity)
  values (p_location_id, p_product_id, 0)
  on conflict (location_id, product_id) do nothing;

  select quantity into v_physical
  from public.inventory_balances
  where location_id = p_location_id and product_id = p_product_id
  for update;

  select coalesce(sum(quantity), 0) into v_reserved
  from public.sale_stock_reservations
  where location_id = p_location_id and product_id = p_product_id and status = 'ACTIVE';

  v_available := v_physical - v_reserved;

  if v_available < p_required_qty and not p_allow_negative then
    select name into v_product_name from public.products where id = p_product_id;
    raise exception using
      errcode = 'P1002',
      message = format(
        'No hay stock disponible de %s. Físico: %s. Reservado: %s. Disponible: %s. Requerido: %s.',
        coalesce(v_product_name, 'producto'), v_physical, v_reserved, v_available, p_required_qty
      );
  end if;
end;
$$;

comment on function public.fn_check_available_stock(uuid, uuid, numeric, boolean) is
  'Disponible = físico - reservas ACTIVE. Lockea inventory_balances (mismo patrón que '
  'fn_apply_stock_movement) para serializar reservas/ventas concurrentes del mismo producto+sede. '
  'No inserta nada — solo valida y, si no alcanza, lanza excepción (errcode P1002).';

revoke execute on function public.fn_check_available_stock(uuid, uuid, numeric, boolean) from public;

-- ---------------------------------------------------------------------------
-- 2) fn_reserve_stock: valida (fn_check_available_stock, bajo el mismo lock)
--    e inserta la fila de reserva, atómico. Se llama una vez por cada
--    (sale_item_id, product_id) resuelto — para un kit, una vez POR
--    COMPONENTE FÍSICO, nunca una fila "kit".
-- ---------------------------------------------------------------------------
create or replace function public.fn_reserve_stock(
  p_sale_id uuid,
  p_sale_item_id uuid,
  p_location_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_created_by uuid,
  p_allow_negative boolean default false
)
returns public.sale_stock_reservations
language plpgsql
as $$
declare
  v_reservation public.sale_stock_reservations;
begin
  perform public.fn_check_available_stock(p_location_id, p_product_id, p_quantity, p_allow_negative);

  insert into public.sale_stock_reservations (
    sale_id, sale_item_id, location_id, product_id, quantity, status, created_by
  ) values (
    p_sale_id, p_sale_item_id, p_location_id, p_product_id, p_quantity, 'ACTIVE', p_created_by
  )
  returning * into v_reservation;

  return v_reservation;
end;
$$;

comment on function public.fn_reserve_stock(uuid, uuid, uuid, uuid, numeric, uuid, boolean) is
  'Valida disponible (fn_check_available_stock, bajo el mismo lock de inventory_balances) e '
  'inserta la reserva ACTIVE en un solo paso atómico. Nunca descuenta stock físico.';

revoke execute on function public.fn_reserve_stock(uuid, uuid, uuid, uuid, numeric, uuid, boolean) from public;

-- ---------------------------------------------------------------------------
-- 3) fn_create_sale_core — firma con 2 parámetros nuevos al final. Se
--    dropea la firma vigente de 16 parámetros antes de crear la de 18
--    (mismo criterio que 20260201000025 cuando agregó payment_account_id).
-- ---------------------------------------------------------------------------
drop function if exists public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
);

create or replace function public.fn_create_sale_core(
  p_seller_id uuid,
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid,
  p_doctor_id uuid,
  p_notes text,
  p_external_source text,
  p_external_order_id text,
  p_sold_at timestamptz,
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null,
  p_fulfillment_type public.sale_fulfillment_type default null,
  p_payment_status public.sale_payment_status default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_quote jsonb;
  v_sale_id uuid;
  v_sale_number text;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_line jsonb;
  v_line_promotion_id uuid;
  v_promotion public.promotions;
  v_required record;
  v_allow_negative boolean;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
  v_deposito_location_id uuid;
  v_pickup_location_id uuid;
  v_fulfillment_status public.sale_fulfillment_status;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
  if v_payment_method_code is null then
    raise exception 'El medio de pago seleccionado no existe o está inactivo.';
  end if;

  if p_customer_id is not null and not exists (
    select 1 from public.customers where id = p_customer_id and active
  ) then
    raise exception 'El cliente seleccionado no existe.';
  end if;

  if p_doctor_id is not null and not exists (
    select 1 from public.doctors where id = p_doctor_id and active
  ) then
    raise exception 'La doctora seleccionada no existe o está inactiva.';
  end if;

  if p_is_free_sale and p_free_sale_reason is null then
    raise exception 'Una entrega sin costo necesita un motivo (regalo, muestra, canje, cortesía u otro).';
  end if;

  if p_sold_at < now() - interval '1 hour' and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta con fecha anterior.';
  end if;

  if p_skip_stock_movement and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta sin descontar stock.';
  end if;

  if p_skip_stock_movement and p_is_free_sale then
    raise exception 'Una entrega sin costo siempre descuenta stock — no se puede combinar con carga histórica.';
  end if;

  -- ---------------------------------------------------------------------
  -- Fulfillment (BUGFIX 55, nuevo): solo aplica cuando el caller pide
  -- explícitamente un fulfillment_type. Si es null (create_web_order y
  -- todo create_sale de siempre), este bloque entero es un no-op y el
  -- comportamiento es idéntico al de antes de esta migración.
  -- ---------------------------------------------------------------------
  if p_fulfillment_type is not null then
    if p_is_free_sale or p_skip_stock_movement then
      raise exception 'Un pedido Web (retiro o envío) no puede ser una entrega sin costo ni una carga histórica.';
    end if;

    if p_payment_status is null then
      raise exception 'Un pedido Web necesita indicar el estado de pago (pagado / pendiente de cobro).';
    end if;

    select id into v_deposito_location_id from public.stock_locations where code = 'DEP';

    if p_fulfillment_type = 'SHIPPING' then
      if p_location_id is distinct from v_deposito_location_id then
        raise exception 'Envío por correo solo puede descontar stock del Depósito.';
      end if;
      v_pickup_location_id := null;
      v_fulfillment_status := 'SHIPPED';
    else -- PICKUP
      if p_location_id = v_deposito_location_id then
        raise exception 'Retiro en sede no puede ser en Depósito — elegí Sede 25 o Sede 37.';
      end if;
      v_pickup_location_id := p_location_id;
      v_fulfillment_status := 'PENDING_PICKUP';
    end if;
  end if;

  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    -- Pedido Web PENDING de cobro: todavía no se sabe en qué cuenta va a
    -- entrar la plata (no entró todavía) — se completa después, al cobrar
    -- (mark_web_order_paid). Para cualquier otro caso (no-Web, o Web ya
    -- pagado) el comportamiento es exactamente el de siempre: obligatorio.
    if p_payment_status is distinct from 'PENDING' then
      if p_payment_account_id is null or not exists (
        select 1 from public.payment_accounts where id = p_payment_account_id and active
      ) then
        raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
      end if;
      v_payment_account_id := p_payment_account_id;
    else
      v_payment_account_id := p_payment_account_id; -- puede venir null, o ya cargada si se conoce
    end if;

    if p_customer_id is null or not exists (
      select 1 from public.customers
      where id = p_customer_id and dni is not null and trim(dni) <> ''
    ) then
      raise exception
        'Esta operación se puede facturar, así que necesita un cliente identificado con nombre y DNI.';
    end if;

    v_billing_status := 'PENDING';
  else
    v_payment_account_id := null;
    v_billing_status := 'NOT_REQUIRED';
  end if;

  if p_external_source is not null and p_external_order_id is not null
     and exists (
       select 1 from public.sales
       where external_source = p_external_source and external_order_id = p_external_order_id
     ) then
    raise exception 'Este pedido externo ya fue importado (%: %).', p_external_source, p_external_order_id;
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at, p_is_free_sale);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  if not p_is_free_sale and p_doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = p_doctor_id;
  end if;

  select coalesce(sum((line ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_quote -> 'lines') line
  where (line ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_sale_number := public.fn_next_sale_number(p_location_id, p_sold_at);

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status,
    fulfillment_type, fulfillment_status, payment_status, pickup_location_id
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status,
    p_fulfillment_type, v_fulfillment_status, p_payment_status, v_pickup_location_id
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    v_line_promotion_id := nullif(v_line ->> 'applied_promotion_id', '')::uuid;
    if v_line_promotion_id is not null then
      select * into v_promotion from public.promotions where id = v_line_promotion_id;
    else
      v_promotion := null;
    end if;

    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount,
      promotion_name_snapshot, promotion_type_snapshot, promotion_discount_percent_snapshot,
      promotion_started_at_snapshot, promotion_ended_at_snapshot
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      coalesce((v_line ->> 'line_surcharge')::numeric, 0),
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      v_line_promotion_id,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      v_promotion.name, v_promotion.type, v_promotion.discount_percent,
      v_promotion.valid_from, v_promotion.valid_until
    );
  end loop;

  if p_fulfillment_type = 'PICKUP' then
    -- ---------------------------------------------------------------------
    -- Retiro en sede: NO se genera ningún movimiento SALE todavía — se
    -- reserva. Misma expansión de kits que el camino normal (fan-out a
    -- componentes físicos reales), agrupada por (sale_item_id, product_id)
    -- — un kit y, aparte, una unidad suelta del mismo componente en el
    -- mismo carrito, NUNCA se funden en una sola reserva.
    -- ---------------------------------------------------------------------
    for v_required in
      with items as (
        select id as sale_item_id, product_id, quantity
        from public.sale_items
        where sale_id = v_sale_id
      ),
      expanded as (
        select i.sale_item_id, i.product_id, i.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = true
        union all
        select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = false
        join public.kit_components kc on kc.kit_product_id = i.product_id
      )
      select sale_item_id, product_id, sum(required_qty) as required_qty
      from expanded
      group by sale_item_id, product_id
      order by product_id
    loop
      -- p_allow_negative NUNCA se pasa acá — sobrevender un pickup pendiente
      -- (sección 29 del pedido) tiene que rechazarse siempre, sea cual sea
      -- allow_negative_stock (ese setting es para permitir un negativo real
      -- de stock físico ya vendido, no para permitir comprometer más de lo
      -- que hay disponible en una reserva nueva).
      perform public.fn_reserve_stock(
        v_sale_id, v_required.sale_item_id, p_location_id, v_required.product_id,
        v_required.required_qty, p_seller_id, false
      );
    end loop;
  elsif not p_skip_stock_movement then
    for v_required in
      with items as (
        select id as sale_item_id, product_id, quantity
        from public.sale_items
        where sale_id = v_sale_id
      ),
      expanded as (
        select i.sale_item_id, i.product_id, i.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = true
        union all
        select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = false
        join public.kit_components kc on kc.kit_product_id = i.product_id
      )
      select sale_item_id, product_id, sum(required_qty) as required_qty
      from expanded
      group by sale_item_id, product_id
      order by product_id
    loop
      -- Disponible = físico - reservado (sección 5/29 del pedido). Con cero
      -- reservas del producto en esa sede (el caso de siempre, hasta que
      -- exista el primer pickup), esto es indistinguible de validar solo
      -- físico — mismo resultado que antes de esta migración.
      perform public.fn_check_available_stock(
        p_location_id, v_required.product_id, v_required.required_qty, v_allow_negative
      );
      perform public.fn_apply_stock_movement(
        p_location_id => p_location_id,
        p_product_id => v_required.product_id,
        p_movement_type => 'SALE',
        p_quantity_delta => -v_required.required_qty,
        p_sale_id => v_sale_id,
        p_reference => v_sale_number,
        p_created_by => p_seller_id,
        p_allow_negative => v_allow_negative,
        p_source_sale_item_id => v_required.sale_item_id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'surcharge_total', coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'is_free_sale', p_is_free_sale,
    'stock_skipped', p_skip_stock_movement,
    'billing_status', v_billing_status,
    'fulfillment_type', p_fulfillment_type,
    'fulfillment_status', v_fulfillment_status,
    'payment_status', p_payment_status,
    'pickup_location_id', v_pickup_location_id,
    'lines', v_quote -> 'lines'
  );
end;
$$;

comment on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid,
  public.sale_fulfillment_type, public.sale_payment_status
) is
  'Punto único de creación de ventas confirmadas. p_fulfillment_type/p_payment_status son nuevos '
  '(BUGFIX 55) y default null — mientras sean null el comportamiento es idéntico al de antes de '
  'esta migración para TODO caller existente (create_web_order nunca los pasa). Cuando '
  'fulfillment_type=PICKUP: no genera SALE, reserva (fn_reserve_stock) — nunca kit_components '
  'vigente, siempre la composición real resuelta en sale_items de ESTA venta. Toda venta (Web o '
  'no) valida disponible = físico - reservado antes de descontar, no solo físico.';

-- ---------------------------------------------------------------------------
-- 4) create_sale — mismos parámetros de siempre + los 2 nuevos al final.
--    Se dropea la firma vigente de 15 parámetros.
-- ---------------------------------------------------------------------------
drop function if exists public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
);

create or replace function public.create_sale(
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_external_source text default null,
  p_external_order_id text default null,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null,
  p_fulfillment_type public.sale_fulfillment_type default null,
  p_payment_status public.sale_payment_status default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_channel_code text;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede cargar ventas.';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  select code into v_channel_code from public.sales_channels where id = p_sales_channel_id;
  if v_channel_code = 'WEB' and v_profile.role <> 'admin' then
    raise exception 'Solo un administrador puede registrar ventas por el canal Web.';
  end if;

  if p_fulfillment_type is not null and v_channel_code <> 'WEB' then
    raise exception 'Forma de entrega (retiro/envío) solo aplica al canal Web.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    p_payment_account_id, p_fulfillment_type, p_payment_status
  );
end;
$$;

comment on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid,
  public.sale_fulfillment_type, public.sale_payment_status
) is
  'Valida sede (has_location_access) y canal (Web exclusivo de admin) antes de delegar en '
  'fn_create_sale_core. p_fulfillment_type/p_payment_status (BUGFIX 55) solo se aceptan con canal '
  'WEB — todavía no son obligatorios a nivel backend cuando el canal es WEB (ver comentario de '
  'archivo, riesgo de rollout con la UI vieja); eso se cierra en una migración aparte cuando la UI '
  'nueva (BLOQUE C) ya esté desplegada.';

-- ---------------------------------------------------------------------------
-- 5) deliver_web_pickup: transacción atómica de entrega (sección 21 del
--    pedido). Lock de la venta + de sus reservas, valida todo, consume,
--    genera SALE real, marca DELIVERED, audita. Cualquier fallo revierte
--    TODO (una sola función plpgsql = una sola transacción implícita).
-- ---------------------------------------------------------------------------
create or replace function public.deliver_web_pickup(p_sale_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_reservation record;
  v_reserved_count int := 0;
  v_expected_count int;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede marcar entregas.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type <> 'PICKUP' then
    raise exception 'Este pedido no es un retiro en sede.';
  end if;

  if not public.has_location_access(v_sale.pickup_location_id) then
    raise exception 'Tu usuario no tiene acceso a la sede de retiro de este pedido.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Este pedido no está confirmado (anulado) — no se puede entregar.';
  end if;

  if v_sale.fulfillment_status = 'DELIVERED' then
    raise exception 'Este pedido ya fue entregado (%, por %).', v_sale.delivered_at, v_sale.delivered_by;
  end if;

  if v_sale.fulfillment_status <> 'PENDING_PICKUP' then
    raise exception 'Este pedido no está pendiente de retiro.';
  end if;

  if v_sale.payment_status <> 'PAID' then
    raise exception using
      errcode = 'P1003',
      message = 'Este pedido está pendiente de cobro — hay que cobrarlo antes de entregarlo (mark_web_order_paid).';
  end if;

  select count(*) into v_expected_count from public.sale_items where sale_id = p_sale_id;

  for v_reservation in
    select * from public.sale_stock_reservations
    where sale_id = p_sale_id and status = 'ACTIVE'
    order by product_id
    for update
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_reservation.location_id,
      p_product_id => v_reservation.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_reservation.quantity,
      p_sale_id => p_sale_id,
      p_reference => v_sale.sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => false,
      p_source_sale_item_id => v_reservation.sale_item_id
    );

    update public.sale_stock_reservations
    set status = 'CONSUMED', consumed_at = now()
    where id = v_reservation.id;

    v_reserved_count := v_reserved_count + 1;
  end loop;

  -- Post-chequeo (sección 44 del pedido): tiene que haber consumido al
  -- menos una reserva por cada sale_item con producto trackeable/kit — si
  -- un pedido quedó sin ninguna reserva ACTIVE (dato corrupto/huérfano),
  -- mejor abortar con excepción explícita que "entregar" sin mover nada.
  if v_reserved_count = 0 then
    raise exception 'Este pedido no tiene ninguna reserva de stock activa — no se puede entregar. Contactá a un administrador.';
  end if;

  update public.sales
  set fulfillment_status = 'DELIVERED', delivered_at = now(), delivered_by = auth.uid()
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_DELIVERED', 'sales', p_sale_id,
    jsonb_build_object(
      'sale_id', p_sale_id, 'location_id', v_sale.pickup_location_id,
      'fulfillment_type', v_sale.fulfillment_type, 'payment_status', v_sale.payment_status,
      'delivered_by', auth.uid()
    )
  );

  return jsonb_build_object(
    'sale_id', p_sale_id, 'fulfillment_status', 'DELIVERED',
    'delivered_at', now(), 'reservations_consumed', v_reserved_count
  );
end;
$$;

comment on function public.deliver_web_pickup(uuid) is
  'Transacción atómica: lock del pedido + sus reservas, valida sede/estado/cobro, consume cada '
  'reserva ACTIVE generando su SALE real (fn_apply_stock_movement, trazado por source_sale_item_id), '
  'marca DELIVERED + delivered_at/by, audita WEB_ORDER_DELIVERED. Cualquier excepción revierte todo '
  '(nada de stock descontado a medias). Exige payment_status=PAID — nunca entrega sin cobro resuelto.';

-- ---------------------------------------------------------------------------
-- 6) mark_web_order_paid: el "cobrar" del flujo "Cobrar y entregar" (sección
--    20/27). Nunca reescribe commission_total ni ningún otro snapshot — solo
--    cambia payment_status y, opcionalmente, corrige medio de pago/cuenta si
--    el cobro real terminó siendo distinto de lo esperado al cargar el pedido.
-- ---------------------------------------------------------------------------
create or replace function public.mark_web_order_paid(
  p_sale_id uuid,
  p_payment_method_id uuid default null,
  p_payment_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_payment_method_code text;
  v_requires_billing boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar cobros.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type is null then
    raise exception 'Este pedido no es un pedido Web.';
  end if;

  if not (public.has_location_access(v_sale.location_id) or v_profile.role = 'admin') then
    raise exception 'Tu usuario no tiene acceso a la sede de este pedido.';
  end if;

  if v_sale.payment_status = 'PAID' then
    raise exception 'Este pedido ya está marcado como pagado.';
  end if;

  if p_payment_method_id is not null then
    select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
    if v_payment_method_code is null then
      raise exception 'El medio de pago indicado no existe o está inactivo.';
    end if;
  else
    select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  end if;

  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    if coalesce(p_payment_account_id, v_sale.payment_account_id) is null then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;
    if p_payment_account_id is not null and not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'La cuenta indicada no existe o está inactiva.';
    end if;
  end if;

  update public.sales
  set payment_status = 'PAID',
      payment_method_id = coalesce(p_payment_method_id, payment_method_id),
      payment_account_id = coalesce(p_payment_account_id, payment_account_id)
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_PAID', 'sales', p_sale_id,
    jsonb_build_object('sale_id', p_sale_id, 'payment_method_id', coalesce(p_payment_method_id, v_sale.payment_method_id))
  );

  return jsonb_build_object('sale_id', p_sale_id, 'payment_status', 'PAID');
end;
$$;

comment on function public.mark_web_order_paid(uuid, uuid, uuid) is
  'Cobro de un pedido Web (PENDING -> PAID). Nunca toca commission_total ni ningún otro snapshot '
  '— solo el estado de pago y, si corresponde, corrige medio de pago/cuenta real. No entrega '
  '(deliver_web_pickup es un paso aparte, que exige payment_status=PAID).';

-- ---------------------------------------------------------------------------
-- 7) cancel_sale: agrega, al final del bloque existente (sin tocar nada de
--    lo anterior), liberar cualquier reserva ACTIVE del pedido. Para una
--    venta sin ninguna reserva (el 100% de las ventas hasta hoy) es un
--    no-op exacto — select vacío, loop de 0 iteraciones.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_sale(p_sale_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_movement record;
  v_reservation record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede anular ventas.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'El motivo de cancelación es obligatorio.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'La venta no existe.';
  end if;

  if v_sale.status = 'cancelled' then
    raise exception 'La venta ya se encuentra anulada.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where sale_id = p_sale_id and movement_type = 'SALE'
    order by product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'SALE_CANCEL',
      p_quantity_delta => -v_movement.quantity_delta,
      p_sale_id => v_sale.id,
      p_reference => v_sale.sale_number,
      p_notes => p_reason,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  -- Pickup web todavía no retirado: no hay ningún stock_movement que
  -- revertir (arriba, 0 iteraciones) — lo que hay que deshacer es la
  -- RESERVA. Nunca genera SALE, nunca toca stock físico (sección 30 del
  -- pedido: "al cancelar antes de entregar, stock físico no cambia").
  for v_reservation in
    select id from public.sale_stock_reservations
    where sale_id = p_sale_id and status = 'ACTIVE'
    for update
  loop
    update public.sale_stock_reservations
    set status = 'RELEASED', released_at = now()
    where id = v_reservation.id;
  end loop;

  update public.sales
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = p_reason
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'cancel_sale', 'sales', p_sale_id, jsonb_build_object('reason', p_reason));

  return jsonb_build_object('sale_id', p_sale_id, 'status', 'cancelled');
end;
$$;

comment on function public.cancel_sale is
  'Nunca hace hard delete. Admin o vendedor con acceso a la sede de la venta. Revierte los '
  'movimientos SALE originales (ledger real, nunca kit_components vigente). BUGFIX 55: si el '
  'pedido tiene reservas ACTIVE (pickup web todavía no retirado), las libera (RELEASED) en vez de '
  'generar ningún movimiento — nunca toca stock físico. Idempotente: una venta ya cancelada no '
  'puede volver a cancelarse.';

-- ---------------------------------------------------------------------------
-- 8) create_sale_exchange / create_sale_return: un solo guard nuevo,
--    agregado tal cual sobre la versión vigente (20260201000053) — nada
--    más cambia. Una Venta Web todavía pendiente de retiro no puede entrar
--    a Cambios/Devoluciones porque físicamente no fue entregada (sección
--    31 del pedido). Para toda venta que no sea un pickup pendiente
--    (fulfillment_status is null o ya DELIVERED/SHIPPED) esta condición es
--    siempre falsa — no-op total.
-- ---------------------------------------------------------------------------
create or replace function public.create_sale_exchange(
  p_original_sale_id uuid,
  p_returned_sale_item_id uuid,
  p_returned_quantity numeric,
  p_new_product_id uuid,
  p_new_quantity numeric,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_returned_item public.sale_items;
  v_new_product public.products;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_root_sale_id uuid;
  v_has_traced_movements boolean;
  v_movement record;
  v_reversal_qty numeric;
  v_reversal_count integer;
  v_price jsonb;
  v_recognized_value numeric;
  v_new_line_total numeric;
  v_difference numeric;
  v_difference_direction public.sale_exchange_direction;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_replacement_billing_status public.sale_billing_status;
  v_difference_settlement_status public.sale_settlement_status;
  v_settings public.app_settings;
  v_allow_negative boolean;
  v_remaining_qty numeric;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_item record;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_surcharge_total numeric := 0;
  v_total numeric := 0;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_replacement_sale_id uuid;
  v_replacement_sale_number text;
  v_new_line_item_id uuid;
  v_new_sale_item_id uuid;
  v_exchange_id uuid;
  v_required record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede hacer cambios de producto.';
  end if;

  if p_returned_quantity is null or p_returned_quantity <= 0 then
    raise exception 'La cantidad devuelta tiene que ser mayor a 0.';
  end if;

  if p_new_quantity is null or p_new_quantity <= 0 then
    raise exception 'La cantidad del producto nuevo tiene que ser mayor a 0.';
  end if;

  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada o ya reemplazada por otro cambio) — no se puede volver a usar como origen de un cambio.';
  end if;

  if v_sale.fulfillment_status = 'PENDING_PICKUP' then
    raise exception 'Esta venta es un pedido Web todavía pendiente de retiro — no se puede hacer un cambio hasta que se entregue.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede hacer un cambio sobre una entrega sin costo.';
  end if;

  if v_sale.customer_id is null then
    raise exception 'La venta original no tiene un cliente identificado — no se puede hacer un cambio.';
  end if;

  select * into v_returned_item
  from public.sale_items
  where id = p_returned_sale_item_id
  for update;

  if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
    raise exception 'El producto a devolver no pertenece a esta venta.';
  end if;

  if p_returned_quantity > v_returned_item.quantity then
    raise exception
      'No podés devolver % unidades: esta línea solo tiene % disponibles (ya se descontó cualquier cambio anterior).',
      p_returned_quantity, v_returned_item.quantity;
  end if;

  select * into v_new_product from public.products where id = p_new_product_id and active = true;
  if v_new_product is null then
    raise exception 'El producto nuevo no existe o está inactivo.';
  end if;

  v_physical_source_id := coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id);
  select quantity, sale_id into v_root_quantity, v_root_sale_id
  from public.sale_items where id = v_physical_source_id;

  v_price := public.fn_exchange_new_item_price(p_new_product_id, p_new_quantity, v_sale.payment_method_id, now());
  if not (v_price ->> 'ok')::boolean then
    raise exception '%', v_price ->> 'error_message';
  end if;

  v_recognized_value := round(v_returned_item.sale_unit_price * p_returned_quantity, 2);
  v_new_line_total := (v_price ->> 'line_total')::numeric;
  v_difference := round(v_new_line_total - v_recognized_value, 2);
  v_difference_direction := case
    when v_difference > 0 then 'CUSTOMER_PAYS'
    when v_difference < 0 then 'BUSINESS_REFUNDS'
    else 'NONE'
  end;

  select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if not v_requires_billing then
    v_replacement_billing_status := 'NOT_REQUIRED';
    v_difference_settlement_status := 'NOT_REQUIRED';
  elsif v_sale.billing_status = 'INVOICED' then
    v_replacement_billing_status := 'INVOICED';
    v_difference_settlement_status := case when v_difference <> 0 then 'PENDING' else 'NOT_REQUIRED' end;
  else
    v_replacement_billing_status := 'PENDING';
    v_difference_settlement_status := 'NOT_REQUIRED';
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  for v_item in
    select * from public.sale_items where sale_id = p_original_sale_id and id <> p_returned_sale_item_id
  loop
    v_lines := v_lines || jsonb_build_object(
      'role', 'copy',
      'product_id', v_item.product_id,
      'quantity', v_item.quantity,
      'list_unit_price', v_item.list_unit_price,
      'sale_unit_price', v_item.sale_unit_price,
      'line_list_total', v_item.line_list_total,
      'line_discount', round(greatest((v_item.list_unit_price - v_item.sale_unit_price) * v_item.quantity, 0), 2),
      'line_surcharge', round(greatest((v_item.sale_unit_price - v_item.list_unit_price) * v_item.quantity, 0), 2),
      'line_total', v_item.line_total,
      'applied_price_condition_id', v_item.applied_price_condition_id,
      'commissionable', v_item.commissionable,
      'applied_promotion_id', v_item.applied_promotion_id,
      'promotion_discount', v_item.promotion_discount,
      'promotion_name_snapshot', v_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', coalesce(v_item.physical_source_sale_item_id, v_item.id)
    );
  end loop;

  v_remaining_qty := v_returned_item.quantity - p_returned_quantity;
  if v_remaining_qty > 0 then
    v_lines := v_lines || jsonb_build_object(
      'role', 'remainder',
      'product_id', v_returned_item.product_id,
      'quantity', v_remaining_qty,
      'list_unit_price', v_returned_item.list_unit_price,
      'sale_unit_price', v_returned_item.sale_unit_price,
      'line_list_total', round(v_returned_item.list_unit_price * v_remaining_qty, 2),
      'line_discount', round(greatest((v_returned_item.list_unit_price - v_returned_item.sale_unit_price) * v_remaining_qty, 0), 2),
      'line_surcharge', round(greatest((v_returned_item.sale_unit_price - v_returned_item.list_unit_price) * v_remaining_qty, 0), 2),
      'line_total', round(v_returned_item.sale_unit_price * v_remaining_qty, 2),
      'applied_price_condition_id', v_returned_item.applied_price_condition_id,
      'commissionable', v_returned_item.commissionable,
      'applied_promotion_id', v_returned_item.applied_promotion_id,
      'promotion_discount', 0,
      'promotion_name_snapshot', v_returned_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_returned_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_returned_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_returned_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_returned_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', v_physical_source_id
    );
  end if;

  v_lines := v_lines || jsonb_build_object(
    'role', 'new',
    'product_id', p_new_product_id,
    'quantity', p_new_quantity,
    'list_unit_price', (v_price ->> 'list_unit_price')::numeric,
    'sale_unit_price', (v_price ->> 'sale_unit_price')::numeric,
    'line_list_total', (v_price ->> 'line_list_total')::numeric,
    'line_discount', (v_price ->> 'line_discount')::numeric,
    'line_surcharge', (v_price ->> 'line_surcharge')::numeric,
    'line_total', v_new_line_total,
    'applied_price_condition_id', (v_price ->> 'applied_price_condition_id')::uuid,
    'commissionable', v_new_product.commissionable,
    'applied_promotion_id', null,
    'promotion_discount', 0,
    'promotion_name_snapshot', null,
    'promotion_type_snapshot', null,
    'promotion_discount_percent_snapshot', null,
    'promotion_started_at_snapshot', null,
    'promotion_ended_at_snapshot', null,
    'physical_source_sale_item_id', null
  );

  select
    coalesce(sum((elem ->> 'line_list_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_surcharge')::numeric), 0),
    coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_subtotal, v_discount_total, v_surcharge_total, v_total
  from jsonb_array_elements(v_lines) elem;

  if v_sale.doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = v_sale.doctor_id;
  end if;

  select coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_lines) elem
  where (elem ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_replacement_sale_number := public.fn_next_sale_number(v_sale.location_id, now());

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    notes, payment_account_id, billing_status, invoiced_at, invoiced_by, replaces_sale_id
  ) values (
    v_replacement_sale_number, now(), v_sale.location_id, v_sale.sales_channel_id, auth.uid(),
    v_sale.customer_id, v_sale.doctor_id, v_sale.payment_method_id, null,
    v_subtotal, v_discount_total, v_surcharge_total, v_total, v_commission_total, 'confirmed',
    p_notes, v_sale.payment_account_id, v_replacement_billing_status,
    case when v_replacement_billing_status = 'INVOICED' then now() end,
    case when v_replacement_billing_status = 'INVOICED' then auth.uid() end,
    p_original_sale_id
  )
  returning id into v_replacement_sale_id;

  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount, physical_source_sale_item_id,
      promotion_name_snapshot, promotion_type_snapshot, promotion_discount_percent_snapshot,
      promotion_started_at_snapshot, promotion_ended_at_snapshot
    ) values (
      v_replacement_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_surcharge')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      nullif(v_line ->> 'physical_source_sale_item_id', '')::uuid,
      v_line ->> 'promotion_name_snapshot',
      nullif(v_line ->> 'promotion_type_snapshot', '')::public.promotion_type,
      nullif(v_line ->> 'promotion_discount_percent_snapshot', '')::numeric,
      nullif(v_line ->> 'promotion_started_at_snapshot', '')::timestamptz,
      nullif(v_line ->> 'promotion_ended_at_snapshot', '')::timestamptz
    )
    returning id into v_new_sale_item_id;

    if v_line ->> 'role' = 'new' then
      v_new_line_item_id := v_new_sale_item_id;
    end if;
  end loop;

  select exists(
    select 1 from public.stock_movements
    where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
  ) into v_has_traced_movements;

  v_reversal_count := 0;
  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where movement_type = 'SALE'
      and (
        (v_has_traced_movements and source_sale_item_id = v_physical_source_id)
        or (not v_has_traced_movements and sale_id = v_root_sale_id and source_sale_item_id is null)
      )
    order by product_id
  loop
    v_reversal_qty := round(p_returned_quantity * abs(v_movement.quantity_delta) / v_root_quantity, 2);
    if v_reversal_qty is null or v_reversal_qty <= 0 then
      raise exception
        'No se pudo calcular una cantidad válida de reintegro de stock para el producto % (cantidad devuelta %, movimiento original % en cantidad raíz %) — resultado: %. Se aborta el cambio completo: no se descuenta el producto nuevo ni se reintegra nada.',
        v_movement.product_id, p_returned_quantity, v_movement.quantity_delta, v_root_quantity, v_reversal_qty;
    end if;
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'RETURN',
      p_quantity_delta => v_reversal_qty,
      p_sale_id => p_original_sale_id,
      p_reference => v_sale.sale_number,
      p_notes => format('Cambio %s', v_replacement_sale_number),
      p_created_by => auth.uid(),
      p_allow_negative => true,
      p_source_sale_item_id => v_physical_source_id
    );
    v_reversal_count := v_reversal_count + 1;
  end loop;

  if v_reversal_count = 0 then
    raise exception
      'No se encontró ningún movimiento de stock original para reintegrar (línea raíz %, venta raíz %) — la línea devuelta no tiene historial de stock rastreable. Se aborta el cambio completo en vez de continuar sin reintegrar nada.',
      v_physical_source_id, v_root_sale_id;
  end if;

  for v_required in
    with items as (
      select v_new_line_item_id as sale_item_id, p_new_product_id as product_id, p_new_quantity as quantity
    ),
    expanded as (
      select i.sale_item_id, i.product_id, i.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = true
      union all
      select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = false
      join public.kit_components kc on kc.kit_product_id = i.product_id
    )
    select sale_item_id, product_id, sum(required_qty) as required_qty
    from expanded
    group by sale_item_id, product_id
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_sale.location_id,
      p_product_id => v_required.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_required.required_qty,
      p_sale_id => v_replacement_sale_id,
      p_reference => v_replacement_sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => v_allow_negative,
      p_source_sale_item_id => v_required.sale_item_id
    );
  end loop;

  update public.sales set status = 'replaced' where id = p_original_sale_id;

  insert into public.sale_exchanges (
    original_sale_id, replacement_sale_id, difference_amount, difference_direction,
    difference_settlement_status, notes, created_by
  ) values (
    p_original_sale_id, v_replacement_sale_id, v_difference, v_difference_direction,
    v_difference_settlement_status, p_notes, auth.uid()
  )
  returning id into v_exchange_id;

  insert into public.sale_exchange_items (
    exchange_id, direction, source_sale_item_id, product_id, quantity, unit_price, line_total
  ) values
    (v_exchange_id, 'RETURNED', p_returned_sale_item_id, v_returned_item.product_id,
      p_returned_quantity, v_returned_item.sale_unit_price, v_recognized_value),
    (v_exchange_id, 'ADDED', null, p_new_product_id,
      p_new_quantity, (v_price ->> 'sale_unit_price')::numeric, v_new_line_total);

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_EXCHANGE_CREATED', 'sales', v_replacement_sale_id,
    jsonb_build_object(
      'original_sale_id', p_original_sale_id,
      'replacement_sale_id', v_replacement_sale_id,
      'customer_id', v_sale.customer_id,
      'returned_product_id', v_returned_item.product_id,
      'returned_quantity', p_returned_quantity,
      'new_product_id', p_new_product_id,
      'new_quantity', p_new_quantity,
      'difference_amount', v_difference,
      'difference_direction', v_difference_direction,
      'payment_method_id', v_sale.payment_method_id,
      'location_id', v_sale.location_id
    )
  );

  return jsonb_build_object(
    'exchange_id', v_exchange_id,
    'original_sale_id', p_original_sale_id,
    'sale_id', v_replacement_sale_id,
    'sale_number', v_replacement_sale_number,
    'total', v_total,
    'surcharge_total', v_surcharge_total,
    'recognized_value', v_recognized_value,
    'new_item_total', v_new_line_total,
    'difference_amount', v_difference,
    'difference_direction', v_difference_direction,
    'billing_status', v_replacement_billing_status,
    'difference_settlement_status', v_difference_settlement_status
  );
end;
$$;

comment on function public.create_sale_exchange(uuid, uuid, numeric, uuid, numeric, text) is
  'Cambio de producto. BUGFIX 55: agrega un guard nuevo — una venta con fulfillment_status = '
  'PENDING_PICKUP (pedido Web todavía no retirado) no puede usarse como origen de un cambio, '
  'porque físicamente no fue entregada. Todo lo demás es exactamente 20260201000053, sin cambios.';

create or replace function public.create_sale_return(
  p_original_sale_id uuid,
  p_items jsonb,
  p_refund_method public.sale_refund_method,
  p_payment_account_id uuid default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_item jsonb;
  v_sale_item_id uuid;
  v_quantity numeric;
  v_returned_item public.sale_items;
  v_already_returned numeric;
  v_available numeric;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_root_sale_id uuid;
  v_has_traced_movements boolean;
  v_movement record;
  v_reversal_qty numeric;
  v_reversal_count integer;
  v_line_refund numeric;
  v_return_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_refund_amount numeric := 0;
  v_return_id uuid;
  v_new_return_item_id uuid;
  v_net_remaining numeric;
  v_billing_status public.sale_billing_status;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar devoluciones.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Tenés que indicar al menos un producto a devolver.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(sale_item_id uuid, quantity numeric)
    group by x.sale_item_id
    having count(*) > 1
  ) then
    raise exception 'No se puede indicar el mismo producto más de una vez en la misma devolución — sumá la cantidad en una sola línea.';
  end if;

  if p_refund_method = 'TRANSFER' then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Una devolución por transferencia necesita indicar la cuenta desde la que sale el dinero.';
    end if;
  elsif p_payment_account_id is not null then
    raise exception 'Una devolución en efectivo no lleva cuenta asociada.';
  end if;

  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada, reemplazada por un cambio, o ya devuelta en su totalidad) — no admite una devolución.';
  end if;

  if v_sale.fulfillment_status = 'PENDING_PICKUP' then
    raise exception 'Esta venta es un pedido Web todavía pendiente de retiro — no se puede registrar una devolución hasta que se entregue.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede devolver dinero de una entrega sin costo — no hubo pago que reintegrar.';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_sale_item_id := (v_item ->> 'sale_item_id')::uuid;
    v_quantity := (v_item ->> 'quantity')::numeric;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'La cantidad a devolver tiene que ser mayor a 0.';
    end if;

    select * into v_returned_item from public.sale_items where id = v_sale_item_id for update;

    if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
      raise exception 'El producto a devolver no pertenece a esta venta.';
    end if;

    select coalesce(sum(quantity), 0) into v_already_returned
    from public.sale_return_items
    where sale_item_id = v_sale_item_id;

    v_available := v_returned_item.quantity - v_already_returned;

    if v_quantity > v_available then
      raise exception
        'No podés devolver % unidades: esta línea solo tiene % disponibles para devolver (ya se descontó cualquier devolución anterior).',
        v_quantity, v_available;
    end if;

    v_line_refund := round(v_returned_item.sale_unit_price * v_quantity, 2);
    v_refund_amount := v_refund_amount + v_line_refund;

    v_return_lines := v_return_lines || jsonb_build_object(
      'sale_item_id', v_sale_item_id,
      'product_id', v_returned_item.product_id,
      'quantity', v_quantity,
      'unit_price_refunded', v_returned_item.sale_unit_price,
      'line_refund_total', v_line_refund,
      'physical_source_sale_item_id', coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id)
    );
  end loop;

  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    v_physical_source_id := (v_line ->> 'physical_source_sale_item_id')::uuid;
    select quantity, sale_id into v_root_quantity, v_root_sale_id
    from public.sale_items where id = v_physical_source_id;

    select exists(
      select 1 from public.stock_movements
      where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
    ) into v_has_traced_movements;

    v_reversal_count := 0;
    for v_movement in
      select location_id, product_id, quantity_delta
      from public.stock_movements
      where movement_type = 'SALE'
        and (
          (v_has_traced_movements and source_sale_item_id = v_physical_source_id)
          or (not v_has_traced_movements and sale_id = v_root_sale_id and source_sale_item_id is null)
        )
      order by product_id
    loop
      v_reversal_qty := round(
        (v_line ->> 'quantity')::numeric * abs(v_movement.quantity_delta) / v_root_quantity, 2
      );
      if v_reversal_qty is null or v_reversal_qty <= 0 then
        raise exception
          'No se pudo calcular una cantidad válida de reintegro de stock para el producto % (cantidad devuelta %, movimiento original % en cantidad raíz %) — resultado: %. Se aborta la devolución completa.',
          v_movement.product_id, (v_line ->> 'quantity')::numeric, v_movement.quantity_delta, v_root_quantity, v_reversal_qty;
      end if;
      perform public.fn_apply_stock_movement(
        p_location_id => v_movement.location_id,
        p_product_id => v_movement.product_id,
        p_movement_type => 'RETURN',
        p_quantity_delta => v_reversal_qty,
        p_sale_id => p_original_sale_id,
        p_reference => v_sale.sale_number,
        p_notes => 'Devolución de producto',
        p_created_by => auth.uid(),
        p_allow_negative => true,
        p_source_sale_item_id => v_physical_source_id
      );
      v_reversal_count := v_reversal_count + 1;
    end loop;

    if v_reversal_count = 0 then
      raise exception
        'No se encontró ningún movimiento de stock original para reintegrar (línea raíz %, venta raíz %) — la línea devuelta no tiene historial de stock rastreable. Se aborta la devolución completa en vez de continuar sin reintegrar nada.',
        v_physical_source_id, v_root_sale_id;
    end if;
  end loop;

  insert into public.sale_returns (
    original_sale_id, refund_amount, refund_method, payment_account_id, notes, created_by
  ) values (
    p_original_sale_id, v_refund_amount, p_refund_method, p_payment_account_id, p_notes, auth.uid()
  )
  returning id into v_return_id;

  for v_line in select * from jsonb_array_elements(v_return_lines)
  loop
    insert into public.sale_return_items (
      return_id, sale_item_id, product_id, quantity, unit_price_refunded, line_refund_total
    ) values (
      v_return_id,
      (v_line ->> 'sale_item_id')::uuid,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'unit_price_refunded')::numeric,
      (v_line ->> 'line_refund_total')::numeric
    )
    returning id into v_new_return_item_id;
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_RETURN_CREATED', 'sales', p_original_sale_id,
    jsonb_build_object(
      'return_id', v_return_id,
      'original_sale_id', p_original_sale_id,
      'customer_id', v_sale.customer_id,
      'location_id', v_sale.location_id,
      'refund_amount', v_refund_amount,
      'refund_method', p_refund_method,
      'payment_account_id', p_payment_account_id,
      'items', v_return_lines
    )
  );

  select coalesce(sum(net_line_total), 0) into v_net_remaining
  from public.sale_item_net
  where sale_id = p_original_sale_id;

  v_billing_status := v_sale.billing_status;

  if v_net_remaining = 0 then
    update public.sales
    set status = 'returned',
        billing_status = case when v_sale.billing_status = 'PENDING' then 'NOT_REQUIRED' else v_sale.billing_status end
    where id = p_original_sale_id
    returning billing_status into v_billing_status;
  end if;

  return jsonb_build_object(
    'return_id', v_return_id,
    'original_sale_id', p_original_sale_id,
    'refund_amount', v_refund_amount,
    'refund_method', p_refund_method,
    'is_full_return', v_net_remaining = 0,
    'sale_status', case when v_net_remaining = 0 then 'returned' else v_sale.status end,
    'billing_status', v_billing_status
  );
end;
$$;

comment on function public.create_sale_return(uuid, jsonb, public.sale_refund_method, uuid, text) is
  'Nunca hace hard delete. BUGFIX 55: agrega el mismo guard que create_sale_exchange — un pedido '
  'Web PENDING_PICKUP no admite devolución hasta entregarse. Todo lo demás es exactamente '
  '20260201000053, sin cambios.';

-- =============================================================================
-- MIGRACIÓN 056_web_payment_status_metrics_filter
-- Fuente: supabase/migrations/20260201000056_web_payment_status_metrics_filter.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 56 · Circuito Ventas Web — filtro central de métricas/comisión
-- por payment_status (cierre de BLOQUE B)
-- =============================================================================
-- Aprobado por el usuario (sección 10/32 del pedido original, precisado en la
-- ronda de BLOQUE B): un pedido Web PENDING de cobro NO debe sumar
-- facturación/revenue ni comisión — recién cuenta cuando payment_status='PAID'.
-- fulfillment (pendiente de retiro o ya entregado) NO cambia esta condición
-- económica — son ejes distintos, nunca se mezclan (regla ya establecida).
-- Un pedido cancelado/reembolsado ya queda afuera por status<>'confirmed',
-- sin cambios ahí.
--
-- Filtro único, centralizado, agregado literalmente igual en cada WHERE de
-- revenue/comisión de las 3 funciones aprobadas:
--   and (s.payment_status is null or s.payment_status = 'PAID')
-- payment_status es null para TODA venta no-Web (el 100% de las ventas hasta
-- hoy) — así que esta condición es un no-op exacto para ellas, cero cambio
-- de comportamiento. Solo empieza a filtrar algo el día que exista el primer
-- pedido Web con payment_status='PENDING'.
--
-- NO se toca critical_stock_count (alerta de stock físico, dimensión
-- distinta) ni customer_purchase_history (no estaba en el alcance aprobado:
-- historial de compras del cliente, no un reporte de facturación/comisión).
-- Mismas firmas exactas que 20260201000041 — CREATE OR REPLACE sin DROP.

create or replace function public.dashboard_report(
  p_from date,
  p_to date,
  p_location_id uuid default null,
  p_sales_channel_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_from timestamptz;
  v_to timestamptz;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  return jsonb_build_object(
    'kpis', (
      select jsonb_build_object(
        'sales_count', count(*),
        'revenue', coalesce(sum(sn.net_total), 0),
        'avg_ticket', coalesce(round(avg(sn.net_total), 2), 0),
        'units_sold', coalesce(sum(sn.net_units), 0),
        'web_sales_count', coalesce(sum(case when sc.code = 'WEB' then 1 else 0 end), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join public.sales_channels sc on sc.id = s.sales_channel_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(net_quantity), 0) as net_units,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
        and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    ),
    'revenue_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (s.sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by 1
      ) t
    ),
    'sales_by_location', (
      select coalesce(jsonb_agg(jsonb_build_object('location', sl.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.location_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.location_id
      ) t
      join public.stock_locations sl on sl.id = t.location_id
    ),
    'sales_by_channel', (
      select coalesce(jsonb_agg(jsonb_build_object('channel', sc.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.sales_channel_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.sales_channel_id
      ) t
      join public.sales_channels sc on sc.id = t.sales_channel_id
    ),
    'revenue_by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('payment_method', pm.name, 'revenue', t.revenue)), '[]'::jsonb)
      from (
        select s.payment_method_id, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.payment_method_id
      ) t
      join public.payment_methods pm on pm.id = t.payment_method_id
    ),
    'top_products_by_units', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'units', t.units) order by t.units desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
        order by units desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'top_products_by_revenue', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'revenue', t.revenue) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_line_total) > 0
        order by revenue desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'commission_by_doctor', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'doctor_id', d.id, 'doctor', d.full_name, 'sales_count', t.cnt,
        'commissionable_revenue', t.commissionable_revenue, 'commission', t.commission
      ) order by t.commission desc), '[]'::jsonb)
      from (
        select s.doctor_id, count(*) as cnt,
          sum(sn.net_commissionable) as commissionable_revenue,
          sum(case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end) as commission
        from public.sales s
        join lateral (
          select
            coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
            coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and s.doctor_id is not null
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.doctor_id
      ) t
      join public.doctors d on d.id = t.doctor_id
    ),
    'critical_stock_count', (
      select count(*) from public.product_stock_status pss
      where pss.status in ('bajo', 'sin_stock')
        and pss.product_active = true
        and public.has_location_access(pss.location_id)
        and (p_location_id is null or pss.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.dashboard_report(date, date, uuid, uuid) is
  'Único punto de agregación para /dashboard. Requiere admin o can_view_financial_reports. '
  'Toda la agregación ocurre en SQL: el cliente nunca pagina/filtra ventas crudas. '
  'critical_stock_count excluye productos inactivos — no son una alerta operativa real. '
  'Revenue/unidades/top productos/comisión son SIEMPRE netos de devoluciones (sale_item_net) — '
  'status=confirmed solo no alcanza porque una devolución parcial no cambia el status. BUGFIX 56: '
  'además excluyen un pedido Web con payment_status=PENDING (no cobrado todavía) — fulfillment '
  '(pendiente/entregado) no cambia esta condición económica, son ejes distintos.';

-- ---------------------------------------------------------------------------
-- 2) product_revenue_report
-- ---------------------------------------------------------------------------
create or replace function public.product_revenue_report(
  p_from date,
  p_to date,
  p_location_id uuid default null,
  p_sales_channel_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_from timestamptz;
  v_to timestamptz;
  v_rows jsonb;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', p.id, 'sku', p.sku, 'name', p.name, 'product_type', p.product_type,
    'units', t.units, 'revenue', t.revenue, 'discount_total', t.discount_total
  ) order by t.revenue desc), '[]'::jsonb)
  into v_rows
  from (
    select sin.product_id, sum(sin.net_quantity) as units, sum(sin.net_line_total) as revenue,
      sum(si.line_discount) as discount_total
    from public.sale_item_net sin
    join public.sale_items si on si.id = sin.sale_item_id
    join public.sales s on s.id = sin.sale_id
    where s.status = 'confirmed' and s.sold_at between v_from and v_to
      and (s.payment_status is null or s.payment_status = 'PAID')
      and public.has_location_access(s.location_id)
      and (p_location_id is null or s.location_id = p_location_id)
      and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    group by sin.product_id
  ) t
  join public.products p on p.id = t.product_id;

  return jsonb_build_object('rows', v_rows);
end;
$$;

comment on function public.product_revenue_report(date, date, uuid, uuid) is
  'Facturación completa por producto/kit (sin LIMIT, para /dashboard/productos). '
  'Un kit atribuye su facturación a sí mismo — nunca se reparte entre kit_components. '
  'units/revenue son netos de devoluciones (sale_item_net); discount_total queda bruto. '
  'BUGFIX 56: excluye pedidos Web con payment_status=PENDING.';

-- ---------------------------------------------------------------------------
-- 3) doctor_sales_detail
-- ---------------------------------------------------------------------------
create or replace function public.doctor_sales_detail(
  p_doctor_id uuid,
  p_from date,
  p_to date,
  p_location_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_from timestamptz;
  v_to timestamptz;
  v_doctor public.doctors;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  select * into v_doctor from public.doctors where id = p_doctor_id;
  if v_doctor is null then
    raise exception 'La doctora no existe.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  return jsonb_build_object(
    'doctor', jsonb_build_object('id', v_doctor.id, 'full_name', v_doctor.full_name, 'code', v_doctor.code),
    'summary', (
      select jsonb_build_object(
        'sales_count', count(*),
        'commissionable_revenue', coalesce(sum(sn.net_commissionable), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join lateral (
        select
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    ),
    'products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_id', p.id, 'name', p.name, 'units', t.units, 'revenue', t.revenue
      ) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
      ) t
      join public.products p on p.id = t.product_id
    ),
    'sales', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'sale_number', s.sale_number, 'sold_at', s.sold_at,
        'total', sn.net_total,
        'commission_total', case when sn.gross_commissionable > 0
          then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
          else 0 end,
        'location', sl.name
      ) order by s.sold_at desc), '[]'::jsonb)
      from public.sales s
      join public.stock_locations sl on sl.id = s.location_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.doctor_sales_detail(uuid, date, date, uuid) is
  'Drill-down de Ventas por médica: resumen + productos vendidos + listado de '
  'operaciones, todos netos de devoluciones (sale_item_net). sales.commission_total '
  'nunca se reescribe — se reaplica su tasa efectiva original sobre la base comisionable neta. '
  'BUGFIX 56: excluye pedidos Web con payment_status=PENDING de las 3 secciones (summary/products/sales).';

-- =============================================================================
-- MIGRACIÓN 057_web_fulfillment_permissions_and_billing_fix
-- Fuente: supabase/migrations/20260201000057_web_fulfillment_permissions_and_billing_fix.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 57 · Circuito Ventas Web — cierre BLOQUE C: permisos de
-- fulfillment para admin + timing correcto de billing_status vs payment_status
-- =============================================================================
-- Dos hallazgos confirmados por auditoría (releyendo el código vigente de
-- 20260201000055, sin necesidad de reproducir en datos — ambos son
-- estructurales) antes de tocar nada, tal como se pidió:
--
-- HALLAZGO 1 — permisos: create_sale() valida
-- `has_location_access(p_location_id)` de forma UNIFORME para toda venta,
-- Web incluida — esa función es rol-agnóstica desde el origen del proyecto
-- ("un admin también necesita estar en profile_locations", comentario de
-- 20260101000002_profiles.sql). Confirmado con el código: hoy, un admin SIN
-- Sede 25 en profile_locations NO PUEDE crear un pickup en Sede 25 (ídem
-- Sede 37 y Depósito/SHIPPING) — la función corta en esa validación antes
-- de llegar a resolver canal/fulfillment. Esto predata BLOQUE B/C, nunca
-- fue un requisito específico de Web hasta ahora.
--
-- HALLAZGO 2 — billing_status: fn_create_sale_core (línea "v_billing_status
-- := 'PENDING'") lo setea de forma INCONDICIONAL apenas el medio de pago
-- factura (TRANSFER/CARD_1/CARD_3), sin mirar payment_status. Confirmado:
-- crear HOY "Web + payment_status=PENDING + Transferencia" deja
-- billing_status='PENDING' desde el instante de creación, generando
-- obligación de facturación antes de que exista un cobro real — exactamente
-- lo que el usuario NO quiere. mark_web_order_paid, además, nunca toca
-- billing_status — un pedido creado con billing_status=NOT_REQUIRED (si se
-- corrige el hallazgo 2) se quedaría así para siempre, nunca facturable, ni
-- siquiera después de cobrado.
--
-- FIX 1 (create_sale): admin + canal WEB puede operar sobre Sede 25/37/
-- Depósito SIN necesitar profile_locations — bypass acotado a esos 3
-- códigos exactos, nunca a cualquier sede. Nunca aplica a vendedores (el
-- canal Web ya es admin-only, sección 18 del pedido original) ni a ventas
-- presenciales (el bypass exige v_channel_code = 'WEB' explícito). El resto
-- del sistema (Stock, Movimientos, ventas presenciales) sigue exactamente
-- igual — has_location_access() en sí NO se modifica.
--
-- FIX 2 (fn_create_sale_core + mark_web_order_paid): billing_status queda
-- NOT_REQUIRED al crear un pedido Web PENDING de cobro (aunque el medio de
-- pago sea de los que facturan) — la obligación de facturación nace recién
-- al cobrar. mark_web_order_paid, al pasar a PAID, evalúa si el medio de
-- pago vigente factura y, si corresponde, activa billing_status='PENDING'
-- recién en ese momento (nunca antes, nunca lo pisa si ya viene distinto).
-- DNI sigue exigido en la creación sin cambios — es información del
-- cliente, se recolecta con el cliente presente, no depende de cuándo se
-- cobra.
--
-- NO se toca en este archivo: deliver_web_pickup (sigue exigiendo
-- has_location_access real, sin bypass de admin — ver informe entregado al
-- usuario, es una pregunta abierta, no una corrección todavía), ni ninguna
-- otra función.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) fn_create_sale_core — misma firma exacta que 20260201000055 (sin
--    cambios de parámetros, create or replace alcanza). Único cambio real:
--    v_billing_status ya no se fija en 'PENDING' de forma incondicional.
-- ---------------------------------------------------------------------------
create or replace function public.fn_create_sale_core(
  p_seller_id uuid,
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid,
  p_doctor_id uuid,
  p_notes text,
  p_external_source text,
  p_external_order_id text,
  p_sold_at timestamptz,
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null,
  p_fulfillment_type public.sale_fulfillment_type default null,
  p_payment_status public.sale_payment_status default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_quote jsonb;
  v_sale_id uuid;
  v_sale_number text;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_line jsonb;
  v_line_promotion_id uuid;
  v_promotion public.promotions;
  v_required record;
  v_allow_negative boolean;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
  v_deposito_location_id uuid;
  v_pickup_location_id uuid;
  v_fulfillment_status public.sale_fulfillment_status;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  if not exists (select 1 from public.sales_channels where id = p_sales_channel_id and active) then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
  if v_payment_method_code is null then
    raise exception 'El medio de pago seleccionado no existe o está inactivo.';
  end if;

  if p_customer_id is not null and not exists (
    select 1 from public.customers where id = p_customer_id and active
  ) then
    raise exception 'El cliente seleccionado no existe.';
  end if;

  if p_doctor_id is not null and not exists (
    select 1 from public.doctors where id = p_doctor_id and active
  ) then
    raise exception 'La doctora seleccionada no existe o está inactiva.';
  end if;

  if p_is_free_sale and p_free_sale_reason is null then
    raise exception 'Una entrega sin costo necesita un motivo (regalo, muestra, canje, cortesía u otro).';
  end if;

  if p_sold_at < now() - interval '1 hour' and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta con fecha anterior.';
  end if;

  if p_skip_stock_movement and not public.is_admin() then
    raise exception 'Solo un administrador puede cargar una venta sin descontar stock.';
  end if;

  if p_skip_stock_movement and p_is_free_sale then
    raise exception 'Una entrega sin costo siempre descuenta stock — no se puede combinar con carga histórica.';
  end if;

  if p_fulfillment_type is not null then
    if p_is_free_sale or p_skip_stock_movement then
      raise exception 'Un pedido Web (retiro o envío) no puede ser una entrega sin costo ni una carga histórica.';
    end if;

    if p_payment_status is null then
      raise exception 'Un pedido Web necesita indicar el estado de pago (pagado / pendiente de cobro).';
    end if;

    select id into v_deposito_location_id from public.stock_locations where code = 'DEP';

    if p_fulfillment_type = 'SHIPPING' then
      if p_location_id is distinct from v_deposito_location_id then
        raise exception 'Envío por correo solo puede descontar stock del Depósito.';
      end if;
      v_pickup_location_id := null;
      v_fulfillment_status := 'SHIPPED';
    else -- PICKUP
      if p_location_id = v_deposito_location_id then
        raise exception 'Retiro en sede no puede ser en Depósito — elegí Sede 25 o Sede 37.';
      end if;
      v_pickup_location_id := p_location_id;
      v_fulfillment_status := 'PENDING_PICKUP';
    end if;
  end if;

  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    -- BUGFIX 57: mientras un pedido Web esté PENDING de cobro, todavía no
    -- existe un cobro real — la obligación de facturación (billing_status)
    -- NO nace acá. Nace recién al cobrar (mark_web_order_paid). Para
    -- cualquier otro caso (no-Web, o Web ya pagado) es exactamente el
    -- comportamiento de siempre.
    if p_payment_status is distinct from 'PENDING' then
      if p_payment_account_id is null or not exists (
        select 1 from public.payment_accounts where id = p_payment_account_id and active
      ) then
        raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
      end if;
      v_payment_account_id := p_payment_account_id;
      v_billing_status := 'PENDING';
    else
      v_payment_account_id := p_payment_account_id; -- puede venir null, o ya cargada si se conoce
      v_billing_status := 'NOT_REQUIRED';
    end if;

    -- DNI sigue exigido siempre que el medio de pago facture, cobrado o no
    -- — es información del cliente, se recolecta con el cliente presente,
    -- nunca depende de cuándo se cobra.
    if p_customer_id is null or not exists (
      select 1 from public.customers
      where id = p_customer_id and dni is not null and trim(dni) <> ''
    ) then
      raise exception
        'Esta operación se puede facturar, así que necesita un cliente identificado con nombre y DNI.';
    end if;
  else
    v_payment_account_id := null;
    v_billing_status := 'NOT_REQUIRED';
  end if;

  if p_external_source is not null and p_external_order_id is not null
     and exists (
       select 1 from public.sales
       where external_source = p_external_source and external_order_id = p_external_order_id
     ) then
    raise exception 'Este pedido externo ya fue importado (%: %).', p_external_source, p_external_order_id;
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  v_quote := public.fn_pricing_quote(p_items, p_payment_method_id, p_sold_at, p_is_free_sale);
  if not (v_quote ->> 'ok')::boolean then
    raise exception '%', v_quote ->> 'error_message';
  end if;

  if not p_is_free_sale and p_doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = p_doctor_id;
  end if;

  select coalesce(sum((line ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_quote -> 'lines') line
  where (line ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_sale_number := public.fn_next_sale_number(p_location_id, p_sold_at);

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status,
    fulfillment_type, fulfillment_status, payment_status, pickup_location_id
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status,
    p_fulfillment_type, v_fulfillment_status, p_payment_status, v_pickup_location_id
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    v_line_promotion_id := nullif(v_line ->> 'applied_promotion_id', '')::uuid;
    if v_line_promotion_id is not null then
      select * into v_promotion from public.promotions where id = v_line_promotion_id;
    else
      v_promotion := null;
    end if;

    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount,
      promotion_name_snapshot, promotion_type_snapshot, promotion_discount_percent_snapshot,
      promotion_started_at_snapshot, promotion_ended_at_snapshot
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      coalesce((v_line ->> 'line_surcharge')::numeric, 0),
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      v_line_promotion_id,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      v_promotion.name, v_promotion.type, v_promotion.discount_percent,
      v_promotion.valid_from, v_promotion.valid_until
    );
  end loop;

  if p_fulfillment_type = 'PICKUP' then
    for v_required in
      with items as (
        select id as sale_item_id, product_id, quantity
        from public.sale_items
        where sale_id = v_sale_id
      ),
      expanded as (
        select i.sale_item_id, i.product_id, i.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = true
        union all
        select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = false
        join public.kit_components kc on kc.kit_product_id = i.product_id
      )
      select sale_item_id, product_id, sum(required_qty) as required_qty
      from expanded
      group by sale_item_id, product_id
      order by product_id
    loop
      perform public.fn_reserve_stock(
        v_sale_id, v_required.sale_item_id, p_location_id, v_required.product_id,
        v_required.required_qty, p_seller_id, false
      );
    end loop;
  elsif not p_skip_stock_movement then
    for v_required in
      with items as (
        select id as sale_item_id, product_id, quantity
        from public.sale_items
        where sale_id = v_sale_id
      ),
      expanded as (
        select i.sale_item_id, i.product_id, i.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = true
        union all
        select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
        from items i
        join public.products p on p.id = i.product_id and p.track_stock = false
        join public.kit_components kc on kc.kit_product_id = i.product_id
      )
      select sale_item_id, product_id, sum(required_qty) as required_qty
      from expanded
      group by sale_item_id, product_id
      order by product_id
    loop
      perform public.fn_check_available_stock(
        p_location_id, v_required.product_id, v_required.required_qty, v_allow_negative
      );
      perform public.fn_apply_stock_movement(
        p_location_id => p_location_id,
        p_product_id => v_required.product_id,
        p_movement_type => 'SALE',
        p_quantity_delta => -v_required.required_qty,
        p_sale_id => v_sale_id,
        p_reference => v_sale_number,
        p_created_by => p_seller_id,
        p_allow_negative => v_allow_negative,
        p_source_sale_item_id => v_required.sale_item_id
      );
    end loop;
  end if;

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'sale_number', v_sale_number,
    'total', (v_quote ->> 'total')::numeric,
    'subtotal', (v_quote ->> 'subtotal')::numeric,
    'discount_total', (v_quote ->> 'discount_total')::numeric,
    'surcharge_total', coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'is_free_sale', p_is_free_sale,
    'stock_skipped', p_skip_stock_movement,
    'billing_status', v_billing_status,
    'fulfillment_type', p_fulfillment_type,
    'fulfillment_status', v_fulfillment_status,
    'payment_status', p_payment_status,
    'pickup_location_id', v_pickup_location_id,
    'lines', v_quote -> 'lines'
  );
end;
$$;

comment on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid,
  public.sale_fulfillment_type, public.sale_payment_status
) is
  'Punto único de creación de ventas confirmadas. BUGFIX 57: billing_status queda NOT_REQUIRED '
  'mientras un pedido Web esté payment_status=PENDING, aunque el medio de pago facture — la '
  'obligación de facturación nace recién al cobrar (mark_web_order_paid). DNI sigue exigido en la '
  'creación sin cambios. Para todo lo demás (no-Web, o Web ya PAID) es el comportamiento de '
  'siempre. Resto de la función sin cambios respecto de 20260201000055/56.';

-- ---------------------------------------------------------------------------
-- 2) create_sale — misma firma exacta. Único cambio real: el chequeo de
--    sede admite un bypass acotado para admin + canal WEB + Sede 25/37/
--    Depósito exactos (nunca cualquier sede, nunca otro rol, nunca otro
--    canal). Se reordena v_channel_code ANTES del chequeo de sede (antes se
--    resolvía después) para poder evaluar el bypass.
-- ---------------------------------------------------------------------------
create or replace function public.create_sale(
  p_items jsonb,
  p_location_id uuid,
  p_sales_channel_id uuid,
  p_payment_method_id uuid,
  p_customer_id uuid default null,
  p_doctor_id uuid default null,
  p_notes text default null,
  p_external_source text default null,
  p_external_order_id text default null,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false,
  p_free_sale_reason public.free_sale_reason default null,
  p_free_sale_notes text default null,
  p_skip_stock_movement boolean default false,
  p_payment_account_id uuid default null,
  p_fulfillment_type public.sale_fulfillment_type default null,
  p_payment_status public.sale_payment_status default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_channel_code text;
  v_web_location_allowed boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede cargar ventas.';
  end if;

  select code into v_channel_code from public.sales_channels where id = p_sales_channel_id;

  if v_channel_code = 'WEB' and v_profile.role <> 'admin' then
    raise exception 'Solo un administrador puede registrar ventas por el canal Web.';
  end if;

  -- BUGFIX 57: un admin operando el canal Web puede elegir Sede 25/37/
  -- Depósito para el fulfillment SIN necesitar profile_locations — esas 3
  -- son las únicas ubicaciones que un pedido Web puede usar de todos modos
  -- (fn_create_sale_core ya lo exige estructuralmente), así que el bypass
  -- no amplía qué sede se puede tocar, solo quita la exigencia de
  -- asignación explícita PARA ESTE FLUJO. Nunca aplica a vendedores (el
  -- canal ya es admin-only, chequeo de arriba) ni a ventas presenciales
  -- (v_channel_code = 'WEB' explícito) — has_location_access() en sí no se
  -- toca, sigue rigiendo todo lo demás (Stock, Movimientos, ventas
  -- presenciales, entrega de pickup) exactamente igual que siempre.
  v_web_location_allowed :=
    v_profile.role = 'admin'
    and v_channel_code = 'WEB'
    and exists (
      select 1 from public.stock_locations
      where id = p_location_id and code in ('SED-25', 'SED-37', 'DEP')
    );

  if not (public.has_location_access(p_location_id) or v_web_location_allowed) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  if p_fulfillment_type is not null and v_channel_code <> 'WEB' then
    raise exception 'Forma de entrega (retiro/envío) solo aplica al canal Web.';
  end if;

  return public.fn_create_sale_core(
    auth.uid(), p_items, p_location_id, p_sales_channel_id, p_payment_method_id,
    p_customer_id, p_doctor_id, p_notes, p_external_source, p_external_order_id, p_sold_at,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    p_payment_account_id, p_fulfillment_type, p_payment_status
  );
end;
$$;

comment on function public.create_sale(
  jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid,
  public.sale_fulfillment_type, public.sale_payment_status
) is
  'Valida sede (has_location_access, con bypass acotado para admin + canal WEB + Sede 25/37/'
  'Depósito — BUGFIX 57) y canal (Web exclusivo de admin) antes de delegar en fn_create_sale_core. '
  'p_fulfillment_type/p_payment_status todavía no son obligatorios a nivel backend cuando el canal '
  'es WEB (riesgo de rollout documentado en 20260201000055, sigue vigente).';

-- ---------------------------------------------------------------------------
-- 3) mark_web_order_paid — misma firma exacta. Único cambio real: activa
--    billing_status='PENDING' recién en este momento si el medio de pago
--    vigente factura y el pedido no lo tenía ya activado (fue creado
--    NOT_REQUIRED por estar PENDING de cobro, BUGFIX 57 arriba). Nunca pisa
--    un billing_status que ya sea distinto (ej. si en algún escenario
--    futuro ya viniera INVOICED/PENDING desde antes, se respeta tal cual).
-- ---------------------------------------------------------------------------
create or replace function public.mark_web_order_paid(
  p_sale_id uuid,
  p_payment_method_id uuid default null,
  p_payment_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_new_billing_status public.sale_billing_status;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede registrar cobros.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type is null then
    raise exception 'Este pedido no es un pedido Web.';
  end if;

  if not (public.has_location_access(v_sale.location_id) or v_profile.role = 'admin') then
    raise exception 'Tu usuario no tiene acceso a la sede de este pedido.';
  end if;

  if v_sale.payment_status = 'PAID' then
    raise exception 'Este pedido ya está marcado como pagado.';
  end if;

  if p_payment_method_id is not null then
    select code into v_payment_method_code from public.payment_methods where id = p_payment_method_id and active;
    if v_payment_method_code is null then
      raise exception 'El medio de pago indicado no existe o está inactivo.';
    end if;
  else
    select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  end if;

  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    if coalesce(p_payment_account_id, v_sale.payment_account_id) is null then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;
    if p_payment_account_id is not null and not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'La cuenta indicada no existe o está inactiva.';
    end if;
  end if;

  -- BUGFIX 57: la obligación de facturación nace ACÁ, al cobrar — nunca
  -- antes. Si el pedido se creó NOT_REQUIRED (porque estaba PENDING de
  -- cobro, ver fn_create_sale_core) y el medio de pago vigente factura,
  -- pasa a PENDING recién ahora. Si billing_status ya no fuera
  -- NOT_REQUIRED por algún motivo (no debería pasar en este flujo, pero se
  -- programa defensivo), se respeta tal cual — nunca se pisa.
  v_new_billing_status := case
    when v_requires_billing and v_sale.billing_status = 'NOT_REQUIRED' then 'PENDING'
    else v_sale.billing_status
  end;

  update public.sales
  set payment_status = 'PAID',
      payment_method_id = coalesce(p_payment_method_id, payment_method_id),
      payment_account_id = coalesce(p_payment_account_id, payment_account_id),
      billing_status = v_new_billing_status
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_PAID', 'sales', p_sale_id,
    jsonb_build_object(
      'sale_id', p_sale_id, 'payment_method_id', coalesce(p_payment_method_id, v_sale.payment_method_id),
      'billing_status', v_new_billing_status
    )
  );

  return jsonb_build_object('sale_id', p_sale_id, 'payment_status', 'PAID', 'billing_status', v_new_billing_status);
end;
$$;

comment on function public.mark_web_order_paid(uuid, uuid, uuid) is
  'Cobro de un pedido Web (PENDING -> PAID). Nunca toca commission_total ni ningún otro snapshot. '
  'BUGFIX 57: activa billing_status=PENDING recién acá si el medio de pago factura y el pedido '
  'había quedado NOT_REQUIRED por estar pendiente de cobro — nunca antes, nunca lo pisa si ya '
  'venía distinto. No entrega (deliver_web_pickup es un paso aparte, que exige payment_status=PAID).';

-- =============================================================================
-- MIGRACIÓN 058_web_admin_delivery_bypass_and_stock_availability
-- Fuente: supabase/migrations/20260201000058_web_admin_delivery_bypass_and_stock_availability.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 58 · Circuito Ventas Web — bypass de admin en entrega +
-- disponibilidad comercial (físico - reservado) para Nueva Venta Web
-- =============================================================================
-- Cierre de los dos puntos pendientes que el usuario dejó explícitamente
-- abiertos al aprobar 20260201000057 (permisos de creación + timing de
-- billing_status):
--
-- 1) deliver_web_pickup: ahora admite el MISMO bypass acotado que ya tiene
--    create_sale (057) y mark_web_order_paid (055) — un admin sin la sede de
--    retiro en profile_locations puede marcar como entregado un pickup Web
--    válido de Sede 25 o Sede 37. Acotado EXCLUSIVAMENTE a:
--      - rol admin;
--      - v_sale.fulfillment_type = 'PICKUP' (estructuralmente exclusivo del
--        canal Web — sales_fulfillment_consistency de 20260201000054 nunca
--        deja fulfillment_type no nulo en una venta no-Web);
--      - pickup_location_id con code IN ('SED-25', 'SED-37') (chequeo
--        explícito igual al de 057, aunque ya esté garantizado por el CHECK
--        de la tabla — mismo estilo defensivo que el resto del archivo 057).
--    Un vendedor sigue necesitando has_location_access real: vendedora de
--    Sede 25 puede entregar pickups de Sede 25, nunca de Sede 37. Ninguna
--    otra validación de deliver_web_pickup cambia (pago PAID, no repetir
--    entrega, etc. — todo lo demás queda idéntico a 20260201000055).
--
-- 2) web_admin_stock_availability(p_location_id): nueva RPC de lectura,
--    security definer, admin-only, para alimentar el selector de stock de
--    Nueva Venta Web SIN ampliar RLS general de inventory_balances /
--    product_stock_status / kit_availability (esas vistas y sus políticas
--    de RLS quedan exactamente como están — vendedores y ventas
--    presenciales las siguen usando sin cambios).
--
--    Devuelve, para Sede 25 / Sede 37 / Depósito (las únicas 3 sedes que
--    Web puede usar), disponible = físico - reservas ACTIVE — la MISMA
--    fórmula que ya usa fn_check_available_stock, acá solo LEÍDA (sin lock,
--    sin insertar nada) — y, para kits, la cantidad armable usando ese
--    disponible por componente en vez del físico crudo (misma lógica de
--    fn_kit_buildable_qty, adaptada). Esto además adelanta el pendiente de
--    "Nueva Venta debería mostrar disponible, no físico" — para el flujo
--    Web específicamente, sin tocar el resto de las pantallas.
--
--    Una sola query (dos ramas UNION ALL sobre la misma CTE `reserved`) —
--    nunca un loop por producto, nunca N llamados a la RPC por fila. El
--    admin bajo prueba (sin ninguna sede en profile_locations) puede
--    invocarla igual que cualquier otro admin porque la autorización es
--    interna (is_admin()), nunca depende de RLS de inventory_balances.
--
-- Ambos cambios son additivos — no se modifica 054/055/056/057.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) deliver_web_pickup: agrega el bypass de admin acotado.
-- ---------------------------------------------------------------------------
create or replace function public.deliver_web_pickup(p_sale_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_reservation record;
  v_reserved_count int := 0;
  v_expected_count int;
  v_admin_pickup_bypass boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede marcar entregas.';
  end if;

  select * into v_sale from public.sales where id = p_sale_id for update;

  if v_sale is null then
    raise exception 'El pedido no existe.';
  end if;

  if v_sale.fulfillment_type <> 'PICKUP' then
    raise exception 'Este pedido no es un retiro en sede.';
  end if;

  -- Bypass acotado (idéntico en espíritu al de create_sale en 057): un
  -- admin puede entregar cualquier pickup Web válido de Sede 25/37 aunque
  -- no tenga esa sede en profile_locations. Nunca aplica a otros roles, ni
  -- a ningún otro tipo de operación (ventas presenciales/Stock/Movimientos
  -- no llaman esta función). Un vendedor SIEMPRE necesita acceso real.
  v_admin_pickup_bypass :=
    v_profile.role = 'admin'
    and exists (
      select 1 from public.stock_locations sl
      where sl.id = v_sale.pickup_location_id and sl.code in ('SED-25', 'SED-37')
    );

  if not (public.has_location_access(v_sale.pickup_location_id) or v_admin_pickup_bypass) then
    raise exception 'Tu usuario no tiene acceso a la sede de retiro de este pedido.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Este pedido no está confirmado (anulado) — no se puede entregar.';
  end if;

  if v_sale.fulfillment_status = 'DELIVERED' then
    raise exception 'Este pedido ya fue entregado (%, por %).', v_sale.delivered_at, v_sale.delivered_by;
  end if;

  if v_sale.fulfillment_status <> 'PENDING_PICKUP' then
    raise exception 'Este pedido no está pendiente de retiro.';
  end if;

  if v_sale.payment_status <> 'PAID' then
    raise exception using
      errcode = 'P1003',
      message = 'Este pedido está pendiente de cobro — hay que cobrarlo antes de entregarlo (mark_web_order_paid).';
  end if;

  select count(*) into v_expected_count from public.sale_items where sale_id = p_sale_id;

  for v_reservation in
    select * from public.sale_stock_reservations
    where sale_id = p_sale_id and status = 'ACTIVE'
    order by product_id
    for update
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_reservation.location_id,
      p_product_id => v_reservation.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_reservation.quantity,
      p_sale_id => p_sale_id,
      p_reference => v_sale.sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => false,
      p_source_sale_item_id => v_reservation.sale_item_id
    );

    update public.sale_stock_reservations
    set status = 'CONSUMED', consumed_at = now()
    where id = v_reservation.id;

    v_reserved_count := v_reserved_count + 1;
  end loop;

  -- Post-chequeo (sección 44 del pedido): tiene que haber consumido al
  -- menos una reserva por cada sale_item con producto trackeable/kit — si
  -- un pedido quedó sin ninguna reserva ACTIVE (dato corrupto/huérfano),
  -- mejor abortar con excepción explícita que "entregar" sin mover nada.
  if v_reserved_count = 0 then
    raise exception 'Este pedido no tiene ninguna reserva de stock activa — no se puede entregar. Contactá a un administrador.';
  end if;

  update public.sales
  set fulfillment_status = 'DELIVERED', delivered_at = now(), delivered_by = auth.uid()
  where id = p_sale_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'WEB_ORDER_DELIVERED', 'sales', p_sale_id,
    jsonb_build_object(
      'sale_id', p_sale_id, 'location_id', v_sale.pickup_location_id,
      'fulfillment_type', v_sale.fulfillment_type, 'payment_status', v_sale.payment_status,
      'delivered_by', auth.uid(), 'admin_bypass', v_admin_pickup_bypass
    )
  );

  return jsonb_build_object(
    'sale_id', p_sale_id, 'fulfillment_status', 'DELIVERED',
    'delivered_at', now(), 'reservations_consumed', v_reserved_count
  );
end;
$$;

comment on function public.deliver_web_pickup(uuid) is
  'Transacción atómica: lock del pedido + sus reservas, valida sede/estado/cobro, consume cada '
  'reserva ACTIVE generando su SALE real (fn_apply_stock_movement, trazado por source_sale_item_id), '
  'marca DELIVERED + delivered_at/by, audita WEB_ORDER_DELIVERED. Cualquier excepción revierte todo '
  '(nada de stock descontado a medias). Exige payment_status=PAID — nunca entrega sin cobro resuelto. '
  'Un admin puede entregar cualquier pickup Web válido de Sede 25/37 sin necesitar esa sede en '
  'profile_locations (bypass acotado, 20260201000058) — un vendedor siempre necesita acceso real.';

-- ---------------------------------------------------------------------------
-- 2) web_admin_stock_availability: disponibilidad comercial (físico -
--    reservado) de Sede 25 / Sede 37 / Depósito, para Nueva Venta Web.
-- ---------------------------------------------------------------------------
create or replace function public.web_admin_stock_availability(p_location_id uuid default null)
returns table (
  location_id uuid,
  location_code text,
  product_id uuid,
  is_kit boolean,
  available numeric,
  status text
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede consultar disponibilidad para Ventas Web.';
  end if;

  return query
  with web_locations as (
    select sl.id, sl.code
    from public.stock_locations sl
    where sl.code in ('SED-25', 'SED-37', 'DEP')
      and (p_location_id is null or sl.id = p_location_id)
  ),
  reserved as (
    select ssr.location_id, ssr.product_id, sum(ssr.quantity) as reserved_qty
    from public.sale_stock_reservations ssr
    where ssr.status = 'ACTIVE'
    group by ssr.location_id, ssr.product_id
  ),
  simple_products as (
    select
      wl.id as location_id,
      wl.code as location_code,
      p.id as product_id,
      false as is_kit,
      coalesce(ib.quantity, 0) - coalesce(r.reserved_qty, 0) as available,
      coalesce(ib.min_stock_override, p.default_min_stock) as min_stock
    from public.products p
    cross join web_locations wl
    left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = wl.id
    left join reserved r on r.product_id = p.id and r.location_id = wl.id
    where p.track_stock = true and p.active = true
  ),
  kits as (
    select
      wl.id as location_id,
      wl.code as location_code,
      k.id as product_id,
      true as is_kit,
      coalesce(
        min(floor((coalesce(ib.quantity, 0) - coalesce(r.reserved_qty, 0)) / kc.quantity)),
        0
      ) as available
    from public.products k
    cross join web_locations wl
    join public.kit_components kc on kc.kit_product_id = k.id
    left join public.inventory_balances ib
      on ib.product_id = kc.component_product_id and ib.location_id = wl.id
    left join reserved r
      on r.product_id = kc.component_product_id and r.location_id = wl.id
    where k.active = true
    group by wl.id, wl.code, k.id
  )
  select
    sp.location_id, sp.location_code, sp.product_id, sp.is_kit, sp.available,
    case
      when sp.available <= 0 then 'sin_stock'
      when sp.available <= sp.min_stock then 'bajo'
      else 'ok'
    end as status
  from simple_products sp

  union all

  select
    kt.location_id, kt.location_code, kt.product_id, kt.is_kit, kt.available,
    null::text as status
  from kits kt;
end;
$$;

comment on function public.web_admin_stock_availability(uuid) is
  'Solo admin (is_admin(), chequeo interno — nunca depende de RLS). Disponible = físico - reservas '
  'ACTIVE (misma fórmula que fn_check_available_stock), para Sede 25/Sede 37/Depósito únicamente — '
  'las 3 sedes que Ventas Web puede usar. Kits: armable usando ese disponible por componente (misma '
  'lógica de fn_kit_buildable_qty). Una sola query (CTE reserved compartida), sin loops por producto. '
  'No modifica RLS de inventory_balances/product_stock_status/kit_availability — esas vistas y '
  'vendedores/ventas presenciales siguen exactamente igual. Pensada para alimentar Nueva Venta Web '
  'cuando el admin que la usa no tiene la sede en profile_locations (20260201000057 ya le permite '
  'crear la venta; esta RPC evita que la vea con stock vacío por RLS).';

-- =============================================================================
-- MIGRACIÓN 059_web_pending_pickups
-- Fuente: supabase/migrations/20260201000059_web_pending_pickups.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 59 · Circuito Ventas Web — BLOQUE D: bandeja de Notificaciones
-- (pedidos Web pendientes de retiro) + contador
-- =============================================================================
-- Definición acordada: NO se crea una tabla `notifications` — la bandeja se
-- deriva directo de `sales` (canal WEB + fulfillment_type=PICKUP +
-- fulfillment_status=PENDING_PICKUP), exactamente como sale_stock_
-- reservations se decidió como la única fuente de verdad para reservas en
-- BLOQUE A. Una única RPC (`web_pending_pickups`) sirve TANTO al contador
-- de navegación (el layout toma length(resultado)) COMO a la pantalla de
-- Notificaciones (mismo resultado, sin volver a filtrar) — una sola fuente
-- de verdad, cero lógica duplicada entre "contar" y "listar".
--
-- Por qué es una RPC (security definer) y no un select directo con RLS:
-- sales_select ya exige has_location_access(location_id) inclusive para
-- admin (mismo motivo estructural que obligó a web_admin_stock_availability
-- en 20260201000058) — un admin sin Sede 25/37 en profile_locations vería
-- la bandeja vacía aunque el pedido exista y sea perfectamente válido. Acá
-- la regla de visibilidad se decide DENTRO de la función:
--   - admin: ve TODOS los pendientes de retiro (Sede 25 + Sede 37), sin
--     depender de profile_locations — igual que ya puede crear/entregar
--     cualquiera de los dos (057/058).
--   - vendedor/viewer: solo ve los de la(s) sede(s) donde tiene acceso real
--     (has_location_access(pickup_location_id)) — Sede 25 ve solo Sede 25,
--     Sede 37 ve solo Sede 37. Viewer se deja pasar (rol de solo lectura,
--     puede consultar la bandeja igual que consulta todo lo demás) — la
--     acción de cobrar/entregar la sigue rechazando mark_web_order_paid/
--     deliver_web_pickup, esta RPC no escribe nada.
--
-- Filtro (los 3 ejes pedidos, ninguno opcional):
--   - status = 'confirmed' (excluye canceladas — un pickup pendiente SE
--     PUEDE cancelar con cancel_sale, que libera la reserva pero nunca
--     mueve fulfillment_status; sin este filtro una venta cancelada
--     seguiría apareciendo en la bandeja).
--   - fulfillment_type = 'PICKUP' (nunca SHIPPING — un envío queda
--     fulfillment_status=SHIPPED desde el instante en que se crea, jamás
--     pasa por PENDING_PICKUP, así que este filtro es redundante con el
--     siguiente pero se deja explícito por legibilidad).
--   - fulfillment_status = 'PENDING_PICKUP' (nunca DELIVERED — un pedido ya
--     entregado desaparece de acá; queda para el historial de BLOQUE
--     siguiente, ver comentario al final).
--
-- Datos devueltos: los 10 campos pedidos (número de venta, fecha, cliente,
-- DNI, productos/kits y cantidades, total, forma de pago, payment_status,
-- sede de retiro, quién cargó la venta) en una ÚNICA query — sale_items +
-- products se agregan con jsonb_agg en un subselect correlacionado por
-- sale_id (no es un loop del lado de la aplicación: es una sola sentencia
-- SQL que Postgres resuelve con un solo plan, sin N+1 real). seller_id es
-- NOT NULL en sales (create_web_order, el único camino con seller_id NULL,
-- nunca pasa fulfillment_type — 20260101000016 — así que un inner join
-- contra profiles para "quién cargó la venta" es seguro acá).
--
-- Historial de entregados (siguiente bloque): a propósito esta función NO
-- recibe un parámetro de status — mantenerla fija a PENDING_PICKUP es lo
-- que pidió el usuario para este bloque. Cuando se implemente el historial,
-- la forma más simple de reusar esto es una función hermana con el mismo
-- SELECT y fulfillment_status IN ('DELIVERED') en vez de duplicar toda la
-- lógica de joins/agregación a mano — no se hace ahora para no adelantar
-- alcance sin pedido explícito, pero la estructura (mismo shape de fila,
-- mismos joins) queda lista para eso.
-- =============================================================================

create or replace function public.web_pending_pickups()
returns table (
  sale_id uuid,
  sale_number text,
  sold_at timestamptz,
  customer_name text,
  customer_dni text,
  items jsonb,
  total numeric,
  payment_method_id uuid,
  payment_method_name text,
  payment_account_id uuid,
  payment_status public.sale_payment_status,
  pickup_location_id uuid,
  pickup_location_code text,
  pickup_location_name text,
  seller_name text
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_profile public.profiles;
  v_see_all boolean;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  v_see_all := v_profile.role = 'admin';

  return query
  select
    s.id,
    s.sale_number,
    s.sold_at,
    c.full_name,
    c.dni,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_name', p.name,
            'quantity', si.quantity,
            'is_kit', p.product_type = 'kit'
          )
          order by p.name
        )
        from public.sale_items si
        join public.products p on p.id = si.product_id
        where si.sale_id = s.id
      ),
      '[]'::jsonb
    ) as items,
    s.total,
    s.payment_method_id,
    pm.name,
    s.payment_account_id,
    s.payment_status,
    s.pickup_location_id,
    sl.code,
    sl.name,
    seller.full_name
  from public.sales s
  join public.sales_channels ch on ch.id = s.sales_channel_id and ch.code = 'WEB'
  join public.payment_methods pm on pm.id = s.payment_method_id
  join public.stock_locations sl on sl.id = s.pickup_location_id
  join public.profiles seller on seller.id = s.seller_id
  left join public.customers c on c.id = s.customer_id
  where s.status = 'confirmed'
    and s.fulfillment_type = 'PICKUP'
    and s.fulfillment_status = 'PENDING_PICKUP'
    and (v_see_all or public.has_location_access(s.pickup_location_id))
  order by s.sold_at asc;
end;
$$;

comment on function public.web_pending_pickups() is
  'Bandeja de Notificaciones (BLOQUE D): pedidos Web PICKUP pendientes de retiro. Nunca crea una '
  'tabla notifications — se deriva de sales/sale_items/products, agregados en una sola query (sin '
  'N+1). admin ve todos (Sede 25 + Sede 37) sin depender de profile_locations, igual que ya puede '
  'crear/entregar cualquiera (057/058); vendedor/viewer solo ve su(s) sede(s) reales '
  '(has_location_access). Misma fuente para el contador de navegación (length del resultado) y para '
  'el listado completo — nunca se duplica el filtro en dos lugares.';

-- =============================================================================
-- MIGRACIÓN 060_web_order_history
-- Fuente: supabase/migrations/20260201000060_web_order_history.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 60 · Circuito Ventas Web — BLOQUE E: Historial de pedidos Web
-- =============================================================================
-- Misma fuente de verdad que BLOQUE D: NO se crea ninguna tabla de historial
-- paralela. Se deriva de sales/sale_items/products/profiles/customers, con
-- una única RPC nueva (web_order_history), mismo patrón exacto que
-- web_pending_pickups (059) — security definer, filtro de sede/rol resuelto
-- DENTRO de la función (no en RLS, por el mismo motivo estructural: admin
-- sin Sede 25/37/Depósito en profile_locations necesita ver TODO igual).
--
-- Auditoría previa (antes de escribir una sola línea de código, tal como se
-- pidió) sobre qué existe hoy para cubrir cada estado del historial:
--
--   - DELIVERED (pickup): delivered_at/delivered_by YA existen en sales
--     (20260201000054) con su propio CHECK de consistencia
--     (sales_delivered_consistency) — se usan tal cual, no se agrega nada.
--   - SHIPPED: el modelo actual NO tiene una columna shipped_at ni un actor
--     separado de "quién despachó". fn_create_sale_core (055) marca
--     fulfillment_status='SHIPPED' en el mismo instante de crear el pedido
--     (comentario textual del enum en 054: "SHIPPED se asigna una única vez,
--     en el momento de crear un pedido SHIPPING — el envío ya salió de
--     Depósito de inmediato"). No hay ninguna fecha de envío distinta de
--     sold_at, ni ningún registro de un "shipped_by" distinto del vendedor
--     que cargó la venta (seller_id). Conclusión de la auditoría: NO se
--     inventa una columna nueva. sold_at ES la fecha de envío (coinciden
--     por diseño); delivered_at/delivered_by quedan NULL siempre para
--     SHIPPING (lo exige sales_delivered_consistency) — el frontend decide
--     qué mostrar según fulfillment_type, esta RPC solo expone las
--     columnas reales, nunca fabrica un valor.
--   - CANCELLED: sales.status='cancelled' + cancelled_at/cancelled_by/
--     cancellation_reason YA existen de forma genérica desde el primer
--     schema de ventas (20260101000006) — cancel_sale (055) los llena
--     igual para un pedido Web que para uno presencial, y NUNCA toca
--     fulfillment_status al cancelar (puede quedar en cualquier estado
--     previo: PENDING_PICKUP, DELIVERED o SHIPPED). Por eso el filtro de
--     Historial usa status='cancelled' como eje independiente de
--     fulfillment_status — cubre un pickup cancelado antes de retirar, uno
--     cancelado después de entregado, y un envío cancelado.
--
-- display_status (columna calculada, nunca persistida): 'CANCELLED' si
-- status='cancelled' (sin importar fulfillment_status), si no
-- fulfillment_status tal cual ('DELIVERED' o 'SHIPPED'). Nunca aparece acá
-- 'PENDING_PICKUP' confirmado — esos pedidos siguen exclusivamente en
-- Notificaciones (BLOQUE D); un pickup PENDING_PICKUP cancelado sí entra acá
-- como CANCELLED (dejó de estar pendiente).
--
-- Filtros: sede (location_id — cubre pickup_location_id para PICKUP y
-- Depósito para SHIPPING, ambos caben en location_id), estado
-- (display_status), rango de fecha (sold_at, mismo criterio que el filtro
-- from/to de /ventas), búsqueda libre (número de venta / cliente / DNI).
-- Paginación: limit/offset con total_count vía count(*) over() en la misma
-- query (un solo round-trip, nunca un segundo select count(*) aparte).
-- limit se clampea a 100 como tope duro contra un límite mal pasado desde
-- el cliente.
-- =============================================================================

create or replace function public.web_order_history(
  p_location_id uuid default null,
  p_status text default null,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_search text default null,
  p_limit int default 30,
  p_offset int default 0
)
returns table (
  sale_id uuid,
  sale_number text,
  sold_at timestamptz,
  customer_name text,
  customer_dni text,
  items jsonb,
  total numeric,
  payment_method_name text,
  payment_status public.sale_payment_status,
  fulfillment_type public.sale_fulfillment_type,
  display_status text,
  location_id uuid,
  location_code text,
  location_name text,
  delivered_at timestamptz,
  delivered_by_name text,
  cancelled_at timestamptz,
  cancelled_by_name text,
  cancellation_reason text,
  seller_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_profile public.profiles;
  v_see_all boolean;
  v_limit int;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if p_status is not null and p_status not in ('DELIVERED', 'SHIPPED', 'CANCELLED') then
    raise exception 'Estado de historial inválido: %.', p_status;
  end if;

  v_see_all := v_profile.role = 'admin';
  v_limit := least(greatest(coalesce(p_limit, 30), 1), 100);

  return query
  select
    s.id,
    s.sale_number,
    s.sold_at,
    c.full_name,
    c.dni,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'product_name', p.name,
            'quantity', si.quantity,
            'is_kit', p.product_type = 'kit'
          )
          order by p.name
        )
        from public.sale_items si
        join public.products p on p.id = si.product_id
        where si.sale_id = s.id
      ),
      '[]'::jsonb
    ) as items,
    s.total,
    pm.name,
    s.payment_status,
    s.fulfillment_type,
    case when s.status = 'cancelled' then 'CANCELLED' else s.fulfillment_status::text end as display_status,
    s.location_id,
    sl.code,
    sl.name,
    s.delivered_at,
    delivered_by_profile.full_name,
    s.cancelled_at,
    cancelled_by_profile.full_name,
    s.cancellation_reason,
    seller.full_name,
    count(*) over ()
  from public.sales s
  join public.sales_channels ch on ch.id = s.sales_channel_id and ch.code = 'WEB'
  join public.payment_methods pm on pm.id = s.payment_method_id
  join public.stock_locations sl on sl.id = s.location_id
  join public.profiles seller on seller.id = s.seller_id
  left join public.customers c on c.id = s.customer_id
  left join public.profiles delivered_by_profile on delivered_by_profile.id = s.delivered_by
  left join public.profiles cancelled_by_profile on cancelled_by_profile.id = s.cancelled_by
  where s.fulfillment_type is not null
    and (s.status = 'cancelled' or s.fulfillment_status in ('DELIVERED', 'SHIPPED'))
    and (v_see_all or public.has_location_access(s.location_id))
    and (p_location_id is null or s.location_id = p_location_id)
    and (
      p_status is null
      or (p_status = 'CANCELLED' and s.status = 'cancelled')
      or (p_status <> 'CANCELLED' and s.status <> 'cancelled' and s.fulfillment_status::text = p_status)
    )
    and (p_date_from is null or s.sold_at >= p_date_from)
    and (p_date_to is null or s.sold_at <= p_date_to)
    and (
      p_search is null or trim(p_search) = ''
      or s.sale_number ilike '%' || p_search || '%'
      or c.full_name ilike '%' || p_search || '%'
      or c.dni ilike '%' || p_search || '%'
    )
  order by s.sold_at desc
  limit v_limit offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.web_order_history(uuid, text, timestamptz, timestamptz, text, int, int) is
  'Historial de pedidos Web (BLOQUE E): DELIVERED, SHIPPED y CANCELLED — nunca PENDING_PICKUP '
  'confirmado (eso sigue en Notificaciones/web_pending_pickups). admin ve todas las sedes sin '
  'depender de profile_locations; vendedor/viewer solo su(s) sede(s) real(es) '
  '(has_location_access). Sin tabla paralela: se deriva de sales/sale_items/products/profiles/'
  'customers. Paginado (limit clampeado a 100, offset) con total_count vía count(*) over() en la '
  'misma query — un solo round-trip. SHIPPED nunca tiene delivered_at/delivered_by (no existe una '
  'fecha/actor de envío separados en el modelo — sold_at coincide con el envío por diseño, ver '
  'comentario de la migración); el frontend decide qué mostrar según fulfillment_type, esta RPC '
  'nunca fabrica un valor que no esté en la base.';

-- ---------------------------------------------------------------------------
-- Índice de soporte: mismo criterio que sales_pickup_pending_idx (054) pero
-- para el conjunto de Historial (delivered/shipped/cancelled), filtrado por
-- sede y ordenado por fecha — cubre el WHERE + ORDER BY de arriba sin
-- escanear toda la tabla sales a medida que crece.
-- ---------------------------------------------------------------------------
create index sales_web_history_idx
  on public.sales (location_id, sold_at desc)
  where fulfillment_type is not null;

comment on index public.sales_web_history_idx is
  'Cubre web_order_history(): fulfillment_type is not null, filtrado por location_id y ordenado '
  'por sold_at. No filtra por status/fulfillment_status en la definición del índice (cambian con '
  'el tiempo — DELIVERED/CANCELLED se alcanzan después de creado el pedido) para que un único '
  'índice sirva tanto a Notificaciones (fulfillment_status=PENDING_PICKUP) como a Historial.';

-- =============================================================================
-- MIGRACIÓN 061_stock_available_transversal
-- Fuente: supabase/migrations/20260201000061_stock_available_transversal.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 61 · BLOQUE F — Stock disponible transversal
-- =============================================================================
-- Auditoría previa (ver informe entregado al usuario) confirmó que el
-- camino general de creación de ventas (fn_create_sale_core, rama no-PICKUP
-- — presenciales y SHIPPING) YA es reservation-aware desde BLOQUE B (055):
-- llama fn_check_available_stock antes de fn_apply_stock_movement. Ese
-- camino NO se toca acá. Lo que sí encontró la auditoría:
--
--   1) create_sale_exchange: el descuento del producto NUEVO llamaba
--      fn_apply_stock_movement directo, SIN fn_check_available_stock previo
--      — gap real de integridad (un cambio podía entregar una unidad
--      comprometida para un pickup Web pendiente). Se corrige acá.
--   2) transfer_stock: sin protección — un admin podía transferir stock
--      físicamente presente pero reservado, dejando "disponible" negativo
--      en origen. Se agrega un guard duro (fn_check_available_stock en la
--      sede de origen, SIEMPRE, sin importar allow_transfer_overdraft —
--      ese setting es sobre permitir físico negativo por flexibilidad
--      operativa, un eje distinto de "no romper una promesa ya hecha a un
--      cliente Web").
--   3) Todo el resto era un gap de VISUALIZACIÓN (el backend general ya
--      protegía la operación real, pero las pantallas mostraban físico
--      crudo, lo que podía llevar a un rechazo evitable al confirmar):
--      product_stock_status gana columnas ADITIVAS (reserved/available/
--      available_status — quantity/status NUNCA se tocan, siguen siendo el
--      físico crudo para /stock, el CSV de inventario y set-stock-dialog,
--      que deliberadamente quedan fuera de este bloque). kit_availability.
--      buildable_qty pasa a ser reservation-aware EN EL LUGAR (fn_
--      kit_buildable_qty) — a diferencia de un producto simple, "armable"
--      ya era un valor derivado sin significado "solo físico" que preservar.
--
-- Nueva Venta Web sigue usando web_admin_stock_availability (058) —
-- ninguna de las 2 vistas de acá reemplaza esa RPC, que existe por el
-- motivo estructural distinto de admin-sin-profile_locations.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) product_stock_status: agrega reserved/available/available_status.
--    quantity/status quedan exactamente iguales — /stock, el CSV de
--    inventario y set-stock-dialog los siguen usando sin ningún cambio.
-- ---------------------------------------------------------------------------
create or replace view public.product_stock_status
with (security_invoker = true) as
select
  p.id as product_id,
  p.sku,
  p.name,
  p.category,
  sl.id as location_id,
  sl.code as location_code,
  coalesce(ib.quantity, 0) as quantity,
  coalesce(ib.min_stock_override, p.default_min_stock) as min_stock,
  case
    when coalesce(ib.quantity, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as status,
  p.active as product_active,
  coalesce(res.reserved_qty, 0) as reserved,
  coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) as available,
  case
    when coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) - coalesce(res.reserved_qty, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as available_status
from public.products p
cross join public.stock_locations sl
left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = sl.id
left join lateral (
  select sum(ssr.quantity) as reserved_qty
  from public.sale_stock_reservations ssr
  where ssr.location_id = sl.id and ssr.product_id = p.id and ssr.status = 'ACTIVE'
) res on true
where p.track_stock = true;

comment on view public.product_stock_status is
  'Estado de stock por sede y producto trackeable. quantity/status = físico crudo, SIN CAMBIOS '
  '(así siguen /stock, el CSV de inventario y set-stock-dialog — verdad física real, deliberado). '
  'reserved/available/available_status son columnas ADITIVAS (BLOQUE F, 20260201000061): '
  'available = quantity - reservas ACTIVE de sale_stock_reservations. Nueva Venta (ambas ramas), '
  'Cambios/Devoluciones y Home usan available/available_status. Los kits usan kit_availability.';

-- ---------------------------------------------------------------------------
-- 2) fn_kit_buildable_qty: pasa a usar disponible real por componente
--    (físico del componente - reservas ACTIVE del componente), no el físico
--    crudo. Único consumidor: kit_availability (20260101000013) — ningún
--    otro lugar del sistema llama esta función, así que modificarla en el
--    lugar no tiene efectos colaterales que documentar aparte.
-- ---------------------------------------------------------------------------
create or replace function public.fn_kit_buildable_qty(p_kit_product_id uuid, p_location_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(
    min(
      floor(
        (
          coalesce(ib.quantity, 0)
          - coalesce(
              (
                select sum(ssr.quantity)
                from public.sale_stock_reservations ssr
                where ssr.location_id = p_location_id
                  and ssr.product_id = kc.component_product_id
                  and ssr.status = 'ACTIVE'
              ),
              0
            )
        ) / kc.quantity
      )
    ),
    0
  )
  from public.kit_components kc
  left join public.inventory_balances ib
    on ib.product_id = kc.component_product_id and ib.location_id = p_location_id
  where kc.kit_product_id = p_kit_product_id;
$$;

comment on function public.fn_kit_buildable_qty(uuid, uuid) is
  'Cuántas unidades del kit se pueden armar HOY con lo realmente disponible (físico - reservas '
  'ACTIVE) de cada componente en esa sede — BLOQUE F (20260201000061). A diferencia de un producto '
  'simple, "armable" ya era un valor derivado sin un "solo físico" que preservar para auditoría, '
  'así que se corrige en el lugar (único consumidor: kit_availability). Devuelve 0 si el kit no '
  'tiene componentes cargados.';

-- ---------------------------------------------------------------------------
-- 3) create_sale_exchange: agrega fn_check_available_stock antes de
--    descontar el producto NUEVO — mismo patrón que fn_create_sale_core
--    (055). Todo lo demás es exactamente 20260201000055, sin cambios.
-- ---------------------------------------------------------------------------
create or replace function public.create_sale_exchange(
  p_original_sale_id uuid,
  p_returned_sale_item_id uuid,
  p_returned_quantity numeric,
  p_new_product_id uuid,
  p_new_quantity numeric,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_sale public.sales;
  v_returned_item public.sale_items;
  v_new_product public.products;
  v_physical_source_id uuid;
  v_root_quantity numeric;
  v_root_sale_id uuid;
  v_has_traced_movements boolean;
  v_movement record;
  v_reversal_qty numeric;
  v_reversal_count integer;
  v_price jsonb;
  v_recognized_value numeric;
  v_new_line_total numeric;
  v_difference numeric;
  v_difference_direction public.sale_exchange_direction;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_replacement_billing_status public.sale_billing_status;
  v_difference_settlement_status public.sale_settlement_status;
  v_settings public.app_settings;
  v_allow_negative boolean;
  v_remaining_qty numeric;
  v_lines jsonb := '[]'::jsonb;
  v_line jsonb;
  v_item record;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_surcharge_total numeric := 0;
  v_total numeric := 0;
  v_commission_percent numeric := 0;
  v_commission_total numeric := 0;
  v_replacement_sale_id uuid;
  v_replacement_sale_number text;
  v_new_line_item_id uuid;
  v_new_sale_item_id uuid;
  v_exchange_id uuid;
  v_required record;
begin
  if auth.uid() is null then
    raise exception 'No autenticado.';
  end if;

  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar (desactivado).';
  end if;

  if v_profile.role = 'viewer' then
    raise exception 'Tu usuario es de solo lectura — no puede hacer cambios de producto.';
  end if;

  if p_returned_quantity is null or p_returned_quantity <= 0 then
    raise exception 'La cantidad devuelta tiene que ser mayor a 0.';
  end if;

  if p_new_quantity is null or p_new_quantity <= 0 then
    raise exception 'La cantidad del producto nuevo tiene que ser mayor a 0.';
  end if;

  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada o ya reemplazada por otro cambio) — no se puede volver a usar como origen de un cambio.';
  end if;

  if v_sale.fulfillment_status = 'PENDING_PICKUP' then
    raise exception 'Esta venta es un pedido Web todavía pendiente de retiro — no se puede hacer un cambio hasta que se entregue.';
  end if;

  if not public.has_location_access(v_sale.location_id) then
    raise exception 'Tu usuario no tiene acceso a la sucursal de esta venta.';
  end if;

  if v_sale.is_free_sale then
    raise exception 'No se puede hacer un cambio sobre una entrega sin costo.';
  end if;

  if v_sale.customer_id is null then
    raise exception 'La venta original no tiene un cliente identificado — no se puede hacer un cambio.';
  end if;

  select * into v_returned_item
  from public.sale_items
  where id = p_returned_sale_item_id
  for update;

  if v_returned_item is null or v_returned_item.sale_id <> p_original_sale_id then
    raise exception 'El producto a devolver no pertenece a esta venta.';
  end if;

  if p_returned_quantity > v_returned_item.quantity then
    raise exception
      'No podés devolver % unidades: esta línea solo tiene % disponibles (ya se descontó cualquier cambio anterior).',
      p_returned_quantity, v_returned_item.quantity;
  end if;

  select * into v_new_product from public.products where id = p_new_product_id and active = true;
  if v_new_product is null then
    raise exception 'El producto nuevo no existe o está inactivo.';
  end if;

  v_physical_source_id := coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id);
  select quantity, sale_id into v_root_quantity, v_root_sale_id
  from public.sale_items where id = v_physical_source_id;

  v_price := public.fn_exchange_new_item_price(p_new_product_id, p_new_quantity, v_sale.payment_method_id, now());
  if not (v_price ->> 'ok')::boolean then
    raise exception '%', v_price ->> 'error_message';
  end if;

  v_recognized_value := round(v_returned_item.sale_unit_price * p_returned_quantity, 2);
  v_new_line_total := (v_price ->> 'line_total')::numeric;
  v_difference := round(v_new_line_total - v_recognized_value, 2);
  v_difference_direction := case
    when v_difference > 0 then 'CUSTOMER_PAYS'
    when v_difference < 0 then 'BUSINESS_REFUNDS'
    else 'NONE'
  end;

  select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if not v_requires_billing then
    v_replacement_billing_status := 'NOT_REQUIRED';
    v_difference_settlement_status := 'NOT_REQUIRED';
  elsif v_sale.billing_status = 'INVOICED' then
    v_replacement_billing_status := 'INVOICED';
    v_difference_settlement_status := case when v_difference <> 0 then 'PENDING' else 'NOT_REQUIRED' end;
  else
    v_replacement_billing_status := 'PENDING';
    v_difference_settlement_status := 'NOT_REQUIRED';
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  for v_item in
    select * from public.sale_items where sale_id = p_original_sale_id and id <> p_returned_sale_item_id
  loop
    v_lines := v_lines || jsonb_build_object(
      'role', 'copy',
      'product_id', v_item.product_id,
      'quantity', v_item.quantity,
      'list_unit_price', v_item.list_unit_price,
      'sale_unit_price', v_item.sale_unit_price,
      'line_list_total', v_item.line_list_total,
      'line_discount', round(greatest((v_item.list_unit_price - v_item.sale_unit_price) * v_item.quantity, 0), 2),
      'line_surcharge', round(greatest((v_item.sale_unit_price - v_item.list_unit_price) * v_item.quantity, 0), 2),
      'line_total', v_item.line_total,
      'applied_price_condition_id', v_item.applied_price_condition_id,
      'commissionable', v_item.commissionable,
      'applied_promotion_id', v_item.applied_promotion_id,
      'promotion_discount', v_item.promotion_discount,
      'promotion_name_snapshot', v_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', coalesce(v_item.physical_source_sale_item_id, v_item.id)
    );
  end loop;

  v_remaining_qty := v_returned_item.quantity - p_returned_quantity;
  if v_remaining_qty > 0 then
    v_lines := v_lines || jsonb_build_object(
      'role', 'remainder',
      'product_id', v_returned_item.product_id,
      'quantity', v_remaining_qty,
      'list_unit_price', v_returned_item.list_unit_price,
      'sale_unit_price', v_returned_item.sale_unit_price,
      'line_list_total', round(v_returned_item.list_unit_price * v_remaining_qty, 2),
      'line_discount', round(greatest((v_returned_item.list_unit_price - v_returned_item.sale_unit_price) * v_remaining_qty, 0), 2),
      'line_surcharge', round(greatest((v_returned_item.sale_unit_price - v_returned_item.list_unit_price) * v_remaining_qty, 0), 2),
      'line_total', round(v_returned_item.sale_unit_price * v_remaining_qty, 2),
      'applied_price_condition_id', v_returned_item.applied_price_condition_id,
      'commissionable', v_returned_item.commissionable,
      'applied_promotion_id', v_returned_item.applied_promotion_id,
      'promotion_discount', 0,
      'promotion_name_snapshot', v_returned_item.promotion_name_snapshot,
      'promotion_type_snapshot', v_returned_item.promotion_type_snapshot,
      'promotion_discount_percent_snapshot', v_returned_item.promotion_discount_percent_snapshot,
      'promotion_started_at_snapshot', v_returned_item.promotion_started_at_snapshot,
      'promotion_ended_at_snapshot', v_returned_item.promotion_ended_at_snapshot,
      'physical_source_sale_item_id', v_physical_source_id
    );
  end if;

  v_lines := v_lines || jsonb_build_object(
    'role', 'new',
    'product_id', p_new_product_id,
    'quantity', p_new_quantity,
    'list_unit_price', (v_price ->> 'list_unit_price')::numeric,
    'sale_unit_price', (v_price ->> 'sale_unit_price')::numeric,
    'line_list_total', (v_price ->> 'line_list_total')::numeric,
    'line_discount', (v_price ->> 'line_discount')::numeric,
    'line_surcharge', (v_price ->> 'line_surcharge')::numeric,
    'line_total', v_new_line_total,
    'applied_price_condition_id', (v_price ->> 'applied_price_condition_id')::uuid,
    'commissionable', v_new_product.commissionable,
    'applied_promotion_id', null,
    'promotion_discount', 0,
    'promotion_name_snapshot', null,
    'promotion_type_snapshot', null,
    'promotion_discount_percent_snapshot', null,
    'promotion_started_at_snapshot', null,
    'promotion_ended_at_snapshot', null,
    'physical_source_sale_item_id', null
  );

  select
    coalesce(sum((elem ->> 'line_list_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_surcharge')::numeric), 0),
    coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_subtotal, v_discount_total, v_surcharge_total, v_total
  from jsonb_array_elements(v_lines) elem;

  if v_sale.doctor_id is not null then
    select commission_percent into v_commission_percent from public.doctors where id = v_sale.doctor_id;
  end if;

  select coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_commission_total
  from jsonb_array_elements(v_lines) elem
  where (elem ->> 'commissionable')::boolean = true;

  v_commission_total := round(v_commission_total * v_commission_percent, 2);

  v_replacement_sale_number := public.fn_next_sale_number(v_sale.location_id, now());

  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    notes, payment_account_id, billing_status, invoiced_at, invoiced_by, replaces_sale_id
  ) values (
    v_replacement_sale_number, now(), v_sale.location_id, v_sale.sales_channel_id, auth.uid(),
    v_sale.customer_id, v_sale.doctor_id, v_sale.payment_method_id, null,
    v_subtotal, v_discount_total, v_surcharge_total, v_total, v_commission_total, 'confirmed',
    p_notes, v_sale.payment_account_id, v_replacement_billing_status,
    case when v_replacement_billing_status = 'INVOICED' then now() end,
    case when v_replacement_billing_status = 'INVOICED' then auth.uid() end,
    p_original_sale_id
  )
  returning id into v_replacement_sale_id;

  for v_line in select * from jsonb_array_elements(v_lines)
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_surcharge, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount, physical_source_sale_item_id,
      promotion_name_snapshot, promotion_type_snapshot, promotion_discount_percent_snapshot,
      promotion_started_at_snapshot, promotion_ended_at_snapshot
    ) values (
      v_replacement_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_surcharge')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      nullif(v_line ->> 'physical_source_sale_item_id', '')::uuid,
      v_line ->> 'promotion_name_snapshot',
      nullif(v_line ->> 'promotion_type_snapshot', '')::public.promotion_type,
      nullif(v_line ->> 'promotion_discount_percent_snapshot', '')::numeric,
      nullif(v_line ->> 'promotion_started_at_snapshot', '')::timestamptz,
      nullif(v_line ->> 'promotion_ended_at_snapshot', '')::timestamptz
    )
    returning id into v_new_sale_item_id;

    if v_line ->> 'role' = 'new' then
      v_new_line_item_id := v_new_sale_item_id;
    end if;
  end loop;

  select exists(
    select 1 from public.stock_movements
    where movement_type = 'SALE' and source_sale_item_id = v_physical_source_id
  ) into v_has_traced_movements;

  v_reversal_count := 0;
  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where movement_type = 'SALE'
      and (
        (v_has_traced_movements and source_sale_item_id = v_physical_source_id)
        or (not v_has_traced_movements and sale_id = v_root_sale_id and source_sale_item_id is null)
      )
    order by product_id
  loop
    v_reversal_qty := round(p_returned_quantity * abs(v_movement.quantity_delta) / v_root_quantity, 2);
    if v_reversal_qty is null or v_reversal_qty <= 0 then
      raise exception
        'No se pudo calcular una cantidad válida de reintegro de stock para el producto % (cantidad devuelta %, movimiento original % en cantidad raíz %) — resultado: %. Se aborta el cambio completo: no se descuenta el producto nuevo ni se reintegra nada.',
        v_movement.product_id, p_returned_quantity, v_movement.quantity_delta, v_root_quantity, v_reversal_qty;
    end if;
    perform public.fn_apply_stock_movement(
      p_location_id => v_movement.location_id,
      p_product_id => v_movement.product_id,
      p_movement_type => 'RETURN',
      p_quantity_delta => v_reversal_qty,
      p_sale_id => p_original_sale_id,
      p_reference => v_sale.sale_number,
      p_notes => format('Cambio %s', v_replacement_sale_number),
      p_created_by => auth.uid(),
      p_allow_negative => true,
      p_source_sale_item_id => v_physical_source_id
    );
    v_reversal_count := v_reversal_count + 1;
  end loop;

  if v_reversal_count = 0 then
    raise exception
      'No se encontró ningún movimiento de stock original para reintegrar (línea raíz %, venta raíz %) — la línea devuelta no tiene historial de stock rastreable. Se aborta el cambio completo en vez de continuar sin reintegrar nada.',
      v_physical_source_id, v_root_sale_id;
  end if;

  for v_required in
    with items as (
      select v_new_line_item_id as sale_item_id, p_new_product_id as product_id, p_new_quantity as quantity
    ),
    expanded as (
      select i.sale_item_id, i.product_id, i.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = true
      union all
      select i.sale_item_id, kc.component_product_id, i.quantity * kc.quantity as required_qty
      from items i
      join public.products p on p.id = i.product_id and p.track_stock = false
      join public.kit_components kc on kc.kit_product_id = i.product_id
    )
    select sale_item_id, product_id, sum(required_qty) as required_qty
    from expanded
    group by sale_item_id, product_id
  loop
    -- BLOQUE F (61): antes de descontar, valida disponible = físico -
    -- reservas ACTIVE (mismo fn_check_available_stock que ya usa
    -- fn_create_sale_core desde 055) — un cambio no puede entregar una
    -- unidad comprometida para un pickup Web pendiente.
    perform public.fn_check_available_stock(
      v_sale.location_id, v_required.product_id, v_required.required_qty, v_allow_negative
    );
    perform public.fn_apply_stock_movement(
      p_location_id => v_sale.location_id,
      p_product_id => v_required.product_id,
      p_movement_type => 'SALE',
      p_quantity_delta => -v_required.required_qty,
      p_sale_id => v_replacement_sale_id,
      p_reference => v_replacement_sale_number,
      p_created_by => auth.uid(),
      p_allow_negative => v_allow_negative,
      p_source_sale_item_id => v_required.sale_item_id
    );
  end loop;

  update public.sales set status = 'replaced' where id = p_original_sale_id;

  insert into public.sale_exchanges (
    original_sale_id, replacement_sale_id, difference_amount, difference_direction,
    difference_settlement_status, notes, created_by
  ) values (
    p_original_sale_id, v_replacement_sale_id, v_difference, v_difference_direction,
    v_difference_settlement_status, p_notes, auth.uid()
  )
  returning id into v_exchange_id;

  insert into public.sale_exchange_items (
    exchange_id, direction, source_sale_item_id, product_id, quantity, unit_price, line_total
  ) values
    (v_exchange_id, 'RETURNED', p_returned_sale_item_id, v_returned_item.product_id,
      p_returned_quantity, v_returned_item.sale_unit_price, v_recognized_value),
    (v_exchange_id, 'ADDED', null, p_new_product_id,
      p_new_quantity, (v_price ->> 'sale_unit_price')::numeric, v_new_line_total);

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'SALE_EXCHANGE_CREATED', 'sales', v_replacement_sale_id,
    jsonb_build_object(
      'original_sale_id', p_original_sale_id,
      'replacement_sale_id', v_replacement_sale_id,
      'customer_id', v_sale.customer_id,
      'returned_product_id', v_returned_item.product_id,
      'returned_quantity', p_returned_quantity,
      'new_product_id', p_new_product_id,
      'new_quantity', p_new_quantity,
      'difference_amount', v_difference,
      'difference_direction', v_difference_direction,
      'payment_method_id', v_sale.payment_method_id,
      'location_id', v_sale.location_id
    )
  );

  return jsonb_build_object(
    'exchange_id', v_exchange_id,
    'original_sale_id', p_original_sale_id,
    'sale_id', v_replacement_sale_id,
    'sale_number', v_replacement_sale_number,
    'total', v_total,
    'surcharge_total', v_surcharge_total,
    'recognized_value', v_recognized_value,
    'new_item_total', v_new_line_total,
    'difference_amount', v_difference,
    'difference_direction', v_difference_direction,
    'billing_status', v_replacement_billing_status,
    'difference_settlement_status', v_difference_settlement_status
  );
end;
$$;

comment on function public.create_sale_exchange(uuid, uuid, numeric, uuid, numeric, text) is
  'Cambio de producto. BLOQUE F (61): antes de descontar el producto nuevo, valida disponible '
  '(fn_check_available_stock — físico - reservas ACTIVE), igual que ya hace fn_create_sale_core '
  'desde 055 — un cambio no puede entregar una unidad comprometida para un pickup Web pendiente. '
  'BUGFIX 55 (guard PENDING_PICKUP) y todo lo demás siguen exactamente igual.';

-- ---------------------------------------------------------------------------
-- 4) transfer_stock: agrega un guard duro — no se puede transferir más que
--    el disponible de la sede de origen. SIEMPRE se aplica, sin importar
--    allow_transfer_overdraft (ese setting es sobre permitir físico
--    negativo por flexibilidad operativa; esto es sobre no romper una
--    reserva ya comprometida con un cliente Web — ejes distintos).
--    set_stock/adjust_stock NO se tocan en este bloque — siguen siendo
--    operaciones administrativas sobre el físico real, deliberadamente.
--    Riesgo documentado: un admin puede seguir corrigiendo el físico con
--    set_stock/adjust_stock a un valor por debajo de lo reservado (ninguna
--    de las 2 valida contra reservas) — es una inconsistencia posible,
--    pero deliberada: son herramientas de corrección administrativa
--    (stock físico real, ej. rotura/vencimiento/recepción), no ventas, y
--    limitarlas ahí podría bloquear una corrección legítima. Si en el
--    futuro se decide blindarlas también, es un bloque aparte.
-- ---------------------------------------------------------------------------
create or replace function public.transfer_stock(
  p_from_location_id uuid,
  p_to_location_id uuid,
  p_items jsonb, -- [{"product_id": uuid, "quantity": number}]
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings public.app_settings;
  v_transfer_id uuid;
  v_transfer_number text;
  v_seq int;
  v_item record;
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para transferir stock.';
  end if;

  if p_from_location_id = p_to_location_id then
    raise exception 'La sede de origen y destino no pueden ser la misma.';
  end if;

  if not (public.has_location_access(p_from_location_id) and public.has_location_access(p_to_location_id)) then
    raise exception 'Tu usuario no tiene acceso a alguna de las sedes involucradas.';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La transferencia no tiene productos.';
  end if;

  select * into v_settings from public.app_settings where id = 1;

  perform pg_advisory_xact_lock(hashtext('stock_transfer_number'));
  select count(*) + 1 into v_seq
  from public.stock_transfers
  where created_at::date = (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_transfer_number := format('TRF-%s-%s', to_char(now(), 'YYYYMMDD'), lpad(v_seq::text, 4, '0'));

  insert into public.stock_transfers (transfer_number, from_location_id, to_location_id, notes, created_by)
  values (v_transfer_number, p_from_location_id, p_to_location_id, p_notes, auth.uid())
  returning id into v_transfer_id;

  for v_item in
    select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_items) elem
    order by (elem ->> 'product_id')::uuid
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Cantidad inválida en la transferencia.';
    end if;

    if not exists (select 1 from public.products where id = v_item.product_id and track_stock = true) then
      raise exception 'Solo se pueden transferir productos con stock propio (no kits).';
    end if;

    -- BLOQUE F (61): no se puede dejar la sede de origen con disponible
    -- negativo — nunca se pasa allow_negative acá, a propósito (ver
    -- comentario del bloque de arriba).
    perform public.fn_check_available_stock(p_from_location_id, v_item.product_id, v_item.quantity, false);

    insert into public.stock_transfer_items (transfer_id, product_id, quantity)
    values (v_transfer_id, v_item.product_id, v_item.quantity);

    perform public.fn_apply_stock_movement(
      p_location_id => p_from_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_OUT',
      p_quantity_delta => -v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => coalesce(v_settings.allow_transfer_overdraft, false)
    );

    perform public.fn_apply_stock_movement(
      p_location_id => p_to_location_id,
      p_product_id => v_item.product_id,
      p_movement_type => 'TRANSFER_IN',
      p_quantity_delta => v_item.quantity,
      p_transfer_id => v_transfer_id,
      p_reference => v_transfer_number,
      p_created_by => auth.uid(),
      p_allow_negative => true
    );
  end loop;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'transfer_stock', 'stock_transfers', v_transfer_id,
          jsonb_build_object('from', p_from_location_id, 'to', p_to_location_id, 'items', p_items));

  return jsonb_build_object('transfer_id', v_transfer_id, 'transfer_number', v_transfer_number);
end;
$$;

comment on function public.transfer_stock(uuid, uuid, jsonb, text) is
  'Transferencia de stock entre sedes (admin). BLOQUE F (61): antes de descontar en origen, valida '
  'disponible (fn_check_available_stock, SIEMPRE sin allow_negative — nunca se puede dejar la sede '
  'de origen con disponible negativo, sin importar allow_transfer_overdraft, que solo permite '
  'físico negativo por flexibilidad operativa, un eje distinto). set_stock/adjust_stock siguen sin '
  'validar contra reservas — operaciones administrativas deliberadas sobre el físico real.';

grant execute on function public.transfer_stock(uuid, uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) dashboard_report.critical_stock_count: pasa a contar sobre disponible
--    (available_status), no físico crudo — un producto con reservas ACTIVE
--    que agotan el disponible es una alerta operativa real aunque el
--    físico todavía diga "ok". Misma firma exacta que 20260201000056 —
--    CREATE OR REPLACE sin DROP, el resto del cuerpo es idéntico.
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_report(
  p_from date,
  p_to date,
  p_location_id uuid default null,
  p_sales_channel_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_from timestamptz;
  v_to timestamptz;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  return jsonb_build_object(
    'kpis', (
      select jsonb_build_object(
        'sales_count', count(*),
        'revenue', coalesce(sum(sn.net_total), 0),
        'avg_ticket', coalesce(round(avg(sn.net_total), 2), 0),
        'units_sold', coalesce(sum(sn.net_units), 0),
        'web_sales_count', coalesce(sum(case when sc.code = 'WEB' then 1 else 0 end), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join public.sales_channels sc on sc.id = s.sales_channel_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(net_quantity), 0) as net_units,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
        and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    ),
    'revenue_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (s.sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by 1
      ) t
    ),
    'sales_by_location', (
      select coalesce(jsonb_agg(jsonb_build_object('location', sl.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.location_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.location_id
      ) t
      join public.stock_locations sl on sl.id = t.location_id
    ),
    'sales_by_channel', (
      select coalesce(jsonb_agg(jsonb_build_object('channel', sc.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.sales_channel_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.sales_channel_id
      ) t
      join public.sales_channels sc on sc.id = t.sales_channel_id
    ),
    'revenue_by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('payment_method', pm.name, 'revenue', t.revenue)), '[]'::jsonb)
      from (
        select s.payment_method_id, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.payment_method_id
      ) t
      join public.payment_methods pm on pm.id = t.payment_method_id
    ),
    'top_products_by_units', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'units', t.units) order by t.units desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
        order by units desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'top_products_by_revenue', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'revenue', t.revenue) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_line_total) > 0
        order by revenue desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'commission_by_doctor', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'doctor_id', d.id, 'doctor', d.full_name, 'sales_count', t.cnt,
        'commissionable_revenue', t.commissionable_revenue, 'commission', t.commission
      ) order by t.commission desc), '[]'::jsonb)
      from (
        select s.doctor_id, count(*) as cnt,
          sum(sn.net_commissionable) as commissionable_revenue,
          sum(case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end) as commission
        from public.sales s
        join lateral (
          select
            coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
            coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and s.doctor_id is not null
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.doctor_id
      ) t
      join public.doctors d on d.id = t.doctor_id
    ),
    'critical_stock_count', (
      select count(*) from public.product_stock_status pss
      where pss.available_status in ('bajo', 'sin_stock')
        and pss.product_active = true
        and public.has_location_access(pss.location_id)
        and (p_location_id is null or pss.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.dashboard_report(date, date, uuid, uuid) is
  'Único punto de agregación para /dashboard. Requiere admin o can_view_financial_reports. '
  'Toda la agregación ocurre en SQL: el cliente nunca pagina/filtra ventas crudas. '
  'critical_stock_count excluye productos inactivos — no son una alerta operativa real. BLOQUE F '
  '(61): cuenta sobre available_status (disponible = físico - reservas ACTIVE), no el físico '
  'crudo — antes podía mostrar "ok" con reservas que agotaban el disponible real. '
  'Revenue/unidades/top productos/comisión son SIEMPRE netos de devoluciones (sale_item_net) — '
  'status=confirmed solo no alcanza porque una devolución parcial no cambia el status. BUGFIX 56: '
  'además excluyen un pedido Web con payment_status=PENDING (no cobrado todavía) — fulfillment '
  '(pendiente/entregado) no cambia esta condición económica, son ejes distintos.';


-- =============================================================================
-- MIGRACIÓN 062_shipping_pending_v1_semantics
-- Fuente: supabase/migrations/20260201000062_shipping_pending_v1_semantics.sql (contenido exacto, sin cambios)
-- =============================================================================

-- =============================================================================
-- Maguirejuve · 62 · Decisión V1 explícita: WEB + SHIPPING + payment_status
-- PENDING queda fulfillment_status=SHIPPED desde la creación
-- =============================================================================
-- Solo comentarios — CERO cambio funcional. Cierre de BLOQUE G: el usuario
-- confirmó explícitamente que el comportamiento actual (vigente desde
-- 20260201000054/055) es el comportamiento QUERIDO para esta V1, no un bug
-- pendiente de corregir. Se documenta acá, en el esquema, para que quien
-- audite este código más adelante no lo interprete como una omisión.
--
-- Semántica confirmada para V1:
--   - SHIPPING descuenta stock físico de Depósito de inmediato al crear el
--     pedido (fn_create_sale_core, misma rama que una venta presencial —
--     fn_check_available_stock + fn_apply_stock_movement, sin reserva).
--   - SHIPPING nunca genera una fila en sale_stock_reservations — no hay
--     nada que "retirar" después, el envío ya salió.
--   - fulfillment_status queda 'SHIPPED' desde el instante de creación,
--     siempre, sin importar payment_status.
--   - payment_status puede seguir en 'PENDING' después de creado — el envío
--     y el cobro son ejes independientes (igual que para PICKUP): se puede
--     despachar un pedido y cobrarlo después con mark_web_order_paid, sin
--     que eso bloquee ni reordene el envío.
--   - Deliberadamente NO se agrega, en esta V1, un estado intermedio
--     'PENDING_SHIPMENT' ni ningún workflow de "despacho" separado de la
--     creación — si en el futuro el negocio necesita un paso de picking/
--     packing previo al envío real, es un bloque de producto aparte, con
--     su propio diseño (fecha de despacho real, quién empacó, etc.),
--     nunca una corrección de esto.
-- =============================================================================

comment on type public.sale_fulfillment_status is
  'PENDING_PICKUP/DELIVERED son el ciclo de un PICKUP. SHIPPED se asigna una única vez, en el '
  'momento de crear un pedido SHIPPING (el envío ya salió de Depósito de inmediato) — nunca pasa '
  'por PENDING_PICKUP. Decisión V1 confirmada (20260201000062): SHIPPED se asigna así incluso si '
  'payment_status queda PENDING — el envío y el cobro son ejes independientes, igual que para '
  'PICKUP. No existe (a propósito, en esta V1) un estado intermedio de "pendiente de despacho".';

comment on column public.sales.fulfillment_status is
  'Ver sale_fulfillment_status. Null para toda venta no-Web. Para SHIPPING queda SHIPPED desde la '
  'creación sin importar payment_status (decisión V1, 20260201000062) — nunca se reinterprete como '
  'un bug: no hay ningún paso de despacho separado de la creación en esta versión.';

comment on column public.sales.payment_status is
  'PAID o PENDING. Null para toda venta no-Web (esas siempre se asumen cobradas de inmediato, '
  'como siempre funcionó). NUNCA depende de billing_status/invoiced_at — son ejes distintos. '
  'Tampoco depende de fulfillment_status/fulfillment_type (decisión V1, 20260201000062): un '
  'SHIPPING con payment_status=PENDING se despacha igual de inmediato y se cobra después con '
  'mark_web_order_paid, sin que eso reordene ni bloquee el envío ya realizado.';

-- =============================================================================
-- Fin de las 9 migraciones — cierra la transacción.
-- =============================================================================
commit;

-- =============================================================================
-- VERIFICACIÓN POST-DEPLOY (solo lectura — correr DESPUÉS del COMMIT de
-- arriba, como sentencias aparte). Ninguna de estas modifica datos.
-- =============================================================================

-- 1) Las funciones/vistas nuevas existen.
select proname
from pg_proc
where proname in (
  'fn_check_available_stock', 'fn_reserve_stock', 'create_sale', 'cancel_sale',
  'create_sale_exchange', 'transfer_stock', 'deliver_web_pickup',
  'mark_web_order_paid', 'web_pending_pickups', 'web_order_history',
  'web_admin_stock_availability', 'dashboard_report', 'fn_kit_buildable_qty'
)
order by proname;
-- Esperado: las 13 filas, una por función.

select viewname from pg_views where viewname in ('product_stock_status', 'kit_availability');
-- Esperado: 2 filas.

-- 2) Las columnas nuevas de sales/product_stock_status existen.
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'sales'
  and column_name in (
    'fulfillment_type', 'fulfillment_status', 'payment_status',
    'pickup_location_id', 'delivered_at', 'delivered_by'
  )
order by column_name;
-- Esperado: las 6 columnas.

select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'product_stock_status'
  and column_name in ('reserved', 'available', 'available_status')
order by column_name;
-- Esperado: las 3 columnas (además de quantity/status, que no cambiaron).

-- 3) La tabla de reservas existe.
select count(*) from public.sale_stock_reservations;
-- Esperado: no da error (la tabla existe); el conteo va a ser 0 si todavía
-- no hay ningún pedido Web creado en producción.

-- 4) Ningún pedido Web todavía (antes de exponer el frontend nuevo).
select count(*) from public.sales where fulfillment_type is not null;
-- Esperado: 0 (recién después del deploy del frontend van a empezar a
-- crearse pedidos Web reales).

-- 5) El enum de historial nuevo existe con sus 3 valores esperados.
select enumlabel from pg_enum e
join pg_type t on t.oid = e.enumtypid
where t.typname = 'sale_fulfillment_status'
order by e.enumsortorder;
-- Esperado: PENDING_PICKUP, DELIVERED, SHIPPED (en ese orden).
