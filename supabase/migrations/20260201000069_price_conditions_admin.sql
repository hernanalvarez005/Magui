-- =============================================================================
-- Maguirejuve · 69 · Condiciones de precio administrables (Checkpoint 1: DB/domain)
-- =============================================================================
-- Caso real: se vendió (intentó vender) hoy una venta Web en "2 cuotas sin
-- interés" y la condición no existe — hoy crear una condición de precio
-- nueva exige una migración (ver 20260201000067_card6_installments_and_billing.sql).
-- Auditoría previa (presentada y aprobada por el usuario antes de este
-- archivo) encontró que payment_methods/price_conditions/product_prices ya
-- son 100% genéricos a nivel de datos — fn_pricing_quote resuelve cualquier
-- condición nueva sin código especial. El único hardcode de código VIVO
-- (confirmado leyendo las definiciones vigentes, no el historial de
-- migraciones superadas por CREATE OR REPLACE) era:
--   v_requires_billing := ... in ('TRANSFER', 'CARD_1', 'CARD_3', 'CARD_6')
-- repetido en exactamente 2 funciones: fn_create_sale_core y
-- create_sale_exchange. Esta migración lo elimina, lo convierte en la
-- columna payment_methods.requires_billing (data-driven), y agrega:
--   1) disponibilidad por sede (price_condition_locations) y por canal
--      (price_condition_sales_channels) — dos junction tables genéricas,
--      NUNCA columnas boolean con nombre de sede hardcodeado;
--   2) snapshot histórico del nombre de la condición en sales (no
--      sale_items: la condición se resuelve UNA vez por venta, no por
--      línea — a diferencia de las promociones, que sí son por línea;
--      mismo criterio de "nunca se completa retroactivamente con un valor
--      inventado" que 20260201000048_promotion_snapshot_schema.sql: la
--      columna queda NULL para ventas anteriores a esta migración, sin
--      backfill);
--   3) una RPC administrativa única (create_price_condition) que crea
--      payment_method + price_condition + disponibilidad + product_prices
--      iniciales en una sola operación atómica (todo dentro de una función
--      plpgsql = misma transacción que la llamada, cualquier excepción
--      revierte todo — no hace falta BEGIN/COMMIT explícito);
--   4) validación de disponibilidad server-side dentro de fn_create_sale_core
--      (único punto real de creación de ventas — create_sale/create_web_order
--      son wrappers delgados que delegan acá, confirmado leyendo sus
--      definiciones). create_sale_exchange NO la necesita: hereda el medio
--      de pago histórico de la venta original, nunca deja elegir uno nuevo
--      (confirmado leyendo la función — "el medio de pago siempre se
--      hereda... nunca se re-selecciona en un cambio").
--
-- Fuera de alcance de este archivo (Checkpoint 1, solo DB/domain): UI de
-- administración, integración con Nueva Venta/matriz, formulario. Se
-- implementan en un Checkpoint 2 separado, tras aprobación.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) payment_methods.requires_billing — reemplaza el hardcode de código.
-- ---------------------------------------------------------------------------
alter table public.payment_methods
  add column requires_billing boolean not null default false;

comment on column public.payment_methods.requires_billing is
  'Si TRUE, una venta con este medio de pago exige cliente con DNI + cuenta de ingreso + '
  'billing_status (misma regla que antes vivía hardcodeada como '
  'v_payment_method_code in (''TRANSFER'',''CARD_1'',''CARD_3'',''CARD_6'') dentro de '
  'fn_create_sale_core/create_sale_exchange — ver migración 69). Data-driven: crear un medio de '
  'pago nuevo con este flag en TRUE/FALSE no requiere ningún cambio de código.';

-- Backfill: preserva EXACTAMENTE el comportamiento vigente antes de esta
-- migración. CASH nunca estuvo en la lista hardcodeada -> queda FALSE (su
-- default). TRANSFER/CARD_1/CARD_3/CARD_6 sí estaban -> TRUE.
update public.payment_methods
set requires_billing = true
where code in ('TRANSFER', 'CARD_1', 'CARD_3', 'CARD_6');

