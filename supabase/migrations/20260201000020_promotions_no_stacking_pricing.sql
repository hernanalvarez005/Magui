-- =============================================================================
-- Maguirejuve · 36 · Promociones no acumulables: precio base propio (Bloque C)
-- =============================================================================
-- Bug real corregido acá: fn_apply_promotions calculaba el % de la promoción
-- sobre c.sale_unit_price, que ya venía resuelto por price_conditions (medio
-- de pago/cantidad). Eso hacía que "promo 20% + transferencia" diera "20%
-- sobre el precio transferencia" en vez de sobre la condición base que la
-- propia promoción declara (promotions.price_condition_id, Bloque B).
--
-- Regla nueva (pseudológica del pedido):
--   IF sale_has_promotion: calculate_using_promotion_only()
--   ELSE:                  calculate_using_normal_price_condition()
-- Nunca los dos combinados. Para CADA producto alcanzado por una promoción
-- ganadora, esta función ahora resuelve su propio precio bajo
-- promotions.price_condition_id (fn_pricing_quote nunca le pasa el
-- sale_unit_price de la condición de pago para esos productos) — eso incluye
-- TODAS las unidades del producto que la promoción alcanza, no solo las que
-- terminan con descuento (ej. las unidades "remanente" de un 3x2/duo cuando
-- la cantidad no cierra justo también se recalculan bajo la condición base
-- de la promoción, nunca bajo la del medio de pago).
--
-- Si un producto alcanzado por una promoción ganadora no tiene precio
-- cargado bajo la condición base de esa promoción, se rechaza la venta con
-- un mensaje claro (mismo criterio que "no tiene precio para <condición>"
-- ya existente) — nunca se cae en silencio a otro precio.
create or replace function public.fn_apply_promotions(
  p_lines jsonb,
  p_sold_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_missing_product text;
  v_result jsonb;
begin
  -- -------------------------------------------------------------------------
  -- Paso 1: ¿algún producto de una promoción GANADORA no tiene precio bajo la
  -- condición base que esa promoción declara? Se chequea antes de construir
  -- las líneas para poder rechazar con un mensaje de negocio claro.
  -- -------------------------------------------------------------------------
  with cart as (
    select (elem ->> 'product_id')::uuid as product_id, (elem ->> 'quantity')::numeric as quantity
    from jsonb_array_elements(p_lines) elem
  ),
  active_promos as (
    select * from public.promotions
    where active = true and valid_from <= p_sold_at and (valid_until is null or valid_until > p_sold_at)
  ),
  promo_products_agg as (
    select promotion_id, array_agg(product_id) as product_ids
    from public.promotion_products
    group by promotion_id
  ),
  matches as (
    select ap.id, ap.type, ap.price_condition_id, ap.priority, ap.stackable, ppa.product_ids,
      case
        when ap.type = 'THREE_FOR_TWO' then
          (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids)) >= ap.group_size
          and (select coalesce(bool_and(c.quantity = floor(c.quantity)), false)
               from cart c where c.product_id = any (ppa.product_ids))
        when ap.type = 'DUO_PERCENT' then
          coalesce(array_length(ppa.product_ids, 1), 0) = 2
          and (select count(*) from cart c where c.product_id = any (ppa.product_ids)) = 2
        when ap.type = 'KIT_PERCENT' then
          exists (select 1 from cart c where c.product_id = any (ppa.product_ids))
        else false
      end as is_match
    from active_promos ap
    join promo_products_agg ppa on ppa.promotion_id = ap.id
  ),
  exclusive_winner as (
    select id from matches where is_match and stackable = false order by priority asc limit 1
  ),
  winners as (
    select m.* from matches m
    where m.is_match
      and (
        (exists (select 1 from exclusive_winner) and m.id = (select id from exclusive_winner))
        or (not exists (select 1 from exclusive_winner) and m.stackable = true)
      )
  )
  select p.name into v_missing_product
  from winners w
  join cart c on c.product_id = any (w.product_ids)
  join public.products p on p.id = c.product_id
  where not exists (
    select 1 from public.product_prices pp
    where pp.product_id = c.product_id
      and pp.price_condition_id = w.price_condition_id
      and pp.active = true
      and pp.amount > 0
      and pp.valid_from <= p_sold_at
      and (pp.valid_until is null or pp.valid_until > p_sold_at)
  )
  limit 1;

  if v_missing_product is not null then
    raise exception
      'La promoción no tiene precio configurado para su condición base en este producto: %.',
      v_missing_product;
  end if;

  -- -------------------------------------------------------------------------
  -- Paso 2: misma resolución de ganadoras, esta vez construyendo las líneas.
  -- Cada producto alcanzado por una promoción usa SIEMPRE promo_base_prices
  -- (precio bajo la condición base declarada por la promoción) como punto de
  -- partida — nunca cart.sale_unit_price (el resuelto por medio de pago).
  -- -------------------------------------------------------------------------
  with cart as (
    select
      (elem ->> 'product_id')::uuid as product_id,
      elem ->> 'sku' as sku,
      elem ->> 'name' as name,
      (elem ->> 'quantity')::numeric as quantity,
      (elem ->> 'list_unit_price')::numeric as list_unit_price,
      (elem ->> 'sale_unit_price')::numeric as sale_unit_price,
      (elem ->> 'line_list_total')::numeric as line_list_total,
      (elem ->> 'line_discount')::numeric as line_discount,
      (elem ->> 'line_total')::numeric as line_total,
      (elem ->> 'commissionable')::boolean as commissionable,
      nullif(elem ->> 'applied_price_condition_id', '')::uuid as applied_price_condition_id
    from jsonb_array_elements(p_lines) elem
  ),
  active_promos as (
    select * from public.promotions
    where active = true and valid_from <= p_sold_at and (valid_until is null or valid_until > p_sold_at)
  ),
  promo_products_agg as (
    select promotion_id, array_agg(product_id) as product_ids
    from public.promotion_products
    group by promotion_id
  ),
  matches as (
    select
      ap.id, ap.type, ap.price_condition_id, ap.discount_percent, ap.group_size, ap.priority, ap.stackable,
      ppa.product_ids,
      (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids))
        as total_eligible_qty,
      case
        when ap.type = 'THREE_FOR_TWO' then
          (select coalesce(sum(c.quantity), 0) from cart c where c.product_id = any (ppa.product_ids)) >= ap.group_size
          and (select coalesce(bool_and(c.quantity = floor(c.quantity)), false)
               from cart c where c.product_id = any (ppa.product_ids))
        when ap.type = 'DUO_PERCENT' then
          coalesce(array_length(ppa.product_ids, 1), 0) = 2
          and (select count(*) from cart c where c.product_id = any (ppa.product_ids)) = 2
        when ap.type = 'KIT_PERCENT' then
          exists (select 1 from cart c where c.product_id = any (ppa.product_ids))
        else false
      end as is_match
    from active_promos ap
    join promo_products_agg ppa on ppa.promotion_id = ap.id
  ),
  exclusive_winner as (
    select id from matches where is_match and stackable = false order by priority asc limit 1
  ),
  winners as (
    select m.* from matches m
    where m.is_match
      and (
        (exists (select 1 from exclusive_winner) and m.id = (select id from exclusive_winner))
        or (not exists (select 1 from exclusive_winner) and m.stackable = true)
      )
  ),
  promo_base_prices as (
    select
      w.id as promotion_id,
      c.product_id,
      (
        select pp.amount
        from public.product_prices pp
        where pp.product_id = c.product_id
          and pp.price_condition_id = w.price_condition_id
          and pp.active = true
          and pp.amount > 0
          and pp.valid_from <= p_sold_at
          and (pp.valid_until is null or pp.valid_until > p_sold_at)
        order by pp.valid_from desc
        limit 1
      ) as promo_unit_price
    from winners w
    join cart c on c.product_id = any (w.product_ids)
  ),
  t2_units as (
    select w.id as promotion_id, c.product_id, pbp.promo_unit_price, gs as unit_idx
    from winners w
    join cart c on c.product_id = any (w.product_ids)
    join promo_base_prices pbp on pbp.promotion_id = w.id and pbp.product_id = c.product_id
    cross join lateral generate_series(1, c.quantity::int) as gs
    where w.type = 'THREE_FOR_TWO'
  ),
  t2_ranked as (
    select
      *,
      row_number() over (partition by promotion_id order by promo_unit_price asc, product_id asc, unit_idx asc) as rn
    from t2_units
  ),
  t2_free_totals as (
    select id as promotion_id, floor(total_eligible_qty / group_size)::int as free_total
    from winners
    where type = 'THREE_FOR_TWO'
  ),
  t2_free_by_product as (
    select r.promotion_id, r.product_id, count(*) filter (where r.rn <= ft.free_total) as free_units
    from t2_ranked r
    join t2_free_totals ft on ft.promotion_id = r.promotion_id
    group by r.promotion_id, r.product_id
  ),
  duo_resolved as (
    select
      w.id as promotion_id,
      w.price_condition_id,
      w.discount_percent,
      w.product_ids[1] as product_a,
      w.product_ids[2] as product_b,
      least(
        (select quantity from cart where product_id = w.product_ids[1]),
        (select quantity from cart where product_id = w.product_ids[2])
      ) as duo_count
    from winners w
    where w.type = 'DUO_PERCENT'
  ),
  kit_resolved as (
    select w.id as promotion_id, w.price_condition_id, w.discount_percent, w.product_ids[1] as product_id
    from winners w
    where w.type = 'KIT_PERCENT'
  ),
  sub_lines as (
    -- 3x2: remanente pago — al precio base de la PROPIA promoción, nunca al
    -- del medio de pago (esas unidades siguen "alcanzadas" por la promo).
    select
      c.product_id, c.sku, c.name, (c.quantity - t2.free_units) as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * (c.quantity - t2.free_units), 2) as line_list_total,
      round((c.list_unit_price - pbp.promo_unit_price) * (c.quantity - t2.free_units), 2) as line_discount,
      round(pbp.promo_unit_price * (c.quantity - t2.free_units), 2) as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where (c.quantity - t2.free_units) > 0

    union all

    -- 3x2: unidades gratis — la más barata según el precio base de la promoción.
    select
      c.product_id, c.sku, c.name, t2.free_units as quantity,
      c.list_unit_price, 0::numeric as sale_unit_price,
      round(c.list_unit_price * t2.free_units, 2) as line_list_total,
      round(c.list_unit_price * t2.free_units, 2) as line_discount,
      0::numeric as line_total,
      c.commissionable, w.price_condition_id as applied_price_condition_id,
      t2.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * t2.free_units, 2) as promotion_discount
    from cart c
    join t2_free_by_product t2 on t2.product_id = c.product_id
    join winners w on w.id = t2.promotion_id
    join promo_base_prices pbp on pbp.promotion_id = t2.promotion_id and pbp.product_id = c.product_id
    where t2.free_units > 0

    union all

    -- duo: remanente (compró más del producto abundante de lo que "duos" se
    -- formaron) — igual criterio: precio base de la promoción, no el del pago.
    select
      c.product_id, c.sku, c.name, (c.quantity - d.duo_count) as quantity,
      c.list_unit_price, pbp.promo_unit_price as sale_unit_price,
      round(c.list_unit_price * (c.quantity - d.duo_count), 2) as line_list_total,
      round((c.list_unit_price - pbp.promo_unit_price) * (c.quantity - d.duo_count), 2) as line_discount,
      round(pbp.promo_unit_price * (c.quantity - d.duo_count), 2) as line_total,
      c.commissionable, d.price_condition_id as applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    join promo_base_prices pbp on pbp.promotion_id = d.promotion_id and pbp.product_id = c.product_id
    where (c.quantity - d.duo_count) > 0

    union all

    -- duo: unidades con descuento.
    select
      c.product_id, c.sku, c.name, d.duo_count as quantity,
      c.list_unit_price, round(pbp.promo_unit_price * (1 - d.discount_percent), 2) as sale_unit_price,
      round(c.list_unit_price * d.duo_count, 2) as line_list_total,
      round((c.list_unit_price - round(pbp.promo_unit_price * (1 - d.discount_percent), 2)) * d.duo_count, 2)
        as line_discount,
      round(round(pbp.promo_unit_price * (1 - d.discount_percent), 2) * d.duo_count, 2) as line_total,
      c.commissionable, d.price_condition_id as applied_price_condition_id,
      d.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * d.discount_percent * d.duo_count, 2) as promotion_discount
    from cart c
    join duo_resolved d on c.product_id in (d.product_a, d.product_b)
    join promo_base_prices pbp on pbp.promotion_id = d.promotion_id and pbp.product_id = c.product_id
    where d.duo_count > 0

    union all

    -- kit%: toda la cantidad, a precio reducido sobre la condición base de la promoción.
    select
      c.product_id, c.sku, c.name, c.quantity,
      c.list_unit_price, round(pbp.promo_unit_price * (1 - k.discount_percent), 2) as sale_unit_price,
      c.line_list_total,
      round((c.list_unit_price - round(pbp.promo_unit_price * (1 - k.discount_percent), 2)) * c.quantity, 2)
        as line_discount,
      round(round(pbp.promo_unit_price * (1 - k.discount_percent), 2) * c.quantity, 2) as line_total,
      c.commissionable, k.price_condition_id as applied_price_condition_id,
      k.promotion_id as applied_promotion_id,
      round(pbp.promo_unit_price * k.discount_percent * c.quantity, 2) as promotion_discount
    from cart c
    join kit_resolved k on k.product_id = c.product_id
    join promo_base_prices pbp on pbp.promotion_id = k.promotion_id and pbp.product_id = c.product_id

    union all

    -- sin promoción: pasa igual que venía de price_conditions (medio de pago/cantidad) — intacto.
    select
      c.product_id, c.sku, c.name, c.quantity, c.list_unit_price, c.sale_unit_price,
      c.line_list_total, c.line_discount, c.line_total, c.commissionable, c.applied_price_condition_id,
      null::uuid as applied_promotion_id, 0::numeric as promotion_discount
    from cart c
    where not exists (select 1 from t2_free_by_product t2 where t2.product_id = c.product_id)
      and not exists (select 1 from duo_resolved d where c.product_id in (d.product_a, d.product_b))
      and not exists (select 1 from kit_resolved k where k.product_id = c.product_id)
  )
  select jsonb_build_object(
    'lines', coalesce(jsonb_agg(jsonb_build_object(
      'product_id', product_id, 'sku', sku, 'name', name, 'quantity', quantity,
      'list_unit_price', list_unit_price, 'sale_unit_price', sale_unit_price,
      'line_list_total', line_list_total, 'line_discount', line_discount, 'line_total', line_total,
      'commissionable', commissionable, 'applied_price_condition_id', applied_price_condition_id,
      'applied_promotion_id', applied_promotion_id, 'promotion_discount', promotion_discount,
      'manual_price', false
    )), '[]'::jsonb),
    'promotion_discount_total', coalesce(sum(promotion_discount), 0)
  )
  into v_result
  from sub_lines;

  return v_result;
end;
$$;

comment on function public.fn_apply_promotions(jsonb, timestamptz) is
  'No acumulable con price_conditions: cada producto alcanzado por una promoción ganadora usa '
  'EXCLUSIVAMENTE el precio bajo promotions.price_condition_id (nunca el resuelto por medio de '
  'pago/cantidad). Rechaza la venta si falta ese precio en vez de mezclar reglas comerciales.';
