-- pgTAP: BUGFIX PRIORITARIO — Cambios/Devoluciones: el reintegro de stock
-- podía saltearse EN SILENCIO cuando la cantidad proporcional calculada
-- resolvía <= 0, o cuando el loop de reintegro no encontraba NINGÚN
-- movimiento SALE que reintegrar. Ninguno de los dos casos generaba una
-- excepción — la operación completaba "exitosamente" habiendo descontado el
-- producto nuevo sin reintegrar el viejo.
--
-- IMPORTANTE (a diferencia de exchange_legacy_stock_reversal.test.sql): acá
-- se verifica el VALOR EXACTO de quantity_delta en cada RETURN, no solo que
-- la fila exista o que el conteo de movimientos sea correcto — es
-- exactamente lo que el bug reportado (aunque resultó no reproducible como
-- fila persistida — ver informe) pedía cubrir explícitamente.
--
-- Casos (PASO D del pedido), en orden:
--   1) Producto simple x1 -> RETURN +1 exacto, SALE -1 exacto, saldos finales correctos
--   2) Venta x3, devuelve 1 -> RETURN +1 exacto (nunca +3 ni 0)
--   3) Venta x3, devuelve 2 -> RETURN +2 exacto
--   4) Kit x2, devuelve 1 -> cada componente físico reintegra su cantidad EXACTA
--   5) Kit + unidad suelta del mismo componente en un mismo carrito, se
--      cambia solo el kit -> reintegra SOLO la porción del kit, nunca toca
--      la unidad suelta
--   6) Cambio encadenado A -> B -> C, cada devolución con cantidad exacta > 0
--   7) Forzado "root sin movimientos" -> EXCEPTION + ROLLBACK, nunca RETURN 0
--   8) Forzado cálculo que resuelve <= 0 -> EXCEPTION, nunca se inserta el movimiento
--   9) create_sale_return (devolución pura) comparte la misma causa raíz ->
--      mismo comportamiento: RETURN exacto en caso normal, EXCEPTION si
--      resuelve <= 0
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente, o supabase
-- test db en CI.
begin;
select plan(30);

insert into auth.users (id, email) values
  ('fc000000-0000-0000-0000-000000000001', 'admin.qtyguard@test.maguirejuve.com'),
  ('fc000000-0000-0000-0000-000000000002', 'seller.qtyguard@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fc000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fc000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fc000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fc000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-37';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('QTY-NIA', 'Serum Niacinamida QtyGuard', 'product', 'Test', true, true, false, true),
  ('QTY-EXF', 'Serum Exfoliante QtyGuard', 'product', 'Test', true, true, false, true),
  ('QTY-CREMA', 'Crema Componente QtyGuard', 'product', 'Test', true, true, false, true),
  ('QTY-SERUM', 'Serum Componente QtyGuard', 'product', 'Test', true, true, false, true),
  ('QTY-KIT', 'Kit QtyGuard', 'kit', 'Test', false, true, false, true),
  ('QTY-NEW2', 'Producto Nuevo Encadenado QtyGuard', 'product', 'Test', true, true, false, true),
  ('QTY-TINY', 'Producto Cantidad Diminuta QtyGuard', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'QTY-KIT'), (select id from products where sku = 'QTY-CREMA'), 2),
  ((select id from products where sku = 'QTY-KIT'), (select id from products where sku = 'QTY-SERUM'), 1);

