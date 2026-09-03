-- pgTAP: motor de precios + ciclo de vida de una venta (create_sale / cancel_sale).
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(11);

-- Fixtures
insert into auth.users (id, email) values
  ('b0000000-0000-0000-0000-000000000001', 'admin.pricing@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'b0000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'b0000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'b0000000-0000-0000-0000-000000000001', false);

-- Caso 1: 1 Vitamina C + Transferencia = 40.770
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from payment_methods where code = 'TRANSFER')
  ) ->> 'total')::numeric,
  40770.00,
  'Caso 1: Vitamina C + Transferencia = 40.770'
);

-- Caso 2: Efectivo = 38.500
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  38500.00,
  'Caso 2: Vitamina C + Efectivo = 38.500'
);

-- Caso 3: 3 cuotas = precio lista (45.300)
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from payment_methods where code = 'CARD_3')
  ) ->> 'total')::numeric,
  45300.00,
  'Caso 3: Vitamina C + 3 cuotas = precio lista 45.300'
);

-- Caso 6 (ajuste "Condiciones de precio por cantidad -> Promociones"): 3
-- productos + transferencia resuelve la condición por MEDIO DE PAGO — nunca
-- una condición QUANTITY (esa lógica migró a Promociones, tipo
-- QUANTITY_DISCOUNT, evaluada aparte en fn_apply_promotions).
select is(
  quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'PROD-OJOS'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'TRANSFER')
  ) ->> 'applied_price_condition_code',
  'TRANSFER',
  'Caso 6: 3 productos + transferencia sigue resolviendo TRANSFER, nunca una condición por cantidad'
);

-- Caso 7: ACC-NEC bajo una condición sin precio configurado -> rechazar
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'ACC-NEC'), 'quantity', 1)),
    (select id from payment_methods where code = 'CARD_3')
  ) ->> 'ok')::boolean,
  false,
  'Caso 7: ACC-NEC sin precio para 3 cuotas se rechaza (nunca $0)'
);

-- Caso 8/9: venta de KIT-VN x2 descuenta componentes y respeta stock del componente limitante
select lives_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku='KIT-VN'), 'quantity', 2)),
    (select id from stock_locations where code='SED-37'),
    (select id from sales_channels where code='BRANCH'),
    (select id from payment_methods where code='CASH')
  )$$,
  'Caso 8: vender 2×KIT-VN con stock suficiente no lanza excepción'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku='PROD-VITC')
     and location_id = (select id from stock_locations where code='SED-37')),
  15.00,
  'Caso 8: KIT-VN x2 descontó 2 unidades de Vitamina C (17 -> 15)'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku='PROD-NIAC')
     and location_id = (select id from stock_locations where code='SED-37')),
  45.00,
  'Caso 8: KIT-VN x2 descontó 2 unidades de Niacinamida (47 -> 45)'
);

-- Caso 9: stock insuficiente en un componente rechaza toda la venta (atomicidad)
select throws_ok(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku='KIT-VN'), 'quantity', 999)),
    (select id from stock_locations where code='SED-37'),
    (select id from sales_channels where code='BRANCH'),
    (select id from payment_methods where code='CASH')
  )$$,
  'Caso 9: stock insuficiente en componente de kit rechaza la venta completa'
);

-- Caso 10: cancelar la venta repone exactamente el stock descontado
select lives_ok(
  format('select cancel_sale(%L, %L)', (select id from sales order by created_at desc limit 1), 'Test pgTAP'),
  'Caso 10: cancel_sale no lanza excepción sobre una venta confirmada'
);

select is(
  (select quantity from inventory_balances where product_id = (select id from products where sku='PROD-VITC')
     and location_id = (select id from stock_locations where code='SED-37')),
  17.00,
  'Caso 10: al cancelar, Vitamina C vuelve a 17 (stock repuesto exactamente)'
);

select * from finish();
rollback;
