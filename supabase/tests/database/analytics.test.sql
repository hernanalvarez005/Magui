-- pgTAP: Analytics de productos, kits y promociones (MAGUI REJUVE — ANALYTICS
-- DE PRODUCTOS, KITS Y PROMOCIONES). 24 casos: los 23 pedidos (9 de
-- productos/kits — Bloque A/B, dashboard_products_breakdown — + 14 de
-- promociones — Bloque C, promotion_performance_report/detail + snapshot
-- histórico en sale_items) más 1 chequeo explícito de configuración previa
-- (Caso C4 "previo": confirma que el duo realmente partió la venta en 2
-- líneas antes de medir que sales_count las cuente como 1 sola operación).
-- Cada caso de Bloque A/B usa su propia fecha histórica aislada (o el rango
-- de "hoy") para no depender del orden ni acumular estado entre casos.
-- Correr con: supabase test db (requiere Supabase CLI + Docker) o
-- scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(24);

insert into auth.users (id, email) values
  ('fe000000-0000-0000-0000-000000000001', 'admin.analytics@test.maguirejuve.com'),
  ('fe000000-0000-0000-0000-000000000002', 'seller.analytics@test.maguirejuve.com'),
  ('fe000000-0000-0000-0000-000000000003', 'sellernoreports.analytics@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fe000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true, can_view_financial_reports = true
  where id = 'fe000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = true, can_view_financial_reports = false
  where id = 'fe000000-0000-0000-0000-000000000003';
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-AN-P1', 'Producto Analytics Uno', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B1', 'Producto Analytics B1', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B2', 'Producto Analytics B2', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B3', 'Producto Analytics B3', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B4', 'Producto Analytics B4', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B5', 'Producto Analytics B5', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B6', 'Producto Analytics B6', 'product', 'Test', true, true, true, true),
  ('TEST-AN-B7', 'Producto Analytics B7', 'product', 'Test', true, true, true, true),
  ('TEST-AN-CREMA', 'Crema Componente Analytics', 'product', 'Test', true, true, false, true),
  ('TEST-AN-SERUM', 'Serum Componente Analytics', 'product', 'Test', true, true, false, true),
  ('TEST-AN-KIT', 'Kit Analytics Test', 'kit', 'Test', false, true, true, true),
  ('TEST-AN-NEW', 'Producto Analytics Nuevo (cambio)', 'product', 'Test', true, true, true, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'TEST-AN-KIT'), (select id from products where sku = 'TEST-AN-CREMA'), 2),
  ((select id from products where sku = 'TEST-AN-KIT'), (select id from products where sku = 'TEST-AN-SERUM'), 1);

-- valid_from explícito en 2020: varios casos de Bloque A/B venden con fecha
-- backdateada (2021) para aislarse entre sí — el precio tiene que existir
-- ANTES de esa fecha, si no fn_pricing_quote la rechaza como "sin precio
-- configurado" (el precio recién existiría desde "ahora", 2026).
select set_product_price((select id from products where sku = 'TEST-AN-P1'), (select id from price_conditions where rule_type = 'BASE'), 10000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-P1'), (select id from price_conditions where code = 'CASH'), 9000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-B' || i), (select id from price_conditions where rule_type = 'BASE'), 1000 * i, '2020-01-01'::timestamptz)
  from generate_series(1, 7) i;
select set_product_price((select id from products where sku = 'TEST-AN-B' || i), (select id from price_conditions where code = 'CASH'), 900 * i, '2020-01-01'::timestamptz)
  from generate_series(1, 7) i;
select set_product_price((select id from products where sku = 'TEST-AN-CREMA'), (select id from price_conditions where rule_type = 'BASE'), 5000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-CREMA'), (select id from price_conditions where code = 'CASH'), 4500, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-SERUM'), (select id from price_conditions where rule_type = 'BASE'), 3000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-SERUM'), (select id from price_conditions where code = 'CASH'), 2700, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-KIT'), (select id from price_conditions where rule_type = 'BASE'), 20000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-KIT'), (select id from price_conditions where code = 'CASH'), 18000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-NEW'), (select id from price_conditions where rule_type = 'BASE'), 8000, '2020-01-01'::timestamptz);
select set_product_price((select id from products where sku = 'TEST-AN-NEW'), (select id from price_conditions where code = 'CASH'), 7200, '2020-01-01'::timestamptz);

