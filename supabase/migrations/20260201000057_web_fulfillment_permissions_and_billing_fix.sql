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
