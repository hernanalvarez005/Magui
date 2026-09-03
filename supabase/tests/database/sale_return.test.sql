-- pgTAP: Devolución de producto — Bloque E (mecánica: cálculo, stock,
-- reintegro, estados, permisos). El cliente devuelve producto y recupera
-- dinero, sin llevarse nada a cambio — a diferencia de Cambios
-- (sale_exchange.test.sql), que NO se toca ni se repite acá.
-- Casos pedidos (secciones 40-44 + precisiones aprobadas):
--   1-2) devolución simple y devolución acumulada sobre la misma línea
--   3) exceso -> rechazo y rollback completo
--   4-5) kit proporcional + kit y componente suelto en la misma venta
--   6-7) devolución multi-línea en un mismo llamado + rechazo de duplicados
--   8-9) devolución total -> status='returned' vs. parcial que deja otra
--        línea con saldo -> sigue 'confirmed' (regla crítica, sección 19)
--   10-13) estados/origen inválidos: returned, cancelled, replaced, sin costo
--   14) viewer rechazado
--   15-16) forma de reintegro: TRANSFER exige cuenta, CASH la rechaza
--   17) cadena Cambio -> Devolución (physical_source_sale_item_id)
--   18) auditoría SALE_RETURN_CREATED
--   19) sale_item_net expone las 4 columnas exigidas
--   20) customer_sales_for_return: available_to_return + exclusión de sin costo
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(34);

insert into auth.users (id, email) values
  ('fd000000-0000-0000-0000-000000000001', 'admin.return@test.maguirejuve.com'),
  ('fd000000-0000-0000-0000-000000000002', 'seller.return@test.maguirejuve.com'),
  ('fd000000-0000-0000-0000-000000000003', 'viewer.return@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fd000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fd000000-0000-0000-0000-000000000002';
update public.profiles set role = 'viewer', active = true where id = 'fd000000-0000-0000-0000-000000000003';
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';
insert into public.profile_locations (profile_id, location_id)
  select 'fd000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed. promo_eligible=false a
-- propósito, mismo motivo que sale_exchange.test.sql.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-RET-P1', 'Producto Devolución Uno', 'product', 'Test', true, true, false, true),
  ('TEST-RET-P2', 'Producto Devolución Dos', 'product', 'Test', true, true, false, true),
  ('TEST-RET-KIT', 'Kit Devolución Test', 'kit', 'Test', false, true, false, true),
  ('TEST-RET-CREMA', 'Crema Componente Devolución', 'product', 'Test', true, true, false, true),
  ('TEST-RET-SERUM', 'Serum Componente Devolución', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'TEST-RET-KIT'), (select id from products where sku = 'TEST-RET-CREMA'), 1),
  ((select id from products where sku = 'TEST-RET-KIT'), (select id from products where sku = 'TEST-RET-SERUM'), 2);

select set_product_price((select id from products where sku = 'TEST-RET-P1'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'TEST-RET-P1'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'TEST-RET-P1'), (select id from price_conditions where code = 'TRANSFER'), 9500);
select set_product_price((select id from products where sku = 'TEST-RET-P2'), (select id from price_conditions where rule_type = 'BASE'), 15000);
select set_product_price((select id from products where sku = 'TEST-RET-P2'), (select id from price_conditions where code = 'CASH'), 12000);
select set_product_price((select id from products where sku = 'TEST-RET-KIT'), (select id from price_conditions where rule_type = 'BASE'), 50000);
select set_product_price((select id from products where sku = 'TEST-RET-KIT'), (select id from price_conditions where code = 'CASH'), 45000);
select set_product_price((select id from products where sku = 'TEST-RET-CREMA'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'TEST-RET-CREMA'), (select id from price_conditions where code = 'CASH'), 4500);

insert into public.customers (full_name, dni) values ('Cliente Devoluciones Test', '30999222');

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RET-P1'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RET-P2'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RET-CREMA'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-RET-SERUM'), 20, 'RECEPTION');

-- Devoluciones: vendedora (no admin) puede registrar, igual que Cambios.
set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1-2: producto x3 (CASH) — devuelve 1, después devuelve 1 más
-- (acumulado sobre la MISMA línea).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 3)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_a_id \gset
select (select id from sale_items where sale_id = :'sale_a_id') as item_a_id \gset

select (create_sale_return(
  :'sale_a_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_a_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 1'
)) as result_1 \gset

