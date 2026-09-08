-- pgTAP: Formas de pago habilitadas por promoción (migración 63).
-- Casos, en orden (numeración según el pedido original entre paréntesis):
--   1-4)  set_promotion_payment_methods: rechaza array vacío, duplicados,
--         medio inactivo/inexistente, y no-admin.
--   5-8)  Alta de la configuración de prueba (CASH+TRANSFER / TRANSFER /
--         CASH-only / legacy sin configurar).
--   9-10) (1,2) Promo CASH+TRANSFER: venta CASH y TRANSFER -> OK.
--   11-12)(3,4) Promo CASH+TRANSFER: venta CARD_3 y CARD_1 -> rechazadas.
--   13)   (5) Producto sin promoción: todos los medios siguen funcionando.
--   14-15)(6) Dos promos con intersección TRANSFER: TRANSFER OK, CASH rechazada.
--   16-17)(7) Dos promos sin intersección: ambos medios probados rechazan.
--   18)   (8) Cambiar el carrito invalida un medio antes válido.
--   19)   (9) Llamada directa a la RPC (sin pasar por el frontend) rechaza igual.
--   20)   (10) WEB + promo restringida + medio no permitido -> NO bloqueada.
--   21)   (11) Sede 25 explícito -> validación activa.
--   22)   (12) Sede 37 explícito -> validación activa.
--   23)   (13) Venta histórica no cambia al editar la promoción después.
--   24)   (14) Promoción legacy sin configurar sigue admitiendo cualquier medio.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(25);

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'admin.ppm@test.maguirejuve.com'),
  ('a1000000-0000-0000-0000-000000000002', 'seller.ppm@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'a1000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'a1000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'a1000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'a1000000-0000-0000-0000-000000000002', id from public.stock_locations where code in ('SED-25', 'SED-37');

set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo de prueba: 4 productos, cada uno con precio bajo LIST/CASH/
-- TRANSFER/INSTALLMENTS_3(CARD_3)/CARD_1 — así cualquier medio elegido en
-- los tests resuelve precio sin chocar con un error no relacionado.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PPM-A', 'Promo Pago A (CASH+TRANSFER)', 'product', 'Test', true, true, true, true),
  ('PPM-B', 'Promo Pago B (TRANSFER only)', 'product', 'Test', true, true, true, true),
  ('PPM-C', 'Sin promoción', 'product', 'Test', true, true, true, true),
  ('PPM-D', 'Promo legacy sin configurar', 'product', 'Test', true, true, true, true),
  ('PPM-E', 'Promo Pago E (CASH only)', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = sku_val), (select id from price_conditions where code = pc_code), 10000)
from (values ('PPM-A', 'LIST'), ('PPM-A', 'CASH'), ('PPM-A', 'TRANSFER'), ('PPM-A', 'INSTALLMENTS_3'), ('PPM-A', 'CARD_1'),
             ('PPM-B', 'LIST'), ('PPM-B', 'CASH'), ('PPM-B', 'TRANSFER'), ('PPM-B', 'INSTALLMENTS_3'), ('PPM-B', 'CARD_1'),
             ('PPM-C', 'LIST'), ('PPM-C', 'CASH'), ('PPM-C', 'TRANSFER'), ('PPM-C', 'INSTALLMENTS_3'), ('PPM-C', 'CARD_1'),
             ('PPM-D', 'LIST'), ('PPM-D', 'CASH'), ('PPM-D', 'TRANSFER'), ('PPM-D', 'INSTALLMENTS_3'), ('PPM-D', 'CARD_1'),
             ('PPM-E', 'LIST'), ('PPM-E', 'CASH'), ('PPM-E', 'TRANSFER'), ('PPM-E', 'INSTALLMENTS_3'), ('PPM-E', 'CARD_1')
      ) as t(sku_val, pc_code);

