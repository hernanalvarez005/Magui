-- =============================================================================
-- Maguirejuve · 42 · Cambios / Devoluciones — funciones (paso 3/3, Bloque B)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) fn_apply_stock_movement: nuevo parámetro p_source_sale_item_id (ver
--    comentario en la columna, migración anterior). CREATE OR REPLACE no pisa
--    una firma distinta — se dropea la firma exacta vigente antes.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_apply_stock_movement(
  uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text,
  public.stock_adjustment_reason, text, uuid, boolean
);

create or replace function public.fn_apply_stock_movement(
  p_location_id uuid,
  p_product_id uuid,
  p_movement_type public.stock_movement_type,
  p_quantity_delta numeric,
  p_sale_id uuid default null,
  p_transfer_id uuid default null,
  p_reference text default null,
  p_reason public.stock_adjustment_reason default null,
  p_notes text default null,
  p_created_by uuid default null,
  p_allow_negative boolean default false,
  p_source_sale_item_id uuid default null
)
returns public.stock_movements
language plpgsql
as $$
declare
  v_current numeric(14, 2);
  v_resulting numeric(14, 2);
  v_movement public.stock_movements;
  v_product_name text;
begin
  insert into public.inventory_balances (location_id, product_id, quantity)
  values (p_location_id, p_product_id, 0)
  on conflict (location_id, product_id) do nothing;

  select quantity into v_current
  from public.inventory_balances
  where location_id = p_location_id and product_id = p_product_id
  for update;

  v_resulting := v_current + p_quantity_delta;

  if v_resulting < 0 and not p_allow_negative then
    select name into v_product_name from public.products where id = p_product_id;
    raise exception using
      errcode = 'P1001',
      message = format(
        'No hay stock suficiente de %s. Disponible: %s. Requerido: %s.',
        coalesce(v_product_name, 'producto'), v_current, abs(p_quantity_delta)
      );
  end if;

  update public.inventory_balances
  set quantity = v_resulting, updated_at = now()
  where location_id = p_location_id and product_id = p_product_id;

  insert into public.stock_movements (
    location_id, product_id, movement_type, quantity_delta,
    sale_id, transfer_id, reference, reason, notes, created_by, source_sale_item_id
  ) values (
    p_location_id, p_product_id, p_movement_type, p_quantity_delta,
    p_sale_id, p_transfer_id, p_reference, p_reason, p_notes, p_created_by, p_source_sale_item_id
  )
  returning * into v_movement;

  return v_movement;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) fn_create_sale_core: misma firma (sin cambios de parámetros — no hace
--    falta dropear nada), solo cambia CÓMO arma el descuento de stock. Antes
--    agrupaba el fan-out de kits únicamente por product_id, así que un kit y,
--    por separado, uno de sus mismos componentes en el mismo carrito
--    terminaban fusionados en un único movimiento (indistinguible después).
--    Ahora agrupa por (sale_item_id, product_id) y toma la cantidad desde los
--    sale_items YA insertados (en vez de reparsear p_items) — cada
--    stock_movement queda trazado a la línea comercial exacta que lo generó,
--    algo que además ya faltaba para promociones 3x2/duo% (que también
--    pueden partir una misma línea en varias filas de sale_items). La suma
--    total descontada no cambia; solo se vuelve trazable por línea.
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
  p_payment_account_id uuid default null
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
  v_required record;
  v_allow_negative boolean;
  v_payment_method_code text;
  v_requires_billing boolean;
  v_billing_status public.sale_billing_status;
  v_payment_account_id uuid;
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

  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if v_requires_billing then
    if p_payment_account_id is null or not exists (
      select 1 from public.payment_accounts where id = p_payment_account_id and active
    ) then
      raise exception 'Esta forma de pago requiere indicar la cuenta donde ingresó el dinero.';
    end if;

    if p_customer_id is null or not exists (
      select 1 from public.customers
      where id = p_customer_id and dni is not null and trim(dni) <> ''
    ) then
      raise exception
        'Esta operación se puede facturar, así que necesita un cliente identificado con nombre y DNI.';
    end if;

    v_payment_account_id := p_payment_account_id;
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
    subtotal, discount_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    insert into public.sale_items (
      sale_id, product_id, quantity, list_unit_price, sale_unit_price,
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount
    ) values (
      v_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0)
    );
  end loop;

  if not p_skip_stock_movement then
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
    'commission_total', v_commission_total,
    'applied_price_condition_name', v_quote ->> 'applied_price_condition_name',
    'explanation', v_quote ->> 'explanation',
    'is_free_sale', p_is_free_sale,
    'stock_skipped', p_skip_stock_movement,
    'billing_status', v_billing_status,
    'lines', v_quote -> 'lines'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) fn_exchange_new_item_price: precio del producto nuevo de un cambio.
