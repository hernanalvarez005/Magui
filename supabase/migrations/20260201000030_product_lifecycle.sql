-- =============================================================================
-- Maguirejuve · Administración de productos: activar, desactivar y eliminar
-- =============================================================================
-- PASO 0 (auditoría, resumen — ver informe completo entregado al usuario):
--   - products.active YA existe (desde el schema original) y YA es lo que
--     filtran Nueva Venta, /precios y el selector de productos al crear
--     promociones (todas con .eq("active", true)) — el "modo comercial" de
--     un producto inactivo ya estaba resuelto por esas 3 pantallas. Nada de
--     esto se toca.
--   - Un producto inactivo NUNCA puede entrar al carrito de una venta nueva
--     (el picker de Nueva Venta ya filtra active=true) — así que
--     fn_apply_promotions nunca puede matchearlo en una venta nueva, aunque
--     promotion_products lo siga listando como participante histórico. La
--     preferencia del pedido ("conservar la relación histórica, no
--     aplicarla a ventas nuevas") ya está garantizada por esa única regla,
--     sin tocar el motor de promociones.
--   - El único gap real de "alertas" (sección 17 del pedido):
--     product_stock_status (vista) no filtraba por products.active — un
--     producto inactivo con stock bajo/sin stock seguía apareciendo en
--     Home y en las alertas de /stock y dashboard_report. Se agrega una
--     columna `product_active` a la vista (al final, no reordena/rompe
--     nada de lo que ya la consume con columnas explícitas) para que cada
--     pantalla filtre según corresponda.
--   - Las FK de sale_items/inventory_balances/stock_movements/
--     promotion_products (RESTRICT/NO ACTION) y kit_components.
--     component_product_id (RESTRICT) YA protegen la integridad para hard
--     delete — no hace falta reimplementar esos chequeos a mano ni
--     desactivar constraints (sección 21). product_prices y
--     kit_components.kit_product_id son CASCADE a propósito (precio nunca
--     usado / composición propia del kit que se borra) — un producto sin
--     ventas/movimientos/kits/promociones puede tener precio cargado y
--     nunca haber sido vendido, y eso no debería bloquear el hard delete
--     (el ejemplo del pedido, "Sérum Test", no menciona el precio como
--     bloqueante). delete_product() intenta el DELETE real y traduce
--     cualquier foreign_key_violation a un mensaje claro — la única fuente
--     de verdad es la FK, nunca un pre-chequeo separado sujeto a race
--     condition.
--   - trg_audit_products (20260101000014_audit_triggers.sql) YA audita
--     TODO update de products genéricamente (before/after completo). Las
--     RPC de acá agregan además una fila explícita con las acciones que
--     pide el pedido (PRODUCT_DEACTIVATED/PRODUCT_REACTIVATED/
--     PRODUCT_DELETED) — no se saca el trigger genérico, solo se suma
--     información más específica encima, mismo patrón que cancel_sale/
--     mark_sale_invoiced (RPC de negocio con su propia fila de auditoría,
--     además de lo que ya audite un trigger de tabla).

-- ---------------------------------------------------------------------------
-- 1) product_stock_status: agrega product_active al final (columna nueva,
--    no reordena ni saca ninguna existente).
-- ---------------------------------------------------------------------------
create or replace view public.product_stock_status
with (security_invoker = true) as
select
  p.id as product_id,
  p.sku,
  p.name,
  p.category,
  sl.id as location_id,
  sl.code as location_code,
  coalesce(ib.quantity, 0) as quantity,
  coalesce(ib.min_stock_override, p.default_min_stock) as min_stock,
  case
    when coalesce(ib.quantity, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as status,
  p.active as product_active
from public.products p
cross join public.stock_locations sl
left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = sl.id
where p.track_stock = true;

comment on view public.product_stock_status is
  'Estado de stock (ok/bajo/sin_stock) por sede y producto trackeable. Solo para productos '
  'con track_stock = true; los kits usan kit_availability. product_active permite a cada '
  'pantalla decidir si un producto inactivo debe contar como alerta operativa (nunca) o '
  'seguir siendo consultable por Administración (sí, sin filtrar acá).';

-- ---------------------------------------------------------------------------
-- 2) deactivate_product / reactivate_product: admin-only, usan el mismo
--    registro (UPDATE de active, nunca se recrea el producto — sección 14).
--    Conservan todo lo demás intacto: ventas, sale_items, stock_movements,
--    inventory_balances, promotion_products, kit_components y precios
--    históricos no se tocan.
-- ---------------------------------------------------------------------------
create or replace function public.deactivate_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.products;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede desactivar productos.';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if v_product is null then
    raise exception 'El producto no existe.';
  end if;

  update public.products set active = false where id = p_product_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRODUCT_DEACTIVATED', 'products', p_product_id,
    jsonb_build_object('sku', v_product.sku, 'name', v_product.name)
  );
