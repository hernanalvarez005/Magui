-- =============================================================================
-- Maguirejuve · 45 · Devolución de producto — Bloque D: reportes netos
-- =============================================================================
-- Secciones 20-26 del pedido (cerradas en el PASO 0): revenue, unidades
-- vendidas, top productos, kits, promociones y comisión de doctora tienen
-- que ser SIEMPRE netos de devoluciones — nunca alcanza con filtrar
-- status='confirmed', porque una venta con una devolución PARCIAL sigue
-- 'confirmed' (regla crítica, sección 19) mostrando su bruto original si no
-- se ajusta explícitamente. sale_item_net (Bloque B) es el único punto de
-- cálculo de "bruto menos devuelto" — estas 4 funciones pasan a leer de ahí
-- en vez de sale_items/sales.total crudos. Mismas firmas, mismos permisos,
-- mismo has_location_access: CREATE OR REPLACE sin necesidad de DROP.
--
-- Comisión neta (precisión #5 del usuario + audit answer #5): nunca se
-- relee/recalcula con doctors.commission_percent VIGENTE (ese sigue siendo
-- solo el % de hoy, puede haber cambiado desde la venta) — se preserva la
-- TASA EFECTIVA con la que ya se calculó sales.commission_total (columna
-- histórica, nunca reescrita) y se la vuelve a aplicar sobre la base
-- comisionable neta:
--   tasa_efectiva   = commission_total / gross_commissionable   (de ESA venta)
--   commission_neta = round(net_commissionable * tasa_efectiva, 2)
-- Si gross_commissionable = 0 (venta sin líneas comisionables, o doctora sin
-- % > 0), commission_neta = 0 directo, sin dividir por cero.

-- ---------------------------------------------------------------------------
-- 1) dashboard_report — de paso corrige un bug preexistente y no relacionado
--    en commission_by_doctor: el join contra sale_items (fan-out por línea)
--    hacía sum(s.commission_total) una vez POR ÍTEM, multiplicando la
--    comisión real de cualquier venta con más de una línea. El join lateral
--    por venta (necesario para el cálculo neto) lo resuelve de paso: ahora
--    cuenta una fila por venta, no por línea.
-- ---------------------------------------------------------------------------
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
  'status=confirmed solo no alcanza porque una devolución parcial no cambia el status.';

-- ---------------------------------------------------------------------------
-- 2) product_revenue_report — units/revenue netos; discount_total se deja
--    tal cual (bruto, informativo — fuera del alcance explícito del pedido,
--    que pide netos de revenue/unidades/comisión, no de descuento otorgado).
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
    -- join 1:1 de vuelta a sale_items (sale_item_net tiene exactamente una
    -- fila por sale_items.id) para poder sumar line_discount sin duplicar
    -- lógica: units/revenue vienen del neto, discount_total del bruto.
    select sin.product_id, sum(sin.net_quantity) as units, sum(sin.net_line_total) as revenue,
      sum(si.line_discount) as discount_total
    from public.sale_item_net sin
    join public.sale_items si on si.id = sin.sale_item_id
    join public.sales s on s.id = sin.sale_id
    where s.status = 'confirmed' and s.sold_at between v_from and v_to
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
  'units/revenue son netos de devoluciones (sale_item_net); discount_total queda bruto.';

-- ---------------------------------------------------------------------------
-- 3) doctor_sales_detail — resumen, productos y listado de operaciones,
--    todos netos de devoluciones. sales.commission_total (columna
--    persistida) sigue sin reescribirse nunca — se preserva su tasa
--    efectiva y se reaplica sobre la base comisionable neta (ver comentario
--    arriba de este archivo).
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
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.doctor_sales_detail(uuid, date, date, uuid) is
  'Drill-down de Ventas por médica: resumen + productos vendidos + listado de '
  'operaciones, todos netos de devoluciones (sale_item_net). sales.commission_total '
  'nunca se reescribe — se reaplica su tasa efectiva original sobre la base comisionable neta.';

-- ---------------------------------------------------------------------------
-- 4) customer_purchase_history — cantidades/importes por línea y total de la
--    venta netos de devoluciones. No filtra líneas con net_quantity=0 (un
--    producto devuelto en su totalidad sigue siendo parte de la historia de
--    lo que el cliente compró; queda en 0, no desaparece).
-- ---------------------------------------------------------------------------
create or replace function public.customer_purchase_history(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver esta información.';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'El cliente no existe.';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'sale_id', s.id,
          'sale_number', s.sale_number,
          'sold_at', s.sold_at,
          'location_name', l.name,
          'seller_name', p.full_name,
          'total', sn.net_total,
          'is_free_sale', s.is_free_sale,
          'stock_skipped', s.stock_skipped,
          'items', t.items
        )
        order by s.sold_at desc
      )
      from public.sales s
      join public.stock_locations l on l.id = s.location_id
      left join public.profiles p on p.id = s.seller_id
      join lateral (
        select coalesce(sum(net_line_total), 0) as net_total
        from public.sale_item_net sin where sin.sale_id = s.id
      ) sn on true
      join lateral (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'product_id', sin.product_id,
              'name', pr.name,
              'sku', pr.sku,
              'quantity', sin.net_quantity,
              'line_total', sin.net_line_total
            )
            order by pr.name
          ),
          '[]'::jsonb
        ) as items
        from public.sale_item_net sin
        join public.products pr on pr.id = sin.product_id
        where sin.sale_id = s.id
      ) t on true
      where s.customer_id = p_customer_id
        and s.status = 'confirmed'
        and public.has_location_access(s.location_id)
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.customer_purchase_history is
  'Historial de compras de un cliente (fecha, sede, vendedora, productos) — '
  'a diferencia de sales_select (RLS), no se recorta por seller_id: cualquier '
  'usuario activo con acceso a la sede ve la historia completa del cliente, '
  'porque el alcance acá es el cliente, no "mis propias ventas". Solo ventas '
  'confirmadas. Cantidades/importes netos de devoluciones (sale_item_net).';
