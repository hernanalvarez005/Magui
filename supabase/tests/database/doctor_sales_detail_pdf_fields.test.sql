-- pgTAP: doctor_sales_detail — campos aditivos para Comisiones por Dra. →
-- Exportar PDF (migración 68). Casos, en orden:
--   1)   commissionable_revenue de una venta simple = base comisionable bruta.
--   2)   effective_commission_percent = tasa histórica (10%), no la actual.
--   3)   products consolida el producto vendido con su nombre y cantidad.
--   4)   INVARIANCIA CRÍTICA (pedido del usuario): sube el % actual de la
--        doctora DESPUÉS de la venta -> effective_commission_percent de la
--        venta histórica NO cambia (sigue 10%, nunca lee doctors.commission_percent).
--   5-6) Devolución parcial: commissionable_revenue/commission_total bajan
--        proporcionalmente, pero effective_commission_percent sigue
--        invariante (10%) — Importe comisionable × % efectivo ≈ Comisión.
--   7)   products refleja la cantidad NETA (post-devolución), no la bruta.
--   8-9) Venta con producto comisionable + no comisionable: products SOLO
--        trae el comisionable (decisión B), commissionable_revenue no
--        incluye el no comisionable.
--   10-11) THREE_FOR_TWO: el split interno (pagas + gratis) se consolida en
--          UNA sola entrada de products, con la cantidad total.
--   12)  Kit: aparece como su propio producto, nunca explotado a componentes.
--   13)  Venta cancelada queda excluida de sales[] (sin cambios, regresión).
--   14)  Regresión: summary.commission_total sigue la fórmula ya vigente
--        (suma de comisión neta reescalada), sin alterar por esta migración.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(14);

insert into auth.users (id, email) values
  ('d5000000-0000-0000-0000-000000000001', 'admin.pdfcom@test.maguirejuve.com'),
  ('d5000000-0000-0000-0000-000000000002', 'seller.pdfcom@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'd5000000-0000-0000-0000-000000000001';
-- Vendedora con can_view_financial_reports=true a propósito: prueba en el
-- mismo paso que este flag (independiente del rol) alcanza para leer
-- doctor_sales_detail sin ser admin — mismo caso auditado antes de implementar.
update public.profiles set role = 'seller', active = true, can_view_financial_reports = true
  where id = 'd5000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'd5000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'd5000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PDF-N1', 'Serum PDF Uno', 'product', 'Test', true, true, false, true),
  ('PDF-N2', 'Accesorio PDF No Comisiona', 'product', 'Test', true, false, false, true),
  ('PDF-3A', 'Crema PDF 3x2 A', 'product', 'Test', true, true, true, true),
  ('PDF-3B', 'Crema PDF 3x2 B', 'product', 'Test', true, true, true, true),
  ('PDF-KITCOMP', 'Componente PDF Kit', 'product', 'Test', true, true, false, true);
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PDF-KIT', 'Kit PDF Completo', 'kit', 'Test', false, true, false, true);
insert into public.kit_components (kit_product_id, component_product_id, quantity)
  values ((select id from products where sku = 'PDF-KIT'), (select id from products where sku = 'PDF-KITCOMP'), 1);

select set_product_price((select id from products where sku = sku_val), (select id from price_conditions where rule_type = 'BASE'), amount)
from (values
  ('PDF-N1', 30000), ('PDF-N2', 5000), ('PDF-3A', 10000), ('PDF-3B', 12000),
  ('PDF-KITCOMP', 8000), ('PDF-KIT', 15000)
) as t(sku_val, amount);
select set_product_price((select id from products where sku = sku_val), (select id from price_conditions where code = 'CASH'), amount)
from (values
  ('PDF-N1', 30000), ('PDF-N2', 5000), ('PDF-3A', 10000), ('PDF-3B', 12000),
  ('PDF-KITCOMP', 8000), ('PDF-KIT', 15000)
) as t(sku_val, amount);

insert into public.doctors (full_name, code, commission_percent, active) values ('Doctora PDF Test', 'PDT', 0.10, true);

insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable) values
  ('PDF-3X2', 'PDF 3x2', 'THREE_FOR_TWO', (select id from price_conditions where rule_type = 'BASE'), 3, 10, false);
select set_promotion_products(
  (select id from promotions where code = 'PDF-3X2'),
  array[(select id from products where sku = 'PDF-3A')]
);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = sku_val), 100, 'RECEPTION')
from (values ('PDF-N1'), ('PDF-N2'), ('PDF-3A'), ('PDF-KITCOMP')) as t(sku_val);

select id as dep_id from stock_locations where code = 'DEP' \gset
select id as channel_id from sales_channels limit 1 \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as doctor_id from doctors where code = 'PDT' \gset

set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Casos 1-4: venta simple, 4 unidades de PDF-N1 @ 30000 = 120000, doctora al 10%.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PDF-N1'), 'quantity', 4)),
  :'dep_id', :'channel_id', :'cash_id', null, :'doctor_id'
) ->> 'sale_id')::uuid as sale_simple_id \gset

select (select id from sale_items where sale_id = :'sale_simple_id') as item_simple_id \gset