-- ---------------------------------------------------------------------------
-- 2) Disponibilidad — dos junction tables genéricas (mismo shape que
--    profile_locations/promotion_payment_methods, patrón ya establecido en
--    el proyecto). NO se modela como dos columnas boolean
--    (available_sede_25/available_sede_37): eso hardcodearía las sedes
--    actuales en el esquema — una sede nueva no debe requerir una migración.
--
--    Por qué DOS tablas y no una sola "price_condition_sales_channels"
--    genérica para todo (evaluado explícitamente, sección 9 del pedido):
--    "Sede 25"/"Sede 37" son stock_locations (BRANCH es un único
--    sales_channel compartido por ambas sedes — no alcanza para
--    distinguirlas). "Web" sí es un sales_channel real, pero una venta Web
--    puede usar location_id = Depósito (envío) o el location_id de una
--    sede (retiro) según fulfillment_type (confirmado leyendo
--    fn_create_sale_core) — el location_id de una venta Web NO representa
--    "en qué sede está habilitada esta condición para Web", así que la
--    disponibilidad de Web tiene que resolverse por canal, no por sede.
--    Dos dimensiones reales del dominio -> dos tablas, mismo patrón. La
--    disponibilidad de BRANCH en sí (a diferencia de Web) nunca se modela
--    aparte: ya está implícita en tener al menos una sede habilitada, así
--    que en la práctica price_condition_sales_channels solo llega a tener
--    filas para el canal WEB — pero la tabla es genérica: si mañana existe
--    un tercer canal (ej. un marketplace), no hace falta ninguna migración
--    nueva para poder togglearlo por condición.
-- ---------------------------------------------------------------------------
create table public.price_condition_locations (
  price_condition_id uuid not null references public.price_conditions (id) on delete cascade,
  location_id uuid not null references public.stock_locations (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (price_condition_id, location_id)
);

comment on table public.price_condition_locations is
  'Sedes (stock_locations) donde una condición de precio está habilitada para ventas '
  'presenciales. Sin filas para una condición = no disponible en ninguna sede presencial '
  '(distinto del criterio legacy de promotion_payment_methods: acá la ausencia de filas NO es '
  '"sin restricción", es "sin disponibilidad" — toda condición nueva creada por '
  'create_price_condition() recibe sus filas explícitas en el mismo paso atómico).';

alter table public.price_condition_locations enable row level security;

create policy price_condition_locations_select on public.price_condition_locations
  for select using (public.is_active_profile());
create policy price_condition_locations_admin_write on public.price_condition_locations
  for insert with check (public.is_admin());
create policy price_condition_locations_admin_update on public.price_condition_locations
  for update using (public.is_admin()) with check (public.is_admin());
create policy price_condition_locations_admin_delete on public.price_condition_locations
  for delete using (public.is_admin());

-- Supabase ya no otorga privilegios implícitos a tablas nuevas del schema
-- public — GRANT explícito en la misma migración (sección 14 del pedido),
-- mismo patrón que 20260101000010_rls.sql (privilegios DML amplios a nivel
-- de rol, RLS hace la autorización real fila por fila/operación por
-- operación).
grant select, insert, update, delete on public.price_condition_locations to authenticated;
grant all on public.price_condition_locations to service_role;

create table public.price_condition_sales_channels (
  price_condition_id uuid not null references public.price_conditions (id) on delete cascade,
  sales_channel_id uuid not null references public.sales_channels (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (price_condition_id, sales_channel_id)
);

comment on table public.price_condition_sales_channels is
  'Canales (sales_channels) donde una condición de precio está habilitada. En la práctica hoy '
  'solo se usa para el canal WEB (la disponibilidad de BRANCH se resuelve por sede vía '
  'price_condition_locations) pero la tabla es genérica sobre sales_channels — un canal nuevo no '
  'requiere ninguna migración. Mismo criterio de ausencia de filas que price_condition_locations: '
  'sin filas = sin disponibilidad, nunca "sin restricción".';

alter table public.price_condition_sales_channels enable row level security;

create policy price_condition_sales_channels_select on public.price_condition_sales_channels
  for select using (public.is_active_profile());
create policy price_condition_sales_channels_admin_write on public.price_condition_sales_channels
  for insert with check (public.is_admin());
create policy price_condition_sales_channels_admin_update on public.price_condition_sales_channels
  for update using (public.is_admin()) with check (public.is_admin());
create policy price_condition_sales_channels_admin_delete on public.price_condition_sales_channels
  for delete using (public.is_admin());

grant select, insert, update, delete on public.price_condition_sales_channels to authenticated;
grant all on public.price_condition_sales_channels to service_role;

-- Backfill: preserva el comportamiento actual EXACTO (hoy cualquier
-- condición activa aparece en cualquier sede/canal, sin ninguna
-- restricción) para todas las condiciones ya existentes que un usuario
-- puede efectivamente llegar a usar (BASE/PAYMENT_METHOD — QUANTITY quedó
-- deprecado desde la migración 45, nunca se resuelve en fn_pricing_quote,
-- se excluye igual que ya excluye la pantalla /admin/condiciones-precio).
-- TODAS las stock_locations, no solo type='branch': una venta no-Web hoy
-- puede legítimamente usar location_id = Depósito (confirmado leyendo
-- fn_create_sale_core — la restricción de "Depósito solo para envío Web"
-- vive exclusivamente dentro del bloque p_fulfillment_type, nunca aplica a
-- una venta común) y varios tests/flujos ya vigentes venden así. Filtrar
-- a type='branch' acá rompía exactamente ese caso — el filtro por sede
-- real (Sede 25/Sede 37) es correcto SOLO como restricción de la UI/RPC de
-- creación hacia adelante (create_price_condition), nunca como recorte del
-- backfill de compatibilidad histórica.
insert into public.price_condition_locations (price_condition_id, location_id)
select pc.id, sl.id
from public.price_conditions pc
cross join public.stock_locations sl
where pc.rule_type in ('BASE', 'PAYMENT_METHOD')
on conflict do nothing;

insert into public.price_condition_sales_channels (price_condition_id, sales_channel_id)
select pc.id, sc.id
from public.price_conditions pc
cross join public.sales_channels sc
where pc.rule_type in ('BASE', 'PAYMENT_METHOD')
  and sc.code = 'WEB'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 3) Snapshot histórico del nombre de condición — en sales, no sale_items.
--    La condición se resuelve UNA sola vez por venta (v_condition en
--    fn_pricing_quote, mismo valor para todas las líneas no-manuales del
--    carrito) — a diferencia de promotions, que sí varía línea por línea.
--    sales.applied_price_condition_id ya existe (columna original de
--    20260101000006_sales.sql) y es lo que hoy lee en vivo
--    app/(app)/ventas/[id]/page.tsx para mostrar el nombre — confirmado
--    que es el ÚNICO lugar del código que muestra el nombre de una
--    condición para una venta ya persistida (grep exhaustivo sobre
--    app/lib/components, checkpoint de auditoría previo a este archivo).
--    NULL para ventas anteriores a esta migración — nunca se completa
--    retroactivamente con el nombre actual (mismo criterio exacto que
--    promotion_name_snapshot, comentario textual de esa migración: "NUNCA
--    se completa retroactivamente con un valor inventado" — un backfill
--    con el nombre de HOY no sería la foto histórica real si la condición
--    ya cambió de nombre antes de esta migración).
-- ---------------------------------------------------------------------------
alter table public.sales
  add column price_condition_name_snapshot text;

comment on column public.sales.price_condition_name_snapshot is
  'price_conditions.name tal como era al momento de esta venta. NULL si la venta no tuvo '
  'condición resuelta (100% precio manual) o si es una venta anterior a esta columna (ahí la UI '
  'cae a resolver por JOIN contra price_conditions vigente). Nunca se reescribe si más adelante '
  'se edita el nombre de la condición. Escrito exclusivamente por fn_create_sale_core, desde '
  'fn_pricing_quote(...)->>''applied_price_condition_name'' (ya lo devuelve, sin query extra). '
  'create_sale_exchange no lo setea: la venta de reemplazo ya deja applied_price_condition_id en '
  'null (mezcla de líneas copiadas/nueva, sin una única condición resuelta), mismo criterio '
  'preexistente.';

-- ---------------------------------------------------------------------------
-- 4) fn_price_condition_available — helper reusado por fn_create_sale_core.
--    STABLE (no escribe, mismo criterio que has_location_access).
-- ---------------------------------------------------------------------------
create or replace function public.fn_price_condition_available(
  p_price_condition_id uuid,
  p_location_id uuid,
  p_sales_channel_code text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_sales_channel_code = 'WEB' then exists (
      select 1 from public.price_condition_sales_channels pcsc
      join public.sales_channels sc on sc.id = pcsc.sales_channel_id
      where pcsc.price_condition_id = p_price_condition_id and sc.code = 'WEB'
    )
    else exists (
      select 1 from public.price_condition_locations pcl
      where pcl.price_condition_id = p_price_condition_id and pcl.location_id = p_location_id
    )
  end;
$$;

comment on function public.fn_price_condition_available(uuid, uuid, text) is
  'Disponibilidad real de una condición de precio para una venta concreta. Canal WEB se resuelve '
  'por price_condition_sales_channels (el location_id de una venta Web es DEP o una sede de '
  'retiro según fulfillment_type, nunca representa disponibilidad "por sede" para Web). Cualquier '
  'otro canal (BRANCH) se resuelve por price_condition_locations contra el location_id real de la '
  'venta. Usado exclusivamente por fn_create_sale_core — create_sale_exchange no la necesita '
  '(hereda el medio de pago histórico, nunca re-selecciona uno).';

-- ---------------------------------------------------------------------------
-- 5) fn_create_sale_core — copia exacta de 20260201000067, con dos cambios
--    reales: (a) v_requires_billing pasa a leer payment_methods.requires_billing
--    en vez del IN hardcodeado; (b) nuevo bloque de validación de
--    disponibilidad, ubicado junto al de promotion_payment_methods (mismo
--    criterio: después de fn_pricing_quote, antes del insert en sales — un
--    rechazo no llega a tocar sales/sale_items/stock/comisión); (c) el
--    insert en sales ahora escribe price_condition_name_snapshot. Ninguna
--    otra línea cambia.
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
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
  v_deposito_location_id uuid;
  v_pickup_location_id uuid;
  v_fulfillment_status public.sale_fulfillment_status;
  v_channel_code text;
  v_invalid_promotion_payment boolean;
  v_applied_price_condition_id uuid;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  select code into v_channel_code from public.sales_channels where id = p_sales_channel_id and active;
  if v_channel_code is null then
    raise exception 'El canal de venta seleccionado no existe o está inactivo.';
  end if;

  -- Migración 69: requires_billing pasa a leerse de payment_methods (data-driven) en
  -- vez de un IN hardcodeado de códigos. Único cambio real de este bloque.
  select requires_billing into v_requires_billing
  from public.payment_methods where id = p_payment_method_id and active;
  if not found then
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

  v_requires_billing := not p_is_free_sale and coalesce(v_requires_billing, false);

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

  v_applied_price_condition_id := nullif(v_quote ->> 'applied_price_condition_id', '')::uuid;

  -- ---------------------------------------------------------------------
  -- Migración 69: disponibilidad de la condición de precio resuelta por
  -- sede/canal. Ubicado junto a la validación de promociones (mismo
  -- criterio: después de fn_pricing_quote, antes de insertar nada — un
  -- rechazo no toca sales/sale_items/stock/comisión). Solo aplica si el
  -- carrito efectivamente resolvió una condición (100% manual -> null,
  -- nada que validar, igual que ya tolera el resto de la función).
  -- ---------------------------------------------------------------------
  if v_applied_price_condition_id is not null
     and not public.fn_price_condition_available(v_applied_price_condition_id, p_location_id, v_channel_code)
  then
    raise exception 'Esta condición de precio no está disponible en esta sucursal/canal.';
  end if;

  -- ---------------------------------------------------------------------
  -- Formas de pago habilitadas por promoción (migración 63). Exclusivo de
  -- ventas presenciales (canal <> WEB) — el circuito Web queda exceptuado
  -- explícitamente, no se reinterpreta acá su propio flujo de cobro.
  -- Recorre las promociones GANADORAS de este carrito (v_quote ya las
  -- resolvió, independiente del medio de pago — ver fn_apply_promotions) y
  -- rechaza si, para alguna que tenga configuración explícita en
  -- promotion_payment_methods, el medio elegido no figura entre los
  -- permitidos. Cubre en un mismo chequeo tanto "una promoción no admite
  -- este medio" como "dos promociones del carrito no tienen un medio en
  -- común" (intersección vacía) — mismo mensaje para ambos casos.
  -- Promoción sin ninguna fila configurada (legacy, nunca editada) no
  -- restringe nada.
  -- ---------------------------------------------------------------------
  if v_channel_code <> 'WEB' then
    select bool_or(
      exists (
        select 1 from public.promotion_payment_methods ppm
        where ppm.promotion_id = line_promo.promotion_id
      )
      and not exists (
        select 1 from public.promotion_payment_methods ppm
        where ppm.promotion_id = line_promo.promotion_id
          and ppm.payment_method_id = p_payment_method_id
      )
    )
    into v_invalid_promotion_payment
    from (
      select distinct nullif(line ->> 'applied_promotion_id', '')::uuid as promotion_id
      from jsonb_array_elements(v_quote -> 'lines') line
      where nullif(line ->> 'applied_promotion_id', '') is not null
    ) line_promo;

    if coalesce(v_invalid_promotion_payment, false) then
      raise exception 'Este método de pago no está disponible para esta promoción.';
    end if;
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
    price_condition_name_snapshot,
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status,
    fulfillment_type, fulfillment_status, payment_status, pickup_location_id
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, v_applied_price_condition_id,
    v_quote ->> 'applied_price_condition_name',
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
  'Punto único de creación de ventas confirmadas. Migración 69: v_requires_billing pasa a leer '
  'payment_methods.requires_billing (data-driven, reemplaza el IN hardcodeado de códigos); nueva '
  'validación de disponibilidad de la condición de precio por sede/canal '
  '(fn_price_condition_available) entre fn_pricing_quote y el insert en sales; sales.'
  'price_condition_name_snapshot se escribe con el nombre resuelto en ese momento. Migración 63: '
  'valida medios de pago permitidos por promoción (promotion_payment_methods) para canal <> WEB. '
  'Resto de la función sin cambios respecto de 20260201000067.';