select set_product_price((select id from products where sku = 'QTY-NIA'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'QTY-NIA'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'QTY-EXF'), (select id from price_conditions where rule_type = 'BASE'), 12000);
select set_product_price((select id from products where sku = 'QTY-EXF'), (select id from price_conditions where code = 'CASH'), 10800);
select set_product_price((select id from products where sku = 'QTY-CREMA'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'QTY-CREMA'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'QTY-SERUM'), (select id from price_conditions where rule_type = 'BASE'), 3000);
select set_product_price((select id from products where sku = 'QTY-SERUM'), (select id from price_conditions where code = 'CASH'), 2700);
select set_product_price((select id from products where sku = 'QTY-KIT'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'QTY-KIT'), (select id from price_conditions where code = 'CASH'), 18000);
select set_product_price((select id from products where sku = 'QTY-NEW2'), (select id from price_conditions where rule_type = 'BASE'), 8000);
select set_product_price((select id from products where sku = 'QTY-NEW2'), (select id from price_conditions where code = 'CASH'), 7200);
select set_product_price((select id from products where sku = 'QTY-TINY'), (select id from price_conditions where rule_type = 'BASE'), 1000);
select set_product_price((select id from products where sku = 'QTY-TINY'), (select id from price_conditions where code = 'CASH'), 900);

insert into public.customers (full_name, dni) values ('Clienta QtyGuard (test)', '30999888');

select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-NIA'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-EXF'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-CREMA'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-SERUM'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-NEW2'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'SED-37'), (select id from products where sku = 'QTY-TINY'), 50, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1: producto simple x1 -> RETURN +1 EXACTO, SALE -1 EXACTO.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_1_id \gset
select id as item_1_id from sale_items where sale_id = :'sale_1_id' \gset

select create_sale_exchange(
  :'sale_1_id'::uuid, :'item_1_id'::uuid, 1,
  (select id from products where sku = 'QTY-EXF'), 1
) as result_1 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_1_id'
    order by created_at desc limit 1),
  1.00::numeric,
  'Caso 1: quantity_delta del RETURN es EXACTAMENTE +1.00, no 0 ni ningún otro valor'
);
select is(
  (select quantity_delta from stock_movements
    where movement_type = 'SALE' and product_id = (select id from products where sku = 'QTY-EXF')
      and sale_id = (select id from sales where replaces_sale_id = :'sale_1_id')),
  -1.00::numeric,
  'Caso 1: quantity_delta del SALE del producto nuevo es EXACTAMENTE -1.00'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-NIA')),
  50.00::numeric,
  'Caso 1: saldo final de Niacinamida vuelve a 50 (49 tras la venta, +1 tras el reintegro)'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-EXF')),
  49.00::numeric,
  'Caso 1: saldo final de Exfoliante queda en 49 (50 - 1)'
);

-- ===========================================================================
-- Caso 2: venta x3, devuelve 1 -> RETURN +1 EXACTO (nunca +3 ni 0).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 3)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_2_id \gset
select id as item_2_id from sale_items where sale_id = :'sale_2_id' \gset

select create_sale_exchange(
  :'sale_2_id'::uuid, :'item_2_id'::uuid, 1,
  (select id from products where sku = 'QTY-EXF'), 1
) as result_2 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_2_id'
    order by created_at desc limit 1),
  1.00::numeric,
  'Caso 2: de una línea de 3 unidades se devuelve 1 -> RETURN es EXACTAMENTE +1.00 (nunca +3 ni 0)'
);
select is(
  (select quantity from sale_items where sale_id = (select id from sales where replaces_sale_id = :'sale_2_id') and product_id = (select id from products where sku = 'QTY-NIA')),
  2::numeric,
  'Caso 2: quedan 2 unidades como línea "remainder" en la venta de reemplazo'
);

-- ===========================================================================
-- Caso 3: venta x3, devuelve 2 -> RETURN +2 EXACTO.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 3)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_3_id \gset
select id as item_3_id from sale_items where sale_id = :'sale_3_id' \gset

select create_sale_exchange(
  :'sale_3_id'::uuid, :'item_3_id'::uuid, 2,
  (select id from products where sku = 'QTY-EXF'), 1
) as result_3 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_3_id'
    order by created_at desc limit 1),
  2.00::numeric,
  'Caso 3: de una línea de 3 unidades se devuelven 2 -> RETURN es EXACTAMENTE +2.00'
);

