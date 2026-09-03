-- =============================================================================
-- Maguirejuve · 47 · Analytics de productos, kits y promociones — Bloques A/B
-- (paso 3/5): dashboard_products_breakdown
-- =============================================================================
-- Bloque A — donut de productos vendidos INDIVIDUALMENTE (unidades físicas):
-- un kit se descompone en sus componentes REALES de ESE momento, nunca según
-- kit_components vigente. La fuente es directamente stock_movements: desde
-- siempre (bien antes de esta migración — ver fn_create_sale_core, el fan-out
-- kit -> componentes ya existía en el bloque de kits, muchísimo antes de
-- source_sale_item_id), cada movimiento SALE de un kit se graba YA descompuesto
-- por producto físico — stock_movements.product_id nunca es el kit, es cada
-- componente. source_sale_item_id (migración 42, Cambios) solo agrega "qué
-- LÍNEA comercial causó este movimiento" para poder revertir proporcionalmente
-- una devolución/cambio — no aporta nada a la pregunta "qué producto es
-- este movimiento", que stock_movements.product_id ya contesta con precisión
-- histórica exacta desde el primer día. Por eso NO hace falta excluir ni
-- avisar de ningún rango como "no trazable": sumando SALE (negativo) + RETURN
-- (positivo) por producto se obtiene el neto físico real, sea cual sea la
-- fecha, incluidos cambios/devoluciones de kits vendidos antes de la
-- migración 42.
--
-- 'replaced' nunca duplica ni pierde unidades: una venta reemplazada por un
-- Cambio no genera un movimiento SALE nuevo para las líneas 'copy'/'remainder'
-- (el producto físico no volvió a salir) — el único movimiento SALE nuevo es
-- el del producto efectivamente nuevo que se llevó, en la venta de reemplazo.
-- 'cancelled' se excluye explícitamente porque su reversión usa
-- movement_type = 'SALE_CANCEL' (no 'RETURN'), así que sin este filtro el
-- SALE original de una venta anulada seguiría contando.
--
-- Bloque B — kits más vendidos: a diferencia de A, es COMERCIAL, no físico:
-- se lee de sale_item_net (cantidad de kits vendidos como unidad comercial,
-- nunca explotados a componentes), ya neto de devoluciones/cambios (mismo
-- mecanismo que el resto de los reportes, Bloque D de Devolución).
create or replace function public.dashboard_products_breakdown(
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
  v_individual jsonb;
  v_others_units numeric;
  v_kits jsonb;
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

  -- -----------------------------------------------------------------------
  -- Bloque A: top 6 + "Otros", por unidades físicas netas.
  -- -----------------------------------------------------------------------
  with movements as (
    select sm.product_id, sm.quantity_delta
    from public.stock_movements sm
    join public.sales s on s.id = sm.sale_id
    where sm.movement_type in ('SALE', 'RETURN')
      and s.status <> 'cancelled'
      and s.sold_at between v_from and v_to
      and public.has_location_access(s.location_id)
      and (p_location_id is null or s.location_id = p_location_id)
      and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
  ),
  agg as (
    select product_id, sum(-quantity_delta) as units
    from movements
    group by product_id
    having sum(-quantity_delta) > 0
  ),
  ranked as (
    select a.product_id, p.name, a.units, row_number() over (order by a.units desc, p.name asc) as rn
    from agg a
    join public.products p on p.id = a.product_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'name', name, 'units', units) order by units desc)
      filter (where rn <= 6), '[]'::jsonb),
    coalesce(sum(units) filter (where rn > 6), 0)
  into v_individual, v_others_units
  from ranked;

  -- -----------------------------------------------------------------------
  -- Bloque B: top 10 kits más vendidos, por unidades comerciales netas.
  -- -----------------------------------------------------------------------
  with kit_sales as (
    select sin.product_id, sum(sin.net_quantity) as units
    from public.sale_item_net sin
    join public.sales s on s.id = sin.sale_id
    join public.products p on p.id = sin.product_id and p.product_type = 'kit'
    where s.status = 'confirmed'
      and s.sold_at between v_from and v_to
      and public.has_location_access(s.location_id)
      and (p_location_id is null or s.location_id = p_location_id)
      and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    group by sin.product_id
    having sum(sin.net_quantity) > 0
    order by sum(sin.net_quantity) desc
    limit 10
  )
  select coalesce(jsonb_agg(jsonb_build_object('product_id', ks.product_id, 'name', p.name, 'units', ks.units) order by ks.units desc), '[]'::jsonb)
  into v_kits
  from kit_sales ks
  join public.products p on p.id = ks.product_id;

  return jsonb_build_object(
    'individual_products', jsonb_build_object('top', v_individual, 'others_units', v_others_units),
    'top_kits', v_kits
  );
end;
$$;

comment on function public.dashboard_products_breakdown(date, date, uuid, uuid) is
  'Bloque A: unidades físicas netas por producto individual (kits SIEMPRE descompuestos a su '
  'composición histórica real vía stock_movements.product_id — nunca kit_components vigente), '
  'top 6 + "Otros". Bloque B: top 10 kits más vendidos como unidad comercial (sale_item_net, '
  'nunca explotados a componentes). Mismo filtro de fecha/sede/canal y mismo gate de permiso '
  '(admin o can_view_financial_reports) que dashboard_report.';

grant execute on function public.dashboard_products_breakdown(date, date, uuid, uuid) to authenticated;
