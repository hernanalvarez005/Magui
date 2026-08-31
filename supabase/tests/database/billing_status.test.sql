-- pgTAP: Bloque A — facturación pendiente + cuenta de ingreso. Casos 1-11 de
-- la sección 35 del pedido "Facturación pendiente + cuenta de cobro + orden
-- de productos". Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(15);

insert into auth.users (id, email) values
  ('d1000000-0000-0000-0000-000000000001', 'admin.billing@test.maguirejuve.com'),
  ('d1000000-0000-0000-0000-000000000002', 'seller.billing@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'd1000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'd1000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'd1000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'd1000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);

select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 50, 'RECEPTION');
insert into public.customers (full_name, dni) values ('Cliente Con DNI Test', '30111222');
insert into public.customers (full_name) values ('Cliente Sin DNI Test');

set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000002', false);

-- ---------------------------------------------------------------------------
-- Caso 1: Transferencia + Banco Galicia -> PENDING.
-- ---------------------------------------------------------------------------
select is(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'TRANSFER'),
    (select id from customers where dni = '30111222'),
    null, null, null, null, now(), false, null, null, false,
    (select id from payment_accounts where code = 'BANCO_GALICIA')
  ) ->> 'billing_status'),
  'PENDING',
  'Caso 1: Transferencia + Banco Galicia -> PENDING'
);

-- ---------------------------------------------------------------------------
-- Caso 2: Transferencia + Mercado Pago -> PENDING.
-- ---------------------------------------------------------------------------
select is(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'TRANSFER'),
    (select id from customers where dni = '30111222'),
    null, null, null, null, now(), false, null, null, false,
    (select id from payment_accounts where code = 'MERCADO_PAGO')
  ) ->> 'billing_status'),
  'PENDING',
  'Caso 2: Transferencia + Mercado Pago -> PENDING'
);

-- ---------------------------------------------------------------------------
-- Caso 3: CARD_1 (1 pago) + Banco Galicia -> PENDING.
-- ---------------------------------------------------------------------------
select is(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'CARD_1'),
    (select id from customers where dni = '30111222'),
    null, null, null, null, now(), false, null, null, false,
    (select id from payment_accounts where code = 'BANCO_GALICIA')
  ) ->> 'billing_status'),
  'PENDING',
  'Caso 3: CARD_1 + Banco Galicia -> PENDING'
);

-- ---------------------------------------------------------------------------
-- Caso 4: CARD_3 (3 cuotas) + Mercado Pago -> PENDING.
-- ---------------------------------------------------------------------------
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CARD_3'),
  (select id from customers where dni = '30111222'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'MERCADO_PAGO')
) ->> 'sale_id')::uuid as caso4_sale_id \gset

select is(
  (select billing_status::text from sales where id = :'caso4_sale_id'),
  'PENDING',
  'Caso 4: CARD_3 + Mercado Pago -> PENDING'
);

-- ---------------------------------------------------------------------------
-- Caso 5: Efectivo -> NOT_REQUIRED (sin cuenta, sin cliente).
-- ---------------------------------------------------------------------------
select is(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'billing_status'),
  'NOT_REQUIRED',
  'Caso 5: Efectivo -> NOT_REQUIRED'
);

-- ---------------------------------------------------------------------------
-- Caso 6: venta sin costo -> NOT_REQUIRED, aunque el medio "de base" elegido
-- sea transferencia (is_free_sale manda por encima de todo).
-- ---------------------------------------------------------------------------
select is(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'TRANSFER'),
    null, null, null, null, null, now(), true, 'GIFT', 'Regalo test'
  ) ->> 'billing_status'),
  'NOT_REQUIRED',
  'Caso 6: venta sin costo -> NOT_REQUIRED aunque el medio de pago sea facturable'
);

-- ---------------------------------------------------------------------------
-- Caso 7: operación facturable sin cuenta -> rechazada.
-- ---------------------------------------------------------------------------
select throws_like(
  $$select create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    (select id from stock_locations where code = 'DEP'),
    (select id from sales_channels limit 1),
    (select id from payment_methods where code = 'TRANSFER'),
    (select id from customers where dni = '30111222')
  )$$,
  '%cuenta donde ingresó el dinero%',
  'Caso 7: transferencia sin payment_account_id se rechaza'
);

-- ---------------------------------------------------------------------------
-- Caso 8: operación facturable sin cliente/DNI -> rechazada (sin cliente, y
-- con un cliente que no tiene DNI cargado).
-- ---------------------------------------------------------------------------
select throws_like(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
      (select id from stock_locations where code = 'DEP'),
      (select id from sales_channels limit 1),
      (select id from payment_methods where code = 'TRANSFER'),
      null, null, null, null, null, now(), false, null, null, false,
      '%s'::uuid
    )$$,
    (select id from payment_accounts where code = 'BANCO_GALICIA')
  ),
  '%cliente identificado con nombre y DNI%',
  'Caso 8a: transferencia facturable sin cliente se rechaza'
);

select throws_like(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
      (select id from stock_locations where code = 'DEP'),
      (select id from sales_channels limit 1),
      (select id from payment_methods where code = 'TRANSFER'),
      (select id from customers where full_name = 'Cliente Sin DNI Test'),
      null, null, null, null, now(), false, null, null, false,
      '%s'::uuid
    )$$,
    (select id from payment_accounts where code = 'BANCO_GALICIA')
  ),
  '%cliente identificado con nombre y DNI%',
  'Caso 8b: transferencia facturable con cliente SIN dni se rechaza'
);

-- ---------------------------------------------------------------------------
-- Caso 9: admin marca como facturada -> INVOICED.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);

select is(
  (mark_sale_invoiced(:'caso4_sale_id') ->> 'billing_status'),
  'INVOICED',
  'Caso 9: admin marca la venta como facturada -> INVOICED'
);

select ok(
  (select invoiced_at from sales where id = :'caso4_sale_id') is not null
  and (select invoiced_by from sales where id = :'caso4_sale_id') = 'd1000000-0000-0000-0000-000000000001'::uuid,
  'Caso 9b: invoiced_at e invoiced_by quedan registrados'
);

-- ---------------------------------------------------------------------------
-- Caso 10: un vendedor no puede marcar como facturada.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER'),
  (select id from customers where dni = '30111222'),
  null, null, null, null, now(), false, null, null, false,
  (select id from payment_accounts where code = 'BANCO_GALICIA')
) ->> 'sale_id')::uuid as caso10_sale_id \gset

select throws_ok(
  format($$select mark_sale_invoiced('%s'::uuid)$$, :'caso10_sale_id'),
  'Caso 10: un vendedor no puede marcar una venta como facturada'
);

-- ---------------------------------------------------------------------------
-- Caso 11: una venta anulada no aparece entre pendientes.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'd1000000-0000-0000-0000-000000000001', false);

select is(
  (select count(*)::int from sales where id = :'caso10_sale_id' and status = 'confirmed' and billing_status = 'PENDING'),
  1,
  'Precondición Caso 11: la venta aparece pendiente antes de anularla'
);

select cancel_sale(:'caso10_sale_id', 'Prueba: cancelar una venta pendiente de facturar');

select is(
  (select count(*)::int from sales where id = :'caso10_sale_id' and status = 'confirmed' and billing_status = 'PENDING'),
  0,
  'Caso 11: tras anularla, la venta ya no aparece en el query de pendientes (status <> confirmed)'
);

select is(
  (select billing_status::text from sales where id = :'caso10_sale_id'),
  'PENDING',
  'Caso 11b: billing_status se conserva como snapshot (no se borra), solo la deja afuera el filtro status=confirmed'
);

select * from finish();
rollback;
