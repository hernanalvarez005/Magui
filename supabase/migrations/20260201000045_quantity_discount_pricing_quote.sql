-- =============================================================================
-- Maguirejuve · 46 · Condiciones QUANTITY -> Promociones — fn_pricing_quote (paso 4/5)
-- =============================================================================
-- Único cambio real de esta migración: la resolución de v_condition deja de
-- considerar rule_type = 'QUANTITY' — queda BASE/PAYMENT_METHOD únicamente
-- (sección 20 del pedido). El flujo conceptual final:
--   1) condición base según medio de pago (o BASE si no hay ninguna PAYMENT_METHOD)
--   2) precio base bajo esa condición
--   3) fn_apply_promotions evalúa TODAS las promociones activas (incluida
--      QUANTITY_DISCOUNT, ver migración anterior)
--   4) se aplica como máximo una promoción ganadora
-- v_total_qty se mantiene (todavía se usa como comentario histórico de por
-- qué se excluyen líneas manuales del cálculo de promociones) pero ya no
-- alimenta ninguna condición de precio — fn_apply_promotions calcula su
-- propia cuenta de unidades participantes de forma independiente, por
-- promoción, no por carrito completo.
-- Resto de la función sin cambios respecto de 20260201000037. Misma firma —
-- CREATE OR REPLACE sin necesidad de DROP.
create or replace function public.fn_pricing_quote(
  p_items jsonb,
  p_payment_method_id uuid,
  p_sold_at timestamptz default now(),
  p_is_free_sale boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_condition record;
  v_line record;
  v_lines jsonb := '[]'::jsonb;
  v_manual_lines jsonb := '[]'::jsonb;
  v_auto_lines jsonb := '[]'::jsonb;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_surcharge numeric := 0;
  v_total numeric := 0;
  v_item_count int;
  v_distinct_count int;
  v_missing_product text;
  v_invalid_qty boolean;
  v_has_manual boolean;
  v_invalid_manual boolean;
  v_promo_result jsonb;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'error_message', 'El carrito está vacío.');
  end if;

  select count(*), count(distinct (elem ->> 'product_id'))
  into v_item_count, v_distinct_count
  from jsonb_array_elements(p_items) elem;

  if v_item_count <> v_distinct_count then
    return jsonb_build_object('ok', false, 'error_message', 'Hay un producto duplicado en el carrito.');
  end if;

  select bool_or((elem ->> 'quantity')::numeric is null or (elem ->> 'quantity')::numeric <= 0)
  into v_invalid_qty
  from jsonb_array_elements(p_items) elem;

  if v_invalid_qty then
    return jsonb_build_object('ok', false, 'error_message', 'Hay una cantidad inválida en el carrito.');
  end if;

  select string_agg(elem ->> 'product_id', ', ')
  into v_missing_product
  from jsonb_array_elements(p_items) elem
  left join public.products p on p.id = (elem ->> 'product_id')::uuid and p.active = true
  where p.id is null;

  if v_missing_product is not null then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'Uno de los productos del carrito no existe o está inactivo.'
    );
  end if;

  -- Precio manual: exclusivo de admin, nunca confiando en que el frontend
  -- lo oculte (mismo criterio que backdatear una venta o saltear stock).
  select bool_or(nullif(elem ->> 'manual_price', '') is not null)
  into v_has_manual
  from jsonb_array_elements(p_items) elem;

  if v_has_manual and not public.is_admin() then
    raise exception 'Solo un administrador puede editar el precio manualmente.';
  end if;

  if v_has_manual and p_is_free_sale then
    return jsonb_build_object(
      'ok', false,
      'error_message', 'Una entrega sin costo no admite precio manual — son modos distintos.'
    );
  end if;

  select bool_or(nullif(elem ->> 'manual_price', '') is not null and (elem ->> 'manual_price')::numeric <= 0)
  into v_invalid_manual
  from jsonb_array_elements(p_items) elem;

  if v_invalid_manual then
    return jsonb_build_object('ok', false, 'error_message', 'El precio manual tiene que ser mayor a $0.');
  end if;

  -- -------------------------------------------------------------------------
  -- Venta sin costo: sin condición de precio, sin comisión, sin promociones,
  -- sin precio manual (ya se descartó esa combinación arriba) — precio de
  -- lista únicamente como referencia. Nunca se interpreta como "precio $0 manual".
  -- -------------------------------------------------------------------------
  if p_is_free_sale then
    for v_line in
      select ti.product_id, p.sku, p.name, ti.quantity, list_price.amount as list_unit_price
      from (
        select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
        from jsonb_array_elements(p_items) elem
      ) ti
      join public.products p on p.id = ti.product_id
      left join lateral (
        select pp.amount
        from public.product_prices pp
        join public.price_conditions lc on lc.id = pp.price_condition_id and lc.rule_type = 'BASE'
        where pp.product_id = ti.product_id
          and pp.active = true
          and pp.amount > 0
          and pp.valid_from <= p_sold_at
          and (pp.valid_until is null or pp.valid_until > p_sold_at)
        order by pp.valid_from desc
        limit 1
      ) list_price on true
    loop
      v_line.list_unit_price := coalesce(v_line.list_unit_price, 0);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      v_lines := v_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', 0,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_surcharge', 0,
        'line_total', 0,
        'commissionable', false,
        'applied_price_condition_id', null
      );
    end loop;

    return jsonb_build_object(
      'ok', true,
      'error_message', null,
      'applied_price_condition_id', null,
      'applied_price_condition_code', null,
      'applied_price_condition_name', null,
      'explanation', 'Venta sin costo',
      'subtotal', round(v_subtotal, 2),
      'discount_total', round(v_subtotal, 2),
      'surcharge_total', 0,
      'total', 0,
      'lines', v_lines
    );
  end if;

  -- -------------------------------------------------------------------------
  -- Condición base: SOLO medio de pago (o BASE como fallback universal).
  -- rule_type = 'QUANTITY' ya no se resuelve acá — esa lógica migró
  -- enteramente a fn_apply_promotions (tipo QUANTITY_DISCOUNT), evaluada por
  -- promoción de forma independiente, nunca escalando la condición de TODO
  -- el carrito por su cuenta (sección 20/21 del pedido de migración).
  -- -------------------------------------------------------------------------
  select pc.* into v_condition
  from public.price_conditions pc
  where pc.active
    and (
      pc.rule_type = 'BASE'
      or (pc.rule_type = 'PAYMENT_METHOD' and pc.payment_method_id = p_payment_method_id)
    )
  order by pc.priority asc
  limit 1;

  -- v_condition puede quedar sin resolver legítimamente solo si TODO el
  -- carrito tiene precio manual (no hace falta ninguna condición en ese
  -- caso) — el chequeo real de "hace falta y no hay" pasa adentro del loop,
  -- por línea, no acá arriba.

  for v_line in
    select
      ti.product_id,
      p.sku,
      p.name,
      p.commissionable,
      ti.quantity,
      ti.manual_price,
      list_price.amount as list_unit_price,
      sale_price.amount as sale_unit_price
    from (
      select
        (elem ->> 'product_id')::uuid as product_id,
        (elem ->> 'quantity')::numeric as quantity,
        nullif(elem ->> 'manual_price', '')::numeric as manual_price
      from jsonb_array_elements(p_items) elem
    ) ti
    join public.products p on p.id = ti.product_id
    left join lateral (
      select pp.amount
      from public.product_prices pp
      join public.price_conditions lc on lc.id = pp.price_condition_id and lc.rule_type = 'BASE'
      where pp.product_id = ti.product_id
        and pp.active = true
        and pp.amount > 0
        and pp.valid_from <= p_sold_at
        and (pp.valid_until is null or pp.valid_until > p_sold_at)
      order by pp.valid_from desc
      limit 1
    ) list_price on true
    left join lateral (
      select pp.amount
      from public.product_prices pp
      where pp.product_id = ti.product_id
        and pp.price_condition_id = v_condition.id
        and pp.active = true
        and pp.amount > 0
        and pp.valid_from <= p_sold_at
        and (pp.valid_until is null or pp.valid_until > p_sold_at)
      order by pp.valid_from desc
      limit 1
    ) sale_price on true
  loop
    if v_line.manual_price is not null then
      -- Precio editado a mano: ignora price_conditions por completo. El
      -- precio de lista queda solo como referencia para mostrar el
      -- "descuento"/"recargo" en el resumen — si el producto ni siquiera
      -- tiene lista cargada, se usa el propio precio manual (sin referencia
      -- = ni descuento ni recargo que mostrar, no es un error). Un admin
      -- puede legítimamente editar a mano un precio por ENCIMA de lista
      -- (mismo criterio que cualquier condición de pago).
      v_line.list_unit_price := coalesce(v_line.list_unit_price, v_line.manual_price);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      v_manual_lines := v_manual_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', v_line.manual_price,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(greatest((v_line.list_unit_price - v_line.manual_price) * v_line.quantity, 0), 2),
        'line_surcharge', round(greatest((v_line.manual_price - v_line.list_unit_price) * v_line.quantity, 0), 2),
        'line_total', round(v_line.manual_price * v_line.quantity, 2),
        'commissionable', v_line.commissionable,
        'applied_price_condition_id', null,
        'applied_promotion_id', null,
        'promotion_discount', 0,
        'manual_price', true
      );
    else
      if v_condition is null then
        return jsonb_build_object('ok', false, 'error_message', 'No hay ninguna condición de precio activa configurada.');
      end if;

      if v_line.sale_unit_price is null then
        return jsonb_build_object(
          'ok', false,
          'error_message', format('Este producto no tiene precio configurado para %s: %s.', v_condition.name, v_line.name)
        );
      end if;

      v_line.list_unit_price := coalesce(v_line.list_unit_price, v_line.sale_unit_price);
      v_subtotal := v_subtotal + (v_line.list_unit_price * v_line.quantity);

      -- Una condición de pago más cara que Lista (ej. cuotas) es un recargo
      -- comercial VÁLIDO, no un error — line_discount y line_surcharge son
      -- complementarios, nunca los dos > 0 en la misma línea.
      v_auto_lines := v_auto_lines || jsonb_build_object(
        'product_id', v_line.product_id,
        'sku', v_line.sku,
        'name', v_line.name,
        'quantity', v_line.quantity,
        'list_unit_price', v_line.list_unit_price,
        'sale_unit_price', v_line.sale_unit_price,
        'line_list_total', round(v_line.list_unit_price * v_line.quantity, 2),
        'line_discount', round(greatest((v_line.list_unit_price - v_line.sale_unit_price) * v_line.quantity, 0), 2),
        'line_surcharge', round(greatest((v_line.sale_unit_price - v_line.list_unit_price) * v_line.quantity, 0), 2),
        'line_total', round(v_line.sale_unit_price * v_line.quantity, 2),
        'commissionable', v_line.commissionable,
        'applied_price_condition_id', v_condition.id
      );
    end if;
  end loop;

  -- Promociones: se evalúan solo sobre las líneas SIN precio manual — un
  -- override puntual no participa como candidata de 3x2/duo%/kit%/cantidad%,
  -- ni cuenta para el umbral de cantidad de otro producto.
  v_promo_result := public.fn_apply_promotions(v_auto_lines, p_sold_at);
  v_lines := v_manual_lines || (v_promo_result -> 'lines');

  -- discount_total/surcharge_total SIEMPRE sumados desde las líneas ya
  -- clampeadas — nunca derivados como subtotal-total (esa resta no puede
  -- representar un recargo: rompería en cuanto total > subtotal).
  select
    coalesce(sum((elem ->> 'line_total')::numeric), 0),
    coalesce(sum((elem ->> 'line_discount')::numeric), 0),
    coalesce(sum((elem ->> 'line_surcharge')::numeric), 0)
  into v_total, v_discount, v_surcharge
  from jsonb_array_elements(v_lines) elem;

  -- v_condition resuelve a una condición real (típicamente Lista) aunque el
  -- carrito sea 100% manual — la búsqueda no depende de que haya líneas
  -- auto. Si NINGUNA línea la usó de verdad, mostrarla en la respuesta sería
  -- engañoso (un reporte que agrupe por applied_price_condition_id le
  -- atribuiría la venta a una condición que nunca se aplicó).
  if jsonb_array_length(v_auto_lines) = 0 then
    return jsonb_build_object(
      'ok', true,
      'error_message', null,
      'applied_price_condition_id', null,
      'applied_price_condition_code', null,
      'applied_price_condition_name', null,
      'explanation', 'Precio manual',
      'subtotal', round(v_subtotal, 2),
      'discount_total', round(v_discount, 2),
      'surcharge_total', round(v_surcharge, 2),
      'total', round(v_total, 2),
      'lines', v_lines
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'error_message', null,
    'applied_price_condition_id', v_condition.id,
    'applied_price_condition_code', v_condition.code,
    'applied_price_condition_name', v_condition.name,
    'explanation', case
      when v_has_manual then format('%s + precio manual', v_condition.name)
      when v_condition.rule_type = 'BASE' then 'Precio lista'
      when v_condition.discount_percent is not null and v_condition.discount_percent > 0
        then format('%s — %s%% OFF', v_condition.name, round(v_condition.discount_percent * 100))
      else v_condition.name
    end,
    'subtotal', round(v_subtotal, 2),
    'discount_total', round(v_discount, 2),
    'surcharge_total', round(v_surcharge, 2),
    'total', round(v_total, 2),
    'lines', v_lines
  );
end;
$$;

comment on function public.fn_pricing_quote(jsonb, uuid, timestamptz, boolean) is
  'Motor de cotización. Condición base = BASE/PAYMENT_METHOD únicamente (QUANTITY migró a '
  'Promociones — tipo QUANTITY_DISCOUNT, ver fn_apply_promotions). Flujo: 1) condición base '
  'según medio de pago, 2) precio base bajo esa condición, 3) fn_apply_promotions evalúa todas '
  'las promociones activas, 4) se aplica como máximo una promoción ganadora (no acumulable).';