select is(
  (
    select (s ->> 'commissionable_revenue')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  120000.00,
  'Caso 1: commissionable_revenue de la venta simple = 4 × 30000 = 120000'
);

select is(
  (
    select (s ->> 'effective_commission_percent')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  10.00,
  'Caso 2: effective_commission_percent = 10.00 (la tasa histórica de la doctora al vender)'
);

select is(
  (
    select s -> 'products'
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  jsonb_build_array(jsonb_build_object('name', 'Serum PDF Uno', 'quantity', 4)),
  'Caso 3: products consolida el producto vendido con nombre comercial y cantidad'
);

-- Sube el % ACTUAL de la doctora DESPUÉS de la venta — no debe afectar la
-- venta histórica ya creada.
set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000001', false);
update public.doctors set commission_percent = 0.50 where code = 'PDT';
set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000002', false);

select is(
  (
    select (s ->> 'effective_commission_percent')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  10.00,
  'Caso 4 (INVARIANCIA CRÍTICA): aunque doctors.commission_percent ahora es 50%, la venta histórica sigue mostrando 10%'
);

-- ===========================================================================
-- Casos 5-7: devolución parcial (1 de 4 unidades, $30000) — commissionable_revenue
-- y commission_total bajan proporcionalmente, pero % efectivo NO cambia.
-- ===========================================================================
select create_sale_return(
  :'sale_simple_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_simple_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test PDF comisiones — devolución parcial'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000001', false);

select is(
  (
    select (s ->> 'commissionable_revenue')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  90000.00,
  'Caso 5: tras devolver 1 unidad ($30000), commissionable_revenue neto = 90000'
);

select is(
  (
    select (s ->> 'effective_commission_percent')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  10.00,
  'Caso 6: effective_commission_percent sigue 10.00 tras la devolución (invariante también ante devoluciones) — 90000 × 10% = 9000 = commission_total'
);

select is(
  (
    select s -> 'products'
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_simple_id'
  ),
  jsonb_build_array(jsonb_build_object('name', 'Serum PDF Uno', 'quantity', 3)),
  'Caso 7: products refleja la cantidad NETA (3, no las 4 originales) tras la devolución'
);

-- ===========================================================================
-- Casos 8-9: venta con producto comisionable + no comisionable — products
-- SOLO trae el comisionable (decisión B), commissionable_revenue no incluye
-- el no comisionable.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'd5000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'PDF-N1'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'PDF-N2'), 'quantity', 1)
  ),
  :'dep_id', :'channel_id', :'cash_id', null, :'doctor_id'
) ->> 'sale_id')::uuid as sale_mixed_id \gset

select is(
  (
    select s -> 'products'
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_mixed_id'
  ),
  jsonb_build_array(jsonb_build_object('name', 'Serum PDF Uno', 'quantity', 1)),
  'Caso 8: venta mixta — products solo trae el producto comisionable (PDF-N2 no aparece)'
);

select is(
  (
    select (s ->> 'commissionable_revenue')::numeric
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_mixed_id'
  ),
  30000.00,
  'Caso 9: commissionable_revenue de la venta mixta = solo PDF-N1 (30000), no incluye PDF-N2'
);

-- ===========================================================================
-- Casos 10-11: THREE_FOR_TWO — el split interno (pagas + gratis) del mismo
-- producto se consolida en UNA sola entrada de products.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PDF-3A'), 'quantity', 3)),
  :'dep_id', :'channel_id', :'cash_id', null, :'doctor_id'
) ->> 'sale_id')::uuid as sale_3x2_id \gset

select is(
  (
    select jsonb_array_length(s -> 'products')
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_3x2_id'
  ),
  1,
  'Caso 10: 3x2 genera 2 sale_items internos (pagas+gratis) pero products consolida en 1 sola entrada'
);

select is(
  (
    select s -> 'products'
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_3x2_id'
  ),
  jsonb_build_array(jsonb_build_object('name', 'Crema PDF 3x2 A', 'quantity', 3)),
  'Caso 11: la cantidad consolidada del 3x2 es 3 (2 pagas + 1 gratis)'
);

-- ===========================================================================
-- Caso 12: kit — aparece como su propio producto, nunca explotado a componentes.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PDF-KIT'), 'quantity', 1)),
  :'dep_id', :'channel_id', :'cash_id', null, :'doctor_id'
) ->> 'sale_id')::uuid as sale_kit_id \gset

select is(
  (
    select s -> 'products'
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_kit_id'
  ),
  jsonb_build_array(jsonb_build_object('name', 'Kit PDF Completo', 'quantity', 1)),
  'Caso 12: el kit aparece como su propio producto (nunca explotado a PDF-KITCOMP)'
);

-- ===========================================================================
-- Caso 13: venta cancelada queda excluida de sales[] (regresión, sin cambios).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PDF-N1'), 'quantity', 1)),
  :'dep_id', :'channel_id', :'cash_id', null, :'doctor_id'
) ->> 'sale_id')::uuid as sale_cancel_id \gset

select cancel_sale(:'sale_cancel_id'::uuid, 'Test PDF comisiones — cancelación');

select is(
  (
    select count(*)
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
    where (s ->> 'id')::uuid = :'sale_cancel_id'
  ),
  0::bigint,
  'Caso 13: la venta cancelada no aparece en sales[] (status<>confirmed, regresión sin cambios)'
);

-- ===========================================================================
-- Caso 14: regresión — summary.commission_total sigue la fórmula ya vigente
-- (suma de comisión neta reescalada de cada venta), migración 68 no la altera.
-- ===========================================================================
select is(
  ((doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'summary') ->> 'commission_total')::numeric,
  (
    select round(sum((s ->> 'commission_total')::numeric), 2)
    from jsonb_array_elements(doctor_sales_detail(:'doctor_id', current_date - 1, current_date + 1) -> 'sales') s
  ),
  'Caso 14: regresión — summary.commission_total = suma de sales[].commission_total (fórmula ya vigente, sin cambios)'
);

select * from finish();
rollback;
