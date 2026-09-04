-- pgTAP: Circuito Ventas Web / Fulfillment / Reservas — BLOQUE B (backend).
-- No cubre Notificaciones/UI (todavía no implementado, BLOQUE D en adelante).
-- Casos, en orden:
--   1) PICKUP simple: físico no baja al crear, reservado sube, disponible
--      baja; al entregar: consume reserva, físico baja, DELIVERED + auditoría.
--   2) PICKUP de kit: reserva EXACTA de cada componente físico (proporcional
--      a la composición histórica, nunca kit_components vigente).
--   3) PICKUP de kit + unidad suelta del mismo componente en un carrito
--      normal aparte: la reserva del kit nunca toca la unidad suelta.
--   4) SHIPPING: fuerza Depósito, descuenta físico de inmediato, SIN
--      reserva, fulfillment_status=SHIPPED desde la creación.
--   5) SHIPPING rechazado si location != Depósito.
--   6) PICKUP rechazado si location = Depósito.
--   7) Sobreventa (sección 29 del pedido): reservado = físico -> una venta
--      PRESENCIAL nueva de 1 unidad se rechaza aunque inventory_balances
--      todavía diga el valor físico completo.
--   8) payment_status=PENDING bloquea deliver_web_pickup (errcode P1003).
--   9) mark_web_order_paid: PENDING -> PAID, después sí se puede entregar.
--   10) Seguridad: vendedora de Sede 25 no puede entregar un pickup de
--       Sede 37 (has_location_access).
--   11) Doble entrega rechazada (ya DELIVERED).
--   12) cancel_sale sobre un pickup pendiente: libera la reserva, NUNCA
--       genera SALE, físico no cambia.
--   13) create_sale_exchange/create_sale_return rechazan una venta
--       PENDING_PICKUP; una vez DELIVERED, funcionan normal (venta común).
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente, o supabase
-- test db en CI.
begin;
select plan(36);

insert into auth.users (id, email) values
  ('fd000000-0000-0000-0000-000000000001', 'admin.webful@test.maguirejuve.com'),
  ('fd000000-0000-0000-0000-000000000002', 'seller25.webful@test.maguirejuve.com'),
  ('fd000000-0000-0000-0000-000000000003', 'seller37.webful@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fd000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fd000000-0000-0000-0000-000000000002';
update public.profiles set role = 'seller', active = true where id = 'fd000000-0000-0000-0000-000000000003';
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-37';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('WEB-A', 'Producto Web A', 'product', 'Test', true, true, false, true),
  ('WEB-COMP1', 'Componente Web 1', 'product', 'Test', true, true, false, true),
  ('WEB-COMP2', 'Componente Web 2', 'product', 'Test', true, true, false, true),
  ('WEB-KIT', 'Kit Web', 'kit', 'Test', false, true, false, true),
  ('WEB-TINY', 'Producto Web Sobreventa', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'WEB-KIT'), (select id from products where sku = 'WEB-COMP1'), 2),
  ((select id from products where sku = 'WEB-KIT'), (select id from products where sku = 'WEB-COMP2'), 1);

select set_product_price((select id from products where sku = 'WEB-A'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'WEB-A'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'WEB-COMP1'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'WEB-COMP1'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'WEB-COMP2'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'WEB-COMP2'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'WEB-KIT'), (select id from price_conditions where rule_type = 'BASE'), 13000);
select set_product_price((select id from products where sku = 'WEB-KIT'), (select id from price_conditions where code = 'CASH'), 11700);
select set_product_price((select id from products where sku = 'WEB-TINY'), (select id from price_conditions where rule_type = 'BASE'), 1000);
select set_product_price((select id from products where sku = 'WEB-TINY'), (select id from price_conditions where code = 'CASH'), 900);

insert into public.customers (full_name, dni) values ('Clienta Web Fulfillment (test)', '30999900');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WEB-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'WEB-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WEB-COMP1'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WEB-COMP2'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'WEB-A'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'WEB-TINY'), 2, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'WEB-TINY'), 2, 'RECEPTION');

-- Admin ejecuta todo lo de acá — canal Web es admin-only.
select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as presencial_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as dep_id from stock_locations where code = 'DEP' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30999900' \gset

-- ===========================================================================
-- Caso 1: PICKUP simple — físico NO baja al crear, reservado sube,
-- disponible baja. Al entregar: consume, físico baja, DELIVERED + auditoría.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-A')
) as a_physical_before_1 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_1_id \gset

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-A')),
  :a_physical_before_1::numeric,
  'Caso 1: al crear un PICKUP, el físico NO baja'
);
select is(
  (select coalesce(sum(quantity), 0) from sale_stock_reservations where sale_id = :'sale_1_id' and status = 'ACTIVE'),
  1.00::numeric,
  'Caso 1: la reserva ACTIVE queda en exactamente 1.00'
);
select is(
  (select status from sales where id = :'sale_1_id'),
  'confirmed'::sale_status,
  'Caso 1: sales.status queda confirmed (nunca se reutiliza draft)'
);
select is(
  (select fulfillment_status from sales where id = :'sale_1_id'),
  'PENDING_PICKUP'::sale_fulfillment_status,
  'Caso 1: fulfillment_status queda PENDING_PICKUP'
);
select is(
  (select count(*)::int from stock_movements where sale_id = :'sale_1_id' and movement_type = 'SALE'),
  0,
  'Caso 1: NO se generó ningún movimiento SALE todavía'
);

