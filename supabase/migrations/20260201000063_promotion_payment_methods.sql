-- =============================================================================
-- Maguirejuve · 63 · Formas de pago habilitadas por promoción
-- =============================================================================
-- Caso real de producción a evitar estructuralmente: una promoción 3x2
-- comercialmente válida solo con Efectivo/Transferencia se vendió con 3
-- cuotas sin interés porque nada en el sistema impedía esa combinación.
--
-- Modelo (auditoría previa, presentada y aprobada por el usuario antes de
-- este archivo): tabla M:N `promotion_payment_methods`, separada de
-- `promotions.price_condition_id` (que sigue siendo la base económica del
-- descuento, nunca se toca acá) — son dos conceptos distintos: price
-- condition = precio base sobre el que se calcula la promo; allowed payment
-- methods = medios con los que comercialmente se permite pagarla.
--
-- Legacy (sin backfill, opción confirmada por el usuario): una promoción sin
-- ninguna fila en `promotion_payment_methods` queda SIN restricción — todos
-- los medios activos son válidos, exactamente el comportamiento de hoy. La
-- regla "al guardar, exigir al menos 1 medio" vive en
-- `set_promotion_payment_methods` y se aplica a cualquier guardado explícito
-- (alta o edición) — una promoción legacy nunca vuelve a quedar en el estado
-- "0 filas" una vez que un admin la edita y guarda. No hace falta una
-- columna extra tipo `payment_methods_restricted`: la ausencia de filas es
-- una señal inequívoca de "todavía no configurada".
--
-- Alcance (confirmado): exclusivamente ventas de canal <> 'WEB' (hoy el
-- único otro canal es 'BRANCH' = Sede 25/Sede 37 — nunca Depósito, que no es
-- una sede de venta presencial). Las Ventas Web (`create_sale` con canal
-- WEB, y `create_web_order` para integraciones externas, que siempre resuelve
-- WEB internamente) quedan completamente exceptuadas — el circuito de
-- fulfillment recién mergeado (BLOQUES B-G) no se toca.
--
-- Punto de validación (auditoría): dentro de `fn_create_sale_core`, justo
-- después de `fn_pricing_quote` y ANTES del insert en `sales` — en ese
-- momento ya se conocen con certeza el payment_method_id final y todas las
-- promociones ganadoras por línea (`v_quote -> 'lines' -> applied_promotion_id`).
-- Validar pre-insert (no post-insert-con-rollback) significa que un rechazo
-- no llega a tocar sales/sale_items/stock/comisión/facturación — nada que
-- revertir porque nada se insertó.
--
-- Múltiples promociones en un carrito (auditoría de fn_apply_promotions):
-- un producto pertenece a lo sumo a una promoción activa, así que el
-- carrito termina con UNA promoción no-combinable ganadora sola, o VARIAS
-- combinables ganando en simultáneo en productos distintos — nunca mezcla
-- de ambos casos. La validación intersecta los medios permitidos de todas
-- las promociones ganadoras que SÍ tengan restricción configurada; si la
-- intersección no incluye el medio elegido (incluida intersección vacía
-- entre dos promociones sin medio en común), se rechaza con el mismo
-- mensaje en los dos casos (confirmado por el usuario).
--
-- Sin impacto (auditado, confirmado, sin cambios de código):
--   - fn_pricing_quote/fn_apply_promotions: el matching de promociones ya es
--     independiente de payment_method_id, así que siguen devolviendo
--     exactamente lo mismo — esta validación es de ACEPTACIÓN de la venta,
--     no de CÁLCULO de precio.
--   - create_sale_exchange: reutiliza el payment_method_id HISTÓRICO de la
--     venta original (nunca se re-selecciona) y el producto nuevo del
--     cambio nunca pasa por fn_apply_promotions (applied_promotion_id
--     hardcodeado a null) — cero superficie nueva.
--   - create_sale_return: no referencia payment_method_id ni al motor de
--     promociones en ningún punto.
--   - Ventas históricas: sale_items ya guarda snapshot completo
--     (promotion_name_snapshot/type_snapshot/etc.) y sales.payment_method_id
--     es la columna real de la fila — la validación nueva solo corre al
--     CREAR una venta, nunca reinterpreta una fila ya confirmada.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) promotion_payment_methods — M:N, mismo shape que promotion_products.
-- ---------------------------------------------------------------------------
create table public.promotion_payment_methods (
  id uuid primary key default gen_random_uuid(),
  promotion_id uuid not null references public.promotions (id) on delete cascade,
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint promotion_payment_methods_unique unique (promotion_id, payment_method_id)
);

