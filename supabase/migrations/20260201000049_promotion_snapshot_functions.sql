-- =============================================================================
-- Maguirejuve · 47 · Analytics de productos, kits y promociones — completar y
-- propagar el snapshot de promoción (paso 2/5)
-- =============================================================================
-- Ninguna de las dos funciones de abajo cambia de firma — mismos parámetros
-- exactos que 20260201000037_pricing_surcharge_functions.sql (la versión
-- vigente de cada una) — CREATE OR REPLACE alcanza, no hace falta DROP.

-- ---------------------------------------------------------------------------
-- 1) fn_create_sale_core — al insertar cada sale_item, si la línea tiene
--    applied_promotion_id, se resuelve promotions UNA VEZ por línea y se
--    graban sus 5 columnas de snapshot tal como están AHORA (que es "ahora"
--    desde el punto de vista de esta venta — es la primera y única vez que
--    se escribe). De acá en más nunca se vuelve a tocar esta fila.
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
  v_line_promotion_id uuid;
  v_promotion public.promotions;
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
    subtotal, discount_total, surcharge_total, total, commission_total, status,
    external_source, external_order_id, notes,
    is_free_sale, free_sale_reason, free_sale_notes, stock_skipped,
    payment_account_id, billing_status
  ) values (
    v_sale_number, p_sold_at, p_location_id, p_sales_channel_id, p_seller_id,
    p_customer_id, p_doctor_id, p_payment_method_id, (v_quote ->> 'applied_price_condition_id')::uuid,
    (v_quote ->> 'subtotal')::numeric, (v_quote ->> 'discount_total')::numeric,
    coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
    (v_quote ->> 'total')::numeric, v_commission_total, 'confirmed',
    p_external_source, p_external_order_id, p_notes,
    p_is_free_sale, p_free_sale_reason, p_free_sale_notes, p_skip_stock_movement,
    v_payment_account_id, v_billing_status
  )
  returning id into v_sale_id;

  for v_line in select * from jsonb_array_elements(v_quote -> 'lines')
  loop
    -- Snapshot de promoción: se resuelve una única vez, acá, contra
    -- promotions "vivo" — es la ÚNICA vez que esta fila de sale_items se
    -- escribe, así que "vivo ahora" y "snapshot histórico" son el mismo
    -- valor en este preciso instante. v_promotion queda NULL (y por lo
    -- tanto todas las columnas de snapshot también) cuando la línea no
    -- tuvo promoción — coherente con applied_promotion_id null.
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
    'surcharge_total', coalesce((v_quote ->> 'surcharge_total')::numeric, 0),
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

comment on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text, timestamptz,
  boolean, public.free_sale_reason, text, boolean, uuid
) is
  'Punto único de creación de ventas confirmadas. Cada sale_item con promoción graba, además de '
  'applied_promotion_id (la referencia viva), un snapshot de identidad (nombre/tipo/%/vigencia de '
  'promotions en ESE momento) — así Analytics puede comparar promociones históricas mes a mes sin '
  'que una edición posterior del nombre/% cambie retroactivamente lo ya vendido.';

-- ---------------------------------------------------------------------------
-- 2) create_sale_exchange — las líneas 'copy'/'remainder' son literalmente
--    la MISMA línea comercial trasladada (mismo criterio ya usado para
--    applied_promotion_id/promotion_discount: se copian tal cual, nunca se
--    recalculan) — el snapshot viaja con ellas. La línea 'new' nunca tiene
--    promoción (fn_exchange_new_item_price no evalúa promociones — decisión
--    de diseño ya cerrada), así que sus 5 columnas de snapshot quedan null,
--    igual que su applied_promotion_id.
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
  select quantity into v_root_quantity from public.sale_items where id = v_physical_source_id;

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

  -- Líneas no tocadas: copiadas verbatim, snapshot de promoción incluido tal
  -- cual estaba en la línea original — nunca se vuelve a resolver contra
  -- promotions (sería repreciar/reinterpretar algo que el cliente no tocó).
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
  'Cambio de producto: genera una venta de reemplazo completa, nunca edita la original (pasa a '
  'replaced). Líneas copy/remainder trasladan su snapshot de promoción tal cual (nunca se '
  're-resuelve contra promotions); la línea new nunca tiene promoción (fn_exchange_new_item_price '
  'no evalúa promociones), así que su snapshot queda null.';
