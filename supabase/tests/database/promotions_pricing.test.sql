-- pgTAP: Bloque C — promociones no acumulables con precio base propio.
-- Casos 1-9 de la sección 30 del pedido "Stock, promociones y anulación de
-- ventas". Correr con: supabase test db (Supabase CLI + Docker).
begin;
select plan(10);

insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-000000000001', 'admin.promopricing@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'a0000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'a0000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'a0000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Caso 1 y 2: 20% sobre Lista, no se combina con transferencia.
-- Vitamina C: Lista 45300, Transferencia 40770. 20% sobre LISTA = 36240.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
values ('T-VITC-20', 'Vitamina C 20% OFF', 'KIT_PERCENT',
  (select id from price_conditions where rule_type = 'BASE'), 0.20, 5, false);
select set_promotion_products(
  (select id from promotions where code = 'T-VITC-20'),
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
  36240.00,
  'Caso 1: 20% sobre Lista da 36240 (45300 * 0,80)'
);

select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
        (select id from payment_methods where code = 'TRANSFER')
      ) -> 'lines'
    ) l
  ),
  36240.00,
  'Caso 2: promo 20% + transferencia -> sigue siendo 36240, NUNCA 40770 con 20% adicional'
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
  36240.00,
  'Caso 3: promo 20% + efectivo -> también 36240 (misma condición base, no la de efectivo)'
);

-- ---------------------------------------------------------------------------
-- Caso 4: promoción declarada sobre la condición Transferencia -> esa es la
-- BASE (no se "aplica transferencia de nuevo" encima).
-- Niacinamida: Transferencia 38250. 15% off sobre esa base = 32512.50.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable)
values ('T-NIAC-TRANSFER', 'Niacinamida 15% sobre transferencia', 'KIT_PERCENT',
  (select id from price_conditions where code = 'TRANSFER'), 0.15, 6, false);
select set_promotion_products(
  (select id from promotions where code = 'T-NIAC-TRANSFER'),
  array[(select id from products where sku = 'PROD-NIAC')]
);

select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
  ),
  32512.50,
  'Caso 4: promo sobre condición Transferencia paga con Efectivo -> usa Transferencia como base (38250 * 0,85), no Efectivo'
);

-- ---------------------------------------------------------------------------
-- Caso 5 y 6: 3x2 — generalización a múltiplos de group_size.
-- Espuma: Lista 36000.
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable)
values ('T-ESP-3X2', 'Espuma 3x2', 'THREE_FOR_TWO',
  (select id from price_conditions where rule_type = 'BASE'), 3, 7, false);
select set_promotion_products(
  (select id from promotions where code = 'T-ESP-3X2'),
  array[(select id from products where sku = 'PROD-ESP')]
);

select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 3)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where (l ->> 'sale_unit_price')::numeric = 0
  ),
  1,
  'Caso 5: 3 unidades -> 1 gratis (floor(3/3))'
);

select is(
  (
    select sum((l ->> 'quantity')::numeric)
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ESP'), 'quantity', 6)),
        (select id from payment_methods where code = 'CASH')
      ) -> 'lines'
    ) l
    where (l ->> 'sale_unit_price')::numeric = 0
  ),
  2::numeric,
  'Caso 6: 6 unidades -> 2 gratis (floor(6/3))'
);

-- ---------------------------------------------------------------------------
-- Caso 7 y 8: promoción vencida / desactivada -> precio normal (medio de pago).
-- ---------------------------------------------------------------------------
insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, valid_from, valid_until)
values ('T-EXPIRED', 'Promo vencida', 'KIT_PERCENT',
  (select id from price_conditions where rule_type = 'BASE'), 0.5, 8, false,
  now() - interval '10 days', now() - interval '1 day');
select set_promotion_products(
  (select id from promotions where code = 'T-EXPIRED'),
  array[(select id from products where sku = 'PROD-OJOS')]
);

select is(
  (
    select (l ->> 'applied_promotion_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-OJOS'), 'quantity', 1)),
        (select id from payment_methods where code = 'TRANSFER')
      ) -> 'lines'
    ) l
  ),
  null,
  'Caso 7: promoción vencida (valid_until en el pasado) no se aplica -> precio normal por medio de pago'
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active)
values ('T-INACTIVE', 'Promo desactivada', 'KIT_PERCENT',
  (select id from price_conditions where rule_type = 'BASE'), 0.5, 9, false, false);
select set_promotion_products(
  (select id from promotions where code = 'T-INACTIVE'),
  array[(select id from products where sku = 'PROD-ANTI')]
);

select is(
  (
    select (l ->> 'applied_promotion_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-ANTI'), 'quantity', 1)),
        (select id from payment_methods where code = 'TRANSFER')
      ) -> 'lines'
    ) l
  ),
  null,
  'Caso 8: promoción desactivada (active = false) no se aplica -> precio normal por medio de pago'
);

-- ---------------------------------------------------------------------------
-- Caso 9: snapshot histórico — editar/desactivar la promoción después NO
-- cambia una venta ya confirmada.
-- ---------------------------------------------------------------------------
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'PROD-VITC'), 10, 'RECEPTION');

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'TRANSFER')
) ->> 'sale_id')::uuid as new_sale_id \gset

select is(
  (select sale_unit_price from sale_items where sale_id = :'new_sale_id'),
  36240.00,
  'Caso 9a: la venta confirmada queda con el precio promocional vigente al momento de la venta'
);

-- Ahora se desactiva la promoción y se le cambia el % — la venta ya
-- confirmada no debe cambiar (sale_items es un snapshot inmutable).
update public.promotions set active = false, discount_percent = 0.9 where code = 'T-VITC-20';

select is(
  (select sale_unit_price from sale_items where sale_id = :'new_sale_id'),
  36240.00,
  'Caso 9b: desactivar/editar la promoción después NO recalcula sale_items de la venta histórica'
);

select * from finish();
rollback;
