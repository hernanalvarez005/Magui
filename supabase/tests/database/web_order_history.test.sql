-- pgTAP: web_order_history (BLOQUE E — Historial de pedidos Web).
-- Casos, en orden:
--   1) Admin sin ninguna sede asignada ve DELIVERED + SHIPPED + CANCELLED
--      (las 3 sedes), nunca un PENDING_PICKUP confirmado.
--   2) Vendedora de Sede 25 ve solo los registros de Sede 25.
--   3) Filtro por estado DELIVERED.
--   4) Filtro por estado SHIPPED.
--   5) Filtro por estado CANCELLED.
--   6) Filtro por sede (p_location_id).
--   7) Búsqueda por DNI.
--   8) Búsqueda por número de venta.
--   9) Filtro de fecha: un rango futuro no matchea nada.
--   10) Paginación: limit=1 devuelve 1 fila pero total_count refleja el
--       total real (3), no el tamaño de la página.
--   11) Estado inválido rechazado.
--   12) Datos completos de un DELIVERED: cliente, DNI, items, total, medio
--       de pago, payment_status, sede, quién entregó, quién cargó.
--   13) SHIPPING: delivered_at/delivered_by_name quedan NULL (no hay fecha
--       ni actor de envío separados en el modelo — hallazgo de auditoría,
--       nunca se inventa un valor).
--   14) Viewer de Sede 25 SÍ puede leer el historial de su sede.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(18);

insert into auth.users (id, email) values
  ('bb000000-0000-0000-0000-000000000001', 'admin.sinsede.hist@test.maguirejuve.com'),
  ('bb000000-0000-0000-0000-000000000002', 'seller25.hist@test.maguirejuve.com'),
  ('bb000000-0000-0000-0000-000000000003', 'viewer25.hist@test.maguirejuve.com'),
  ('bb000000-0000-0000-0000-000000000004', 'admin.setup.hist@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true, full_name = 'Admin Sin Sede Historial (test)' where id = 'bb000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true, full_name = 'Vendedora Sede 25 Historial (test)' where id = 'bb000000-0000-0000-0000-000000000002';
update public.profiles set role = 'viewer', active = true, full_name = 'Viewer Sede 25 Historial (test)' where id = 'bb000000-0000-0000-0000-000000000003';
update public.profiles set role = 'admin', active = true, full_name = 'Admin Setup Historial (test)' where id = 'bb000000-0000-0000-0000-000000000004';
-- bb...001 (admin bajo prueba) NO recibe NINGUNA fila en profile_locations
-- a propósito.
insert into public.profile_locations (profile_id, location_id)
  select 'bb000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'bb000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'SED-25';
insert into public.profile_locations (profile_id, location_id)
  select 'bb000000-0000-0000-0000-000000000004', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'bb000000-0000-0000-0000-000000000004', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('HIST-A', 'Producto Historial A', 'product', 'Test', true, true, false, true);
select set_product_price((select id from products where sku = 'HIST-A'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'HIST-A'), (select id from price_conditions where code = 'CASH'), 4500);

insert into public.customers (full_name, dni) values ('Clienta Historial Perez (test)', '30666622');

select set_stock((select id from stock_locations where code = 'SED-25'), (select id from products where sku = 'HIST-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'HIST-A'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'HIST-A'), 20, 'RECEPTION');

select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as dep_id from stock_locations where code = 'DEP' \gset
select id as cash_method_id from payment_methods where code = 'CASH' \gset
select id as customer_id from customers where dni = '30666622' \gset
select id as a_id from products where sku = 'HIST-A' \gset

-- Sede 25: PICKUP entregado.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 2)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_delivered_id \gset
select deliver_web_pickup(:'sale_delivered_id'::uuid);

-- Sede 25: PICKUP cancelado ANTES de retirar (nunca llegó a DELIVERED).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed25_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_cancelled_id \gset
select cancel_sale(:'sale_cancelled_id'::uuid, 'Clienta se arrepintió (test)');

-- Sede 37: PICKUP todavía pendiente — NUNCA debe aparecer en Historial.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'sed37_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_pending_id \gset

-- Depósito: SHIPPING.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', :'a_id'::uuid, 'quantity', 1)),
  :'dep_id'::uuid, :'web_channel_id'::uuid, :'cash_method_id'::uuid, :'customer_id'::uuid,
  null, null, null, null, now(), false, null, null, false, null,
  'SHIPPING'::sale_fulfillment_type, 'PAID'::sale_payment_status
) ->> 'sale_id')::uuid as sale_shipped_id \gset

-- Capturado ACÁ (todavía como admin.setup, con acceso real a Depósito) —
-- el Caso 8 de más abajo corre como el admin SIN sedes (bb...001), y un
-- select crudo a sales para "buscar el sale_number" quedaría bloqueado por
-- RLS para ese admin (el mismo motivo estructural de siempre). Se captura
-- antes, nunca se vuelve a leer sales directo más abajo.
select sale_number as sale_shipped_number from sales where id = :'sale_shipped_id' \gset

-- ===========================================================================
-- Caso 1: admin sin ninguna sede asignada ve los 3 (delivered+cancelled+
-- shipped), nunca el pendiente.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'bb000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from web_order_history()),
  3,
  'Caso 1: admin sin sedes asignadas ve los 3 registros históricos (delivered+cancelled+shipped)'
);

select is(
  (select count(*)::int from web_order_history() where sale_id = :'sale_pending_id'),
  0,
  'Caso 1b: el pickup todavía pendiente de Sede 37 nunca aparece en Historial'
);

