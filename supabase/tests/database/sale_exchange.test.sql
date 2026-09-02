-- pgTAP: Cambios / Devoluciones — devolución PARCIAL de cantidad (Bloque B).
-- Casos pedidos explícitamente por el usuario antes de aprobar Bloque B:
--   1) producto x3, devuelve 1
--   2) producto x3, devuelve 2
--   3) kit x2, devuelve 1
--   4) dos cambios sucesivos parciales sobre la misma línea
--   5) intento de devolver más cantidad que la disponible -> rechazo y rollback
-- + 2 casos que cierran compromisos de la auditoría previa: kit y componente
-- suelto en la misma venta (source_sale_item_id), y venta original INVOICED.
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(32);

insert into auth.users (id, email) values
  ('f9000000-0000-0000-0000-000000000001', 'admin.exchange@test.maguirejuve.com'),
  ('f9000000-0000-0000-0000-000000000002', 'seller.exchange@test.maguirejuve.com'),
  ('f9000000-0000-0000-0000-000000000003', 'viewer.exchange@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'f9000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'f9000000-0000-0000-0000-000000000002';
update public.profiles set role = 'viewer', active = true where id = 'f9000000-0000-0000-0000-000000000003';
insert into public.profile_locations (profile_id, location_id)
  select 'f9000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'f9000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';
insert into public.profile_locations (profile_id, location_id)
  select 'f9000000-0000-0000-0000-000000000003', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed.
-- ---------------------------------------------------------------------------
-- promo_eligible=false a propósito: la condición QUANTITY (prioridad más alta
-- que PAYMENT_METHOD en el seed real) no debe interferir con estos casos —
-- ya está cerrado con el usuario que un cambio usa la condición PAYMENT_METHOD
-- literal, sin escalar por cantidad del carrito final.
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-EXCH-P1', 'Producto Cambio Uno', 'product', 'Test', true, true, false, true),
  ('TEST-EXCH-P2', 'Producto Cambio Dos', 'product', 'Test', true, true, false, true),
  ('TEST-EXCH-KIT', 'Kit Cambio Test', 'kit', 'Test', false, true, false, true),
  ('TEST-EXCH-CREMA', 'Crema Componente Cambio', 'product', 'Test', true, true, false, true),
  ('TEST-EXCH-SERUM', 'Serum Componente Cambio', 'product', 'Test', true, true, false, true);

insert into public.kit_components (kit_product_id, component_product_id, quantity) values
  ((select id from products where sku = 'TEST-EXCH-KIT'), (select id from products where sku = 'TEST-EXCH-CREMA'), 1),
  ((select id from products where sku = 'TEST-EXCH-KIT'), (select id from products where sku = 'TEST-EXCH-SERUM'), 2);

select set_product_price((select id from products where sku = 'TEST-EXCH-P1'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'TEST-EXCH-P1'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'TEST-EXCH-P1'), (select id from price_conditions where code = 'TRANSFER'), 9500);
select set_product_price((select id from products where sku = 'TEST-EXCH-P2'), (select id from price_conditions where rule_type = 'BASE'), 15000);
select set_product_price((select id from products where sku = 'TEST-EXCH-P2'), (select id from price_conditions where code = 'CASH'), 12000);
select set_product_price((select id from products where sku = 'TEST-EXCH-P2'), (select id from price_conditions where code = 'TRANSFER'), 13000);
select set_product_price((select id from products where sku = 'TEST-EXCH-KIT'), (select id from price_conditions where rule_type = 'BASE'), 50000);
select set_product_price((select id from products where sku = 'TEST-EXCH-KIT'), (select id from price_conditions where code = 'CASH'), 45000);
-- Crema también se vende suelta (Caso 6) además de como componente de kit.
select set_product_price((select id from products where sku = 'TEST-EXCH-CREMA'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'TEST-EXCH-CREMA'), (select id from price_conditions where code = 'CASH'), 4500);

insert into public.customers (full_name, dni) values ('Cliente Cambios Test', '30999111');

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-EXCH-P1'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-EXCH-P2'), 50, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-EXCH-CREMA'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-EXCH-SERUM'), 20, 'RECEPTION');