--    Interpretación LITERAL de "misma forma de pago que la venta original"
--    (cerrado explícitamente con el usuario): resuelve DIRECTO la condición
--    PAYMENT_METHOD del medio de pago, sin volver a evaluar BASE/QUANTITY —
--    un cambio nunca escala de condición por la cantidad del carrito final.
--    Nunca pasa por fn_apply_promotions (decisión de diseño ya cerrada:
--    "los cambios no aplican promociones nuevas automáticamente").
-- ---------------------------------------------------------------------------
create or replace function public.fn_exchange_new_item_price(
  p_product_id uuid,
  p_quantity numeric,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_condition public.price_conditions;
  v_list_price numeric;
  v_sale_price numeric;
begin
  if p_quantity is null or p_quantity <= 0 then
    return jsonb_build_object('ok', false, 'error_message', 'La cantidad tiene que ser mayor a 0.');
  end if;

  if not exists (select 1 from public.products where id = p_product_id and active = true) then
    return jsonb_build_object('ok', false, 'error_message', 'El producto nuevo no existe o está inactivo.');
  end if;

  select * into v_condition
  from public.price_conditions
  where rule_type = 'PAYMENT_METHOD' and payment_method_id = p_payment_method_id and active = true
  order by priority asc
  limit 1;

  if v_condition is null then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'No hay una condición de precio configurada para la forma de pago de la venta original.'
    );
  end if;

  select pp.amount into v_sale_price
  from public.product_prices pp
  where pp.product_id = p_product_id
    and pp.price_condition_id = v_condition.id
    and pp.active = true
    and pp.amount > 0
    and pp.valid_from <= p_sold_at
    and (pp.valid_until is null or pp.valid_until > p_sold_at)
  order by pp.valid_from desc
  limit 1;

  if v_sale_price is null then
    return jsonb_build_object(
      'ok', false,
      'error_message', format('El producto nuevo no tiene precio configurado para %s.', v_condition.name)
    );
  end if;

  select pp.amount into v_list_price
  from public.product_prices pp
  join public.price_conditions lc on lc.id = pp.price_condition_id and lc.rule_type = 'BASE'
  where pp.product_id = p_product_id
    and pp.active = true
    and pp.amount > 0
    and pp.valid_from <= p_sold_at
    and (pp.valid_until is null or pp.valid_until > p_sold_at)
  order by pp.valid_from desc
  limit 1;

  v_list_price := coalesce(v_list_price, v_sale_price);

  return jsonb_build_object(
    'ok', true,
    'error_message', null,
    'product_id', p_product_id,
    'quantity', p_quantity,
    'applied_price_condition_id', v_condition.id,
    'applied_price_condition_code', v_condition.code,
    'applied_price_condition_name', v_condition.name,
    'list_unit_price', v_list_price,
    'sale_unit_price', v_sale_price,
    'line_list_total', round(v_list_price * p_quantity, 2),
    'line_discount', round((v_list_price - v_sale_price) * p_quantity, 2),
    'line_total', round(v_sale_price * p_quantity, 2)
  );
end;
$$;