-- ===========================================================================
-- Caso 4: kit x2, devuelve 1 -> cada componente físico reintegra su cantidad
-- EXACTA (CREMA: 2 por kit x1 kit devuelto = +2.00; SERUM: 1 por kit x1 = +1.00).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-KIT'), 'quantity', 2)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_4_id \gset
select id as item_4_id from sale_items where sale_id = :'sale_4_id' \gset

select create_sale_exchange(
  :'sale_4_id'::uuid, :'item_4_id'::uuid, 1,
  (select id from products where sku = 'QTY-EXF'), 1
) as result_4 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-CREMA')
      and sale_id = :'sale_4_id'
    order by created_at desc limit 1),
  2.00::numeric,
  'Caso 4: de un kit x2 se devuelve 1 -> CREMA reintegra EXACTAMENTE +2.00 (2 por kit, proporcional)'
);
select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-SERUM')
      and sale_id = :'sale_4_id'
    order by created_at desc limit 1),
  1.00::numeric,
  'Caso 4: de un kit x2 se devuelve 1 -> SERUM reintegra EXACTAMENTE +1.00 (1 por kit, proporcional)'
);

-- ===========================================================================
-- Caso 5: kit + unidad suelta del MISMO componente en un mismo carrito. Se
-- cambia solo el kit -> reintegra SOLO la porción del kit (CREMA +2), la
-- unidad suelta de CREMA vendida aparte no se toca para nada.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'QTY-KIT'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'QTY-CREMA'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_5_id \gset
select id as item_5_kit_id from sale_items
  where sale_id = :'sale_5_id' and product_id = (select id from products where sku = 'QTY-KIT') \gset
select id as item_5_standalone_id from sale_items
  where sale_id = :'sale_5_id' and product_id = (select id from products where sku = 'QTY-CREMA') \gset

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-CREMA')) as crema_before_5 \gset

select create_sale_exchange(
  :'sale_5_id'::uuid, :'item_5_kit_id'::uuid, 1,
  (select id from products where sku = 'QTY-EXF'), 1
) as result_5 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-CREMA')
      and sale_id = :'sale_5_id'
    order by created_at desc limit 1),
  2.00::numeric,
  'Caso 5: se cambia solo el kit (no la unidad suelta) -> reintegra EXACTAMENTE +2.00 de CREMA (la porción del kit)'
);
select is(
  (select count(*)::int from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-CREMA')
      and sale_id = :'sale_5_id'),
  1,
  'Caso 5: un solo movimiento RETURN de CREMA (no dos) — la unidad suelta vendida aparte no generó ningún reintegro'
);
select is(
  (select quantity from sale_items where id = :'item_5_standalone_id'),
  1::numeric,
  'Caso 5: la línea de CREMA vendida suelta sigue intacta en la venta original (nunca se tocó)'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-CREMA')),
  (:crema_before_5::numeric + 2),
  'Caso 5: el saldo de CREMA solo subió +2 (la porción del kit), no +3 ni ningún otro valor'
);

-- ===========================================================================
-- Caso 6: cambio encadenado A -> B -> C. Cada devolución (1+1) reintegra una
-- cantidad exacta y positiva, siguiendo physical_source_sale_item_id.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 2)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_a_id \gset
select id as item_a_id from sale_items where sale_id = :'sale_a_id' \gset

-- Cambio 1: A -> B (devuelve 1 de 2).
select (create_sale_exchange(
  :'sale_a_id'::uuid, :'item_a_id'::uuid, 1,
  (select id from products where sku = 'QTY-EXF'), 1
) ->> 'sale_id')::uuid as sale_b_id \gset

select id as item_b_remainder_id from sale_items
  where sale_id = :'sale_b_id' and product_id = (select id from products where sku = 'QTY-NIA') \gset

