-- =============================================================================
-- Maguirejuve · 47 · Analytics de productos, kits y promociones — Bloque C
-- (paso 4/5): rendimiento histórico de promociones
-- =============================================================================
-- Ambas funciones leen EXCLUSIVAMENTE de lo que ya se aplicó (sale_item_net +
-- sale_items.applied_promotion_id/promotion_discount + el snapshot de la
-- migración 48) — nunca se recalcula elegibilidad ni importes con reglas
-- actuales. Identidad de cada promoción: se usa el snapshot MÁS RECIENTE
-- entre las líneas que la usaron en el rango consultado (name/type/%/vigencia
-- "tal como eran" en esa venta); si NINGUNA línea del rango tiene snapshot
-- (venta legado, anterior a la migración 48), cae a promotions vigente —
-- fallback explícitamente marcado como tal en 'identity_source', nunca se
-- inventa un valor histórico que no existe.
--
-- sales_count = operaciones DISTINTAS (distinct sale_id), nunca líneas —
-- una venta con 2 productos de la misma promoción cuenta 1 vez. units_sold =
-- suma de net_quantity de las líneas con esa promoción (un kit con promoción
-- cuenta como 1 unidad promocional por kit vendido, nunca explotado a
-- componentes — mismo criterio que Bloque B). revenue = suma de
-- net_line_total SOLO de las líneas con esa promoción, nunca del carrito
-- completo. average_ticket = revenue / sales_count (nunca revenue / units).
-- Todo neto de devoluciones (sale_item_net) y con 'replaced' excluido de
-- raíz (status = 'confirmed' únicamente, igual que el resto de los reportes).

-- ---------------------------------------------------------------------------
-- 1) promotion_performance_report — una fila por promoción con actividad
--    neta > 0 en el rango. No pagina/agrega en el cliente: una sola llamada
--    trae todo lo necesario para el ranking multi-criterio (revenue/sales/
--    units/avg-ticket — el cliente reordena el mismo array, no hace falta
--    una query por criterio) y para las KPI del módulo.
-- ---------------------------------------------------------------------------
create or replace function public.promotion_performance_report(
  p_from date,
  p_to date
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

  with promo_lines as (
    select
      sin.applied_promotion_id as promotion_id,
      sin.sale_id,
      sin.net_quantity,
      sin.net_line_total,
      si.promotion_name_snapshot,
      si.promotion_type_snapshot,
      si.promotion_discount_percent_snapshot,
      si.promotion_started_at_snapshot,
      si.promotion_ended_at_snapshot,
      s.sold_at
    from public.sale_item_net sin
    join public.sale_items si on si.id = sin.sale_item_id
    join public.sales s on s.id = sin.sale_id
    where sin.applied_promotion_id is not null
      and sin.net_quantity > 0
      and s.status = 'confirmed'
      and s.sold_at between v_from and v_to
      and public.has_location_access(s.location_id)
  ),
  agg as (
    select
      promotion_id,
      count(distinct sale_id) as sales_count,
      sum(net_quantity) as units_sold,
      sum(net_line_total) as revenue
    from promo_lines
    group by promotion_id
  ),
  identity as (
    select distinct on (promotion_id)
      promotion_id, promotion_name_snapshot, promotion_type_snapshot,
      promotion_discount_percent_snapshot, promotion_started_at_snapshot, promotion_ended_at_snapshot
    from promo_lines
    where promotion_name_snapshot is not null
    order by promotion_id, sold_at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'promotion_id', a.promotion_id,
    'code', p.code,
    'name', coalesce(i.promotion_name_snapshot, p.name),
    'type', coalesce(i.promotion_type_snapshot, p.type),
    'discount_percent', coalesce(i.promotion_discount_percent_snapshot, p.discount_percent),
    'valid_from_snapshot', i.promotion_started_at_snapshot,
    'valid_until_snapshot', i.promotion_ended_at_snapshot,
    'identity_source', case when i.promotion_name_snapshot is not null then 'snapshot' else 'legacy_live' end,
    'is_active', p.active,
    'sales_count', a.sales_count,
    'units_sold', a.units_sold,
    'revenue', a.revenue,
    'average_ticket', round(a.revenue / a.sales_count, 2)
  ) order by a.revenue desc), '[]'::jsonb)
  into v_rows
  from agg a
  join public.promotions p on p.id = a.promotion_id
  left join identity i on i.promotion_id = a.promotion_id;

  return jsonb_build_object('from', p_from, 'to', p_to, 'rows', v_rows);
end;
$$;

