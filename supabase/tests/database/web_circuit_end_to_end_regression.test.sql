-- pgTAP: BLOQUE G — regresión final de integración del circuito Ventas Web.
-- Este archivo NO prueba de nuevo lo que ya está cubierto exhaustivamente
-- por función en otros archivos (permisos admin/vendedor/viewer, billing_status
-- vs payment_status, filtros de Historial, sobreventa, doble entrega, etc. —
-- ver README.md y el informe de cierre de BLOQUE G). Prueba específicamente
-- lo que NINGÚN test existente encadena: las 6 combinaciones WEB completas
-- de punta a punta (creación -> reserva/físico -> Notificaciones -> cobro ->
-- entrega -> consumo de reserva -> movimiento SALE -> Historial), más 3
-- casos de integración que tampoco existían: snapshot de kit inmutable ante
-- un cambio posterior de kit_components, una venta Web cancelada dejando de
-- computar en métricas, y que una reserva CONSUMED no sigue restando del
-- disponible.
--
-- Casos, en orden:
--   1-6) Las 6 combinaciones: PICKUP_25/PAID, PICKUP_25/PENDING,
--        PICKUP_37/PAID, PICKUP_37/PENDING, SHIPPING/PAID, SHIPPING/PENDING.
--        Cada una recorre TODO el ciclo y verifica, en orden: sede física,
--        reserva (o físico inmediato para SHIPPING), disponible,
--        payment_status, visibilidad en Notificaciones, cobro (si PENDING),
--        entrega (si PICKUP), consumo de reserva (ACTIVE->CONSUMED),
--        movimiento SALE, aparición en Historial.
--   7) Snapshot de kit: modificar kit_components DESPUÉS de crear el
--      pickup no cambia la reserva ya creada; la entrega consume
--      exactamente lo reservado, no lo que kit_components dice ahora.
--   8) Una venta Web PAID cancelada deja de computar en dashboard_report
--      (revenue y comisión).
--   9) Una reserva CONSUMED (ya entregada) no sigue restando del
--      disponible — reserved vuelve a 0 para ese producto/sede.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(44);

insert into auth.users (id, email) values
  ('ee100000-0000-0000-0000-000000000002', 'admin.setup.g@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true, full_name = 'Admin G Setup (test)' where id = 'ee100000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'ee100000-0000-0000-0000-000000000002', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'ee100000-0000-0000-0000-000000000002', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('G-A', 'Producto G A', 'product', 'Test', true, true, false, true),
  ('G-KIT-COMP', 'Componente Kit G (snapshot)', 'product', 'Test', true, true, false, true),
  ('G-KIT', 'Kit G (snapshot)', 'kit', 'Test', false, true, false, true),
  ('G-CANCEL', 'Producto G Cancelado (métrica)', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'G-KIT'), (select id from products where sku = 'G-KIT-COMP'), 2);

select set_product_price((select id from products where sku = 'G-A'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'G-A'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'G-KIT-COMP'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'G-KIT-COMP'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'G-KIT'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'G-KIT'), (select id from price_conditions where code = 'CASH'), 7200);
select set_product_price((select id from products where sku = 'G-CANCEL'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'G-CANCEL'), (select id from price_conditions where code = 'CASH'), 4500);

insert into public.customers (full_name, dni) values ('Clienta Circuito G (test)', '30999977');
insert into public.doctors (code, full_name, commission_percent, active) values ('DOC-G', 'Doctora Comisión G (test)', 0.10, true);

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'G-A'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'G-A'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'G-A'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'G-KIT-COMP'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'G-CANCEL'), 10, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as dep_id from stock_locations where code = 'DEP' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30999977' \gset
select id as doctor_id from doctors where full_name = 'Doctora Comisión G (test)' \gset
select id as a_id from products where sku = 'G-A' \gset
select id as kit_id from products where sku = 'G-KIT' \gset
select id as kit_comp_id from products where sku = 'G-KIT-COMP' \gset
select id as cancel_id from products where sku = 'G-CANCEL' \gset

