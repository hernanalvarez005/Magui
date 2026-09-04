-- pgTAP: BLOQUE B (cierre) — filtro central de métricas/comisión por
-- payment_status. Un pedido Web PENDING de cobro no debe sumar revenue ni
-- comisión en dashboard_report/product_revenue_report/doctor_sales_detail;
-- al pasar a PAID, sí cuenta. fulfillment (pendiente/entregado) no cambia
-- esto — se prueba con un PICKUP todavía PENDING_PICKUP a propósito.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(9);

insert into auth.users (id, email) values
  ('fe000000-0000-0000-0000-000000000001', 'admin.webmetrics@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true, can_view_financial_reports = true
  where id = 'fe000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'fe000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'fe000000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('WEBMET-A', 'Producto Métricas Web', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'WEBMET-A'), (select id from price_conditions where rule_type = 'BASE'), 100000);
select set_product_price((select id from products where sku = 'WEBMET-A'), (select id from price_conditions where code = 'CASH'), 90000);

insert into public.doctors (code, full_name, commission_percent, active) values ('DRA-WEBMET', 'Doctora Métricas Web (test)', 0.10, true);

insert into public.customers (full_name, dni) values ('Clienta Métricas Web (test)', '30999911');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WEBMET-A'), 20, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30999911' \gset
select id as doctor_id from doctors where code = 'DRA-WEBMET' \gset

-- Baseline: sin el pedido PENDING, todavía no hay nada que contar en la
-- ventana de fechas de este test (catálogo/cliente recién creados).
select (dashboard_report(current_date, current_date) -> 'kpis' ->> 'revenue')::numeric as revenue_before \gset

-- ===========================================================================
-- Pedido Web PICKUP, PENDING de cobro, con doctora asignada (comisionable).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEBMET-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  :'doctor_id'::uuid, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_id \gset

select is(
  (dashboard_report(current_date, current_date) -> 'kpis' ->> 'revenue')::numeric,
  :revenue_before::numeric,
  'dashboard_report: el revenue NO se mueve mientras el pedido Web está PENDING de cobro (aunque ya esté PENDING_PICKUP)'
);
select is(
  (dashboard_report(current_date, current_date) -> 'kpis' ->> 'commission_total')::numeric,
  0::numeric,
  'dashboard_report: commission_total sigue en 0 mientras está PENDING'
);
select is(
  jsonb_array_length(product_revenue_report(current_date, current_date) -> 'rows'),
  0,
  'product_revenue_report: no incluye ninguna fila del producto mientras el único pedido que lo vendió está PENDING'
);
select is(
  (doctor_sales_detail(:'doctor_id'::uuid, current_date, current_date) -> 'summary' ->> 'sales_count')::int,
  0,
  'doctor_sales_detail: sales_count en 0 mientras el pedido de esta doctora está PENDING'
);

-- ===========================================================================
-- Se cobra (mark_web_order_paid) — SIN entregar todavía (sigue PENDING_PICKUP)
-- — ahora sí tiene que contar en las 3 funciones.
-- ===========================================================================
select mark_web_order_paid(:'sale_id'::uuid);

select is(
  (select fulfillment_status from sales where id = :'sale_id'),
  'PENDING_PICKUP'::sale_fulfillment_status,
  'Control: sigue PENDING_PICKUP (no se entregó) — confirma que lo que habilitó el conteo fue el cobro, no el fulfillment'
);
select is(
  (dashboard_report(current_date, current_date) -> 'kpis' ->> 'revenue')::numeric,
  (:revenue_before::numeric + 90000),
  'dashboard_report: una vez PAID, el revenue SÍ suma (90000, precio CASH) — aunque el fulfillment siga pendiente de retiro'
);
select is(
  (dashboard_report(current_date, current_date) -> 'kpis' ->> 'commission_total')::numeric,
  9000.00::numeric,
  'dashboard_report: commission_total ahora es exactamente 10% de 90000 = 9000.00'
);
select is(
  jsonb_array_length(product_revenue_report(current_date, current_date) -> 'rows'),
  1,
  'product_revenue_report: ahora sí trae la fila del producto'
);
select is(
  (doctor_sales_detail(:'doctor_id'::uuid, current_date, current_date) -> 'summary' ->> 'commission_total')::numeric,
  9000.00::numeric,
  'doctor_sales_detail: comisión de la doctora ahora es exactamente 9000.00'
);

select * from finish();
rollback;
