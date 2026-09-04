-- =============================================================================
-- Maguirejuve · 56 · Circuito Ventas Web — filtro central de métricas/comisión
-- por payment_status (cierre de BLOQUE B)
-- =============================================================================
-- Aprobado por el usuario (sección 10/32 del pedido original, precisado en la
-- ronda de BLOQUE B): un pedido Web PENDING de cobro NO debe sumar
-- facturación/revenue ni comisión — recién cuenta cuando payment_status='PAID'.
-- fulfillment (pendiente de retiro o ya entregado) NO cambia esta condición
-- económica — son ejes distintos, nunca se mezclan (regla ya establecida).
-- Un pedido cancelado/reembolsado ya queda afuera por status<>'confirmed',
-- sin cambios ahí.
--
-- Filtro único, centralizado, agregado literalmente igual en cada WHERE de
-- revenue/comisión de las 3 funciones aprobadas:
--   and (s.payment_status is null or s.payment_status = 'PAID')
-- payment_status es null para TODA venta no-Web (el 100% de las ventas hasta
-- hoy) — así que esta condición es un no-op exacto para ellas, cero cambio
-- de comportamiento. Solo empieza a filtrar algo el día que exista el primer
-- pedido Web con payment_status='PENDING'.
--
-- NO se toca critical_stock_count (alerta de stock físico, dimensión
-- distinta) ni customer_purchase_history (no estaba en el alcance aprobado:
-- historial de compras del cliente, no un reporte de facturación/comisión).
-- Mismas firmas exactas que 20260201000041 — CREATE OR REPLACE sin DROP.

create or replace function public.dashboard_report(
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

  return jsonb_build_object(
    'kpis', (
      select jsonb_build_object(
        'sales_count', count(*),
        'revenue', coalesce(sum(sn.net_total), 0),
        'avg_ticket', coalesce(round(avg(sn.net_total), 2), 0),
        'units_sold', coalesce(sum(sn.net_units), 0),
        'web_sales_count', coalesce(sum(case when sc.code = 'WEB' then 1 else 0 end), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join public.sales_channels sc on sc.id = s.sales_channel_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(net_quantity), 0) as net_units,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
        and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    ),
    'revenue_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (s.sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by 1
      ) t
    ),
    'sales_by_location', (
      select coalesce(jsonb_agg(jsonb_build_object('location', sl.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.location_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.location_id
      ) t
      join public.stock_locations sl on sl.id = t.location_id
    ),
    'sales_by_channel', (
      select coalesce(jsonb_agg(jsonb_build_object('channel', sc.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.sales_channel_id, sum(sn.net_total) as revenue, count(*) as cnt
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.sales_channel_id
      ) t
      join public.sales_channels sc on sc.id = t.sales_channel_id
    ),
    'revenue_by_payment_method', (
      select coalesce(jsonb_agg(jsonb_build_object('payment_method', pm.name, 'revenue', t.revenue)), '[]'::jsonb)
      from (
        select s.payment_method_id, sum(sn.net_total) as revenue
        from public.sales s
        join lateral (
          select coalesce(sum(net_line_total), 0) as net_total
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.payment_method_id
      ) t
      join public.payment_methods pm on pm.id = t.payment_method_id
    ),
    'top_products_by_units', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'units', t.units) order by t.units desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
        order by units desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'top_products_by_revenue', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'revenue', t.revenue) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by sin.product_id
        having sum(sin.net_line_total) > 0
        order by revenue desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'commission_by_doctor', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'doctor_id', d.id, 'doctor', d.full_name, 'sales_count', t.cnt,
        'commissionable_revenue', t.commissionable_revenue, 'commission', t.commission
      ) order by t.commission desc), '[]'::jsonb)
      from (
        select s.doctor_id, count(*) as cnt,
          sum(sn.net_commissionable) as commissionable_revenue,
          sum(case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end) as commission
        from public.sales s
        join lateral (
          select
            coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
            coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
          from public.sale_item_net sin where sin.sale_id = s.id
        ) sn on true
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and s.doctor_id is not null
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by s.doctor_id
      ) t
      join public.doctors d on d.id = t.doctor_id
    ),
    'critical_stock_count', (
      select count(*) from public.product_stock_status pss
      where pss.status in ('bajo', 'sin_stock')
        and pss.product_active = true
        and public.has_location_access(pss.location_id)
        and (p_location_id is null or pss.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.dashboard_report(date, date, uuid, uuid) is
  'Único punto de agregación para /dashboard. Requiere admin o can_view_financial_reports. '
  'Toda la agregación ocurre en SQL: el cliente nunca pagina/filtra ventas crudas. '
  'critical_stock_count excluye productos inactivos — no son una alerta operativa real. '
  'Revenue/unidades/top productos/comisión son SIEMPRE netos de devoluciones (sale_item_net) — '
  'status=confirmed solo no alcanza porque una devolución parcial no cambia el status. BUGFIX 56: '
  'además excluyen un pedido Web con payment_status=PENDING (no cobrado todavía) — fulfillment '
  '(pendiente/entregado) no cambia esta condición económica, son ejes distintos.';

-- ---------------------------------------------------------------------------
-- 2) product_revenue_report
-- ---------------------------------------------------------------------------
create or replace function public.product_revenue_report(
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

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', p.id, 'sku', p.sku, 'name', p.name, 'product_type', p.product_type,
    'units', t.units, 'revenue', t.revenue, 'discount_total', t.discount_total
  ) order by t.revenue desc), '[]'::jsonb)
  into v_rows
  from (
    select sin.product_id, sum(sin.net_quantity) as units, sum(sin.net_line_total) as revenue,
      sum(si.line_discount) as discount_total
    from public.sale_item_net sin
    join public.sale_items si on si.id = sin.sale_item_id
    join public.sales s on s.id = sin.sale_id
    where s.status = 'confirmed' and s.sold_at between v_from and v_to
      and (s.payment_status is null or s.payment_status = 'PAID')
      and public.has_location_access(s.location_id)
      and (p_location_id is null or s.location_id = p_location_id)
      and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    group by sin.product_id
  ) t
  join public.products p on p.id = t.product_id;

  return jsonb_build_object('rows', v_rows);
