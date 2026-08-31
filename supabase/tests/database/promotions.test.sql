-- pgTAP: motor de promociones (3x2 / duo% / kit%) — bloque 7.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(10);

insert into auth.users (id, email) values
  ('d0000000-0000-0000-0000-000000000001', 'admin.promos@test.maguirejuve.com'),
  ('d0000000-0000-0000-0000-000000000002', 'seller.promos@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'd0000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'd0000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'd0000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'd0000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';

set role authenticated;
select set_config('request.jwt.claim.sub', 'd0000000-0000-0000-0000-000000000001', false);

-- Fixtures de promociones (admin). El insert de `promotions` va suelto (no
-- dentro de un WITH anidado en el select del assert): Postgres no permite un
-- WITH con INSERT/RETURNING que no esté al tope del statement.
insert into public.promotions (code, name, type, price_condition_id, priority, stackable)
  values ('TEST-3X2', '3x2 test', 'THREE_FOR_TWO', (select id from price_conditions where rule_type = 'BASE'), 10, false);

select is(
  (select (set_promotion_products(
     (select id from promotions where code = 'TEST-3X2'),
     array[(select id from products where sku = 'PROD-ESP'), (select id from products where sku = 'PROD-ANTI')]
   ) ->> 'product_count')::int),
  2,
  'Alta 3x2: 2 productos elegibles cargados en una sola transacción'
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
  values ('TEST-DUO', 'Duo test', 'DUO_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.15, 20, true);

select lives_ok(
  $$select set_promotion_products(
    (select id from promotions where code = 'TEST-DUO'),
    array[(select id from products where sku = 'PROD-NIAC'), (select id from products where sku = 'PROD-VITC')]
  )$$,
  'Alta duo: exactamente 2 productos no revienta el constraint deferred'
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
  values ('TEST-DUO-BAD', 'Duo incompleto', 'DUO_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.15, 21, true);

select throws_ok(
  $$select set_promotion_products(
    (select id from promotions where code = 'TEST-DUO-BAD'),
    array[(select id from products where sku = 'PROD-OJOS')]
  )$$,
  'Duo con 1 solo producto: el constraint deferred lo rechaza'
);

select throws_ok(
  $$select set_promotion_products(
    (select id from promotions where code = 'TEST-3X2'),
    array[(select id from products where sku = 'PROD-VITC')]
  )$$,
  'Un producto no puede quedar en dos promociones activas a la vez'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'd0000000-0000-0000-0000-000000000002', false);

select throws_ok(
  $$insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority)
    values ('TEST-SELLER', 'x', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.1, 1)$$,
  'Vendedora no puede crear promociones (RLS)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'd0000000-0000-0000-0000-000000000001', false);

-- 4 unidades de PROD-ESP con el 3x2 activo -> floor(4/3) = 1 unidad gratis, la más barata
select is(
  jsonb_array_length(
    quote_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 4)),
      (select id from payment_methods where code = 'CASH')
    ) -> 'lines'
  ),
  2,
  '3x2 con 4 unidades de un solo producto parte la línea en pagas + gratis'
);

select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 4)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where (l ->> 'sale_unit_price')::numeric = 0
      and (l ->> 'quantity')::numeric = 1
  ),
  1,
  '3x2: exactamente 1 unidad queda a $0'
);

-- Cruce de productos: 2x PROD-ESP (más barato) + 1x PROD-ANTI (más caro) -> la gratis es de PROD-ESP
select is(
  (
    select (l ->> 'product_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 2),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-ANTI'), 'quantity', 1)
        ),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where (l ->> 'sale_unit_price')::numeric = 0
  ),
  (select id from products where sku = 'PROD-ESP')::text,
  '3x2 entre productos de distinto precio: la unidad gratis es siempre la más barata'
);

-- Duo: niac + vitc juntos -> ambas líneas quedan con applied_promotion_id seteado
select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)
        ),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
  ),
  2,
  'Duo: ambos productos del par reciben el descuento cuando están juntos en el carrito'
);

-- No-stackable excluye a las stackable: 3x2 (no combinable) + duo (combinable) en el mismo carrito -> solo el 3x2 aplica
select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)
        ),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
  ),
  1,
  'No-stackable (3x2) excluye a la stackable (duo) cuando ambas matchean el mismo carrito'
);

select * from finish();
rollback;