-- Cobrar y entregar.
select mark_web_order_paid(:'sale_1_id'::uuid);
select deliver_web_pickup(:'sale_1_id'::uuid) as deliver_result_1 \gset

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-A')),
  (:a_physical_before_1::numeric - 1),
  'Caso 1: al entregar, el físico SÍ baja (-1)'
);
select is(
  (select status from sale_stock_reservations where sale_id = :'sale_1_id'),
  'CONSUMED'::stock_reservation_status,
  'Caso 1: la reserva pasa a CONSUMED'
);
select is(
  (select fulfillment_status from sales where id = :'sale_1_id'),
  'DELIVERED'::sale_fulfillment_status,
  'Caso 1: fulfillment_status queda DELIVERED'
);
select is(
  (select delivered_by from sales where id = :'sale_1_id'),
  'fd000000-0000-0000-0000-000000000001'::uuid,
  'Caso 1: delivered_by queda registrado'
);
select isnt(
  (select delivered_at from sales where id = :'sale_1_id'),
  null,
  'Caso 1: delivered_at queda registrado'
);
select is(
  (select count(*)::int from audit_logs where entity_id = :'sale_1_id' and action = 'WEB_ORDER_DELIVERED'),
  1,
  'Caso 1: queda auditado WEB_ORDER_DELIVERED'
);

-- ===========================================================================
-- Caso 2: PICKUP de kit — reserva EXACTA de cada componente (2×COMP1, 1×COMP2).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-KIT'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_2_id \gset

select is(
  (select quantity from sale_stock_reservations where sale_id = :'sale_2_id' and product_id = (select id from products where sku = 'WEB-COMP1')),
  2.00::numeric,
  'Caso 2: kit reserva EXACTAMENTE 2.00 de COMP1'
);
select is(
  (select quantity from sale_stock_reservations where sale_id = :'sale_2_id' and product_id = (select id from products where sku = 'WEB-COMP2')),
  1.00::numeric,
  'Caso 2: kit reserva EXACTAMENTE 1.00 de COMP2'
);

-- ===========================================================================
-- Caso 3: kit + unidad suelta del MISMO componente en carritos separados —
-- la reserva del kit nunca toca la venta presencial de la unidad suelta.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-COMP1')
) as comp1_physical_before_3 \gset

select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000002', false);
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-COMP1'), 'quantity', 1)),
  :'sed25_id'::uuid, :'presencial_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid
) ->> 'sale_id')::uuid as sale_3_standalone_id \gset
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-COMP1')),
  (:comp1_physical_before_3::numeric - 1),
  'Caso 3: la venta presencial de la unidad suelta SÍ descuenta físico normal (-1), sin relación con la reserva del kit'
);
select is(
  (select count(*)::int from sale_stock_reservations where product_id = (select id from products where sku = 'WEB-COMP1') and sale_id = :'sale_3_standalone_id'::uuid),
  0,
  'Caso 3: la venta presencial de la unidad suelta NO generó ninguna reserva'
);

-- ===========================================================================
-- Caso 4: SHIPPING — fuerza Depósito, descuenta de inmediato, SIN reserva,
-- SHIPPED desde la creación.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'dep_id' and product_id = (select id from products where sku = 'WEB-A')
) as a_dep_before_4 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-A'), 'quantity', 1)),
  :'dep_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_4_id \gset

select is(
  (select quantity from inventory_balances where location_id = :'dep_id' and product_id = (select id from products where sku = 'WEB-A')),
  (:a_dep_before_4::numeric - 1),
  'Caso 4: SHIPPING descuenta físico de Depósito de inmediato (-1)'
);
select is(
  (select count(*)::int from sale_stock_reservations where sale_id = :'sale_4_id'),
  0,
  'Caso 4: SHIPPING no genera ninguna reserva'
);
select is(
  (select fulfillment_status from sales where id = :'sale_4_id'),
  'SHIPPED'::sale_fulfillment_status,
  'Caso 4: fulfillment_status queda SHIPPED desde la creación'
);
select is(
  (select count(*)::int from stock_movements where sale_id = :'sale_4_id' and movement_type = 'SALE'),
  1,
  'Caso 4: SÍ generó su movimiento SALE real de inmediato'
);

-- ===========================================================================
-- Caso 5: SHIPPING rechazado si la sede no es Depósito.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WEB-A'), :'sed25_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 5: SHIPPING con sede distinta de Depósito se rechaza'
);

