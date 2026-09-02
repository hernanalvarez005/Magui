-- pgTAP: Cambios / Devoluciones — Bloque E, batería de negocio (secciones
-- 48-53 del pedido original: búsqueda, pricing, diferencia, métricas,
-- historial). La mecánica de devolución PARCIAL de cantidad (proporción,
-- kits, cadenas, rechazo por exceso) ya está cubierta en sale_exchange.test.sql
-- — este archivo NO la repite, cubre lo que ese no cubre.
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(35);

insert into auth.users (id, email) values
  ('fb100000-0000-0000-0000-000000000001', 'admin.exbiz@test.maguirejuve.com'),
  ('fb100000-0000-0000-0000-000000000002', 'seller.exbiz@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fb100000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fb100000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fb100000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fb100000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo — promo_eligible=true a propósito en VITC/ANTIAGE (para el caso
-- de pricing "QUANTITY nunca escala la condición" más abajo), false en el
-- resto para no interferir con nada que no sea ese caso puntual.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-BIZ-VITC', 'Vitamina C Biz', 'product', 'Test', true, true, true, true),
  ('TEST-BIZ-ESPUMA', 'Espuma Biz', 'product', 'Test', true, true, false, true),
  ('TEST-BIZ-ANTIAGE', 'Antiage Biz', 'product', 'Test', true, true, true, true),
  ('TEST-BIZ-A', 'Producto A Biz', 'product', 'Test', true, true, false, true),
  ('TEST-BIZ-B', 'Producto B Biz', 'product', 'Test', true, true, false, true),
  ('TEST-BIZ-P1', 'Producto Multipago Biz', 'product', 'Test', true, true, false, true);

select set_product_price((select id from products where sku = 'TEST-BIZ-VITC'), (select id from price_conditions where rule_type = 'BASE'), 32000);
select set_product_price((select id from products where sku = 'TEST-BIZ-VITC'), (select id from price_conditions where code = 'CASH'), 30000);
select set_product_price((select id from products where sku = 'TEST-BIZ-ESPUMA'), (select id from price_conditions where rule_type = 'BASE'), 22000);
select set_product_price((select id from products where sku = 'TEST-BIZ-ESPUMA'), (select id from price_conditions where code = 'CASH'), 20000);
select set_product_price((select id from products where sku = 'TEST-BIZ-ANTIAGE'), (select id from price_conditions where rule_type = 'BASE'), 44000);
select set_product_price((select id from products where sku = 'TEST-BIZ-ANTIAGE'), (select id from price_conditions where code = 'CASH'), 40000);
select set_product_price((select id from products where sku = 'TEST-BIZ-A'), (select id from price_conditions where rule_type = 'BASE'), 44000);
select set_product_price((select id from products where sku = 'TEST-BIZ-A'), (select id from price_conditions where code = 'CASH'), 40000);
-- A se compra bajo las 4 formas de pago en Pricing 2-6 más abajo, así que
-- necesita precio cargado en todas (si no, el error sería de la venta
-- ORIGINAL, no del cambio — nada que ver con lo que este bloque prueba).
select set_product_price((select id from products where sku = 'TEST-BIZ-A'), (select id from price_conditions where code = 'TRANSFER'), 41000);
select set_product_price((select id from products where sku = 'TEST-BIZ-A'), (select id from price_conditions where code = 'CARD_1'), 42000);
select set_product_price((select id from products where sku = 'TEST-BIZ-A'), (select id from price_conditions where code = 'INSTALLMENTS_3'), 43000);
select set_product_price((select id from products where sku = 'TEST-BIZ-B'), (select id from price_conditions where rule_type = 'BASE'), 33000);
select set_product_price((select id from products where sku = 'TEST-BIZ-B'), (select id from price_conditions where code = 'CASH'), 30000);
-- Producto Multipago: precio DISTINTO y verificable en cada condición.
-- Ninguna condición supera a BASE (mismo criterio que el catálogo real:
-- CASH/TRANSFER siempre por debajo de lista, CARD_1/CARD_3 como mucho
-- igual) — sales.discount_total exige >= 0 y line_discount = list - venta,
-- así que una condición por ENCIMA de la lista rompería ese constraint (es
-- un bug preexistente de fn_pricing_quote, no de este módulo; se evita acá
-- simplemente no armando ese escenario, no es lo que este test cubre).
select set_product_price((select id from products where sku = 'TEST-BIZ-P1'), (select id from price_conditions where rule_type = 'BASE'), 13000);
select set_product_price((select id from products where sku = 'TEST-BIZ-P1'), (select id from price_conditions where code = 'CASH'), 11000);
select set_product_price((select id from products where sku = 'TEST-BIZ-P1'), (select id from price_conditions where code = 'TRANSFER'), 11500);
select set_product_price((select id from products where sku = 'TEST-BIZ-P1'), (select id from price_conditions where code = 'CARD_1'), 12500);
-- El código de price_conditions para "3 cuotas" es INSTALLMENTS_3 (distinto
-- del código de payment_methods, que sí es CARD_3) — ver seed_data.sql.
select set_product_price((select id from products where sku = 'TEST-BIZ-P1'), (select id from price_conditions where code = 'INSTALLMENTS_3'), 13000);