-- Cambio 2: B (línea remanente) -> C.
select (create_sale_exchange(
  :'sale_b_id'::uuid, :'item_b_remainder_id'::uuid, 1,
  (select id from products where sku = 'QTY-NEW2'), 1
) ->> 'sale_id')::uuid as sale_c_id \gset

-- Nota: cada RETURN de la cadena queda con sale_id = la venta sobre la que
-- se INVOCÓ ese cambio puntual (A para el primero, B para el segundo) —
-- nunca necesariamente la raíz física A —, aunque ambos, por
-- physical_source_sale_item_id, terminan reintegrando contra el mismo
-- movimiento SALE original de A. Por eso se busca por sale_id in (A, B).
select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_a_id'
    order by created_at asc limit 1),
  1.00::numeric,
  'Caso 6: primera devolución (A -> B) reintegra EXACTAMENTE +1.00'
);
select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_b_id'
    order by created_at desc limit 1),
  1.00::numeric,
  'Caso 6: segunda devolución (B remanente -> C) también reintegra EXACTAMENTE +1.00, siguiendo physical_source_sale_item_id hasta A'
);
select is(
  (select count(*)::int from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id in (:'sale_a_id', :'sale_b_id')),
  2,
  'Caso 6: exactamente 2 movimientos RETURN (uno por cada devolución de la cadena), ninguno en 0'
);

-- ===========================================================================
-- Caso 7: forzado "root sin movimientos" -> sale_item existe (con quantity y
-- sale_id resolubles) pero NINGÚN movimiento SALE coincide (ni vía exacta ni
-- fallback). Antes de este fix: 0 iteraciones, éxito silencioso, sin
-- reintegrar nada. Ahora: EXCEPTION, rollback completo, nunca un RETURN 0.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_7_id \gset
select id as item_7_id from sale_items where sale_id = :'sale_7_id' \gset

-- Se borra TODO rastro de movimientos SALE de esta línea (simula un dato
-- corrupto/huérfano: el sale_item existe, pero su historial de stock no).
reset role;
delete from stock_movements where sale_id = :'sale_7_id' and movement_type = 'SALE';
set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000002', false);

select (select count(*) from sale_items) as sale_items_count_before_7 \gset
select (select status from sales where id = :'sale_7_id') as sale_status_before_7 \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, (select id from products where sku = 'QTY-EXF'), 1)$$,
    :'sale_7_id', :'item_7_id'
  ),
  'Caso 7: si no hay NINGÚN movimiento de stock original para la línea raíz, la función lanza excepción (nunca sigue en silencio)'
);
select is(
  (select status from sales where id = :'sale_7_id'), :'sale_status_before_7'::sale_status,
  'Caso 7: tras el fallo, la venta original no cambió de estado'
);
select is(
  (select count(*) from sale_items)::int, :sale_items_count_before_7::int,
  'Caso 7: no quedó ninguna línea nueva huérfana — el rollback fue completo'
);
select is(
  (select count(*)::int from stock_movements
    where movement_type = 'RETURN' and sale_id = :'sale_7_id'),
  0,
  'Caso 7: no se insertó ningún RETURN (ni siquiera en 0 — es literalmente imposible, pero tampoco quedó ninguna fila)'
);

-- ===========================================================================
-- Caso 8: forzado cálculo que resuelve <= 0. Root con quantity=3 y un
-- movimiento SALE cuyo quantity_delta se manipula a -0.01 (el mínimo no-cero
-- representable en numeric(14,2)) -> round(1 * 0.01 / 3, 2) = 0.00. Antes:
-- guard mudo, se saltea sin avisar. Ahora: EXCEPTION antes de aplicar nada.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-TINY'), 'quantity', 3)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_8_id \gset
select id as item_8_id from sale_items where sale_id = :'sale_8_id' \gset

reset role;
update stock_movements set quantity_delta = -0.01
  where sale_id = :'sale_8_id' and movement_type = 'SALE'
    and product_id = (select id from products where sku = 'QTY-TINY');