comment on table public.promotion_payment_methods is
  'Medios de pago con los que comercialmente se permite pagar cada promoción (ventas presenciales '
  'Sede 25/Sede 37 únicamente — Web queda exceptuada, ver fn_create_sale_core). Sin filas para una '
  'promoción = sin restricción configurada (todos los medios activos son válidos) — estado legacy, '
  'nunca alcanzable para una promoción creada/editada después de esta migración porque '
  'set_promotion_payment_methods exige al menos 1 fila en cualquier guardado explícito. No confundir '
  'con promotions.price_condition_id (precio base sobre el que se calcula el descuento — concepto '
  'económico distinto de "con qué medios se puede pagar").';

alter table public.promotion_payment_methods enable row level security;

create policy promotion_payment_methods_select on public.promotion_payment_methods
  for select using (public.is_active_profile());
create policy promotion_payment_methods_admin_write on public.promotion_payment_methods
  for insert with check (public.is_admin());
create policy promotion_payment_methods_admin_update on public.promotion_payment_methods
  for update using (public.is_admin()) with check (public.is_admin());
create policy promotion_payment_methods_admin_delete on public.promotion_payment_methods
  for delete using (public.is_admin());

-- ---------------------------------------------------------------------------
-- 2) set_promotion_payment_methods — reemplaza toda la configuración de
--    medios permitidos de una promoción en una sola transacción (mismo
--    patrón que set_promotion_products). Exige al menos 1 medio SIEMPRE que
--    se llama — así una promoción legacy nunca vuelve a quedar en "0 filas"
--    una vez que un admin la edita y guarda.
-- ---------------------------------------------------------------------------
create or replace function public.set_promotion_payment_methods(p_promotion_id uuid, p_payment_method_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede editar los medios de pago habilitados de una promoción.';
  end if;

  if not exists (select 1 from public.promotions where id = p_promotion_id) then
    raise exception 'La promoción no existe.';
  end if;

  if p_payment_method_ids is null or array_length(p_payment_method_ids, 1) is null then
    raise exception 'Una promoción necesita al menos un medio de pago habilitado.';
  end if;

  if array_length(p_payment_method_ids, 1) <> (select count(distinct x) from unnest(p_payment_method_ids) x) then
    raise exception 'No repitas el mismo medio de pago.';
  end if;

  if exists (
    select 1 from unnest(p_payment_method_ids) x
    where not exists (select 1 from public.payment_methods where id = x and active = true)
  ) then
    raise exception 'Uno de los medios de pago seleccionados no existe o está inactivo.';
  end if;

  delete from public.promotion_payment_methods where promotion_id = p_promotion_id;

  insert into public.promotion_payment_methods (promotion_id, payment_method_id)
  select p_promotion_id, x from unnest(p_payment_method_ids) x;

  return jsonb_build_object('promotion_id', p_promotion_id, 'payment_method_count', array_length(p_payment_method_ids, 1));
end;
$$;

grant execute on function public.set_promotion_payment_methods(uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) fn_create_sale_core — misma firma exacta que 20260201000057 (create or
--    replace, sin cambio de parámetros). Único cambio real: se agrega el
--    lookup de v_channel_code y el bloque de validación de medios de pago
--    permitidos por promoción, entre fn_pricing_quote y el insert en sales.
--    Resto de la función IDÉNTICO a 20260201000057 (billing_status/bypass de
--    sede de esa migración no se tocan).
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
  'Punto único de creación de ventas confirmadas. Migración 63: valida medios de pago permitidos '
  'por promoción (promotion_payment_methods) para canal <> WEB, entre fn_pricing_quote y el insert '
  'en sales — un rechazo no llega a tocar sales/sale_items/stock/comisión. Promoción legacy sin '
  'filas configuradas no restringe nada. BUGFIX 57 (billing_status NOT_REQUIRED mientras un pedido '
  'Web esté PENDING de cobro) sin cambios. Resto de la función sin cambios respecto de '
  '20260201000055/56/57.';