-- Cambios: vendedora (no admin) — sección 16 del pedido original.
set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- Caso 1: producto x3, devuelve 1.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-P1'), 'quantity', 3)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999111')
) ->> 'sale_id')::uuid as sale_a_id \gset

select (select id from sale_items where sale_id = :'sale_a_id') as item_a_id \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  17.00,
  'Precondición Caso 1: la venta de 3 unidades descontó stock (20 -> 17)'
);

select (create_sale_exchange(
  :'sale_a_id'::uuid, :'item_a_id'::uuid, 1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
)) as result_1 \gset

select (:'result_1'::jsonb ->> 'sale_id')::uuid as sale_b_id \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  18.00,
  'Caso 1: devolver 1 de 3 reintegra exactamente 1 unidad (17 -> 18), no las 3'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P2') and location_id = (select id from stock_locations where code = 'DEP')),
  49.00,
  'Caso 1: el producto nuevo descuenta su propio stock (50 -> 49)'
);

select is(
  (select status from sales where id = :'sale_a_id'), 'replaced'::sale_status,
  'Caso 1: la venta original pasa a replaced (nunca se borra ni se edita)'
);

select is(
  (select quantity from sale_items where sale_id = :'sale_b_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')),
  2.00,
  'Caso 1: la venta de reemplazo lleva el remanente (2) de Producto Uno'
);

select is(
  (select sale_unit_price from sale_items where sale_id = :'sale_b_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')),
  9000.00,
  'Caso 1: el remanente conserva el precio histórico (9000), nunca se recalcula'
);

select is(
  (:'result_1'::jsonb ->> 'difference_amount')::numeric, 3000.00,
  'Caso 1: diferencia = 12000 (nuevo) - 9000 (reconocido) = 3000, cliente debe abonar'
);

select is(
  :'result_1'::jsonb ->> 'difference_direction', 'CUSTOMER_PAYS',
  'Caso 1: dirección de la diferencia = CUSTOMER_PAYS'
);

-- ===========================================================================
-- Caso 2: producto x3, devuelve 2 (venta nueva, independiente de la anterior).
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-P1'), 'quantity', 3)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999111')
) ->> 'sale_id')::uuid as sale_c_id \gset

select (select id from sale_items where sale_id = :'sale_c_id') as item_c_id \gset

select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')) as stock_p1_before_ex2 \gset

select (create_sale_exchange(
  :'sale_c_id'::uuid, :'item_c_id'::uuid, 2,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
)) as result_2 \gset

select (:'result_2'::jsonb ->> 'sale_id')::uuid as sale_d_id \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  (:stock_p1_before_ex2 + 2)::numeric,
  'Caso 2: devolver 2 de 3 reintegra exactamente 2 unidades'
);

select is(
  (select quantity from sale_items where sale_id = :'sale_d_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')),
  1.00,
  'Caso 2: la venta de reemplazo lleva el remanente correcto (1)'
);

-- ===========================================================================
-- Caso 3: kit x2, devuelve 1 -> reintegra los componentes en proporción.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-KIT'), 'quantity', 2)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999111')
) ->> 'sale_id')::uuid as sale_e_id \gset

select (select id from sale_items where sale_id = :'sale_e_id') as item_e_id \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  18.00,
  'Precondición Caso 3: 2 kits descontaron Crema (20 -> 18, 1 por kit)'
);
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-SERUM') and location_id = (select id from stock_locations where code = 'DEP')),
  16.00,
  'Precondición Caso 3: 2 kits descontaron Serum (20 -> 16, 2 por kit)'
);

select (create_sale_exchange(
  :'sale_e_id'::uuid, :'item_e_id'::uuid, 1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
)) as result_3 \gset

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  19.00,
  'Caso 3: devolver 1 de 2 kits reintegra Crema +1 (18 -> 19), la mitad de lo descontado'
);
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-SERUM') and location_id = (select id from stock_locations where code = 'DEP')),
  18.00,
  'Caso 3: devolver 1 de 2 kits reintegra Serum +2 (16 -> 18), la mitad de lo descontado'
);