grant execute on function public.fn_exchange_new_item_price(uuid, numeric, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) create_sale_exchange — RPC transaccional. Admin o vendedor con acceso a
--    la sede de la venta original (viewer, bloqueado). Reconstruye el
--    carrito final completo (líneas no tocadas + remanente de la línea
--    parcialmente devuelta + producto nuevo), nunca reprecia lo no tocado.
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
  v_movement record;
  v_reversal_qty numeric;
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

  -- -------------------------------------------------------------------------
  -- Venta original: lock, estado, sede, cliente identificado. Bloquear en
  -- 'confirmed' es lo que además hace estructuralmente imposible devolver
  -- dos veces la misma línea: en cuanto un cambio prospera esta venta pasa a
  -- 'replaced' y ya no puede volver a ser el origen de otro cambio — un
  -- segundo cambio sobre lo mismo tiene que apuntar, si corresponde, a la
  -- venta de reemplazo (encadenado), nunca a esta.
  -- -------------------------------------------------------------------------
  select * into v_sale from public.sales where id = p_original_sale_id for update;

  if v_sale is null then
    raise exception 'La venta original no existe.';
  end if;

  if v_sale.status <> 'confirmed' then
    raise exception 'Esta venta no está confirmada (anulada o ya reemplazada por otro cambio) — no se puede volver a usar como origen de un cambio.';
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

  -- -------------------------------------------------------------------------
  -- Línea devuelta: lock, pertenece a esta venta, cantidad disponible. La
  -- propia sale_items.quantity de la línea referenciada YA es la cantidad
  -- disponible correcta en todo momento — sea la línea original o el
  -- remanente que dejó un cambio parcial anterior (nunca se edita en el
  -- lugar: cada remanente es una fila nueva con la cantidad que quedó).
  -- -------------------------------------------------------------------------
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

  -- -------------------------------------------------------------------------
  -- Ledger físico real de la línea devuelta — resuelto a la raíz (coalesce)
  -- para que funcione igual sea la primera devolución sobre esta línea o una
  -- posterior dentro de una cadena de cambios sucesivos.
  -- -------------------------------------------------------------------------
  v_physical_source_id := coalesce(v_returned_item.physical_source_sale_item_id, v_returned_item.id);
  select quantity into v_root_quantity from public.sale_items where id = v_physical_source_id;

  -- -------------------------------------------------------------------------
  -- Precio del producto nuevo — SIEMPRE recalculado server-side (nunca se
  -- confía en un valor mandado por el frontend), bajo la misma forma de pago
  -- de la venta original, sin promociones.
  -- -------------------------------------------------------------------------
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

  -- -------------------------------------------------------------------------
  -- Facturación de la operación de reemplazo — nunca duplica lo ya facturado
  -- de la original. Regla cerrada con el usuario (originales INVOICED nunca
  -- generan un pendiente nuevo por el total completo).
  -- -------------------------------------------------------------------------
  select code into v_payment_method_code from public.payment_methods where id = v_sale.payment_method_id;
  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3');

  if not v_requires_billing then
    v_replacement_billing_status := 'NOT_REQUIRED';
    v_difference_settlement_status := 'NOT_REQUIRED';
  elsif v_sale.billing_status = 'INVOICED' then
    -- La base ya facturada no se reabre — la operación de reemplazo hereda
    -- INVOICED directo (mismo total si diferencia=0; si no, la diferencia se
    -- trackea aparte, nunca como un pendiente por el total nuevo completo).
    v_replacement_billing_status := 'INVOICED';
    v_difference_settlement_status := case when v_difference <> 0 then 'PENDING' else 'NOT_REQUIRED' end;
  else
    -- NOT_REQUIRED no puede darse acá con v_requires_billing=true (medio de
    -- pago inmutable) salvo el caso ya bloqueado de venta sin costo. Queda
    -- PENDING: todavía no se facturó nada, así que el total nuevo completo
    -- es lo que corresponde dejar pendiente — un único pendiente, sin duplicar.
    v_replacement_billing_status := 'PENDING';
    v_difference_settlement_status := 'NOT_REQUIRED';
  end if;

  select * into v_settings from public.app_settings where id = 1;
  v_allow_negative := coalesce(v_settings.allow_negative_stock, false);

  -- -------------------------------------------------------------------------
  -- Carrito final: copiar sin repreciar cada línea no tocada, agregar el
  -- remanente (si quedó algo) de la línea devuelta al MISMO precio
  -- histórico, y agregar el producto nuevo. Nunca se recalculan precios de
  -- lo que el cliente no tocó.
  -- -------------------------------------------------------------------------
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
      'line_discount', v_item.line_discount,
      'line_total', v_item.line_total,
      'applied_price_condition_id', v_item.applied_price_condition_id,
      'commissionable', v_item.commissionable,
      'applied_promotion_id', v_item.applied_promotion_id,
      'promotion_discount', v_item.promotion_discount,
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
      'line_discount', round((v_returned_item.list_unit_price - v_returned_item.sale_unit_price) * v_remaining_qty, 2),
      'line_total', round(v_returned_item.sale_unit_price * v_remaining_qty, 2),
      'applied_price_condition_id', v_returned_item.applied_price_condition_id,
      'commissionable', v_returned_item.commissionable,
      'applied_promotion_id', v_returned_item.applied_promotion_id,
      'promotion_discount', 0,
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
    'line_total', v_new_line_total,
    'applied_price_condition_id', (v_price ->> 'applied_price_condition_id')::uuid,
    'commissionable', v_new_product.commissionable,
    'applied_promotion_id', null,
    'promotion_discount', 0,
    'physical_source_sale_item_id', null
  );

  select
    coalesce(sum((elem ->> 'line_list_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_total')::numeric), 0)
  into v_subtotal, v_discount_total, v_total
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

  -- billing_status=INVOICED (base ya facturada, heredada) exige invoiced_at/
  -- invoiced_by por sales_billing_invoiced_consistency — se completan con
  -- quien hizo el cambio, ahora, no con los datos de la factura original.
  insert into public.sales (
    sale_number, sold_at, location_id, sales_channel_id, seller_id,
    customer_id, doctor_id, payment_method_id, applied_price_condition_id,
    subtotal, discount_total, total, commission_total, status,
    notes, payment_account_id, billing_status, invoiced_at, invoiced_by, replaces_sale_id
  ) values (
    v_replacement_sale_number, now(), v_sale.location_id, v_sale.sales_channel_id, auth.uid(),
    v_sale.customer_id, v_sale.doctor_id, v_sale.payment_method_id, null,
    v_subtotal, v_discount_total, v_total, v_commission_total, 'confirmed',
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
      line_list_total, line_discount, line_total, applied_price_condition_id, commissionable,
      applied_promotion_id, promotion_discount, physical_source_sale_item_id
    ) values (
      v_replacement_sale_id,
      (v_line ->> 'product_id')::uuid,
      (v_line ->> 'quantity')::numeric,
      (v_line ->> 'list_unit_price')::numeric,
      (v_line ->> 'sale_unit_price')::numeric,
      (v_line ->> 'line_list_total')::numeric,
      (v_line ->> 'line_discount')::numeric,
      (v_line ->> 'line_total')::numeric,
      nullif(v_line ->> 'applied_price_condition_id', '')::uuid,
      (v_line ->> 'commissionable')::boolean,
      nullif(v_line ->> 'applied_promotion_id', '')::uuid,
      coalesce((v_line ->> 'promotion_discount')::numeric, 0),
      nullif(v_line ->> 'physical_source_sale_item_id', '')::uuid
    )
    returning id into v_new_sale_item_id;

    if v_line ->> 'role' = 'new' then
      v_new_line_item_id := v_new_sale_item_id;
    end if;
  end loop;

  -- -------------------------------------------------------------------------
  -- Stock — reintegrar lo devuelto: reversión PROPORCIONAL de cada
  -- stock_movement real de la línea raíz (returned_quantity / root_quantity),
  -- fila por fila del ledger histórico (así, para un kit, cada componente se
  -- repone en su proporción exacta, sin volver a mirar kit_components).
  -- -------------------------------------------------------------------------
  -- OJO: NO se filtra por sale_id = p_original_sale_id acá. En un cambio
  -- encadenado (Venta F -> cambio -> Venta G -> cambio -> Venta H), el
  -- ledger físico real de la línea sigue viviendo contra la venta RAÍZ (F),
  -- no contra p_original_sale_id de ESTE llamado (que puede ser G). Como
  -- source_sale_item_id ya identifica sin ambigüedad el conjunto exacto de
  -- movimientos (resuelto a la raíz más arriba), alcanza con eso.
  for v_movement in
    select location_id, product_id, quantity_delta
    from public.stock_movements
    where movement_type = 'SALE'
      and source_sale_item_id = v_physical_source_id
    order by product_id
  loop
    v_reversal_qty := round(p_returned_quantity * abs(v_movement.quantity_delta) / v_root_quantity, 2);
    if v_reversal_qty > 0 then
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
    end if;
  end loop;

  -- -------------------------------------------------------------------------
  -- Stock — descontar lo nuevo: composición VIGENTE de kit_components (es una
  -- operación nueva), en la misma sede (inmutable) de la venta original.
  -- -------------------------------------------------------------------------
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

  -- -------------------------------------------------------------------------
  -- La original nunca se edita ni se borra: solo cambia de estado.
  -- -------------------------------------------------------------------------
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
    'recognized_value', v_recognized_value,
    'new_item_total', v_new_line_total,
    'difference_amount', v_difference,
    'difference_direction', v_difference_direction,
    'billing_status', v_replacement_billing_status,
    'difference_settlement_status', v_difference_settlement_status
  );
