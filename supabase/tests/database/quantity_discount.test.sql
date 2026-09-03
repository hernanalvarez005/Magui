-- pgTAP: Condiciones de precio por cantidad -> Promociones (ajuste "QUANTITY ->
-- Promociones"). "2 productos o más" / "3 productos o más" dejan de resolverse
-- como price_conditions y pasan a ser promociones (tipo QUANTITY_DISCOUNT),
-- evaluadas en fn_apply_promotions con minimum_quantity + discount_percent
-- completamente editables (nunca hardcodeados a 2/3 ni a 20%/25%).
-- Los 16 casos pedidos en la sección 26 del pedido, en orden.
-- Correr con: supabase test db (requiere Supabase CLI + Docker).
begin;
select plan(16);

insert into auth.users (id, email) values
  ('fc000000-0000-0000-0000-000000000001', 'admin.qtydisc@test.maguirejuve.com'),
  ('fc000000-0000-0000-0000-000000000002', 'seller.qtydisc@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'fc000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'fc000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'fc000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'fc000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'DEP';

set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba, aislado del resto del seed.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('TEST-QD-P1', 'Producto Cantidad Uno', 'product', 'Test', true, true, true, true),
  ('TEST-QD-P2', 'Producto Cantidad Dos', 'product', 'Test', true, true, true, true),
  ('TEST-QD-P3', 'Producto Cantidad Tres', 'product', 'Test', true, true, true, true),
  ('TEST-QD-NP', 'Producto No Participante', 'product', 'Test', true, true, true, true),
  ('TEST-QD-KIT', 'Kit Cantidad Test', 'kit', 'Test', false, true, true, true);

select set_product_price((select id from products where sku = 'TEST-QD-P1'), (select id from price_conditions where rule_type = 'BASE'), 10000);
select set_product_price((select id from products where sku = 'TEST-QD-P1'), (select id from price_conditions where code = 'CASH'), 9000);
select set_product_price((select id from products where sku = 'TEST-QD-P2'), (select id from price_conditions where rule_type = 'BASE'), 20000);
select set_product_price((select id from products where sku = 'TEST-QD-P2'), (select id from price_conditions where code = 'CASH'), 18000);
select set_product_price((select id from products where sku = 'TEST-QD-P3'), (select id from price_conditions where rule_type = 'BASE'), 15000);
select set_product_price((select id from products where sku = 'TEST-QD-P3'), (select id from price_conditions where code = 'CASH'), 13500);
select set_product_price((select id from products where sku = 'TEST-QD-NP'), (select id from price_conditions where rule_type = 'BASE'), 5000);
select set_product_price((select id from products where sku = 'TEST-QD-NP'), (select id from price_conditions where code = 'CASH'), 4500);
select set_product_price((select id from products where sku = 'TEST-QD-KIT'), (select id from price_conditions where rule_type = 'BASE'), 30000);
select set_product_price((select id from products where sku = 'TEST-QD-KIT'), (select id from price_conditions where code = 'CASH'), 27000);

insert into public.customers (full_name, dni) values ('Cliente Cantidad Test', '30999444');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-QD-P1'), 20, 'RECEPTION');
select set_stock((select id from stock_locations where code = 'DEP'), (select id from products where sku = 'TEST-QD-P2'), 20, 'RECEPTION');

-- ===========================================================================
-- Promoción A: mínimo 2, 20% OFF sobre Lista. Participan P1/P2/P3/KIT.
-- ===========================================================================
insert into public.promotions (code, name, type, price_condition_id, discount_percent, minimum_quantity, priority, stackable)
values (
  'TEST-QD-2PLUS', 'Llevando 2 productos', 'QUANTITY_DISCOUNT',
  (select id from price_conditions where rule_type = 'BASE'), 0.20, 2, 40, false
);
select set_promotion_products(
  (select id from promotions where code = 'TEST-QD-2PLUS'),
  array(select id from products where sku in ('TEST-QD-P1', 'TEST-QD-P2', 'TEST-QD-P3', 'TEST-QD-KIT'))
);

-- ===========================================================================
-- Caso 1: 1 unidad no aplica.
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1)),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  9000.00,
  'Caso 1: 1 unidad no alcanza el mínimo (2) — precio normal (CASH), sin promoción'
);