-- ---------------------------------------------------------------------------
-- 6) create_sale_exchange — copia exacta de 20260201000067, con un único
--    cambio real: v_requires_billing pasa a leer payment_methods.requires_billing.
--    NO recibe validación de disponibilidad (hereda el medio de pago
--    histórico de la venta original, nunca deja elegir uno nuevo — no hay
--    ninguna decisión de "disponibilidad" que tomar acá, confirmado leyendo
--    la función completa antes de este archivo). NO setea
--    price_condition_name_snapshot: la venta de reemplazo ya deja
--    applied_price_condition_id en null (mezcla de líneas copiadas + nueva,
--    sin una única condición resuelta) — mismo criterio preexistente,
--    ninguna línea nueva de código necesaria.
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

  -- Migración 69: requires_billing pasa a leerse de payment_methods (data-driven).
  select requires_billing into v_requires_billing
  from public.payment_methods where id = v_sale.payment_method_id;
  v_requires_billing := coalesce(v_requires_billing, false);

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
  'Cambio de producto. Migración 69: v_requires_billing pasa a leer payment_methods.requires_billing '
  '(data-driven). Sin validación de disponibilidad: hereda el medio de pago histórico de la venta '
  'original, nunca lo re-selecciona. No amplía los medios de sale_refund_method (devoluciones) — eje '
  'completamente aparte. Migración 67: comportamiento de facturación idéntico para CARD_6. BLOQUE F '
  '(61): valida disponible antes de descontar el producto nuevo. Resto sin cambios.';