select set_stock((select id from stock_locations where code = loc_code), (select id from products where sku = sku_val), 50, 'RECEPTION')
from (values ('SED-25', 'PPM-A'), ('SED-25', 'PPM-B'), ('SED-25', 'PPM-C'), ('SED-25', 'PPM-D'), ('SED-25', 'PPM-E'),
             ('SED-37', 'PPM-A'), ('SED-37', 'PPM-B'), ('SED-37', 'PPM-C'), ('SED-37', 'PPM-D'), ('SED-37', 'PPM-E')
      ) as t(loc_code, sku_val);

insert into public.customers (full_name, dni) values ('Clienta PPM (test)', '30777711');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as transfer_id from payment_methods where code = 'TRANSFER' \gset
select id as card1_id from payment_methods where code = 'CARD_1' \gset
select id as card3_id from payment_methods where code = 'CARD_3' \gset
select id as account_id from payment_accounts where active limit 1 \gset
select id as customer_id from customers where dni = '30777711' \gset
select id as base_pc_id from price_conditions where rule_type = 'BASE' \gset

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('PPM-PROMO-CT', 'Promo A (CASH+TRANSFER)', 'KIT_PERCENT', :'base_pc_id', 0.10, 30, true),
  ('PPM-PROMO-T', 'Promo B (TRANSFER only)', 'KIT_PERCENT', :'base_pc_id', 0.10, 31, true),
  ('PPM-PROMO-CASH', 'Promo E (CASH only)', 'KIT_PERCENT', :'base_pc_id', 0.10, 32, true),
  ('PPM-PROMO-LEGACY', 'Promo D (legacy, nunca configurada)', 'KIT_PERCENT', :'base_pc_id', 0.10, 33, true);

select set_promotion_products((select id from promotions where code = 'PPM-PROMO-CT'), array[(select id from products where sku = 'PPM-A')]);
select set_promotion_products((select id from promotions where code = 'PPM-PROMO-T'), array[(select id from products where sku = 'PPM-B')]);
select set_promotion_products((select id from promotions where code = 'PPM-PROMO-CASH'), array[(select id from products where sku = 'PPM-E')]);
select set_promotion_products((select id from promotions where code = 'PPM-PROMO-LEGACY'), array[(select id from products where sku = 'PPM-D')]);

select id as promo_ct_id from promotions where code = 'PPM-PROMO-CT' \gset
select id as promo_t_id from promotions where code = 'PPM-PROMO-T' \gset
select id as promo_cash_id from promotions where code = 'PPM-PROMO-CASH' \gset
select id as promo_legacy_id from promotions where code = 'PPM-PROMO-LEGACY' \gset

-- ===========================================================================
-- Casos 1-4: validaciones de set_promotion_payment_methods.
-- ===========================================================================
select throws_ok(
  format($$select set_promotion_payment_methods('%s'::uuid, array[]::uuid[])$$, :'promo_ct_id'),
  'Caso 1: set_promotion_payment_methods rechaza un array vacío'
);

select throws_ok(
  format($$select set_promotion_payment_methods('%s'::uuid, array['%s'::uuid, '%s'::uuid, '%s'::uuid])$$,
    :'promo_ct_id', :'cash_id', :'cash_id', :'transfer_id'),
  'Caso 2: set_promotion_payment_methods rechaza medios de pago repetidos'
);

