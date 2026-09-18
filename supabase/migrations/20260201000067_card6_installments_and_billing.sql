-- =============================================================================
-- Maguirejuve · 67 · Nueva condición de precio: "6 cuotas sin interés"
-- =============================================================================
-- Auditoría previa (entregada y aprobada por el usuario antes de este
-- archivo): payment_methods/price_conditions/product_prices ya son
-- genéricos por completo — el motor de precios (fn_pricing_quote/
-- fn_apply_promotions) resuelve cualquier condición nueva sin código
-- especial, siempre que exista la fila y su precio. El ÚNICO lugar del
-- backend con lógica hardcodeada por código de medio de pago es
-- `v_requires_billing := ... in ('TRANSFER', 'CARD_1', 'CARD_3')`, repetida
-- en exactamente 2 funciones vigentes (fn_create_sale_core y
-- create_sale_exchange — las demás apariciones históricas de esa expresión
-- en migraciones viejas quedaron superadas por sucesivos `create or
-- replace`, no son código vivo). Se agrega 'CARD_6' en las dos, sin tocar
-- ninguna otra línea de ninguna de las dos funciones.
--
-- Convención de nomenclatura (decisión del usuario, sección 1 del pedido):
-- misma semántica que CARD_3/INSTALLMENTS_3 (no la de CARD_1, que reusa el
-- mismo code en payment_methods y price_conditions porque es un pago único,
-- no una familia de cuotas) —
--   payment_methods.code    = 'CARD_6'          (familia CARD_N, como CARD_1/CARD_3)
--   price_conditions.code   = 'INSTALLMENTS_6'   (familia INSTALLMENTS_N, como INSTALLMENTS_3)
--
-- Precio: NINGÚN porcentaje comercial hardcodeado. discount_percent = 0 es
-- el mismo placeholder neutro que ya usan CARD_1/INSTALLMENTS_3 (ese campo
-- es "informativo/comercial, NO se usa para calcular el precio real" —
-- comentario textual preexistente en la propia columna). El precio real de
-- 6 cuotas se siembra igual al de Lista vigente de cada producto (mismo
-- patrón exacto que 20260201000007_card1_payment_method.sql) — administrable
-- después, producto por producto, desde /admin/precios vía set_product_price
-- (RPC ya genérica, sin cambios).
--
-- Facturación (decisión del usuario, sección 2 del pedido): 6 cuotas debe
-- comportarse EXACTAMENTE igual que CARD_1/CARD_3 — requiere DNI, requiere
-- cuenta de ingreso (salvo Web + payment_status=PENDING, regla ya genérica
-- vía computeRequiresPaymentAccountNow/BUGFIX 57, sin tocar), genera
-- billing_status igual. Alcanza con agregar 'CARD_6' al array — el resto de
-- ambas funciones es copia exacta de las versiones vigentes
-- (20260201000063 para fn_create_sale_core, 20260201000061 para
-- create_sale_exchange).
--
-- Promociones: NO se toca fn_apply_promotions ni fn_pricing_quote (decisión
-- del usuario, sección 6). Auditado: el motor ya decide "gana la promoción"
-- por producto (migración 066), independiente de qué medio de pago se haya
-- elegido — agregar una condición de precio nueva no cambia ese mecanismo.
--
-- Medios permitidos por promoción: NO se crea lógica especial (sección 7).
-- promotion_payment_methods / set_promotion_payment_methods ya son
-- genéricos por payment_method_id — CARD_6 aparece solo como opción
-- configurable en Administración → Promociones en cuanto existe la fila en
-- payment_methods. La excepción channel<>WEB de esa validación (migración
-- 63) no se toca.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) payment_methods — nuevo medio de pago.
-- ---------------------------------------------------------------------------
insert into public.payment_methods (code, name, sort_order) values
  ('CARD_6', '6 cuotas sin interés', 5)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2) price_conditions — nueva condición, insertada justo antes de LIST
--    (mismo patrón que 20260201000007: se corre LIST un lugar más abajo en
--    prioridad, sin tocar la precedencia relativa de nada más).
-- ---------------------------------------------------------------------------
update public.price_conditions set priority = 8 where code = 'LIST';