set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000002', false);

select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-TINY')) as tiny_before_8 \gset
select (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-EXF')) as exf_before_8 \gset
select (select count(*) from sale_items) as sale_items_count_before_8 \gset
select (select status from sales where id = :'sale_8_id') as sale_status_before_8 \gset

select throws_ok(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 1, (select id from products where sku = 'QTY-EXF'), 1)$$,
    :'sale_8_id', :'item_8_id'
  ),
  'Caso 8: si la proporción calculada resuelve <= 0, la función lanza excepción — nunca inserta un RETURN en 0'
);
select is(
  (select count(*)::int from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-TINY')
      and sale_id = :'sale_8_id'),
  0,
  'Caso 8: no quedó insertado ningún RETURN (ni en 0 ni en ningún otro valor) para el producto diminuto'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-TINY')),
  :tiny_before_8::numeric,
  'Caso 8: el saldo del producto devuelto no se modificó'
);
select is(
  (select quantity from inventory_balances where location_id=(select id from stock_locations where code='SED-37') and product_id=(select id from products where sku='QTY-EXF')),
  :exf_before_8::numeric,
  'Caso 8: el producto nuevo tampoco se descontó — nunca "nuevo descontado + viejo no reintegrado"'
);
select is(
  (select status from sales where id = :'sale_8_id'), :'sale_status_before_8'::sale_status,
  'Caso 8: la venta original sigue con su estado previo, no quedó replaced a medias'
);
select is(
  (select count(*) from sale_items)::int, :sale_items_count_before_8::int,
  'Caso 8: no quedó ninguna línea de venta de reemplazo huérfana'
);

-- ===========================================================================
-- Caso 9: create_sale_return (devolución pura) comparte la misma causa raíz
-- -> mismo bugfix aplicado, mismo comportamiento verificado.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-NIA'), 'quantity', 1)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_9_id \gset
select id as item_9_id from sale_items where sale_id = :'sale_9_id' \gset

select create_sale_return(
  :'sale_9_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_9_id'::uuid, 'quantity', 1)),
  'CASH'::sale_refund_method
) as result_9 \gset

select is(
  (select quantity_delta from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-NIA')
      and sale_id = :'sale_9_id'
    order by created_at desc limit 1),
  1.00::numeric,
  'Caso 9a (create_sale_return): devolución simple reintegra EXACTAMENTE +1.00'
);

-- Caso 9b: mismo forzado de cálculo <= 0 que el Caso 8, pero en create_sale_return.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'QTY-TINY'), 'quantity', 3)),
  (select id from stock_locations where code = 'SED-37'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999888')
) ->> 'sale_id')::uuid as sale_9b_id \gset
select id as item_9b_id from sale_items where sale_id = :'sale_9b_id' \gset

reset role;
update stock_movements set quantity_delta = -0.01
  where sale_id = :'sale_9b_id' and movement_type = 'SALE'
    and product_id = (select id from products where sku = 'QTY-TINY');
set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000002', false);

select (select count(*)::int from stock_movements
  where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-TINY')) as tiny_returns_before_9b \gset

select throws_ok(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH'::sale_refund_method)$$,
    :'sale_9b_id', :'item_9b_id'
  ),
  'Caso 9b (create_sale_return): si la proporción calculada resuelve <= 0, también lanza excepción'
);
select is(
  (select count(*)::int from stock_movements
    where movement_type = 'RETURN' and product_id = (select id from products where sku = 'QTY-TINY')),
  :tiny_returns_before_9b::int,
  'Caso 9b: no se insertó ningún RETURN nuevo tras el fallo'
);
select is(
  (select status from sales where id = :'sale_9b_id'), 'confirmed'::sale_status,
  'Caso 9b: la venta sigue confirmed, la devolución no quedó registrada a medias'
);

select * from finish();
rollback;