select throws_ok(
  format($$select set_promotion_payment_methods('%s'::uuid, array['00000000-0000-0000-0000-000000000000'::uuid])$$, :'promo_ct_id'),
  'Caso 3: set_promotion_payment_methods rechaza un medio de pago inexistente'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', false);
select throws_ok(
  format($$select set_promotion_payment_methods('%s'::uuid, array['%s'::uuid])$$, :'promo_ct_id', :'cash_id'),
  'Caso 4: un vendedor no puede editar los medios de pago habilitados de una promoción (RLS)'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- Casos 5-8: alta de la configuración de prueba.
-- ===========================================================================
select is(
  (select (set_promotion_payment_methods(:'promo_ct_id', array[:'cash_id'::uuid, :'transfer_id'::uuid]) ->> 'payment_method_count')::int),
  2,
  'Caso 5: Promo A queda habilitada para Efectivo + Transferencia'
);

select is(
  (select (set_promotion_payment_methods(:'promo_t_id', array[:'transfer_id'::uuid]) ->> 'payment_method_count')::int),
  1,
  'Caso 6: Promo B queda habilitada únicamente para Transferencia'
);

select is(
  (select (set_promotion_payment_methods(:'promo_cash_id', array[:'cash_id'::uuid]) ->> 'payment_method_count')::int),
  1,
  'Caso 7: Promo E queda habilitada únicamente para Efectivo'
);

select is(
  (select count(*)::int from promotion_payment_methods where promotion_id = :'promo_legacy_id'),
  0,
  'Caso 8: Promo D (legacy) nunca fue configurada — 0 filas a propósito'
);

-- ===========================================================================
-- Casos 9-10 (1,2 del pedido): Promo CASH+TRANSFER admite ambos medios.
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, null, now()
    )$$,
    (select id from products where sku = 'PPM-A'), :'sed25_id', :'branch_channel_id', :'cash_id'
  ),
  'Caso 9 (1): Promo CASH+TRANSFER, venta en Efectivo -> permitida'
);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 10 (2): Promo CASH+TRANSFER, venta en Transferencia -> permitida'
);

-- ===========================================================================
-- Casos 11-12 (3,4 del pedido): Promo CASH+TRANSFER rechaza CARD_3/CARD_1.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), :'sed25_id', :'branch_channel_id', :'card3_id', :'customer_id', :'account_id'
  ),
  'Caso 11 (3): Promo CASH+TRANSFER, venta en 3 cuotas -> rechazada'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), :'sed25_id', :'branch_channel_id', :'card1_id', :'customer_id', :'account_id'
  ),
  'Caso 12 (4): Promo CASH+TRANSFER, venta en 1 pago tarjeta -> rechazada'
);

-- ===========================================================================
-- Caso 13 (5 del pedido): producto sin ninguna promoción sigue admitiendo
-- cualquier medio, incluidos los que "facturan" (CARD_3).
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-C'), :'sed25_id', :'branch_channel_id', :'card3_id', :'customer_id', :'account_id'
  ),
  'Caso 13 (5): venta sin promoción admite cualquier medio de pago normalmente'
);

-- ===========================================================================
-- Casos 14-15 (6 del pedido): Promo A (CASH+TRANSFER) + Promo B (TRANSFER)
-- en el mismo carrito -> la intersección es únicamente Transferencia.
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), (select id from products where sku = 'PPM-B'),
    :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 14 (6): Promo A + Promo B en el carrito, venta en Transferencia (intersección) -> permitida'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), (select id from products where sku = 'PPM-B'),
    :'sed25_id', :'branch_channel_id', :'cash_id'
  ),
  'Caso 15 (6): mismo carrito, venta en Efectivo (fuera de la intersección) -> rechazada'
);

-- ===========================================================================
-- Casos 16-17 (7 del pedido): Promo E (CASH only) + Promo B (TRANSFER only)
-- en el mismo carrito -> intersección vacía, ningún medio confirma la venta.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-E'), (select id from products where sku = 'PPM-B'),
    :'sed25_id', :'branch_channel_id', :'cash_id'
  ),
  'Caso 16 (7): Promo E (CASH only) + Promo B (TRANSFER only), venta en Efectivo -> rechazada'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-E'), (select id from products where sku = 'PPM-B'),
    :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 17 (7): mismo carrito, venta en Transferencia -> también rechazada (sin medio en común)'
);