-- ---------------------------------------------------------------------------
-- 7) create_price_condition — RPC administrativa única, atómica (toda la
--    lógica corre dentro de esta función = misma transacción que la
--    llamada; cualquier excepción revierte TODO, sin necesidad de
--    BEGIN/COMMIT explícito ni de encadenar requests desde el frontend).
--    Crea, en un único paso: payment_method + price_condition (rule_type
--    PAYMENT_METHOD) + disponibilidad (sedes + canales) + product_prices
--    iniciales (copiados de la condición fuente, por defecto LIST).
--
--    Códigos: generados automáticamente (gen_random_uuid(), nunca a partir
--    del nombre) — estables, únicos, inmutables, independientes de
--    renombres futuros. El admin nunca tipea un code técnico (sección 2
--    del pedido). Los codes históricos (CASH/TRANSFER/CARD_1/CARD_3/CARD_6/
--    INSTALLMENTS_3/etc.) NO se tocan.
-- ---------------------------------------------------------------------------
create or replace function public.create_price_condition(
  p_name text,
  p_discount_percent numeric,
  p_requires_billing boolean,
  p_location_codes text[],
  p_available_web boolean,
  p_active boolean default true,
  p_copy_prices_from_code text default 'LIST'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_method_id uuid;
  v_price_condition_id uuid;
  v_payment_method_code text;
  v_price_condition_code text;
  v_list_priority int;
  v_new_priority int;
  v_source_condition_id uuid;
  v_copied_count int := 0;
  v_skipped_products jsonb := '[]'::jsonb;
  v_invalid_codes text[];
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede crear una condición de precio.';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'El nombre de la condición es obligatorio.';
  end if;

  if p_discount_percent is not null and (p_discount_percent < 0 or p_discount_percent > 1) then
    raise exception 'El porcentaje informativo tiene que estar entre 0%% y 100%%.';
  end if;

  -- Ojo: "code" sin calificar acá adentro resolvería contra
  -- stock_locations.code (la subquery correlacionada tiene su propia
  -- columna "code" en scope, más cercana que la de unnest) y el chequeo
  -- quedaría siempre en true — por eso el alias explícito u(loc_code) y la
  -- referencia calificada u.loc_code, nunca un nombre que colisione con una
  -- columna real de stock_locations.
  select array_agg(u.loc_code) into v_invalid_codes
  from unnest(coalesce(p_location_codes, array[]::text[])) as u(loc_code)
  where not exists (
    select 1 from public.stock_locations sl where sl.code = u.loc_code and sl.type = 'branch'
  );
  if v_invalid_codes is not null and array_length(v_invalid_codes, 1) > 0 then
    raise exception 'Sede desconocida: %.', array_to_string(v_invalid_codes, ', ');
  end if;

  select id into v_source_condition_id
  from public.price_conditions
  where code = p_copy_prices_from_code and active;
  if v_source_condition_id is null then
    raise exception 'La condición de origen para copiar precios (%) no existe o está inactiva.', p_copy_prices_from_code;
  end if;

  -- Códigos técnicos autogenerados — nunca a partir del nombre, nunca
  -- tipeados por el admin. Colisión de gen_random_uuid() es astronómicamente
  -- improbable (122 bits de aleatoriedad); si igual ocurriera, el UNIQUE de
  -- payment_methods.code/price_conditions.code aborta la transacción entera
  -- con un error claro, nunca deja una fila a medio crear.
  v_payment_method_code := 'PM-' || replace(gen_random_uuid()::text, '-', '');
  v_price_condition_code := 'PC-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.payment_methods (code, name, active, requires_billing, sort_order)
  values (
    v_payment_method_code, p_name, p_active, coalesce(p_requires_billing, false),
    coalesce((select max(sort_order) + 1 from public.payment_methods), 1)
  )
  returning id into v_payment_method_id;

  -- Nueva condición entra justo por encima de LIST en precedencia (mismo
  -- patrón manual que usaban las migraciones anteriores, ej.
  -- 20260201000067: "se corre LIST un lugar más abajo en prioridad, sin
  -- tocar la precedencia relativa de nada más" — acá se automatiza).
  select priority into v_list_priority from public.price_conditions where code = 'LIST';
  v_new_priority := coalesce(v_list_priority, 100);
  update public.price_conditions set priority = priority + 1 where code = 'LIST';

  insert into public.price_conditions (
    code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active
  ) values (
    v_price_condition_code, p_name, 'PAYMENT_METHOD', v_payment_method_id,
    coalesce(p_discount_percent, 0), v_new_priority, false, p_active
  )
  returning id into v_price_condition_id;

  -- Disponibilidad: exactamente las sedes pedidas (puede ser un subconjunto
  -- o ninguna — "Sede 25: NO" es una configuración válida) + WEB si se pidió.
  insert into public.price_condition_locations (price_condition_id, location_id)
  select v_price_condition_id, sl.id
  from public.stock_locations sl
  where sl.code = any(coalesce(p_location_codes, array[]::text[])) and sl.type = 'branch';

  if p_available_web then
    insert into public.price_condition_sales_channels (price_condition_id, sales_channel_id)
    select v_price_condition_id, sc.id from public.sales_channels sc where sc.code = 'WEB';
  end if;

  -- Precio inicial = copia del precio vigente de la condición de origen
  -- (LIST por defecto) para cada producto que la tenga — dato real en
  -- product_prices, nunca una fórmula derivada de discount_percent (Modelo
  -- B, ya vigente). Producto sin precio vigente en la condición de origen:
  -- NO se inventa ningún valor, queda directamente sin fila en
  -- product_prices para esta condición nueva (mismo estado que cualquier
  -- producto sin precio para una condición existente — fn_pricing_quote ya
  -- lo maneja con un mensaje explícito al intentar venderlo) — se reporta
  -- en el resultado de esta RPC para que el admin lo vea, no queda oculto.
  with copied as (
    insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
    select pp.product_id, v_price_condition_id, pp.amount, now()
    from public.product_prices pp
    where pp.price_condition_id = v_source_condition_id
      and pp.active = true
      and (pp.valid_until is null or pp.valid_until > now())
    returning product_id
  )
  select count(*) into v_copied_count from copied;

  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name)), '[]'::jsonb)
  into v_skipped_products
  from public.products p
  where p.active
    and not exists (
      select 1 from public.product_prices pp
      where pp.product_id = p.id
        and pp.price_condition_id = v_source_condition_id
        and pp.active = true
        and (pp.valid_until is null or pp.valid_until > now())
    );

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRICE_CONDITION_CREATED', 'price_conditions', v_price_condition_id,
    jsonb_build_object(
      'name', p_name,
      'payment_method_id', v_payment_method_id,
      'requires_billing', coalesce(p_requires_billing, false),
      'location_codes', p_location_codes,
      'available_web', coalesce(p_available_web, false),
      'copied_prices_from', p_copy_prices_from_code,
      'copied_count', v_copied_count,
      'skipped_count', jsonb_array_length(v_skipped_products)
    )
  );

  return jsonb_build_object(
    'price_condition_id', v_price_condition_id,
    'payment_method_id', v_payment_method_id,
    'price_condition_code', v_price_condition_code,
    'payment_method_code', v_payment_method_code,
    'copied_prices_count', v_copied_count,
    'skipped_products', v_skipped_products
  );