select is(
  (:'result_1'::jsonb ->> 'refund_amount')::numeric, 9000.00,
  'Caso 1: refund_amount = 1 × 9000 (precio realmente pagado, nunca Lista/actual)'
);
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  18.00,
  'Caso 1: devolver 1 de 3 reintegra exactamente 1 unidad (17 -> 18)'
);
select is(
  (select status from sales where id = :'sale_a_id'), 'confirmed'::sale_status,
  'Caso 1: la venta original NUNCA cambia de status por una devolución (sigue confirmed)'
);

select (create_sale_return(
  :'sale_a_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_a_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 2'
)) as result_2 \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  19.00,
  'Caso 2: una segunda devolución PARCIAL sobre la misma línea ve correctamente lo ya devuelto (18 -> 19)'
);
select is(
  (select count(*)::int from sale_return_items where sale_item_id = :'item_a_id'), 2,
  'Caso 2: quedan 2 filas de sale_return_items para la misma línea (eventos separados, ninguno se pisa)'
);

-- ===========================================================================
-- Caso 3: intentar devolver más de lo disponible (queda 1 de 3) -> rechazo y
-- rollback completo.
-- ===========================================================================
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P1') and location_id = (select id from stock_locations where code = 'DEP')) as stock_p1_before_3 \gset
select (select count(*)::int from sale_returns) as returns_count_before_3 \gset

select throws_like(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 2)), 'CASH', null, null)$$,
    :'sale_a_id', :'item_a_id'
  ),
  '%disponibles%',
  'Caso 3: devolver 2 cuando solo queda 1 disponible se rechaza con el mensaje esperado'
);
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  :stock_p1_before_3,
  'Caso 3: el rechazo hace rollback completo — el stock queda exactamente igual'
);
select is(
  (select count(*)::int from sale_returns), :returns_count_before_3,
  'Caso 3: el rechazo no dejó ningún sale_returns a mitad de camino'
);

-- ===========================================================================
-- Caso 4: kit x2, devuelve 1 -> reintegra los componentes en proporción.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-KIT'), 'quantity', 2)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_b_id \gset
select (select id from sale_items where sale_id = :'sale_b_id') as item_b_id \gset

select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-CREMA') and location_id = (select id from stock_locations where code = 'DEP')) as crema_before_4 \gset
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-SERUM') and location_id = (select id from stock_locations where code = 'DEP')) as serum_before_4 \gset

select create_sale_return(
  :'sale_b_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_b_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 4'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  (:crema_before_4 + 1)::numeric,
  'Caso 4: devolver 1 de 2 kits reintegra Crema +1, la mitad de lo descontado'
);
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-SERUM') and location_id = (select id from stock_locations where code = 'DEP')),
  (:serum_before_4 + 2)::numeric,
  'Caso 4: devolver 1 de 2 kits reintegra Serum +2, la mitad de lo descontado'
);

-- ===========================================================================
-- Caso 5: un kit y, por separado, una unidad suelta del mismo componente en
-- la MISMA venta — devolver la unidad suelta no debe tocar el stock del kit.
-- ===========================================================================
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-CREMA') and location_id = (select id from stock_locations where code = 'DEP')) as crema_before_5 \gset

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-KIT'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-CREMA'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_c_id \gset

select (select id from sale_items where sale_id = :'sale_c_id' and product_id = (select id from products where sku = 'TEST-RET-CREMA')) as item_crema_suelta_id \gset

select create_sale_return(
  :'sale_c_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_crema_suelta_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 5'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  (:crema_before_5 - 1)::numeric,
  'Caso 5: devolver la unidad SUELTA de Crema reintegra exactamente 1 — nunca toca la Crema del kit'
);

-- ===========================================================================
-- Caso 6-7: devolución MULTI-LÍNEA en un mismo llamado, y rechazo de
-- sale_item_id duplicado dentro del mismo array.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 2),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P2'), 'quantity', 2)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_d_id \gset
select (select id from sale_items where sale_id = :'sale_d_id' and product_id = (select id from products where sku = 'TEST-RET-P1')) as item_d1_id \gset
select (select id from sale_items where sale_id = :'sale_d_id' and product_id = (select id from products where sku = 'TEST-RET-P2')) as item_d2_id \gset

select (create_sale_return(
  :'sale_d_id'::uuid,
  jsonb_build_array(
    jsonb_build_object('sale_item_id', :'item_d1_id'::uuid, 'quantity', 1),
    jsonb_build_object('sale_item_id', :'item_d2_id'::uuid, 'quantity', 1)
  ),
  'CASH', null, 'Test caso 6'
)) as result_6 \gset

