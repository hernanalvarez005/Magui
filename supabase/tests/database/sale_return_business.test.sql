-- pgTAP: Devolución de producto — Bloque E (métricas netas, comisión,
-- facturación e invariancia histórica). Complementa sale_return.test.sql
-- (que cubre mecánica/stock/estados) — este archivo cubre exclusivamente lo
-- que ese no cubre: secciones 20-27 y 28-30 del pedido, más la precisión #5
-- (comisión neta explícita) aprobada por el usuario.
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(17);

insert into auth.users (id, email) values
  ('fe000000-0000-0000-0000-000000000001', 'admin.retbiz@test.maguirejuve.com'),
  ('fe000000-0000-0000-0000-000000000002', 'seller.retbiz@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fe000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fe000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-RETBIZ-P1', 'Producto Devolución Biz Uno', 'product', 'Test', true, true, false, true),
  ('TEST-RETBIZ-P2', 'Producto Devolución Biz Dos (histórico)', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'TEST-RETBIZ-P1'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-RETBIZ-P1'), (select id from price_conditions where code = 'CASH'), 30000);
select set_product_price((select id from products where sku = 'TEST-RETBIZ-P1'), (select id from price_conditions where code = 'TRANSFER'), 31000);
select set_product_price((select id from products where sku = 'TEST-RETBIZ-P2'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'TEST-RETBIZ-P2'), (select id from price_conditions where code = 'CASH'), 20000);

-- Doctora con 10% AL MOMENTO de la venta — se sube a 50% DESPUÉS, antes de la
-- devolución, para probar que la comisión neta preserva la TASA EFECTIVA
-- original (nunca vuelve a leer el % vigente de la doctora).
insert into public.doctors (full_name, code, commission_percent, active) values ('Doctora Devolución Test', 'DDT', 0.10, true);
insert into public.customers (full_name, dni) values ('Cliente Devolución Biz Test', '30999333');
insert into public.payment_accounts (code, name) values ('TEST-RETBIZ-ACC', 'Cuenta Test Devolución') on conflict (code) do nothing;

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RETBIZ-P1'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RETBIZ-P2'), 20, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Venta histórica SIN devolución — control: net debe ser IDÉNTICO al bruto
-- en todos los reportes (invariancia histórica, sección 30 del audit).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RETBIZ-P2'), 'quantity', 2)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999333')
) ->> 'sale_id')::uuid as sale_hist_id \gset

select is(
  (select net_line_total from sale_item_net where sale_id = :'sale_hist_id'),
  (select line_total from sale_items where sale_id = :'sale_hist_id'),
  'Invariancia histórica: una venta sin ninguna devolución tiene net_line_total = line_total (idéntico al bruto)'
);

-- ===========================================================================
-- Venta con doctora (10% al momento de vender) — se sube el % después.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RETBIZ-P1'), 'quantity', 4)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999333'),
  (select id from doctors where code = 'DDT')
) ->> 'sale_id')::uuid as sale_doc_id \gset

select is(
  (select commission_total from sales where id = :'sale_doc_id'), 12000.00,
  'Precondición: 4 × 30000 × 10% = 12000 de comisión histórica (nunca se reescribe)'
);

select (select id from sale_items where sale_id = :'sale_doc_id') as item_doc_id \gset

-- Sube la % de la doctora DESPUÉS de la venta, ANTES de la devolución.
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);
update public.doctors set commission_percent = 0.50 where code = 'DDT';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);

-- Devuelve 1 de las 4 unidades ($30.000 de $120.000 -> queda neto $90.000).
select create_sale_return(
  :'sale_doc_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_doc_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test comisión neta'
);