end;
$$;

grant execute on function public.create_sale_exchange(uuid, uuid, numeric, uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) Acreditación de la diferencia de un cambio — exclusivo de admin, mismo
--    patrón que mark_sale_invoiced/mark_sale_pending.
-- ---------------------------------------------------------------------------
create or replace function public.mark_exchange_difference_settled(p_exchange_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.sale_exchanges;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede marcar acreditada la diferencia de un cambio.';
  end if;

  select * into v_exchange from public.sale_exchanges where id = p_exchange_id for update;
  if v_exchange is null then
    raise exception 'El cambio no existe.';
  end if;

  if v_exchange.difference_settlement_status = 'SETTLED' then
    raise exception 'La diferencia de este cambio ya está acreditada.';
  end if;

  if v_exchange.difference_settlement_status = 'NOT_REQUIRED' then
    raise exception 'Este cambio no tiene una diferencia que requiera acreditación.';
  end if;

  update public.sale_exchanges
  set difference_settlement_status = 'SETTLED', settled_at = now(), settled_by = auth.uid()
  where id = p_exchange_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'mark_exchange_difference_settled', 'sale_exchanges', p_exchange_id, '{}'::jsonb);

  return jsonb_build_object('exchange_id', p_exchange_id, 'difference_settlement_status', 'SETTLED');
end;
$$;

grant execute on function public.mark_exchange_difference_settled(uuid) to authenticated;

create or replace function public.mark_exchange_difference_pending(p_exchange_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.sale_exchanges;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede revertir una acreditación marcada por error.';
  end if;

  select * into v_exchange from public.sale_exchanges where id = p_exchange_id for update;
  if v_exchange is null then
    raise exception 'El cambio no existe.';
  end if;

  if v_exchange.difference_settlement_status <> 'SETTLED' then
    raise exception 'La diferencia de este cambio no está acreditada — no hay nada que revertir.';
  end if;

  update public.sale_exchanges
  set difference_settlement_status = 'PENDING', settled_at = null, settled_by = null
  where id = p_exchange_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'mark_exchange_difference_pending', 'sale_exchanges', p_exchange_id, '{}'::jsonb);

  return jsonb_build_object('exchange_id', p_exchange_id, 'difference_settlement_status', 'PENDING');
end;
$$;

grant execute on function public.mark_exchange_difference_pending(uuid) to authenticated;