select is(
  (:'result_6'::jsonb ->> 'refund_amount')::numeric, 21000.00,
  'Caso 6: devolución multi-línea en un mismo llamado suma ambas líneas (9000 + 12000)'
);
select is(
  (select count(*)::int from sale_return_items where return_id = (:'result_6'::jsonb ->> 'return_id')::uuid), 2,
  'Caso 6: un único sale_returns con 2 sale_return_items, uno por línea'
);

select throws_like(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1), jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$,
    :'sale_d_id', :'item_d1_id', :'item_d1_id'
  ),
  '%más de una vez%',
  'Caso 7: la misma línea repetida dos veces en el mismo array se rechaza'
);

-- ===========================================================================
-- Caso 8-9: devolución total de una venta de una sola línea -> status pasa a
-- 'returned'; una devolución que agota una línea pero deja otra con saldo
-- deja la venta 'confirmed' (regla crítica, sección 19).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_e_id \gset
select (select id from sale_items where sale_id = :'sale_e_id') as item_e_id \gset

select (create_sale_return(
  :'sale_e_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_e_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 8'
)) as result_8 \gset

select is((:'result_8'::jsonb ->> 'is_full_return')::boolean, true, 'Caso 8: devolver el 100% de la única línea marca is_full_return=true');
select is(
  (select status from sales where id = :'sale_e_id'), 'returned'::sale_status,
  'Caso 8: la venta pasa a returned cuando el neto de TODAS sus líneas llega a $0'
);

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P2'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_f_id \gset
select (select id from sale_items where sale_id = :'sale_f_id' and product_id = (select id from products where sku = 'TEST-RET-P1')) as item_f1_id \gset

select (create_sale_return(
  :'sale_f_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_f1_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 9'
)) as result_9 \gset

select is((:'result_9'::jsonb ->> 'is_full_return')::boolean, false, 'Caso 9: agotar UNA línea con otra línea todavía vigente NO es devolución total');
select is(
  (select status from sales where id = :'sale_f_id'), 'confirmed'::sale_status,
  'Caso 9: la venta sigue confirmed — el resto de la venta (Producto Dos) es una venta válida (sección 19)'
);

-- ===========================================================================
-- Caso 10-13: orígenes inválidos.
-- ===========================================================================
select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$, :'sale_e_id', :'item_e_id'),
  '%confirmada%',
  'Caso 10: una venta ya returned (sale_e) no admite una devolución nueva'
);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_g_id \gset
select cancel_sale(:'sale_g_id'::uuid, 'Test cancelación para caso 11');
select (select id from sale_items where sale_id = :'sale_g_id') as item_g_id \gset
select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$, :'sale_g_id', :'item_g_id'),
  '%confirmada%',
  'Caso 11: una venta cancelada no admite una devolución'
);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222')
) ->> 'sale_id')::uuid as sale_h_id \gset
select (select id from sale_items where sale_id = :'sale_h_id') as item_h_id \gset
select create_sale_exchange(:'sale_h_id'::uuid, :'item_h_id'::uuid, 1, (select id from products where sku = 'TEST-RET-P2'), 1);
select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$, :'sale_h_id', :'item_h_id'),
  '%confirmada%',
  'Caso 12: una venta ya reemplazada por un cambio (replaced) no admite una devolución directa — hay que ir contra la venta de reemplazo'
);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-RET-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999222'),
  null, null, null, null, now(), true, 'GIFT'
) ->> 'sale_id')::uuid as sale_i_id \gset
select (select id from sale_items where sale_id = :'sale_i_id') as item_i_id \gset
select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$, :'sale_i_id', :'item_i_id'),
  '%no hubo pago%',
  'Caso 13: una entrega sin costo no admite devolución de dinero — no hubo pago que reintegrar'
);

-- ===========================================================================
-- Caso 14: un viewer no puede registrar devoluciones.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000003', false);
select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', null, null)$$, :'sale_f_id', :'item_f1_id'),
  '%solo lectura%',
  'Caso 14: un viewer no puede registrar una devolución'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 15-16: forma de reintegro — TRANSFER exige cuenta, CASH la rechaza.
-- ===========================================================================
select (select id from sale_items where sale_id = :'sale_f_id' and product_id = (select id from products where sku = 'TEST-RET-P2')) as item_f2_id \gset