insert into public.price_conditions (code, name, rule_type, payment_method_id, min_units, discount_percent, priority, combinable)
values (
  'INSTALLMENTS_6', '6 cuotas sin interés', 'PAYMENT_METHOD',
  (select id from public.payment_methods where code = 'CARD_6'),
  null, 0, 7, false
)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 3) Precio inicial = precio de Lista vigente, para todo producto que ya
--    tenga Lista activa — dato, no código, editable después sin deploy
--    (mismo patrón exacto que CARD_1).
-- ---------------------------------------------------------------------------
insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
select pp.product_id, (select id from public.price_conditions where code = 'INSTALLMENTS_6'), pp.amount, pp.valid_from
from public.product_prices pp
join public.price_conditions lc on lc.id = pp.price_condition_id and lc.code = 'LIST'
where pp.active = true
  and not exists (
    select 1 from public.product_prices existing
    where existing.product_id = pp.product_id
      and existing.price_condition_id = (select id from public.price_conditions where code = 'INSTALLMENTS_6')
  );

-- ---------------------------------------------------------------------------
-- 4) fn_create_sale_core — copia exacta de 20260201000063, con 'CARD_6'
--    agregado a v_requires_billing. Ninguna otra línea cambia.
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
  v_channel_code text;
  v_invalid_promotion_payment boolean;
begin
  if not exists (select 1 from public.stock_locations where id = p_location_id and active) then
    raise exception 'La sucursal seleccionada no existe o está inactiva.';
  end if;

  select code into v_channel_code from public.sales_channels where id = p_sales_channel_id and active;
  if v_channel_code is null then
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

  -- Migración 67: 'CARD_6' agregado — único cambio real de esta función.
  v_requires_billing := not p_is_free_sale and v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3', 'CARD_6');

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
  'Punto único de creación de ventas confirmadas. Migración 67: CARD_6 (6 cuotas sin interés) '
  'agregado a v_requires_billing — se factura exactamente igual que TRANSFER/CARD_1/CARD_3. '
  'Migración 63: valida medios de pago permitidos por promoción (promotion_payment_methods) para '
  'canal <> WEB, entre fn_pricing_quote y el insert en sales — un rechazo no llega a tocar '
  'sales/sale_items/stock/comisión. Promoción legacy sin filas configuradas no restringe nada. '
  'BUGFIX 57 (billing_status NOT_REQUIRED mientras un pedido Web esté PENDING de cobro) sin cambios. '
  'Resto de la función sin cambios respecto de 20260201000055/56/57/63.';

-- ---------------------------------------------------------------------------
-- 5) create_sale_exchange — copia exacta de 20260201000061, con 'CARD_6'
--    agregado a v_requires_billing. Ninguna otra línea cambia. Alcance
--    (decisión del usuario, sección 10): NO se amplían los medios
--    permitidos para reintegros (sale_refund_method sigue CASH/TRANSFER
--    únicamente, sin tocar) — esto es solo la facturación de la OPERACIÓN
--    DE REEMPLAZO de un cambio, que hereda el medio de pago histórico de la
--    venta original (nunca se re-selecciona acá).
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
  -- Migración 67: 'CARD_6' agregado — único cambio real de esta función.
  v_requires_billing := v_payment_method_code in ('TRANSFER', 'CARD_1', 'CARD_3', 'CARD_6');

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
  'Cambio de producto. Migración 67: CARD_6 (6 cuotas sin interés) agregado a v_requires_billing — '
  'la operación de reemplazo se factura exactamente igual que TRANSFER/CARD_1/CARD_3 cuando la '
  'venta original se pagó así (el medio de pago siempre se hereda de la venta original, nunca se '
  're-selecciona en un cambio). No amplía los medios de sale_refund_method (devoluciones) — eje '
  'completamente aparte, sin tocar. BLOQUE F (61): antes de descontar el producto nuevo, valida '
  'disponible (fn_check_available_stock — físico - reservas ACTIVE), igual que ya hace '
  'fn_create_sale_core desde 055. BUGFIX 55 (guard PENDING_PICKUP) y todo lo demás siguen '
  'exactamente igual.';