select is(
  (:'result_3'::jsonb ->> 'difference_amount')::numeric, -33000.00,
  'Caso 3: diferencia = 12000 (nuevo) - 45000 (kit reconocido) = -33000, el negocio devuelve'
);
select is(
  :'result_3'::jsonb ->> 'difference_direction', 'BUSINESS_REFUNDS',
  'Caso 3: dirección de la diferencia = BUSINESS_REFUNDS'
);

-- ===========================================================================
-- Caso 4: dos cambios sucesivos PARCIALES sobre la misma línea (encadenado).
-- Venta F (x3) -> cambio 1 (devuelve 1) -> Venta G (remanente 2) ->
-- cambio 2 (devuelve 1 más) -> Venta H (remanente 1).
-- ===========================================================================
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')) as stock_p1_before_f \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-P1'), 'quantity', 3)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999111')
) ->> 'sale_id')::uuid as sale_f_id \gset
select (select id from sale_items where sale_id = :'sale_f_id') as item_f_id \gset

select (create_sale_exchange(
  :'sale_f_id'::uuid, :'item_f_id'::uuid, 1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
) ->> 'sale_id')::uuid as sale_g_id \gset
select (select id from sale_items where sale_id = :'sale_g_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')) as item_g_id \gset

select is(
  (select quantity from sale_items where id = :'item_g_id'),
  2.00,
  'Caso 4 (paso 1): la venta G lleva el remanente 2 tras el primer cambio parcial'
);

select (create_sale_exchange(
  :'sale_g_id'::uuid, :'item_g_id'::uuid, 1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
) ->> 'sale_id')::uuid as sale_h_id \gset

select is(
  (select quantity from sale_items where sale_id = :'sale_h_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')),
  1.00,
  'Caso 4 (paso 2): la venta H lleva el remanente correcto (1) tras el segundo cambio parcial'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  (:stock_p1_before_f - 1)::numeric,
  'Caso 4: el stock físico neto refleja exactamente lo que quedó sin devolver (vendidos 3, devueltos 1+1=2 en total, a través de la cadena de sale_items)'
);

select is((select status from sales where id = :'sale_f_id'), 'replaced'::sale_status, 'Caso 4: la venta F (raíz) queda replaced');
select is((select status from sales where id = :'sale_g_id'), 'replaced'::sale_status, 'Caso 4: la venta G (intermedia) también queda replaced — no se puede volver a usar como origen');
select is((select status from sales where id = :'sale_h_id'), 'confirmed'::sale_status, 'Caso 4: solo la venta H (última, vigente) queda confirmed');

-- ===========================================================================
-- Caso 5: intentar devolver más cantidad que la disponible -> rechazo y
-- rollback (nada cambia: ni stock, ni el estado de la venta H, ni se crea un
-- sale_exchanges nuevo).
-- ===========================================================================
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')) as stock_p1_before_5 \gset
select (select count(*)::int from sale_exchanges) as exchange_count_before_5 \gset
select (select id from sale_items where sale_id = :'sale_h_id' and product_id = (select id from products where sku = 'TEST-EXCH-P1')) as item_h_id \gset

select throws_like(
  format(
    $$select create_sale_exchange('%s'::uuid, '%s'::uuid, 2, (select id from products where sku = 'TEST-EXCH-P2'), 1)$$,
    :'sale_h_id', :'item_h_id'
  ),
  '%disponibles%',
  'Caso 5: devolver 2 cuando solo queda 1 disponible se rechaza con el mensaje esperado'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-P1') and location_id = (select id from stock_locations where code = 'DEP')),
  :stock_p1_before_5,
  'Caso 5: el rechazo hace rollback completo — el stock queda exactamente igual que antes del intento'
);

select is(
  (select status from sales where id = :'sale_h_id'), 'confirmed'::sale_status,
  'Caso 5: el rechazo no llegó a tocar el estado de la venta H'
);