end;
$$;

comment on function public.product_revenue_report(date, date, uuid, uuid) is
  'Facturación completa por producto/kit (sin LIMIT, para /dashboard/productos). '
  'Un kit atribuye su facturación a sí mismo — nunca se reparte entre kit_components. '
  'units/revenue son netos de devoluciones (sale_item_net); discount_total queda bruto. '
  'BUGFIX 56: excluye pedidos Web con payment_status=PENDING.';

-- ---------------------------------------------------------------------------
-- 3) doctor_sales_detail
-- ---------------------------------------------------------------------------
create or replace function public.doctor_sales_detail(
  p_doctor_id uuid,
  p_from date,
  p_to date,
  p_location_id uuid default null
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
  v_doctor public.doctors;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver este reporte.';
  end if;
  if not (v_profile.role = 'admin' or v_profile.can_view_financial_reports) then
    raise exception 'Tu usuario no tiene permiso para ver reportes financieros.';
  end if;

  select * into v_doctor from public.doctors where id = p_doctor_id;
  if v_doctor is null then
    raise exception 'La doctora no existe.';
  end if;

  v_from := (p_from::text || ' 00:00:00-03')::timestamptz;
  v_to := (p_to::text || ' 23:59:59-03')::timestamptz;

  return jsonb_build_object(
    'doctor', jsonb_build_object('id', v_doctor.id, 'full_name', v_doctor.full_name, 'code', v_doctor.code),
    'summary', (
      select jsonb_build_object(
        'sales_count', count(*),
        'commissionable_revenue', coalesce(sum(sn.net_commissionable), 0),
        'commission_total', coalesce(sum(
          case when sn.gross_commissionable > 0
            then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
            else 0 end
        ), 0)
      )
      from public.sales s
      join lateral (
        select
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    ),
    'products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product_id', p.id, 'name', p.name, 'units', t.units, 'revenue', t.revenue
      ) order by t.revenue desc), '[]'::jsonb)
      from (
        select sin.product_id, sum(sin.net_quantity) as units, sum(sin.net_line_total) as revenue
        from public.sale_item_net sin
        join public.sales s on s.id = sin.sale_id
        where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
          and (s.payment_status is null or s.payment_status = 'PAID')
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
        group by sin.product_id
        having sum(sin.net_quantity) > 0
      ) t
      join public.products p on p.id = t.product_id
    ),
    'sales', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'sale_number', s.sale_number, 'sold_at', s.sold_at,
        'total', sn.net_total,
        'commission_total', case when sn.gross_commissionable > 0
          then round(s.commission_total * sn.net_commissionable / sn.gross_commissionable, 2)
          else 0 end,
        'location', sl.name
      ) order by s.sold_at desc), '[]'::jsonb)
      from public.sales s
      join public.stock_locations sl on sl.id = s.location_id
      join lateral (
        select
          coalesce(sum(net_line_total), 0) as net_total,
          coalesce(sum(case when commissionable then gross_line_total else 0 end), 0) as gross_commissionable,
          coalesce(sum(case when commissionable then net_line_total else 0 end), 0) as net_commissionable
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.doctor_sales_detail(uuid, date, date, uuid) is
  'Drill-down de Ventas por médica: resumen + productos vendidos + listado de '
  'operaciones, todos netos de devoluciones (sale_item_net). sales.commission_total '
  'nunca se reescribe — se reaplica su tasa efectiva original sobre la base comisionable neta. '
  'BUGFIX 56: excluye pedidos Web con payment_status=PENDING de las 3 secciones (summary/products/sales).';