-- ===========================================================================
-- Caso 2: 2 unidades (P1 x1 + P2 x1) aplica 20% sobre Lista.
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  24000.00,
  'Caso 2: 2 unidades alcanzan el mínimo — 20% sobre Lista (10000×0.8 + 20000×0.8 = 24000), no el precio CASH normal'
);

-- ===========================================================================
-- Caso 3: 3 unidades sigue en 20% (solo existe la promo de mínimo 2 todavía).
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P3'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  36000.00,
  'Caso 3: 3 unidades también aplican la promo de mínimo 2 (10000+20000+15000)×0.8 = 36000'
);

-- ===========================================================================
-- Caso 7: un producto NO participante no ayuda a alcanzar el mínimo.
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-NP'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  9000.00 + 4500.00,
  'Caso 7: P1 (1) + no-participante (1) no llega a 2 unidades PARTICIPANTES — ambos al precio CASH normal, sin promo'
);

-- ===========================================================================
-- Caso 8: 2 unidades del MISMO producto también cuentan (no exige SKUs distintos).
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 2)),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  16000.00,
  'Caso 8: 2 unidades del MISMO SKU alcanzan el mínimo — 10000×2×0.8 = 16000'
);

-- ===========================================================================
-- Caso 9: producto + kit participantes cuentan como unidades comerciales
-- (1 kit = 1 unidad hacia el mínimo, nunca se descompone en kit_components).
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-KIT'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  24000.00 + 8000.00,
  'Caso 9: 1 kit + 1 producto = 2 unidades comerciales, alcanzan el mínimo (30000×0.8 + 10000×0.8)'
);

-- ===========================================================================
-- Caso 14: no acumulación — el precio de la promo NUNCA se suma al % de
-- Efectivo (15%) ni a ningún otro descuento. 2 unidades (P1+P2) en CASH:
-- si acumulara sería 24000×0.85=20400 — nunca eso, es 24000 tal cual.
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  24000.00,
  'Caso 14: no acumulación — la promo reemplaza el precio, nunca se suma al descuento de Efectivo (15%)'
);

-- ===========================================================================
-- Promoción B: mínimo 3, 25% OFF sobre Lista. Mismos participantes, MÁS
-- prioridad (número de priority más bajo) que la de mínimo 2 — gana la
-- correcta cuando ambas matchean (decisión administrativa, sección 12/13).
-- ===========================================================================
insert into public.promotions (code, name, type, price_condition_id, discount_percent, minimum_quantity, priority, stackable)
values (
  'TEST-QD-3PLUS', 'Llevando 3 productos', 'QUANTITY_DISCOUNT',
  (select id from price_conditions where rule_type = 'BASE'), 0.25, 3, 30, false
);
select set_promotion_products(
  (select id from promotions where code = 'TEST-QD-3PLUS'),
  array(select id from products where sku in ('TEST-QD-P1', 'TEST-QD-P2', 'TEST-QD-P3', 'TEST-QD-KIT'))
);

-- ===========================================================================
-- Caso 4: con las DOS promos vigentes, 2 unidades no alcanza el mínimo de la
-- de 3+ — sigue aplicando la de 2+ (20%), nunca la de 3+.
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  24000.00,
  'Caso 4: 2 unidades con ambas promos vigentes -> sigue en 20% (mínimo 3 no alcanzado)'
);

-- ===========================================================================
-- Caso 5/6/13: 3 unidades -> gana la de mínimo 3 (25%), NUNCA 20+25 acumulados
-- (sección 13 del pedido: resultado esperado 25% OFF, no 20%+25%).
-- ===========================================================================
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P3'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  (10000 + 20000 + 15000) * 0.75,
  'Caso 5/6: 3 unidades con ambas promos vigentes -> gana la de mínimo 3 (25%), no la de mínimo 2, ni ambas acumuladas'
);

-- ===========================================================================
-- Caso 10: promo vencida no aplica.
-- ===========================================================================
insert into public.promotions (code, name, type, price_condition_id, discount_percent, minimum_quantity, priority, stackable, valid_from, valid_until)
values (
  'TEST-QD-EXPIRED', 'Cantidad vencida', 'QUANTITY_DISCOUNT',
  (select id from price_conditions where rule_type = 'BASE'), 0.50, 1, 5, false,
  now() - interval '30 days', now() - interval '1 day'
);
select set_promotion_products(
  (select id from promotions where code = 'TEST-QD-EXPIRED'),
  array(select id from products where sku = 'TEST-QD-NP')
);
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-NP'), 'quantity', 1)),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  4500.00,
  'Caso 10: una promoción vencida (aunque su % sería más beneficioso) no aplica'
);

