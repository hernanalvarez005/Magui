-- =============================================================================
-- Maguirejuve · 15 · Reportes agregados (dashboard admin + comisiones por doctora)
-- =============================================================================
-- Toda la agregación ocurre en el servidor (nunca se trae la tabla completa de
-- ventas al navegador para filtrarla ahí). Gateado por permiso financiero.

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
        'revenue', coalesce(sum(s.total), 0),
        'avg_ticket', coalesce(round(avg(s.total), 2), 0),
        'units_sold', coalesce((
          select sum(si.quantity) from public.sale_items si
          join public.sales s2 on s2.id = si.sale_id
          where s2.status = 'confirmed' and s2.sold_at between v_from and v_to
            and public.has_location_access(s2.location_id)
            and (p_location_id is null or s2.location_id = p_location_id)
            and (p_sales_channel_id is null or s2.sales_channel_id = p_sales_channel_id)
        ), 0),
        'web_sales_count', coalesce(sum(case when sc.code = 'WEB' then 1 else 0 end), 0),
        'commission_total', coalesce(sum(s.commission_total), 0)
      )
      from public.sales s
      join public.sales_channels sc on sc.id = s.sales_channel_id
      where s.status = 'confirmed' and s.sold_at between v_from and v_to
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
        and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
    ),
    'revenue_by_day', (
      select coalesce(jsonb_agg(jsonb_build_object('day', day, 'revenue', revenue) order by day), '[]'::jsonb)
      from (
        select (s.sold_at at time zone 'America/Argentina/Buenos_Aires')::date as day, sum(s.total) as revenue
        from public.sales s
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by 1
      ) t
    ),
    'sales_by_location', (
      select coalesce(jsonb_agg(jsonb_build_object('location', sl.name, 'revenue', t.revenue, 'count', t.cnt)), '[]'::jsonb)
      from (
        select s.location_id, sum(s.total) as revenue, count(*) as cnt
        from public.sales s
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
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
        select s.sales_channel_id, sum(s.total) as revenue, count(*) as cnt
        from public.sales s
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
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
        select s.payment_method_id, sum(s.total) as revenue
        from public.sales s
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
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
        select si.product_id, sum(si.quantity) as units
        from public.sale_items si
        join public.sales s on s.id = si.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by si.product_id
        order by units desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'top_products_by_revenue', (
      select coalesce(jsonb_agg(jsonb_build_object('product', p.name, 'revenue', t.revenue) order by t.revenue desc), '[]'::jsonb)
      from (
        select si.product_id, sum(si.line_total) as revenue
        from public.sale_items si
        join public.sales s on s.id = si.sale_id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and public.has_location_access(s.location_id)
          and (p_location_id is null or s.location_id = p_location_id)
          and (p_sales_channel_id is null or s.sales_channel_id = p_sales_channel_id)
        group by si.product_id
        order by revenue desc
        limit 8
      ) t
      join public.products p on p.id = t.product_id
    ),
    'commission_by_doctor', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'doctor', d.full_name, 'sales_count', t.cnt, 'commissionable_revenue', t.commissionable_revenue,
        'commission', t.commission
      ) order by t.commission desc), '[]'::jsonb)
      from (
        select s.doctor_id, count(*) as cnt,
          sum(case when si.commissionable then si.line_total else 0 end) as commissionable_revenue,
          sum(s.commission_total) as commission
        from public.sales s
        join public.sale_items si on si.sale_id = s.id
        where s.status = 'confirmed' and s.sold_at between v_from and v_to
          and s.doctor_id is not null
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
        and public.has_location_access(pss.location_id)
        and (p_location_id is null or pss.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.dashboard_report(date, date, uuid, uuid) is
  'Único punto de agregación para /dashboard. Requiere admin o can_view_financial_reports. '
  'Toda la agregación ocurre en SQL: el cliente nunca pagina/filtra ventas crudas.';

grant execute on function public.dashboard_report(date, date, uuid, uuid) to authenticated;