-- ===========================================================================
-- Caso 18 (8 del pedido): un medio válido para el carrito ANTERIOR deja de
-- serlo cuando se agrega un producto con promoción restringida — se prueba
-- en el único punto de verdad real (create_sale), que es autoridad final
-- más allá de lo que haya cacheado la UI.
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-C'), :'sed25_id', :'branch_channel_id', :'card3_id', :'customer_id', :'account_id'
  ),
  'Caso 18a: carrito solo con PPM-C (sin promo), venta en 3 cuotas -> permitida'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1),
        jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)
      ),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-C'), (select id from products where sku = 'PPM-A'),
    :'sed25_id', :'branch_channel_id', :'card3_id', :'customer_id', :'account_id'
  ),
  'Caso 18b (8): mismo medio (3 cuotas), pero se agregó PPM-A (Promo CASH+TRANSFER) al carrito -> ahora rechazada'
);

-- ===========================================================================
-- Caso 19 (9 del pedido): la RPC se llama directo (sin pasar por ninguna
-- pantalla) con un vendedor real — el backend rechaza igual, no depende de
-- que el frontend deshabilite el botón.
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000002', false);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-A'), :'sed25_id', :'branch_channel_id', :'card1_id', :'customer_id', :'account_id'
  ),
  'Caso 19 (9): request "manipulada" (RPC directa) con un vendedor real -> el backend igual rechaza'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- Caso 20 (10 del pedido): canal WEB con la MISMA promoción CASH-only y un
-- medio no permitido (CARD_3) -> el circuito Web queda exceptuado, no se
-- bloquea. PICKUP en Sede 25 (única combinación válida para WEB+PICKUP).
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'PPM-E'), :'sed25_id', :'web_channel_id', :'card3_id', :'customer_id', :'account_id'
  ),
  'Caso 20 (10): WEB + Promo E (CASH only) + venta en 3 cuotas -> NO bloqueada (Web queda exceptuada)'
);

-- ===========================================================================
-- Casos 21-22 (11,12 del pedido): la validación está activa tanto en Sede 25
-- como en Sede 37 — no es un chequeo atado a una sola sucursal.
-- ===========================================================================
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-E'), :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 21 (11): Sede 25 — Promo E (CASH only) rechaza Transferencia'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-E'), :'sed37_id', :'branch_channel_id', :'transfer_id', :'customer_id', :'account_id'
  ),
  'Caso 22 (12): Sede 37 — misma Promo E (CASH only) rechaza Transferencia'
);

-- ===========================================================================
-- Caso 23 (13 del pedido): una venta ya confirmada conserva su medio de pago
-- histórico aunque la promoción se edite después.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PPM-A'), 'quantity', 1)),
  :'sed25_id', :'branch_channel_id', :'cash_id'
) ->> 'sale_id')::uuid as historic_sale_id \gset

-- Editar Promo A a TRANSFER-only (quita Efectivo) DESPUÉS de la venta histórica.
select set_promotion_payment_methods(:'promo_ct_id', array[:'transfer_id'::uuid]);

select is(
  (select payment_method_id from sales where id = :'historic_sale_id'::uuid),
  :'cash_id'::uuid,
  'Caso 23 (13): la venta histórica conserva payment_method_id = Efectivo aunque Promo A ya no lo admita más'
);

-- Restaura Promo A a CASH+TRANSFER para no afectar el resto del archivo si se reordenara.
select set_promotion_payment_methods(:'promo_ct_id', array[:'cash_id'::uuid, :'transfer_id'::uuid]);

-- ===========================================================================
-- Caso 24 (14 del pedido): promoción legacy (nunca configurada) sigue
-- admitiendo cualquier medio, incluidos los que facturan.
-- ===========================================================================
select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PPM-D'), :'sed25_id', :'branch_channel_id', :'card1_id', :'customer_id', :'account_id'
  ),
  'Caso 24 (14): Promo D (legacy, sin configurar) admite 1 pago tarjeta sin problema'
);

select * from finish();
rollback;