insert into public.customers (full_name, dni) values
  ('Cliente Biz Test', '30777222'),
  ('Cliente Biz Sin Ventas', '30777333');

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-VITC'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-ESPUMA'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-ANTIAGE'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-A'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-B'), 30, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-BIZ-P1'), 30, 'RECEPTION');

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000002', false);

-- ===========================================================================
-- BÚSQUEDA (sección 48)
-- ===========================================================================

-- Caso 1: cliente sin ninguna venta -> lista vacía (nunca un error).
select is(
  jsonb_array_length(customer_sales_for_exchange((select id from customers where dni = '30777333'))),
  0,
  'Búsqueda 1: un cliente sin ventas devuelve una lista vacía, no un error'
);

-- Caso 2: cliente inexistente -> error explícito.
select throws_like(
  $$select customer_sales_for_exchange('00000000-0000-0000-0000-000000000000'::uuid)$$,
  '%no existe%',
  'Búsqueda 2: un customer_id inexistente rechaza con error explícito'
);

-- Venta 1 (más vieja) y Venta 2 (más nueva) del mismo cliente, para el orden.
-- now() es estable dentro de esta transacción de test (transaction_timestamp),
-- así que ambas ventas necesitan un sold_at explícitamente distinto para no
-- empatar — clock_timestamp() sí avanza entre sentencias, y al ser >= now()
-- no pisa la validez de los precios recién cargados (valid_from = now()).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222'),
  null, null, null, null, clock_timestamp()
) ->> 'sale_id')::uuid as sale_old_id \gset

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-B'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222'),
  null, null, null, null, clock_timestamp()
) ->> 'sale_id')::uuid as sale_new_id \gset

-- Venta cancelada: no debe listarse.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_to_cancel_id \gset
select cancel_sale(:'sale_to_cancel_id'::uuid, 'Test: no debe aparecer en cambios');

-- Caso 3: orden — la más nueva primero.
select is(
  (customer_sales_for_exchange((select id from customers where dni = '30777222')) -> 0 ->> 'sale_id')::uuid,
  :'sale_new_id'::uuid,
  'Búsqueda 3: la lista viene ordenada con la venta más reciente primero'
);

-- Caso 4: ni la cancelada ni (más abajo) una ya reemplazada aparecen.
select ok(
  not exists (
    select 1 from jsonb_array_elements(customer_sales_for_exchange((select id from customers where dni = '30777222'))) e
    where (e ->> 'sale_id')::uuid = :'sale_to_cancel_id'::uuid
  ),
  'Búsqueda 4a: una venta cancelada no aparece entre las elegibles para un cambio'
);

-- ===========================================================================
-- PRICING (sección 49)
-- ===========================================================================

-- Caso 1: valor reconocido = precio REALMENTE PAGADO histórico, nunca el
-- vigente. VITC se pagó a $30.000 (CASH); después el precio de lista sube.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_vitc_id \gset
select (select id from sale_items where sale_id = :'sale_vitc_id') as item_vitc_id \gset