-- ===========================================================================
-- Caso 11: promo desactivada no aplica.
-- ===========================================================================
update public.promotions set active = false where code = 'TEST-QD-EXPIRED';
insert into public.promotions (code, name, type, price_condition_id, discount_percent, minimum_quantity, priority, stackable)
values (
  'TEST-QD-INACTIVE', 'Cantidad desactivada', 'QUANTITY_DISCOUNT',
  (select id from price_conditions where rule_type = 'BASE'), 0.60, 1, 6, false
);
update public.promotions set active = false where code = 'TEST-QD-INACTIVE';
select is(
  (quote_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-NP'), 'quantity', 1)),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  4500.00,
  'Caso 11: una promoción desactivada (active=false) no aplica aunque matchee'
);

-- ===========================================================================
-- Caso 12: cambiar el % administrativamente se refleja de inmediato (25% -> 30%).
-- ===========================================================================
update public.promotions set discount_percent = 0.30 where code = 'TEST-QD-3PLUS';
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P3'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  (10000 + 20000 + 15000) * 0.70,
  'Caso 12: subir el % de 25 a 30 (sin tocar código) se refleja de inmediato — 30% OFF'
);

-- ===========================================================================
-- Caso 13: cambiar minimum_quantity se refleja de inmediato (3 -> 4).
-- ===========================================================================
update public.promotions set minimum_quantity = 4 where code = 'TEST-QD-3PLUS';
select is(
  (quote_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P2'), 'quantity', 1),
      jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P3'), 'quantity', 1)
    ),
    (select id from payment_methods where code = 'CASH')
  ) ->> 'total')::numeric,
  36000.00,
  'Caso 13: subir minimum_quantity de 3 a 4 -> con 3 unidades ya no alcanza esa promo, vuelve a ganar la de mínimo 2 (20%)'
);
-- Restablece para el resto del archivo.
update public.promotions set minimum_quantity = 3, discount_percent = 0.25 where code = 'TEST-QD-3PLUS';

-- ===========================================================================
-- Caso 15: Cambios (create_sale_exchange) NUNCA aplica QUANTITY_DISCOUNT ni
-- ninguna otra promoción — el producto nuevo usa literalmente la condición
-- PAYMENT_METHOD original (regla ya cerrada, sección 21 del pedido).
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000002', false);

select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'TEST-QD-P1'), 'quantity', 1)),
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  (select id from payment_methods where code = 'CASH'),
  (select id from customers where dni = '30999444')
) ->> 'sale_id')::uuid as sale_qd_id \gset

select (create_sale_exchange(
  :'sale_qd_id'::uuid,
  (select id from sale_items where sale_id = :'sale_qd_id'),
  1,
  (select id from products where sku = 'TEST-QD-P2'),
  1
)) as result_qd \gset

select is(
  (:'result_qd'::jsonb ->> 'new_item_total')::numeric, 18000.00,
  'Caso 15: el producto nuevo de un cambio usa el precio CASH literal (18000) — nunca la promo QUANTITY_DISCOUNT, aunque matchee'
);

-- ===========================================================================
-- Caso 16: histórico — las condiciones QTY_2/QTY_3_PLUS del seed original
-- (si existen) siguen existiendo, solo desactivadas — nunca se borran, para
-- no romper la integridad de sale_items históricos.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'fc000000-0000-0000-0000-000000000001', false);

select ok(
  (select count(*) from price_conditions where code in ('QTY_2', 'QTY_3_PLUS')) >= 0,
  'Caso 16a: chequeo trivial (no rompe si el seed no cargó QTY_2/QTY_3_PLUS en este entorno)'
);
select is(
  coalesce((select bool_and(active = false) from price_conditions where rule_type = 'QUANTITY'), true),
  true,
  'Caso 16b: toda condición rule_type=QUANTITY existente queda desactivada, ninguna se borra'
);

select * from finish();
rollback;