insert into public.customers (full_name, dni) values ('Cliente Analytics Test', '30999666');

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-AN-P1'), 100, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-AN-B' || i), 100, 'RECEPTION')
  from generate_series(1, 7) i;
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-AN-CREMA'), 100, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-AN-SERUM'), 100, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-AN-NEW'), 100, 'RECEPTION');

-- Bloque A/B usa fechas históricas backdateadas (aisladas por caso) para no
-- depender del orden ni acumular estado — create_sale con p_sold_at en el
-- pasado es exclusivo de admin (mismo guard que el resto del sistema), así
-- que todo este bloque corre autenticado como admin; el reporte también lo
-- consulta admin (mismo criterio que dashboard_report en el resto de la suite).
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- BLOQUE A/B — productos individuales (físico) y kits (comercial)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Caso 1: producto individual simple — unidades físicas correctas.
-- ---------------------------------------------------------------------------
select create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-P1'), 'quantity', 5)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-01 12:00:00-03'::timestamptz
);

select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-01', '2021-01-01') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-P1')
  ),
  5::numeric,
  'Caso 1: producto individual — 5 unidades vendidas aparecen tal cual en el donut de productos'
);

-- ---------------------------------------------------------------------------
-- Caso 2/3: kit se descompone en sus componentes REALES (nunca aparece el
-- kit en individual_products) — vender 1 kit (CREMA×2 + SERUM×1).
-- ---------------------------------------------------------------------------
select create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-KIT'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-02 12:00:00-03'::timestamptz
);

select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-02', '2021-01-02') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-CREMA')
  ),
  2::numeric,
  'Caso 2: 1 kit vendido se descompone en su componente CREMA (×2 por kit) — nunca según kit_components vigente, según lo realmente movido'
);
select ok(
  (
    select (elem ->> 'units')::numeric = 1
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-02', '2021-01-02') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-SERUM')
  ) and not exists (
    select 1
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-02', '2021-01-02') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-KIT')
  ),
  'Caso 3: SERUM aparece con 1 unidad y el KIT mismo NUNCA aparece en individual_products (Bloque A es 100% físico)'
);

-- ---------------------------------------------------------------------------
-- Caso 4: el kit SÍ aparece en top_kits como unidad comercial (sin explotar).
-- ---------------------------------------------------------------------------
select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-02', '2021-01-02') -> 'top_kits') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-KIT')
  ),
  1::numeric,
  'Caso 4: el kit vendido aparece en top_kits con 1 unidad comercial (Bloque B nunca explota a componentes)'
);

-- ---------------------------------------------------------------------------
-- Caso 5: venta anulada no cuenta ni en individual_products ni en top_kits.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-P1'), 'quantity', 4)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-03 12:00:00-03'::timestamptz
) ->> 'sale_id')::uuid as sale_cancel_id \gset

select cancel_sale(:'sale_cancel_id'::uuid, 'Test analytics: anulación no debe contar');

select is(
  coalesce((
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-03', '2021-01-03') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-P1')
  ), 0),
  0::numeric,
  'Caso 5: una venta anulada (SALE_CANCEL, no RETURN) no aporta unidades a ningún producto'
);

-- ---------------------------------------------------------------------------
-- Caso 6: devolución parcial de un kit reduce las unidades netas físicas de
-- sus componentes (2 kits vendidos, se devuelve 1 -> neto físico = 1 kit).
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-KIT'), 'quantity', 2)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-04 12:00:00-03'::timestamptz
) ->> 'sale_id')::uuid as sale_kit2_id \gset
select (select id from sale_items where sale_id = :'sale_kit2_id') as item_kit2_id \gset

select create_sale_return(
  :'sale_kit2_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_kit2_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test analytics: devolución parcial de kit'
);

select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-04', '2021-01-04') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-CREMA')
  ),
  2::numeric,
  'Caso 6: 2 kits vendidos (CREMA×4) menos 1 devuelto (CREMA×2 reintegradas) = 2 unidades físicas netas de CREMA'
);