select is(
  (select commission_total from sales where id = :'sale_doc_id'), 12000.00,
  'sales.commission_total NUNCA se reescribe por una devolución — sigue el histórico (12000)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

select is(
  ((doctor_sales_detail((select id from doctors where code = 'DDT'), current_date - 1, current_date + 1) -> 'summary') ->> 'commissionable_revenue')::numeric,
  90000.00,
  'doctor_sales_detail: commissionable_revenue neto = 90000 (120000 - 30000 devueltos)'
);
select is(
  ((doctor_sales_detail((select id from doctors where code = 'DDT'), current_date - 1, current_date + 1) -> 'summary') ->> 'commission_total')::numeric,
  9000.00,
  'Precisión #5: comisión neta = 9000 (90000 × 10% — la TASA ORIGINAL, nunca el 50% vigente hoy)'
);
select isnt(
  ((doctor_sales_detail((select id from doctors where code = 'DDT'), current_date - 1, current_date + 1) -> 'summary') ->> 'commission_total')::numeric,
  45000.00,
  'Precisión #5 (negativo): la comisión neta NO es 90000 × 50% — confirma que no relee el % vigente de la doctora'
);

select is(
  (dashboard_report(current_date - 1, current_date + 1) -> 'kpis' ->> 'commission_total')::numeric,
  9000.00,
  'dashboard_report: commission_total agregado también refleja la tasa efectiva original (9000)'
);
select is(
  (dashboard_report(current_date - 1, current_date + 1) -> 'kpis' ->> 'revenue')::numeric >= 90000.00,
  true,
  'dashboard_report: revenue neto incluye al menos los 90000 netos de la venta con devolución'
);

select is(
  (
    select (elem ->> 'commission')::numeric
    from jsonb_array_elements(dashboard_report(current_date - 1, current_date + 1) -> 'commission_by_doctor') elem
    where elem ->> 'doctor_id' = (select id::text from doctors where code = 'DDT')
  ),
  9000.00,
  'commission_by_doctor: también neto y con la tasa efectiva original (fix de paso del bug de fan-out por línea)'
);
select is(
  (
    select (elem ->> 'sales_count')::int
    from jsonb_array_elements(dashboard_report(current_date - 1, current_date + 1) -> 'commission_by_doctor') elem
    where elem ->> 'doctor_id' = (select id::text from doctors where code = 'DDT')
  ),
  1,
  'commission_by_doctor: sales_count cuenta VENTAS, no líneas (antes del fix de paso, una venta de 1 línea ya daba bien esto — regresión explícita)'
);

select is(
  (
    select (elem ->> 'units')::numeric
    from jsonb_array_elements(product_revenue_report(current_date - 1, current_date + 1) -> 'rows') elem
    where elem ->> 'sku' = 'TEST-RETBIZ-P1'
  ),
  3.00,
  'product_revenue_report: unidades netas = 3 (4 vendidas - 1 devuelta)'
);
select is(
  (
    select (elem ->> 'revenue')::numeric
    from jsonb_array_elements(product_revenue_report(current_date - 1, current_date + 1) -> 'rows') elem
    where elem ->> 'sku' = 'TEST-RETBIZ-P1'
  ),
  90000.00,
  'product_revenue_report: revenue neto = 90000'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000002', false);
select is(
  (
    select (sale ->> 'total')::numeric
    from jsonb_array_elements(customer_purchase_history((select id from customers where dni = '30999333'))) sale
    where sale ->> 'sale_id' = :'sale_doc_id'::text
  ),
  90000.00,
  'customer_purchase_history: total neto = 90000'
);

-- ===========================================================================
-- Matriz PENDING/INVOICED × total (sección 28-30 del pedido): PENDING pasa a
-- NOT_REQUIRED en devolución total; INVOICED NUNCA se toca.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RETBIZ-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30999333'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'TEST-RETBIZ-ACC')
) ->> 'sale_id')::uuid as sale_pending_id \gset
select (select id from sale_items where sale_id = :'sale_pending_id') as item_pending_id \gset

select is((select billing_status from sales where id = :'sale_pending_id'), 'PENDING'::sale_billing_status, 'Precondición: venta por transferencia queda PENDING de facturar');

select create_sale_return(
  :'sale_pending_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_pending_id'::uuid, 'quantity', 1)),
  'TRANSFER', (select id from payment_accounts where code = 'TEST-RETBIZ-ACC'), 'Test matriz PENDING'
);

select is(
  (select billing_status from sales where id = :'sale_pending_id'), 'NOT_REQUIRED'::sale_billing_status,
  'Devolución total sobre venta PENDING: billing_status pasa a NOT_REQUIRED (nada queda por facturar)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RETBIZ-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30999333'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'TEST-RETBIZ-ACC')
) ->> 'sale_id')::uuid as sale_invoiced_id \gset
select mark_sale_invoiced(:'sale_invoiced_id'::uuid);
select (select id from sale_items where sale_id = :'sale_invoiced_id') as item_invoiced_id \gset

select create_sale_return(
  :'sale_invoiced_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_invoiced_id'::uuid, 'quantity', 1)),
  'TRANSFER', (select id from payment_accounts where code = 'TEST-RETBIZ-ACC'), 'Test matriz INVOICED'
);

select is(
  (select billing_status from sales where id = :'sale_invoiced_id'), 'INVOICED'::sale_billing_status,
  'Devolución total sobre venta INVOICED: billing_status NUNCA se toca — el comprobante fiscal ya emitido sigue intacto'
);
select is(
  (select status from sales where id = :'sale_invoiced_id'), 'returned'::sale_status,
  'El status comercial sí refleja la devolución total (returned) aunque el estado fiscal quede intacto — son ejes independientes (sección 28-29)'
);

select * from finish();
rollback;