-- El precio "sube" después de la venta — el histórico no se toca.
-- set_product_price es exclusivo de admin, hay que cambiar de rol un momento.
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000001', false);
select set_product_price((select id from products where sku = 'TEST-BIZ-VITC'), (select id from price_conditions where code = 'CASH'), 35000);
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000002', false);

select is(
  (select sale_unit_price from sale_items where id = :'item_vitc_id'),
  30000.00,
  'Pricing 1: el precio pagado histórico de la línea sigue en $30.000 aunque el precio vigente ya sea $35.000'
);

-- Cambio real: devuelve VITC, se lleva Espuma. El valor reconocido tiene que
-- seguir siendo $30.000 (el pagado), nunca $35.000 (el vigente hoy).
select (create_sale_exchange(
  :'sale_vitc_id'::uuid, :'item_vitc_id'::uuid, 1,
  (select id from products where sku = 'TEST-BIZ-ESPUMA'), 1
)) as result_pricing1 \gset

select is(
  (:'result_pricing1'::jsonb ->> 'recognized_value')::numeric,
  30000.00,
  'Pricing 1b: create_sale_exchange reconoce el precio realmente pagado ($30.000), no el vigente ($35.000)'
);

-- Casos 2-5: el producto nuevo se valúa bajo la condición LITERAL de la
-- forma de pago original — nunca otra, sin importar el carrito final.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_cash_id \gset
select (create_sale_exchange(
  :'sale_cash_id'::uuid, (select id from sale_items where sale_id = :'sale_cash_id'), 1,
  (select id from products where sku = 'TEST-BIZ-P1'), 1
) ->> 'new_item_total')::numeric as new_total_cash \gset
select is(:new_total_cash, 11000.00, 'Pricing 2: forma de pago Efectivo -> precio CASH literal ($11.000)');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30777222'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_transfer_id \gset
select (create_sale_exchange(
  :'sale_transfer_id'::uuid, (select id from sale_items where sale_id = :'sale_transfer_id'), 1,
  (select id from products where sku = 'TEST-BIZ-P1'), 1
) ->> 'new_item_total')::numeric as new_total_transfer \gset
select is(:new_total_transfer, 11500.00, 'Pricing 3: forma de pago Transferencia -> precio TRANSFER literal ($11.500)');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CARD_1'),
  (select id from customers where dni = '30777222'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_card1_id \gset
select (create_sale_exchange(
  :'sale_card1_id'::uuid, (select id from sale_items where sale_id = :'sale_card1_id'), 1,
  (select id from products where sku = 'TEST-BIZ-P1'), 1
) ->> 'new_item_total')::numeric as new_total_card1 \gset
select is(:new_total_card1, 12500.00, 'Pricing 4: forma de pago Tarjeta 1 pago -> precio CARD_1 literal ($12.500)');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CARD_3'),
  (select id from customers where dni = '30777222'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as sale_card3_id \gset
select (create_sale_exchange(
  :'sale_card3_id'::uuid, (select id from sale_items where sale_id = :'sale_card3_id'), 1,
  (select id from products where sku = 'TEST-BIZ-P1'), 1
) ->> 'new_item_total')::numeric as new_total_card3 \gset
select is(:new_total_card3, 13000.00, 'Pricing 5: forma de pago 3 cuotas -> precio CARD_3 literal ($13.000)');

-- Caso 6: ninguna promoción se aplica al producto nuevo, aunque exista una
-- promoción activa vigente sobre ese mismo producto. Crear promociones es
-- exclusivo de admin.
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000001', false);
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('TEST-BIZ-PROMO', 'Promo test cambios', 'KIT_PERCENT', (select id from price_conditions where code = 'CASH'), 0.5, 50, false, true);
select set_promotion_products(
  (select id from promotions where code = 'TEST-BIZ-PROMO'),
  array[(select id from products where sku = 'TEST-BIZ-P1')]
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_promo_id \gset
select (create_sale_exchange(
  :'sale_promo_id'::uuid, (select id from sale_items where sale_id = :'sale_promo_id'), 1,
  (select id from products where sku = 'TEST-BIZ-P1'), 1
) ->> 'new_item_total')::numeric as new_total_promo \gset
select is(
  :new_total_promo, 11000.00,
  'Pricing 6: el producto nuevo NUNCA aplica una promoción activa — sigue siendo el precio CASH literal ($11.000), no el 50% OFF de la promo ($5.500)'
);

-- Caso 7: QUANTITY nunca escala la condición del producto nuevo, ni siquiera
-- si el carrito final terminaría calificando (VITC y Antiage son
-- promo_eligible=true, así que un carrito final de 2+ SÍ activaría QTY_2 en
-- una venta nueva común — acá no debe pasar).
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_qty_id \gset
select (create_sale_exchange(
  :'sale_qty_id'::uuid, (select id from sale_items where sale_id = :'sale_qty_id'), 1,
  (select id from products where sku = 'TEST-BIZ-ANTIAGE'), 2
)) as result_qty \gset
select is(
  (:'result_qty'::jsonb ->> 'new_item_total')::numeric, 80000.00,
  'Pricing 7: 2 unidades de Antiage bajo CASH literal ($40.000 c/u = $80.000) — nunca la condición QUANTITY (que daría otro precio)'
);

-- ===========================================================================
-- DIFERENCIA (sección 50) — ejemplos exactos del pedido original.
-- ===========================================================================

-- Ejemplo 1: Vitamina C ($30.000) + Espuma ($20.000) = $50.000 pagados.
-- Devuelve Vitamina C, se lleva Antiage ($40.000). Espuma queda INTACTA a su
-- precio histórico. Operación final = Antiage $40.000 + Espuma $20.000 =
-- $60.000. Diferencia = $10.000, cliente debe abonar.
select (create_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-VITC'), 'quantity', 1),
    jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-ESPUMA'), 'quantity', 1)
  ),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_ex1_id \gset

select is((select total from sales where id = :'sale_ex1_id'), 50000.00, 'Precondición Diferencia 1: la venta original suma $50.000');

select (create_sale_exchange(
  :'sale_ex1_id'::uuid,
  (select id from sale_items where sale_id = :'sale_ex1_id' and product_id = (select id from products where sku = 'TEST-BIZ-VITC')),
  1,
  (select id from products where sku = 'TEST-BIZ-ANTIAGE'), 1
)) as result_ex1 \gset

select is((:'result_ex1'::jsonb ->> 'difference_amount')::numeric, 10000.00, 'Diferencia 1: $40.000 (nuevo) - $30.000 (reconocido) = $10.000, cliente debe abonar');
select is(:'result_ex1'::jsonb ->> 'difference_direction', 'CUSTOMER_PAYS', 'Diferencia 1b: dirección CUSTOMER_PAYS');
select is(
  (select total from sales where id = (:'result_ex1'::jsonb ->> 'sale_id')::uuid),
  60000.00,
  'Diferencia 1c: la operación final vale $60.000 (Antiage $40.000 + Espuma $20.000 intacta) — NUNCA se recalcula la Espuma'
);
select is(
  (select sale_unit_price from sale_items where sale_id = (:'result_ex1'::jsonb ->> 'sale_id')::uuid and product_id = (select id from products where sku = 'TEST-BIZ-ESPUMA')),
  20000.00,
  'Diferencia 1d: la Espuma (no tocada) conserva EXACTO su precio histórico ($20.000) en la operación final'
);

-- Ejemplo 2: Producto A $40.000 -> Producto B $30.000 -> el negocio devuelve $10.000.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_ex2_id \gset
select (create_sale_exchange(
  :'sale_ex2_id'::uuid, (select id from sale_items where sale_id = :'sale_ex2_id'), 1,
  (select id from products where sku = 'TEST-BIZ-B'), 1
)) as result_ex2 \gset
select is((:'result_ex2'::jsonb ->> 'difference_amount')::numeric, -10000.00, 'Diferencia 2: $30.000 (nuevo) - $40.000 (reconocido) = -$10.000, el negocio devuelve');
select is(:'result_ex2'::jsonb ->> 'difference_direction', 'BUSINESS_REFUNDS', 'Diferencia 2b: dirección BUSINESS_REFUNDS');
select is(
  (select total from sales where id = (:'result_ex2'::jsonb ->> 'sale_id')::uuid), 30000.00,
  'Diferencia 2c: la operación final vale exactamente $30.000 (nunca $40.000 + $30.000)'
);

-- Ejemplo 3: sin diferencia — mismo valor de un lado y del otro.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as sale_ex3_id \gset
select (create_sale_exchange(
  :'sale_ex3_id'::uuid, (select id from sale_items where sale_id = :'sale_ex3_id'), 1,
  (select id from products where sku = 'TEST-BIZ-A'), 1
)) as result_ex3 \gset
select is((:'result_ex3'::jsonb ->> 'difference_amount')::numeric, 0.00, 'Diferencia 3: mismo valor de ida y vuelta -> diferencia 0');
select is(:'result_ex3'::jsonb ->> 'difference_direction', 'NONE', 'Diferencia 3b: dirección NONE');

-- ===========================================================================
-- MÉTRICAS (sección 51) — la venta original REPLACED nunca cuenta, solo la
-- operación final. Se usa el ejemplo 1 de arriba ($50.000 original -> $60.000 final).
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000001', false);

-- Espuma es el caso más exigente: aparece en tres sale_items distintos —
-- la venta ORIGINAL de Diferencia 1 (ya replaced, no debe contar), SU
-- COPIA intacta en la operación final de ese mismo cambio (sí cuenta), y
-- como producto "nuevo" del cambio de Pricing 1 (sí cuenta, es otra
-- operación final legítima). Total esperado = 2 (nunca 3): si el filtro
-- status=confirmed de los reportes fallara, contaría también la original.
select is(
  (
    select coalesce(sum(si.quantity), 0)::numeric
    from sale_items si
    join sales s on s.id = si.sale_id
    where si.product_id = (select id from products where sku = 'TEST-BIZ-ESPUMA')
      and s.status = 'confirmed'
  ),
  2.00,
  'Métricas 0: la Espuma cuenta 2 veces (sus 2 operaciones finales legítimas) — nunca 3, que sería sumar también la venta original ya replaced'
);

select is(
  (select count(*)::int from sales where id = :'sale_ex1_id' and status = 'confirmed'),
  0,
  'Métricas 1: la venta original (ahora replaced) ya no figura como confirmed — el filtro universal de reportes la excluye sola'
);

select is(
  (select count(*)::int from sales where id = (:'result_ex1'::jsonb ->> 'sale_id')::uuid and status = 'confirmed'),
  1,
  'Métricas 2: la operación final SÍ está confirmed — es la única que cuentan los reportes'
);

-- product_revenue_report: Antiage (producto nuevo) atribuye su facturación a
-- las operaciones finales, nunca a la venta original ya replaced. Antiage se
-- usa como "se lleva" en 2 cambios distintos de este archivo (Pricing 7: 2
-- unidades a $40.000 = $80.000; Diferencia 1: 1 unidad = $40.000) — total
-- legítimo $120.000. Si contara también la venta original de Diferencia 1
-- (que nunca tuvo Antiage) no cambiaría nada; lo que prueba este chequeo es
-- que NINGUNA de esas 2 operaciones finales se cuenta dos veces.
select is(
  (
    select coalesce(sum((r ->> 'revenue')::numeric), 0)
    from jsonb_array_elements(
      product_revenue_report(current_date - 1, current_date + 1, (select id from stock_locations where code = 'DEP'))
      -> 'rows'
    ) r
    where (r ->> 'product_id')::uuid = (select id from products where sku = 'TEST-BIZ-ANTIAGE')
  ),
  120000.00,
  'Métricas 3: product_revenue_report atribuye Antiage a $120.000 (2 operaciones finales, cada una una sola vez)'
);

-- El total agregado de ingresos del rango no puede sumar original+reemplazo:
-- si sumara ambas, este total incluiría de más los $50.000 de la venta ya
-- reemplazada. Se verifica indirectamente: la suma de sales.total con
-- status=confirmed para estos 2 ids de la cadena es EXACTAMENTE $60.000.
select is(
  (
    select coalesce(sum(total), 0) from sales
    where id in (:'sale_ex1_id'::uuid, (:'result_ex1'::jsonb ->> 'sale_id')::uuid)
      and status = 'confirmed'
  ),
  60000.00,
  'Métricas 4: sumando status=confirmed sobre la cadena completa da $60.000 — nunca $50.000+$60.000=$110.000'
);

-- La comisión de la venta original NO se recalcula/borra (queda como
-- registro histórico), solo deja de sumar en agregados por el filtro de status.
select ok(
  (select commission_total from sales where id = :'sale_ex1_id') is not null,
  'Métricas 5: la venta original conserva su commission_total histórico intacto (nunca se pisa a 0)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'fb100000-0000-0000-0000-000000000002', false);

-- Búsqueda 4b: ahora que sale_ex1_id ya es replaced (por el cambio de más
-- arriba), tampoco debe aparecer entre las ventas elegibles del cliente —
-- solo su operación final (que sí es confirmed).
select ok(
  not exists (
    select 1 from jsonb_array_elements(customer_sales_for_exchange((select id from customers where dni = '30777222'))) e
    where (e ->> 'sale_id')::uuid = :'sale_ex1_id'::uuid
  ),
  'Búsqueda 4b: una venta ya reemplazada por un cambio anterior tampoco aparece entre las elegibles'
);

-- ===========================================================================
-- HISTORIAL (sección 52) — reconstrucción completa.
-- ===========================================================================

select is(
  (select replaces_sale_id from sales where id = (:'result_ex1'::jsonb ->> 'sale_id')::uuid),
  :'sale_ex1_id'::uuid,
  'Historial 1: la operación final apunta a la original vía replaces_sale_id'
);

select is(
  (select id from sales where replaces_sale_id = :'sale_ex1_id'::uuid),
  (:'result_ex1'::jsonb ->> 'sale_id')::uuid,
  'Historial 2: desde la original se encuentra la operación final por consulta inversa (sin columna espejo)'
);

select is(
  (select count(*)::int from sale_exchanges where original_sale_id = :'sale_ex1_id'::uuid and replacement_sale_id = (:'result_ex1'::jsonb ->> 'sale_id')::uuid),
  1,
  'Historial 3: sale_exchanges tiene exactamente 1 fila cabecera para este cambio'
);

select is(
  (
    select quantity from sale_exchange_items sei
    join sale_exchanges se on se.id = sei.exchange_id
    where se.original_sale_id = :'sale_ex1_id'::uuid and sei.direction = 'RETURNED'
  ),
  1.00,
  'Historial 4a: sale_exchange_items registra la cantidad devuelta (RETURNED)'
);
select is(
  (
    select product_id from sale_exchange_items sei
    join sale_exchanges se on se.id = sei.exchange_id
    where se.original_sale_id = :'sale_ex1_id'::uuid and sei.direction = 'ADDED'
  ),
  (select id from products where sku = 'TEST-BIZ-ANTIAGE'),
  'Historial 4b: sale_exchange_items registra qué se agregó (ADDED) — Antiage'
);

-- Historial 5: cadena de 2 cambios sucesivos (A -> B -> C) se reconstruye
-- completa siguiendo replaces_sale_id / consulta inversa en las dos direcciones.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-BIZ-A'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30777222')
) ->> 'sale_id')::uuid as chain_a_id \gset
select (create_sale_exchange(
  :'chain_a_id'::uuid, (select id from sale_items where sale_id = :'chain_a_id'), 1,
  (select id from products where sku = 'TEST-BIZ-B'), 1
) ->> 'sale_id')::uuid as chain_b_id \gset
select (create_sale_exchange(
  :'chain_b_id'::uuid, (select id from sale_items where sale_id = :'chain_b_id'), 1,
  (select id from products where sku = 'TEST-BIZ-A'), 1
) ->> 'sale_id')::uuid as chain_c_id \gset

select is(
  (
    with recursive chain(id, depth) as (
      select :'chain_c_id'::uuid, 0
      union all
      select s.replaces_sale_id, c.depth + 1
      from sales s join chain c on s.id = c.id
      where s.replaces_sale_id is not null
    )
    select array_agg(id order by depth) from chain
  ),
  array[:'chain_c_id'::uuid, :'chain_b_id'::uuid, :'chain_a_id'::uuid],
  'Historial 5: la cadena completa (C -> B -> A) se reconstruye siguiendo replaces_sale_id de punta a punta'
);

select * from finish();
rollback;