-- ---------------------------------------------------------------------------
-- Caso 7: Cambio (exchange) — el producto original se netea a 0 en SU fecha
-- original (SALE + RETURN se cancelan); el producto nuevo aparece con sus
-- propias unidades en la fecha del cambio (hoy, create_sale_exchange no
-- toma p_sold_at).
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-05 12:00:00-03'::timestamptz
) ->> 'sale_id')::uuid as sale_exch_orig_id \gset
select (select id from sale_items where sale_id = :'sale_exch_orig_id') as item_exch_orig_id \gset

select create_sale_exchange(
  :'sale_exch_orig_id'::uuid,
  :'item_exch_orig_id'::uuid,
  1::numeric,
  (select id from products where sku = 'TEST-AN-NEW'),
  1
);

select ok(
  coalesce((
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-05', '2021-01-05') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-P1')
  ), 0) = 0
  and (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(dashboard_products_breakdown(current_date, current_date) -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-NEW')
  ) = 1,
  'Caso 7: el producto original se netea a 0 en su fecha original (SALE+RETURN); el nuevo producto del cambio aparece con 1 unidad en la fecha del cambio'
);

-- ---------------------------------------------------------------------------
-- Caso 8: top 6 + "Otros" — el 7mo producto (menor cantidad) cae en
-- others_units, no en el top.
-- ---------------------------------------------------------------------------
select create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B1'), 'quantity', 70),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B2'), 'quantity', 60),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B3'), 'quantity', 50),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B4'), 'quantity', 40),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B5'), 'quantity', 30),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B6'), 'quantity', 20),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B7'), 'quantity', 10)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666'),
  null, null, null, null,
  '2021-01-06 12:00:00-03'::timestamptz
);

select ok(
  (dashboard_products_breakdown('2021-01-06', '2021-01-06') -> 'individual_products' ->> 'others_units')::numeric = 10
  and not exists (
    select 1
    from jsonb_array_elements(dashboard_products_breakdown('2021-01-06', '2021-01-06') -> 'individual_products' -> 'top') elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-B7')
  ),
  'Caso 8: con 7 productos distintos, el de menor cantidad (B7, 10 unidades) queda en "Otros" (others_units=10) y fuera del top'
);

-- ---------------------------------------------------------------------------
-- Caso 9: un vendedor sin can_view_financial_reports no puede llamar
-- dashboard_products_breakdown.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000003', false);

select throws_ok(
  $$select dashboard_products_breakdown('2021-01-01', '2021-01-06')$$,
  'Caso 9: un vendedor sin can_view_financial_reports no puede ver el reporte de productos/kits'
);

-- ===========================================================================
-- BLOQUE C — rendimiento de promociones
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

-- Promo 1: KIT_PERCENT sobre TEST-AN-KIT, 10% OFF sobre Lista.
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
values (
  'TEST-AN-KITPROMO', 'Promo Kit Analytics', 'KIT_PERCENT',
  (select id from price_conditions where rule_type = 'BASE'), 0.10, 50, false
);
select set_promotion_products(
  (select id from promotions where code = 'TEST-AN-KITPROMO'),
  array(select id from products where sku = 'TEST-AN-KIT')
);

-- Promo 2: DUO_PERCENT sobre TEST-AN-B1 + TEST-AN-B2 (20% OFF). A diferencia
-- de KIT_PERCENT (1 sola línea), un duo SIEMPRE genera 2 sale_items propias
-- (una por cada producto de la pareja) con el MISMO applied_promotion_id —
-- el escenario real que necesitan los casos C4/C7/C8 (misma promoción,
-- varias líneas, UNA sola operación).
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
values (
  'TEST-AN-DUO', 'Promo Duo Analytics', 'DUO_PERCENT',
  (select id from price_conditions where rule_type = 'BASE'), 0.20, 60, false
);
select set_promotion_products(
  (select id from promotions where code = 'TEST-AN-DUO'),
  array(select id from products where sku in ('TEST-AN-B1', 'TEST-AN-B2'))
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

-- Sale C: KIT×1 (con promo1) + P1×1 (sin promo), CASH, hoy.
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-KIT'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-P1'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666')
) ->> 'sale_id')::uuid as sale_c_id \gset

