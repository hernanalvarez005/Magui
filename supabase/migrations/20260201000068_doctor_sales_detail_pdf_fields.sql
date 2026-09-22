-- =============================================================================
-- Maguirejuve · 68 · doctor_sales_detail: campos aditivos para la liquidación
-- de comisiones en PDF (Comisiones por Dra. → Exportar PDF)
-- =============================================================================
-- Auditoría previa (aprobada por el usuario): el PDF NO debe implementar un
-- segundo motor de cálculo — debe consumir exactamente la misma fuente de
-- verdad que ya alimenta /dashboard/comisiones/[doctorId]. Esta migración
-- extiende doctor_sales_detail de forma puramente ADITIVA: cada elemento de
-- `sales[]` gana tres campos nuevos; `doctor`, `summary` y el `products` de
-- período (agregado, sin cambios) quedan idénticos a la versión vigente
-- (20260201000056). No se toca commission_total ni su cálculo en ningún lado.
--
-- Campos nuevos por venta:
--   commissionable_revenue     -- neto de devoluciones, base sobre la que se
--                                  calculó la comisión de ESA venta (sn.net_commissionable,
--                                  ya se calculaba internamente — ahora se expone).
--   effective_commission_percent -- % HISTÓRICO efectivo de esa venta, derivado
--                                  de datos ya persistidos e inmutables:
--                                  s.commission_total / sn.gross_commissionable.
--                                  gross_commissionable son sale_items.line_total
--                                  originales (nunca cambian con devoluciones
--                                  posteriores) y s.commission_total es el monto
--                                  fijado al crear la venta (con el
--                                  commission_percent de la doctora EN ESE
--                                  MOMENTO) — por lo tanto este porcentaje NO
--                                  se recalcula con doctors.commission_percent
--                                  actual, y no cambia si ese % cambia después
--                                  ni si la venta sufre una devolución parcial
--                                  (ver test dedicado).
--   products                   -- SOLO productos commissionable=true de ESA
--                                  venta (no el agregado de período), splits
--                                  internos de promociones (ej. THREE_FOR_TWO:
--                                  misma línea de producto partida en "pagas"
--                                  + "gratis") consolidados por nombre —
--                                  mismo criterio que groupProductsBySale()
--                                  de lib/xlsx-ventas.ts, expresado en SQL.
--                                  Kits nunca se explotan (ya son su propio
--                                  product_id, sin cambios).
--
-- Nada de esto se usa todavía en la pantalla existente (el frontend de
-- /dashboard/comisiones/[doctorId] sigue leyendo únicamente los campos que ya
-- leía) — son campos nuevos, aditivos, consumidos recién por el endpoint del
-- PDF que se agrega en este mismo bloque.
-- =============================================================================

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
        'location', sl.name,
        -- Migración 68: campos aditivos para el PDF — ver cabecera del archivo.
        'commissionable_revenue', sn.net_commissionable,
        'effective_commission_percent', case when sn.gross_commissionable > 0
          then round(s.commission_total / sn.gross_commissionable * 100, 2)
          else 0 end,
        'products', coalesce(sp.products, '[]'::jsonb)
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
      left join lateral (
        select jsonb_agg(jsonb_build_object('name', p.name, 'quantity', t.quantity) order by p.name) as products
        from (
          select sin.product_id, sum(sin.net_quantity) as quantity
          from public.sale_item_net sin
          where sin.sale_id = s.id and sin.commissionable = true
          group by sin.product_id
          having sum(sin.net_quantity) > 0
        ) t
        join public.products p on p.id = t.product_id
      ) sp on true
      where s.status = 'confirmed' and s.doctor_id = p_doctor_id and s.sold_at between v_from and v_to
        and (s.payment_status is null or s.payment_status = 'PAID')
        and public.has_location_access(s.location_id)
        and (p_location_id is null or s.location_id = p_location_id)
    )
  );
end;
$$;

comment on function public.doctor_sales_detail(uuid, date, date, uuid) is
  'Drill-down de Ventas por médica: resumen + productos vendidos (período) + listado de '
  'operaciones, todos netos de devoluciones (sale_item_net). sales.commission_total '
  'nunca se reescribe — se reaplica su tasa efectiva original sobre la base comisionable neta. '
  'Migración 68: cada venta de sales[] suma commissionable_revenue (base neta de ESA venta), '
  'effective_commission_percent (tasa histórica efectiva = commission_total / gross_commissionable, '
  'invariante ante devoluciones posteriores y ante cambios futuros de doctors.commission_percent — '
  'nunca se recalcula con el % actual) y products (solo productos commissionable=true de ESA venta, '
  'splits de promoción tipo THREE_FOR_TWO consolidados por nombre, kits nunca explotados). Campos '
  'aditivos para Comisiones por Dra. → Exportar PDF — doctor/summary/products de período sin cambios.';