end;
$$;

comment on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text) is
  'Crea una condición de precio administrable completa en una sola operación atómica: '
  'payment_method + price_condition + disponibilidad (sedes/Web) + product_prices iniciales '
  '(copiados de la condición de origen, LIST por defecto). Toda la función corre en la misma '
  'transacción que la llamada — cualquier excepción revierte todo, nunca deja una fila a medio '
  'crear. Códigos técnicos autogenerados (gen_random_uuid()), nunca a partir del nombre ni '
  'tipeados por el admin — estables ante un rename futuro. Solo admin (is_admin()).';

grant execute on function public.create_price_condition(text, numeric, boolean, text[], boolean, boolean, text) to authenticated;
grant execute on function public.fn_price_condition_available(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8) Caso inmediato — "2 cuotas sin interés" (sección 10 del pedido,
--    configuración ya aprobada por el usuario). Una migración corre como
--    dueño de las tablas, sin auth.uid() de sesión -> create_price_condition()
--    (is_admin()-gated) no es invocable acá directamente. Se replica su
--    misma lógica en SQL plano, mismo criterio que las migraciones
--    anteriores de nuevos medios de pago (20260201000007/67) — la RPC en sí
--    se valida aparte con pgTAP simulando una sesión admin real.
-- ---------------------------------------------------------------------------
do $$
declare
  v_payment_method_id uuid;
  v_price_condition_id uuid;
  v_list_priority int;
  v_copied_count int;