-- ---------------------------------------------------------------------------
-- Caso C1/C2: snapshot histórico — la línea con promoción graba nombre/tipo;
-- la línea sin promoción queda null.
-- ---------------------------------------------------------------------------
select is(
  (select promotion_name_snapshot from sale_items
    where sale_id = :'sale_c_id' and product_id = (select id from products where sku = 'TEST-AN-KIT')),
  'Promo Kit Analytics',
  'Caso C1: la línea con promoción graba el snapshot del nombre al momento de la venta'
);
select is(
  (select promotion_name_snapshot from sale_items
    where sale_id = :'sale_c_id' and product_id = (select id from products where sku = 'TEST-AN-P1')),
  null,
  'Caso C2: la línea sin promoción NUNCA graba snapshot (queda null, igual que applied_promotion_id)'
);

-- ---------------------------------------------------------------------------
-- Caso C3: editar el nombre DESPUÉS de vender no cambia el snapshot ni lo
-- que muestra el reporte histórico (identidad estable mes a mes).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

update public.promotions set name = 'Promo Kit Analytics RENOMBRADA' where code = 'TEST-AN-KITPROMO';

select is(
  (
    select elem ->> 'name'
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  'Promo Kit Analytics',
  'Caso C3: renombrar la promoción después de vender NO cambia el nombre histórico ya snapshoteado'
);

-- ---------------------------------------------------------------------------
-- Caso C4: sales_count cuenta OPERACIONES distintas, no líneas — un duo
-- genera 2 líneas (una por producto de la pareja) de la MISMA promoción en
-- UNA sola venta, tiene que contar 1. B1×2 + B2×2 (duo_count=2).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B1'), 'quantity', 2),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-B2'), 'quantity', 2)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666')
) ->> 'sale_id')::uuid as sale_e_id \gset

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

select is(
  (
    select count(*) from sale_items
    where sale_id = :'sale_e_id' and applied_promotion_id = (select id from promotions where code = 'TEST-AN-DUO')
  )::int,
  2,
  'Caso C4 (previo): confirma que el duo realmente generó 2 líneas de la misma promoción en la venta (una por producto, setup del caso)'
);
select is(
  (
    select (elem ->> 'sales_count')::int
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-DUO')
  ),
  1,
  'Caso C4: sales_count cuenta OPERACIONES distintas (1), nunca líneas (2), aunque el duo parta la venta en 2 filas'
);

-- ---------------------------------------------------------------------------
-- Caso C5: units_sold — un kit con promoción cuenta como 1 unidad
-- promocional (nunca se explota a componentes, mismo criterio que top_kits).
-- ---------------------------------------------------------------------------
select is(
  (
    select (elem ->> 'units_sold')::numeric
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  1::numeric,
  'Caso C5: 1 kit vendido con promoción = 1 unidad promocional, nunca explotado a CREMA/SERUM'
);

-- ---------------------------------------------------------------------------
-- Caso C6: revenue — solo suma la línea CON promoción (18000 del kit),
-- nunca el carrito completo (que incluye P1 sin promo, 9000 más).
-- ---------------------------------------------------------------------------
select is(
  (
    select (elem ->> 'revenue')::numeric
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  18000.00,
  'Caso C6: revenue = solo la línea con promoción (kit, 20000×0.9=18000) — nunca el total del carrito (que además tiene P1 sin promo)'
);

-- ---------------------------------------------------------------------------
-- Caso C7: average_ticket = revenue / sales_count, NUNCA revenue / units.
-- Duo B1×2+B2×2 (20% OFF sobre BASE): B1 800×2=1600, B2 1600×2=3200,
-- revenue=4800, sales_count=1, units_sold=4 -> avg correcto=4800, nunca
-- revenue/units (4800/4=1200).
-- ---------------------------------------------------------------------------
select is(
  (
    select (elem ->> 'average_ticket')::numeric
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-DUO')
  ),
  4800.00,
  'Caso C7: average_ticket = revenue/sales_count (4800/1=4800), nunca revenue/units (4800/4=1200)'
);

-- ---------------------------------------------------------------------------
-- Caso C8: neto de devoluciones — devolver 1 de las 2 unidades de la línea
-- B1 reduce units_sold de la promoción (4 -> 3).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

select create_sale_return(
  :'sale_e_id'::uuid,
  jsonb_build_array(jsonb_build_object(
    'sale_item_id',
    (select id from sale_items
      where sale_id = :'sale_e_id' and product_id = (select id from products where sku = 'TEST-AN-B1')),
    'quantity', 1
  )),
  'CASH', null, 'Test analytics: devolución parcial de la línea B1 del duo'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

select is(
  (
    select (elem ->> 'units_sold')::numeric
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-DUO')
  ),
  3::numeric,
  'Caso C8: devolver 1 unidad de la línea B1 reduce units_sold de la promoción (4 -> 3), neto de devoluciones'
);

-- ---------------------------------------------------------------------------
-- Caso C9: 'replaced' se excluye de raíz — un Cambio sobre una venta con
-- promoción NUNCA aporta a las métricas de esa promoción (la original queda
-- replaced, 100% excluida).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-AN-KIT'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999666')
) ->> 'sale_id')::uuid as sale_f_id \gset
select (select id from sale_items where sale_id = :'sale_f_id') as item_f_id \gset