-- ===========================================================================
-- Caso 6: PICKUP rechazado si la sede es Depósito.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid,
      null, null, null, null, now(), false, null, null, false, null,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'WEB-A'), :'dep_id', :'web_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 6: PICKUP en Depósito se rechaza'
);

-- ===========================================================================
-- Caso 7 (sobreventa, sección 29): SED-25 tiene 2 disponibles de WEB-TINY.
-- Un PICKUP reserva las 2 -> disponible = 0. Una venta PRESENCIAL nueva de 1
-- unidad se rechaza, aunque inventory_balances todavía diga 2 (físico).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-TINY'), 'quantity', 2)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_7_id \gset

select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-TINY')),
  2.00::numeric,
  'Caso 7: el físico de WEB-TINY en Sede 25 sigue en 2.00 (nada se descontó)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000002', false);
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'WEB-TINY'), :'sed25_id', :'presencial_channel_id', :'cash_method_id', :'customer_id'
  ),
  'Caso 7: venta presencial de 1 unidad se rechaza — disponible es 0 aunque físico diga 2'
);
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- Caso 8: payment_status=PENDING bloquea deliver_web_pickup.
-- ===========================================================================
select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_7_id'),
  'Caso 8: no se puede entregar un pedido con payment_status PENDING'
);

-- ===========================================================================
-- Caso 9: mark_web_order_paid pasa PENDING -> PAID, después sí se entrega.
-- ===========================================================================
select mark_web_order_paid(:'sale_7_id'::uuid);
select is(
  (select payment_status from sales where id = :'sale_7_id'::uuid),
  'PAID'::sale_payment_status,
  'Caso 9: payment_status pasa a PAID'
);
select lives_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_7_id'),
  'Caso 9: ya pagado, la entrega ahora sí funciona'
);

-- ===========================================================================
-- Caso 10 (seguridad): vendedora de Sede 25 no puede entregar un pickup de
-- Sede 37.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-A'), 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_10_id \gset

set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000002', false); -- seller de Sede 25
select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_10_id'),
  'Caso 10: vendedora de Sede 25 no puede entregar un pickup de Sede 37'
);
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000003', false); -- seller de Sede 37
select lives_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_10_id'),
  'Caso 10: vendedora de Sede 37 SÍ puede entregar su propio pickup'
);
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- Caso 11: doble entrega rechazada.
-- ===========================================================================
select throws_ok(
  format($$select deliver_web_pickup('%s'::uuid)$$, :'sale_10_id'),
  'Caso 11: un pedido ya DELIVERED no se puede volver a entregar'
);

-- ===========================================================================
-- Caso 12: cancel_sale sobre un pickup pendiente — libera la reserva, NUNCA
-- genera SALE, físico no cambia.
-- ===========================================================================
select (
  select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-A')
) as a_physical_before_12 \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
) ->> 'sale_id')::uuid as sale_12_id \gset

select cancel_sale(:'sale_12_id'::uuid, 'Cliente se arrepintió (test)');

select is(
  (select status from sale_stock_reservations where sale_id = :'sale_12_id'),
  'RELEASED'::stock_reservation_status,
  'Caso 12: la reserva pasa a RELEASED al cancelar'
);
select is(
  (select quantity from inventory_balances where location_id = :'sed25_id' and product_id = (select id from products where sku = 'WEB-A')),
  :a_physical_before_12::numeric,
  'Caso 12: el físico NO cambió al cancelar un pickup pendiente'
);
select is(
  (select count(*)::int from stock_movements where sale_id = :'sale_12_id' and movement_type = 'SALE'),
  0,
  'Caso 12: nunca se generó ningún movimiento SALE'
);
select is(
  (select status from sales where id = :'sale_12_id'),
  'cancelled'::sale_status,
  'Caso 12: sales.status queda cancelled'
);

-- ===========================================================================
-- Caso 13: create_sale_exchange/create_sale_return rechazan una venta
-- PENDING_PICKUP; una vez DELIVERED, funcionan como una venta común.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'WEB-A'), 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_13_id \gset
select id as item_13_id from sale_items where sale_id = :'sale_13_id' \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, (select id from products where sku = 'WEB-A'), 1)$$,
    :'sale_13_id', :'item_13_id'
  ),
  'Caso 13a: un pickup PENDING_PICKUP no admite create_sale_exchange'
);
select throws_ok(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH'::sale_refund_method)$$,
    :'sale_13_id', :'item_13_id'
  ),
  'Caso 13b: un pickup PENDING_PICKUP no admite create_sale_return'
);

select deliver_web_pickup(:'sale_13_id'::uuid);

select lives_ok(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH'::sale_refund_method)$$,
    :'sale_13_id', :'item_13_id'
  ),
  'Caso 13c: una vez DELIVERED, la venta funciona como cualquier venta normal (create_sale_return)'
);

select * from finish();
rollback;