select is(
  (select count(*)::int from sale_exchanges), :exchange_count_before_5,
  'Caso 5: el rechazo no dejó ningún sale_exchanges a mitad de camino'
);

-- ===========================================================================
-- Caso 6 (cierre de la auditoría, punto 1): un kit y, por separado, una
-- unidad suelta del mismo componente en la MISMA venta — devolver solo la
-- unidad suelta no debe tocar el stock que le corresponde al kit, y viceversa.
-- ===========================================================================
select (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-CREMA') and location_id = (select id from stock_locations where code = 'DEP')) as crema_before_6 \gset

select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-KIT'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-CREMA'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999111')
) ->> 'sale_id')::uuid as sale_i_id \gset

-- 1 kit (Crema x1) + 1 Crema suelta = 2 unidades de Crema descontadas en total.
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  (:crema_before_6 - 2)::numeric,
  'Precondición Caso 6: el kit y la unidad suelta juntos descontaron 2 de Crema'
);

select (select id from sale_items where sale_id = :'sale_i_id' and product_id = (select id from products where sku = 'TEST-EXCH-CREMA')) as item_crema_suelta_id \gset

select (create_sale_exchange(
  :'sale_i_id'::uuid, :'item_crema_suelta_id'::uuid, 1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
)) as result_6 \gset

-- Si el movimiento de la unidad suelta y el del kit estuvieran fusionados
-- (bug que motivó el punto 1 de la auditoría), esto devolvería 2 en vez de 1.
select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku = 'TEST-EXCH-CREMA') and location_id = (select id from stock_locations where code = 'DEP')),
  (:crema_before_6 - 1)::numeric,
  'Caso 6: devolver la unidad SUELTA de Crema reintegra exactamente 1 — nunca toca la Crema que pertenece al kit'
);

-- ===========================================================================
-- Caso 7 (cierre de la auditoría, punto 2): venta original ya facturada
-- (INVOICED) — la diferencia se trackea aparte, nunca un pendiente por el
-- total completo de la venta de reemplazo.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000001', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-EXCH-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30999111'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_j_id \gset

select mark_sale_invoiced(:'sale_j_id'::uuid);

select is((select billing_status from sales where id = :'sale_j_id'), 'INVOICED'::sale_billing_status, 'Precondición Caso 7: la venta original queda facturada');

-- Capturado ANTES de cambiar de rol: por RLS, una vendedora no ve las ventas
-- de otro usuario (esta la creó el admin) — igual que en Nueva Venta, eso no
-- le impide hacer el cambio (create_sale_exchange no exige ser la vendedora
-- original, solo acceso a la sede), pero sí le impide resolver este id por
-- select directo si lo hiciera ya logueada como vendedora.
select (select id from sale_items where sale_id = :'sale_j_id') as item_j_id \gset

set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000002', false);

select (create_sale_exchange(
  :'sale_j_id'::uuid,
  :'item_j_id'::uuid,
  1,
  (select id from products where sku = 'TEST-EXCH-P2'), 1
)) as result_7 \gset

select is(
  (:'result_7'::jsonb ->> 'billing_status'), 'INVOICED',
  'Caso 7: la venta de reemplazo hereda INVOICED — nunca reabre un pendiente por el total completo'
);
select is(
  (:'result_7'::jsonb ->> 'difference_settlement_status'), 'PENDING',
  'Caso 7: la diferencia (transferencia, monto != 0) sí queda pendiente de acreditar, aparte'
);

-- ===========================================================================
-- Permisos: un viewer no puede hacer cambios.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'f9000000-0000-0000-0000-000000000003', false);

select throws_like(
  format(
    $$select create_sale_exchange('%s'::uuid, (select id from sale_items where sale_id='%s'::uuid limit 1), 1, (select id from products where sku='TEST-EXCH-P2'), 1)$$,
    :'sale_h_id', :'sale_h_id'
  ),
  '%solo lectura%',
  'Permisos: un viewer no puede hacer un cambio de producto'
);

select * from finish();
rollback;