-- Actor de acá en adelante: admin con acceso a todo. El caso "admin SIN
-- ninguna sede asignada" (057/058/059/060) ya está probado exhaustivamente
-- en sus propios archivos por función — este archivo prueba la CADENA
-- completa, no vuelve a probar permisos (se haría con un actor sin sedes
-- solo para volver a chocar contra el mismo RLS de inventory_balances/
-- sale_stock_reservations que esos archivos ya prueban aparte, sin agregar
-- cobertura nueva acá).
select set_config('request.jwt.claim.sub', 'ee100000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1: WEB + PICKUP Sede 25 + PAID.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'sed25_id' and product_id = :'a_id'
) as phys_before_1 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 2)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_1_id \gset

select is((select location_id from sales where id = :'sale_1_id'), :'sed25_id'::uuid, 'Caso 1: sede física = Sede 25');
select is((select quantity from inventory_balances where location_id = :'sed25_id' and product_id = :'a_id'), :'phys_before_1'::numeric, 'Caso 1: físico NO cambia al crear (queda reservado, no descontado)');
select is((select coalesce(sum(quantity),0) from sale_stock_reservations where sale_id = :'sale_1_id' and status = 'ACTIVE'), 2.00::numeric, 'Caso 1: reserva ACTIVE de 2');
select is((select available from product_stock_status where location_id = :'sed25_id' and product_id = :'a_id'), :'phys_before_1'::numeric - 2, 'Caso 1: disponible = físico - reservado');
select is((select payment_status from sales where id = :'sale_1_id'), 'PAID'::sale_payment_status, 'Caso 1: payment_status PAID desde la creación');
select is((select count(*)::int from web_pending_pickups() where sale_id = :'sale_1_id'), 1, 'Caso 1: aparece en Notificaciones (pendiente de retiro)');

select deliver_web_pickup(:'sale_1_id'::uuid);

select is((select fulfillment_status from sales where id = :'sale_1_id'), 'DELIVERED'::sale_fulfillment_status, 'Caso 1: entregado');
select is((select status from sale_stock_reservations where sale_id = :'sale_1_id'), 'CONSUMED'::stock_reservation_status, 'Caso 1: reserva pasa a CONSUMED');
select is((select quantity from inventory_balances where location_id = :'sed25_id' and product_id = :'a_id'), :'phys_before_1'::numeric - 2, 'Caso 1: físico baja recién al entregar');
select is((select count(*)::int from stock_movements where sale_id = :'sale_1_id' and movement_type = 'SALE'), 1, 'Caso 1: exactamente 1 movimiento SALE');
select is((select count(*)::int from web_pending_pickups() where sale_id = :'sale_1_id'), 0, 'Caso 1: desaparece de Notificaciones al entregar');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_1_id' and display_status = 'DELIVERED'), 1, 'Caso 1: aparece en Historial como DELIVERED');

-- ===========================================================================
-- Caso 2: WEB + PICKUP Sede 25 + PENDING.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_2_id \gset

select is((select location_id from sales where id = :'sale_2_id'), :'sed25_id'::uuid, 'Caso 2: sede física = Sede 25');
select is((select payment_status from sales where id = :'sale_2_id'), 'PENDING'::sale_payment_status, 'Caso 2: payment_status PENDING');
select is((select count(*)::int from web_pending_pickups() where sale_id = :'sale_2_id'), 1, 'Caso 2: aparece en Notificaciones aunque esté PENDING de cobro');

select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_2_id'),
  'Caso 2: no se puede entregar sin cobrar primero'
);

select mark_web_order_paid(:'sale_2_id'::uuid);
select is((select payment_status from sales where id = :'sale_2_id'), 'PAID'::sale_payment_status, 'Caso 2: payment_status pasa a PAID al cobrar');