-- ===========================================================================
-- Caso 2: vendedora de Sede 25 ve solo Sede 25 (delivered + cancelled),
-- nunca el SHIPPED de Depósito.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'bb000000-0000-0000-0000-000000000002', false);

select is(
  (select count(*)::int from web_order_history()),
  2,
  'Caso 2: vendedora de Sede 25 ve exactamente 2 registros (delivered + cancelled de su sede)'
);

select is(
  (select count(*)::int from web_order_history() where sale_id in (:'sale_delivered_id', :'sale_cancelled_id')),
  2,
  'Caso 2b: son exactamente los 2 registros esperados de Sede 25'
);

select is(
  (select count(*)::int from web_order_history() where sale_id = :'sale_shipped_id'),
  0,
  'Caso 2c: la vendedora de Sede 25 nunca ve el envío de Depósito'
);

-- ===========================================================================
-- Casos 3-5: filtro por estado (vuelvo a admin).
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'bb000000-0000-0000-0000-000000000001', false);

select is(
  (select array_agg(sale_id) from web_order_history(null, 'DELIVERED')),
  array[:'sale_delivered_id'::uuid],
  'Caso 3: filtro DELIVERED devuelve únicamente el pickup entregado'
);

select is(
  (select array_agg(sale_id) from web_order_history(null, 'SHIPPED')),
  array[:'sale_shipped_id'::uuid],
  'Caso 4: filtro SHIPPED devuelve únicamente el envío'
);

select is(
  (select array_agg(sale_id) from web_order_history(null, 'CANCELLED')),
  array[:'sale_cancelled_id'::uuid],
  'Caso 5: filtro CANCELLED devuelve únicamente el pickup anulado'
);

-- ===========================================================================
-- Caso 6: filtro por sede (Depósito) devuelve solo el envío.
-- ===========================================================================
select is(
  (select array_agg(sale_id) from web_order_history(:'dep_id'::uuid)),
  array[:'sale_shipped_id'::uuid],
  'Caso 6: filtro por sede Depósito devuelve únicamente el envío'
);

-- ===========================================================================
-- Caso 7: búsqueda por DNI.
-- ===========================================================================
select is(
  (select count(*)::int from web_order_history(null, null, null, null, '666622')),
  3,
  'Caso 7: búsqueda por DNI parcial devuelve los 3 registros de esa clienta'
);

-- ===========================================================================
-- Caso 8: búsqueda por número de venta.
-- ===========================================================================
select is(
  (select array_agg(sale_id) from web_order_history(null, null, null, null, :'sale_shipped_number')),
  array[:'sale_shipped_id'::uuid],
  'Caso 8: búsqueda por número de venta exacto devuelve solo esa venta'
);

-- ===========================================================================
-- Caso 9: filtro de fecha — un rango futuro no matchea nada.
-- ===========================================================================
select is(
  (select count(*)::int from web_order_history(null, null, now() + interval '1 day', now() + interval '2 days')),
  0,
  'Caso 9: un rango de fecha futuro no matchea ningún registro'
);

-- ===========================================================================
-- Caso 10: paginación — limit=1 devuelve 1 fila, total_count sigue en 3.
-- ===========================================================================
select is(
  (select row(count(*)::int, max(total_count)::int) from web_order_history(null, null, null, null, null, 1, 0)),
  row(1, 3),
  'Caso 10: limit=1 devuelve 1 fila pero total_count refleja el total real (3), no el tamaño de página'
);

-- ===========================================================================
-- Caso 11: estado inválido rechazado.
-- ===========================================================================
select throws_ok(
  $$select * from web_order_history(null, 'BOGUS')$$,
  'Caso 11: un estado de historial inválido se rechaza'
);

-- ===========================================================================
-- Caso 12: datos completos del DELIVERED.
-- ===========================================================================
select is(
  (select row(customer_name, customer_dni, total, payment_method_name, payment_status, display_status, location_code, delivered_by_name, seller_name)
   from web_order_history() where sale_id = :'sale_delivered_id'),
  row(
    'Clienta Historial Perez (test)'::text, '30666622'::text, 9000.00::numeric, 'Efectivo'::text,
    'PAID'::sale_payment_status, 'DELIVERED'::text, 'SED-25'::text,
    'Admin Setup Historial (test)'::text, 'Admin Setup Historial (test)'::text
  ),
  'Caso 12: cliente, DNI, total, medio de pago, payment_status, estado, sede, quién entregó y quién cargó son correctos'
);

select is(
  (select items from web_order_history() where sale_id = :'sale_delivered_id'),
  '[{"is_kit": false, "quantity": 2.00, "product_name": "Producto Historial A"}]'::jsonb,
  'Caso 12b: items trae producto, cantidad e is_kit=false'
);

-- ===========================================================================
-- Caso 13: SHIPPING no tiene delivered_at/delivered_by_name — no se inventa
-- una fecha/actor de envío que el modelo no tiene.
-- ===========================================================================
select is(
  (select row(delivered_at, delivered_by_name) from web_order_history() where sale_id = :'sale_shipped_id'),
  row(null::timestamptz, null::text),
  'Caso 13: un SHIPPING nunca tiene delivered_at/delivered_by_name — no existen en el modelo, no se fabrican'
);

-- ===========================================================================
-- Caso 14: viewer de Sede 25 SÍ puede leer el historial de su sede.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'bb000000-0000-0000-0000-000000000003', false);

select is(
  (select count(*)::int from web_order_history()),
  2,
  'Caso 14: un viewer de Sede 25 puede leer el historial de su sede (delivered + cancelled)'
);

select * from finish();
rollback;