select create_sale_exchange(
  :'sale_f_id'::uuid, :'item_f_id'::uuid, 1,
  (select id from products where sku = 'TEST-AN-NEW'), 1
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

select is(
  (
    select (elem ->> 'units_sold')::numeric
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  1::numeric,
  'Caso C9: la venta cambiada (ahora replaced) NO suma a la promoción — units_sold sigue en 1 (solo Sale C)'
);

-- ---------------------------------------------------------------------------
-- Caso C10: una promoción desactivada sigue apareciendo en Analytics si tuvo
-- actividad en el rango (nunca se filtra por active — queda consultable
-- para siempre).
-- ---------------------------------------------------------------------------
update public.promotions set active = false where code = 'TEST-AN-KITPROMO';

select is(
  (
    select elem ->> 'is_active'
    from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  'false',
  'Caso C10: una promoción desactivada sigue apareciendo en el reporte (is_active=false), nunca se excluye del histórico'
);

-- ---------------------------------------------------------------------------
-- Caso C11: nunca se puede borrar físicamente una promoción (ni siquiera
-- como admin) — no existe policy de DELETE en la tabla, así que RLS
-- silenciosamente no matchea ninguna fila (DELETE 0), sin lanzar excepción:
-- la fila sigue existiendo después del intento.
-- ---------------------------------------------------------------------------
delete from public.promotions where code = 'TEST-AN-KITPROMO';
select is(
  (select count(*) from promotions where code = 'TEST-AN-KITPROMO')::int,
  1,
  'Caso C11: ni un admin puede hacer DELETE físico de una promoción (sin policy de delete — RLS no matchea ninguna fila, la promoción sigue existiendo)'
);

-- ---------------------------------------------------------------------------
-- Caso C12: filtro de fecha — un rango sin actividad no devuelve la promo.
-- ---------------------------------------------------------------------------
select is(
  promotion_performance_report('2019-01-01', '2019-01-01') -> 'rows',
  '[]'::jsonb,
  'Caso C12: un rango de fechas sin ninguna venta no devuelve ninguna promoción'
);

-- ---------------------------------------------------------------------------
-- Caso C13: promotion_performance_detail — ranking de productos/kits dentro
-- de la promoción.
-- ---------------------------------------------------------------------------
select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(
      promotion_performance_detail(
        (select id from promotions where code = 'TEST-AN-KITPROMO'),
        current_date, current_date
      ) -> 'top_products'
    ) elem
    where elem ->> 'product_id' = (select id::text from products where sku = 'TEST-AN-KIT')
  ),
  1::numeric,
  'Caso C13: el detalle de la promoción muestra el kit en su ranking de productos con 1 unidad'
);

-- ---------------------------------------------------------------------------
-- Caso C14: ranking multi-criterio — por revenue y por units_sold dan
-- órdenes DISTINTOS entre las dos promociones (nunca un único orden fijo).
-- ---------------------------------------------------------------------------
select ok(
  (
    select (elem ->> 'revenue')::numeric from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ) > (
    select (elem ->> 'revenue')::numeric from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-DUO')
  )
  and (
    select (elem ->> 'units_sold')::numeric from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-DUO')
  ) > (
    select (elem ->> 'units_sold')::numeric from jsonb_array_elements(promotion_performance_report(current_date, current_date) -> 'rows') elem
    where elem ->> 'promotion_id' = (select id::text from promotions where code = 'TEST-AN-KITPROMO')
  ),
  'Caso C14: ordenar por revenue vs. por units_sold da un ranking DISTINTO entre las dos promociones — el ranking es multi-criterio, no fijo'
);

select * from finish();
rollback;