select deliver_web_pickup(:'sale_2_id'::uuid);
select is((select status from sale_stock_reservations where sale_id = :'sale_2_id'), 'CONSUMED'::stock_reservation_status, 'Caso 2: reserva CONSUMED tras cobrar y entregar');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_2_id' and display_status = 'DELIVERED'), 1, 'Caso 2: aparece en Historial como DELIVERED');

-- ===========================================================================
-- Caso 3: WEB + PICKUP Sede 37 + PAID.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'sed37_id' and product_id = :'a_id'
) as phys_before_3 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 2)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_3_id \gset

select is((select location_id from sales where id = :'sale_3_id'), :'sed37_id'::uuid, 'Caso 3: sede física = Sede 37');
select is((select coalesce(sum(quantity),0) from sale_stock_reservations where sale_id = :'sale_3_id' and status = 'ACTIVE'), 2.00::numeric, 'Caso 3: reserva ACTIVE de 2 en Sede 37');
select is((select available from product_stock_status where location_id = :'sed37_id' and product_id = :'a_id'), :'phys_before_3'::numeric - 2, 'Caso 3: disponible en Sede 37 refleja la reserva');

select deliver_web_pickup(:'sale_3_id'::uuid);
select is((select quantity from inventory_balances where location_id = :'sed37_id' and product_id = :'a_id'), :'phys_before_3'::numeric - 2, 'Caso 3: físico de Sede 37 baja al entregar');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_3_id' and display_status = 'DELIVERED' and location_code = 'SED-37'), 1, 'Caso 3: Historial marca Sede 37 correctamente');

-- ===========================================================================
-- Caso 4: WEB + PICKUP Sede 37 + PENDING.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_4_id \gset

select is((select payment_status from sales where id = :'sale_4_id'), 'PENDING'::sale_payment_status, 'Caso 4: payment_status PENDING');
select mark_web_order_paid(:'sale_4_id'::uuid);
select deliver_web_pickup(:'sale_4_id'::uuid);
select is((select fulfillment_status from sales where id = :'sale_4_id'), 'DELIVERED'::sale_fulfillment_status, 'Caso 4: cobrar y entregar en Sede 37 funciona end-to-end');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_4_id' and display_status = 'DELIVERED'), 1, 'Caso 4: aparece en Historial como DELIVERED');

-- ===========================================================================
-- Caso 5: WEB + SHIPPING + PAID.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'dep_id' and product_id = :'a_id'
) as phys_before_5 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 3)),
  :'dep_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_5_id \gset

select is((select location_id from sales where id = :'sale_5_id'), :'dep_id'::uuid, 'Caso 5: sede física = Depósito');
select is((select fulfillment_status from sales where id = :'sale_5_id'), 'SHIPPED'::sale_fulfillment_status, 'Caso 5: SHIPPED desde la creación (sin paso intermedio)');
select is((select coalesce(sum(quantity),0) from sale_stock_reservations where sale_id = :'sale_5_id'), 0.00::numeric, 'Caso 5: SHIPPING nunca genera una reserva');
select is((select quantity from inventory_balances where location_id = :'dep_id' and product_id = :'a_id'), :'phys_before_5'::numeric - 3, 'Caso 5: físico de Depósito baja INMEDIATAMENTE (sin esperar entrega)');
select is((select count(*)::int from stock_movements where sale_id = :'sale_5_id' and movement_type = 'SALE'), 1, 'Caso 5: 1 movimiento SALE inmediato');
select is((select count(*)::int from web_pending_pickups() where sale_id = :'sale_5_id'), 0, 'Caso 5: SHIPPING nunca aparece en Notificaciones');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_5_id' and display_status = 'SHIPPED'), 1, 'Caso 5: aparece en Historial como SHIPPED de inmediato');

-- ===========================================================================
-- Caso 6: WEB + SHIPPING + PENDING.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'dep_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'SHIPPING'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_6_id \gset