end;
$$;

comment on function public.deactivate_product(uuid) is
  'Baja comercial (soft): active = false. No borra ni altera ventas, stock, precios ni '
  'promociones históricas — solo deja de ser elegible para operatoria nueva.';

grant execute on function public.deactivate_product(uuid) to authenticated;

create or replace function public.reactivate_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.products;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede reactivar productos.';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if v_product is null then
    raise exception 'El producto no existe.';
  end if;

  update public.products set active = true where id = p_product_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRODUCT_REACTIVATED', 'products', p_product_id,
    jsonb_build_object('sku', v_product.sku, 'name', v_product.name)
  );
end;
$$;

comment on function public.reactivate_product(uuid) is
  'Vuelve a active = true sobre el mismo registro (nunca se recrea el producto) — vuelve a '
  'Nueva Venta, Precios y selección de promociones según las reglas normales.';

grant execute on function public.reactivate_product(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) delete_product: hard delete real, solo para productos cargados por
--    error sin ninguna actividad. La ÚNICA autoridad es la foreign key —
--    nunca un pre-chequeo separado (sección 21: race-safe por diseño, ya
--    que el propio DELETE es la comprobación, dentro de la misma
--    transacción). Auditoría ANTES del borrado (después no queda la fila
--    para poder referenciarla) — sección 22.
-- ---------------------------------------------------------------------------
create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.products;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede eliminar productos.';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if v_product is null then
    raise exception 'El producto no existe.';
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'PRODUCT_DELETED', 'products', p_product_id,
    jsonb_build_object('sku', v_product.sku, 'name', v_product.name, 'product_type', v_product.product_type)
  );

  begin
    delete from public.products where id = p_product_id;
  exception
    when foreign_key_violation then
      raise exception 'Este producto tiene historial y no puede eliminarse definitivamente.';
  end;
end;
$$;

comment on function public.delete_product(uuid) is
  'Hard delete real — exclusivo para productos cargados por error. La comprobación de '
  '"tiene historial" es la propia foreign key (sale_items/stock_movements/inventory_balances/ '
  'promotion_products/kit_components.component_product_id ya son RESTRICT o NO ACTION): si '
  'existe cualquier referencia, el DELETE falla con foreign_key_violation y se traduce a un '
  'mensaje claro, dentro de la misma transacción — sin ventana de carrera entre "comprobar" y '
  '"borrar". product_prices y kit_components.kit_product_id son CASCADE a propósito (precio '
  'nunca vendido / composición propia del kit que se borra), así que no bloquean por sí solos.';

grant execute on function public.delete_product(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) dashboard_report: critical_stock_count deja de contar productos
--    inactivos como alerta operativa (sección 17/18 del pedido). Resto de
--    la función sin cambios respecto de 20260201000013_reports.sql.
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
        'doctor_id', d.id, 'doctor', d.full_name, 'sales_count', t.cnt,
        'commissionable_revenue', t.commissionable_revenue, 'commission', t.commission
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
  'critical_stock_count excluye productos inactivos — no son una alerta operativa real.';