select throws_like(
  format($$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'TRANSFER', null, null)$$, :'sale_f_id', :'item_f2_id'),
  '%cuenta%',
  'Caso 15: una devolución por transferencia sin cuenta se rechaza'
);
select throws_like(
  format(
    $$select create_sale_return('%s'::uuid, jsonb_build_array(jsonb_build_object('sale_item_id', '%s'::uuid, 'quantity', 1)), 'CASH', (select id from payment_accounts where code = 'MERCADO_PAGO'), null)$$,
    :'sale_f_id', :'item_f2_id'
  ),
  '%no lleva cuenta%',
  'Caso 16: una devolución en efectivo con cuenta asociada se rechaza'
);

-- ===========================================================================
-- Caso 17: cadena Cambio -> Devolución. sale_h (Caso 12) ya fue reemplazada
-- por un cambio — la venta VIGENTE es la de reemplazo, con una línea
-- "remainder"/"new" cuyo ledger físico real vive en la venta raíz
-- (physical_source_sale_item_id). Devolver contra esa línea tiene que
-- reintegrar el stock de la raíz correctamente.
-- ===========================================================================
select (select id from sales where replaces_sale_id = :'sale_h_id') as sale_h_replacement_id \gset
select (select id from sale_items where sale_id = :'sale_h_replacement_id' and product_id = (select id from products where sku = 'TEST-RET-P2')) as item_h_new_id \gset
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P2') and location_id = (select id from stock_locations where code = 'DEP')) as p2_before_17 \gset

select create_sale_return(
  :'sale_h_replacement_id'::uuid,
  jsonb_build_array(jsonb_build_object('sale_item_id', :'item_h_new_id'::uuid, 'quantity', 1)),
  'CASH', null, 'Test caso 17'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-RET-P2') and location_id = (select id from stock_locations where code = 'DEP')),
  (:p2_before_17 + 1)::numeric,
  'Caso 17: devolver la línea nueva de un cambio anterior reintegra su propio stock (Producto Dos +1)'
);
select is(
  (select status from sales where id = :'sale_h_replacement_id'), 'returned'::sale_status,
  'Caso 17: esa venta de reemplazo (única línea) queda returned tras la devolución total'
);

-- ===========================================================================
-- Caso 18: auditoría. audit_logs es de lectura exclusiva de admin (RLS).
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fd000000-0000-0000-0000-000000000001', false);
select is(
  (select (metadata ->> 'refund_amount')::numeric from audit_logs where action = 'SALE_RETURN_CREATED' and entity_id = :'sale_a_id' order by created_at desc limit 1),
  9000.00,
  'Caso 18: audit_logs registra SALE_RETURN_CREATED con el refund_amount correcto'
);

-- ===========================================================================
-- Caso 19: sale_item_net expone las 4 columnas exigidas (precisión #1).
-- ===========================================================================
select is((select returned_quantity from sale_item_net where sale_item_id = :'item_a_id'), 2.00, 'Caso 19a: sale_item_net.returned_quantity = 2 tras 2 devoluciones parciales de 1 unidad');
select is((select returned_amount from sale_item_net where sale_item_id = :'item_a_id'), 18000.00, 'Caso 19b: sale_item_net.returned_amount = 18000 (2 × 9000)');
select is((select net_quantity from sale_item_net where sale_item_id = :'item_a_id'), 1.00, 'Caso 19c: sale_item_net.net_quantity = 1 (3 vendidas - 2 devueltas)');
select is((select net_line_total from sale_item_net where sale_item_id = :'item_a_id'), 9000.00, 'Caso 19d: sale_item_net.net_line_total = 9000 (1 unidad restante × 9000)');

-- ===========================================================================
-- Caso 20: customer_sales_for_return — available_to_return correcto y
-- exclusión de entregas sin costo.
-- ===========================================================================
select is(
  (
    select (item ->> 'available_to_return')::numeric
    from jsonb_array_elements(customer_sales_for_return((select id from customers where dni = '30999222'))) sale,
      jsonb_array_elements(sale -> 'items') item
    where sale ->> 'sale_id' = :'sale_a_id'::text and item ->> 'sale_item_id' = :'item_a_id'::text
  ),
  1.00,
  'Caso 20: customer_sales_for_return expone available_to_return = 1 (de 3, con 2 ya devueltas)'
);
select is(
  (select count(*)::int from jsonb_array_elements(customer_sales_for_return((select id from customers where dni = '30999222'))) s where s ->> 'sale_id' = :'sale_i_id'::text),
  0,
  'Caso 20b: una entrega sin costo no aparece como elegible para devolución'
);

select * from finish();
rollback;