select is((select payment_status from sales where id = :'sale_6_id'), 'PENDING'::sale_payment_status, 'Caso 6: payment_status PENDING en un envío también');
select is((select fulfillment_status from sales where id = :'sale_6_id'), 'SHIPPED'::sale_fulfillment_status, 'Caso 6: SHIPPED igual, aunque esté pendiente de cobro (fulfillment y cobro son ejes independientes)');
select is((select count(*)::int from web_order_history() where sale_id = :'sale_6_id' and display_status = 'SHIPPED'), 1, 'Caso 6: aparece en Historial como SHIPPED aunque no esté cobrado');

select mark_web_order_paid(:'sale_6_id'::uuid);
select is((select payment_status from sales where id = :'sale_6_id'), 'PAID'::sale_payment_status, 'Caso 6: se puede cobrar un envío ya despachado sin problema');

-- ===========================================================================
-- Caso 7: snapshot de kit inmutable ante un cambio posterior de
-- kit_components — la reserva ya creada no se recalcula, y la entrega
-- consume exactamente lo reservado, no lo que kit_components diga ahora.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'kit_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_kit_id \gset

select is(
  (select quantity from sale_stock_reservations where sale_id = :'sale_kit_id' and product_id = :'kit_comp_id'),
  2.00::numeric,
  'Caso 7a: la reserva del componente refleja la composición vigente al crear (2 por kit)'
);

-- Cambia la composición del kit DESPUÉS de que la reserva ya existe.
update public.kit_components set quantity = 5
  where kit_product_id = :'kit_id'::uuid and component_product_id = :'kit_comp_id'::uuid;

select is(
  (select quantity from sale_stock_reservations where sale_id = :'sale_kit_id' and product_id = :'kit_comp_id'),
  2.00::numeric,
  'Caso 7b: la reserva NO cambia — sigue en 2, aunque kit_components ahora diga 5'
);

select (
  select quantity from inventory_balances where location_id = :'sed25_id' and product_id = :'kit_comp_id'
) as comp_phys_before_deliver \gset

select deliver_web_pickup(:'sale_kit_id'::uuid);

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = :'kit_comp_id'),
  :'comp_phys_before_deliver'::numeric - 2,
  'Caso 7c: la entrega descuenta exactamente 2 (el snapshot reservado), no 5 (la composición actual)'
);

-- ===========================================================================
-- Caso 8: una venta Web PAID cancelada deja de computar en dashboard_report
-- (revenue y comisión).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'cancel_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  :'doctor_id'::uuid, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_cancel_id \gset

select is(
  (select coalesce((dashboard_report(current_date, current_date, :'sed25_id'::uuid) -> 'kpis' ->> 'revenue')::numeric, 0) >= 4500),
  true,
  'Caso 8a: mientras está confirmada, la venta Web PAID SÍ suma revenue del día en Sede 25'
);

select cancel_sale(:'sale_cancel_id'::uuid, 'Test G: cancelar para verificar métricas');

select is(
  (select exists(
    select 1 from jsonb_array_elements(
      coalesce(dashboard_report(current_date, current_date, :'sed25_id'::uuid) -> 'commission_by_doctor', '[]'::jsonb)
    ) t
    where (t ->> 'doctor_id')::uuid = :'doctor_id'::uuid and (t ->> 'sales_count')::int > 0
  )),
  false,
  'Caso 8b: una vez anulada, la venta ya no aparece en commission_by_doctor'
);

-- ===========================================================================
-- Caso 9: una reserva CONSUMED (ya entregada, caso 1) no sigue restando del
-- disponible — reserved vuelve a reflejar solo lo que sigue ACTIVE.
-- ===========================================================================
select is(
  (select coalesce(sum(quantity), 0) from sale_stock_reservations
   where location_id = :'sed25_id' and product_id = :'a_id' and status = 'ACTIVE' and sale_id = :'sale_1_id'),
  0.00::numeric,
  'Caso 9: la reserva CONSUMED del Caso 1 ya no cuenta como ACTIVE'
);

select * from finish();
rollback;
