-- pgTAP: Bloque E — precios automáticos por % + edición manual. Casos 3, 4,
-- 7, 8 y 9 de la sección 16 del pedido (los casos 1/2/5/6, la sugerencia
-- matemática pura, están en tests/discount-suggestion.test.ts — acá se
-- prueba que la fuente de verdad de una venta SIGUE siendo product_prices,
-- nunca discount_percent). Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(8);

insert into auth.users (id, email) values
  ('a2000000-0000-0000-0000-000000000001', 'admin.discount@test.maguirejuve.com'),
  ('a2000000-0000-0000-0000-000000000002', 'seller.discount@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'a2000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'a2000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'a2000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Caso 3: el admin guarda un precio Efectivo distinto del matemático
-- (redondeo comercial) y, al releer, se mantiene exactamente ese valor.
-- Caso 7 (implícito): guardarlo no genera ningún error de validación —
-- set_product_price solo exige amount > 0, nunca lo compara contra Lista %.
-- ---------------------------------------------------------------------------
select set_product_price(
  (select id from products where sku = 'PROD-VITC'),
  (select id from price_conditions where rule_type = 'BASE'),
  33000
);

select lives_ok(
  $$select set_product_price(
    (select id from products where sku = 'PROD-VITC'),
    (select id from price_conditions where code = 'CASH'),
    30000 -- la sugerencia matemática sería 29.700 (10% off) — 30.000 es el redondeo comercial
  )$$,
  'Caso 7: guardar un precio redondeado (30.000, no 29.700) no genera error de validación'
);

select is(
  (select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-VITC')
      and price_condition_id = (select id from price_conditions where code = 'CASH')
      and active = true),
  30000.00,
  'Caso 3: el precio Efectivo persistido es exactamente el redondeo comercial (30.000), no el matemático (29.700)'
);

-- ---------------------------------------------------------------------------
-- Caso 4: una venta en efectivo usa el precio final guardado (30.000), NUNCA
-- recalcula 29.700 a partir del %.
-- ---------------------------------------------------------------------------
select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
  ),
  30000.00,
  'Caso 4: quote_sale devuelve el precio final guardado (30.000) — nunca recalcula desde discount_percent'
);

-- ---------------------------------------------------------------------------
-- Caso 8: una promoción con condición base "Efectivo" toma como base el
-- PRECIO FINAL guardado (30.000), no el matemático (29.700).
-- Promo 20% OFF -> 30.000 * 0,80 = 24.000.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
values ('T-DISCOUNT-CASH', 'Vitamina C 20% sobre Efectivo', 'KIT_PERCENT',
  (select id from price_conditions where code = 'CASH'), 0.20, 5, false);
select set_promotion_products(
  (select id from promotions where code = 'T-DISCOUNT-CASH'),
  array[(select id from products where sku = 'PROD-VITC')]
);

select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
  ),
  24000.00,
  'Caso 8: la promoción sobre condición base Efectivo parte de 30.000 (guardado), no de 29.700 (matemático) -> 24.000'
);

-- ---------------------------------------------------------------------------
-- Caso 9: cambiar el % de una condición después de una venta NO modifica el
-- snapshot histórico de esa venta.
-- ---------------------------------------------------------------------------
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 5, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH')
) ->> 'sale_id')::uuid as pct_sale_id \gset

select is(
  (select sale_unit_price from sale_items where sale_id = :'pct_sale_id'),
  24000.00,
  'Precondición Caso 9: la venta confirmada quedó con el precio promocional vigente (24.000)'
);

-- Ahora se cambia el % de Efectivo (de 15% a 50%) — no debería afectar nada
-- de lo ya vendido, ni siquiera indirectamente (discount_percent nunca se
-- lee en una venta, ver Caso 4).
update public.price_conditions set discount_percent = 0.50 where code = 'CASH';

select is(
  (select sale_unit_price from sale_items where sale_id = :'pct_sale_id'),
  24000.00,
  'Caso 9: cambiar el % de la condición después NO recalcula sale_items de la venta histórica'
);

select is(
  (select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-VITC')
      and price_condition_id = (select id from price_conditions where code = 'CASH')
      and active = true),
  30000.00,
  'Caso 9b: tampoco toca el precio Efectivo vigente (sigue en 30.000) — el % editado es solo la sugerencia para la PRÓXIMA edición'
);

-- Vendedora no puede modificar el % (RLS ya cubierta por price_conditions_admin_update
-- — igual criterio que active/priority en price-conditions-table.tsx). Una policy de
-- UPDATE que no matchea filtra el WHERE a 0 filas SIN lanzar excepción (comportamiento
-- estándar de RLS en Postgres, no un bug), así que se verifica que el valor no cambió.
set role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', false);
update public.price_conditions set discount_percent = 0.99 where code = 'CASH';

set role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000001', false);
select is(
  (select discount_percent from price_conditions where code = 'CASH'),
  0.50,
  'Caso 15: una vendedora no puede modificar el % de una condición (RLS deja el UPDATE en 0 filas, sigue en 0,50)'
);

select * from finish();
rollback;