comment on function public.promotion_performance_report(date, date) is
  'Rendimiento histórico de TODAS las promociones (activas, finalizadas o desactivadas — nunca '
  'se filtra por promotions.active, la performance queda consultable para siempre). Una fila por '
  'promoción con actividad neta > 0 en el rango. sales_count = operaciones distintas, units_sold '
  '= unidades comerciales (kit sin explotar), revenue = solo líneas con esa promoción, '
  'average_ticket = revenue/sales_count. Todo vía sale_item_net (neto de devoluciones) y '
  'status=confirmed (replaced excluido de raíz). Identidad: snapshot histórico más reciente del '
  'rango, o promotions vigente si la venta es legado (identity_source lo indica).';

-- ---------------------------------------------------------------------------
-- 2) promotion_performance_detail — drill-down de una promoción puntual:
--    metadata + métricas (mismo cálculo que el reporte general, filtrado a
--    una sola promoción) + ranking de productos/kits dentro de ella +
--    evolución diaria opcional (para un gráfico de línea/barras en el
--    detalle, mismo patrón que dashboard_report.revenue_by_day).
-- ---------------------------------------------------------------------------
create or replace function public.promotion_performance_detail(
  p_promotion_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_promotion public.promotions;
  v_from timestamptz;
  v_to timestamptz;
  v_metrics jsonb;
  v_top_products jsonb;
  v_daily jsonb;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  select * into v_promotion from public.promotions where id = p_promotion_id;
  if v_promotion is null then
    raise exception 'La promoción no existe.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  -- Las 3 lecturas (métricas, top de productos, evolución diaria) comparten
  -- la MISMA definición de "línea de esta promoción en el rango" — se arma
  -- una sola vez acá y se referencia 3 veces DENTRO de esta única sentencia
  -- (un CTE solo vive dentro de la sentencia que lo define; por eso todo
  -- tiene que resolverse en un solo select, no en 3 select...into separados).
  with promo_lines as (
    select
      sin.sale_id,
      sin.product_id,
      sin.net_quantity,
      sin.net_line_total,
      s.sold_at
    from public.sale_item_net sin
    join public.sales s on s.id = sin.sale_id
    where sin.applied_promotion_id = p_promotion_id
      and sin.net_quantity > 0
      and s.status = 'confirmed'
      and s.sold_at between v_from and v_to
      and public.has_location_access(s.location_id)
  )
  select
    jsonb_build_object(
      'sales_count', coalesce(count(distinct pl.sale_id), 0),
      'units_sold', coalesce(sum(pl.net_quantity), 0),
      'revenue', coalesce(sum(pl.net_line_total), 0),
      'average_ticket', case when count(distinct pl.sale_id) > 0
        then round(sum(pl.net_line_total) / count(distinct pl.sale_id), 2) else 0 end
    ),
    (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_id', t.product_id, 'sku', p.sku, 'name', p.name, 'product_type', p.product_type,
        'units', t.units, 'revenue', t.revenue
      ) order by t.revenue desc), '[]'::jsonb)
      from (
        select product_id, sum(net_quantity) as units, sum(net_line_total) as revenue
        from promo_lines
        group by product_id
      ) t
      join public.products p on p.id = t.product_id
    ),
    (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(net_line_total) as revenue
        from promo_lines
        group by 1
      ) t
    )
  into v_metrics, v_top_products, v_daily
  from promo_lines pl;

  return jsonb_build_object(
    'promotion', jsonb_build_object(
      'id', v_promotion.id, 'code', v_promotion.code, 'name', v_promotion.name,
      'type', v_promotion.type, 'discount_percent', v_promotion.discount_percent,
      'group_size', v_promotion.group_size, 'minimum_quantity', v_promotion.minimum_quantity,
      'active', v_promotion.active, 'valid_from', v_promotion.valid_from, 'valid_until', v_promotion.valid_until,
      'priority', v_promotion.priority, 'stackable', v_promotion.stackable
    ),
    'metrics', v_metrics,
    'top_products', v_top_products,
    'daily_evolution', v_daily
  );
end;
$$;

comment on function public.promotion_performance_detail(uuid, date, date) is
  'Drill-down de UNA promoción: metadata vigente (para mostrar de qué se trata hoy) + métricas '
  'del rango (mismo cálculo que promotion_performance_report) + ranking de productos/kits dentro '
  'de ella + evolución diaria de facturación. Misma semántica neta/histórica que el reporte '
  'general — nunca recalcula elegibilidad ni importes.';

grant execute on function public.promotion_performance_report(date, date) to authenticated;
grant execute on function public.promotion_performance_detail(uuid, date, date) to authenticated;