begin
  if exists (select 1 from public.payment_methods where name = '2 cuotas sin interés') then
    return; -- idempotente: ya se corrió antes (misma convención que el resto de las migraciones).
  end if;

  insert into public.payment_methods (code, name, active, requires_billing, sort_order)
  values (
    'PM-' || replace(gen_random_uuid()::text, '-', ''), '2 cuotas sin interés', true, true,
    coalesce((select max(sort_order) + 1 from public.payment_methods), 1)
  )
  returning id into v_payment_method_id;

  select priority into v_list_priority from public.price_conditions where code = 'LIST';
  update public.price_conditions set priority = priority + 1 where code = 'LIST';

  insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
  values (
    'PC-' || replace(gen_random_uuid()::text, '-', ''), '2 cuotas sin interés', 'PAYMENT_METHOD',
    v_payment_method_id, 0, coalesce(v_list_priority, 100), false, true
  )
  returning id into v_price_condition_id;

  -- Disponibilidad aprobada: Sede 25 + Sede 37 + Web.
  insert into public.price_condition_locations (price_condition_id, location_id)
  select v_price_condition_id, sl.id from public.stock_locations sl where sl.type = 'branch';

  insert into public.price_condition_sales_channels (price_condition_id, sales_channel_id)
  select v_price_condition_id, sc.id from public.sales_channels sc where sc.code = 'WEB';

  -- Precio inicial = copia de LIST vigente por producto, dato real en
  -- product_prices (Modelo B) — nunca una fórmula. Producto sin LIST
  -- vigente queda sin fila acá, no se inventa nada.
  insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
  select pp.product_id, v_price_condition_id, pp.amount, now()
  from public.product_prices pp
  join public.price_conditions lc on lc.id = pp.price_condition_id and lc.code = 'LIST'
  where pp.active = true and (pp.valid_until is null or pp.valid_until > now());

  get diagnostics v_copied_count = row_count;

  raise notice 'Condición "2 cuotas sin interés" creada (payment_method_id=%, price_condition_id=%, % precios copiados de LIST).',
    v_payment_method_id, v_price_condition_id, v_copied_count;
end;
$$;
