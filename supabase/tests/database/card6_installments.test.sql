-- pgTAP: nueva condición de precio "6 cuotas sin interés" (migración 67).
-- Casos, en orden (numeración según el pedido original entre paréntesis):
--   1)     (6) CARD_6 existe en payment_methods, activo.
--   2)     (6) INSTALLMENTS_6 existe en price_conditions, asociada a CARD_6,
--          discount_percent=0 (placeholder neutro, no un % comercial real).
--   3)     Seed inicial: INSTALLMENTS_6 = Lista para un producto real de
--          seed_data (PROD-VITC) — migración 67 corre después del seed.
--   4)     (7) Admin puede configurar (editar) el precio de 6 cuotas con la
--          misma RPC genérica (set_product_price) que cualquier otra condición.
--   5)     (8) Producto individual + CARD_6 -> toma el precio configurado.
--   6)     (9) Carrito múltiple + CARD_6 -> total = suma de ambas líneas
--          bajo INSTALLMENTS_6 (misma lógica que cualquier otra condición).
--   7)     (10) Producto promocionado (kit%) + CARD_6 -> NO recibe la
--          condición de precio (usa la condición BASE propia de la promo).
--   8)     (11) Producto normal junto a uno promocionado + CARD_6 -> el
--          normal SÍ toma INSTALLMENTS_6.
--   9)     (12) Caso de regresión obligatorio del pedido: 3x2 + kit -25% +
--          sérum individual + CARD_6 -> promociones intactas, 6 cuotas solo
--          en la línea normal.
--   10-11) (13,14) promotion_payment_methods + CARD_6: promo que NO admite
--          CARD_6 rechaza la venta presencial; promo que SÍ lo admite, permite.
--   12)    (15) Web conserva EXACTAMENTE la excepción vigente de la
--          migración 63 (promoción restringida sin CARD_6, venta Web -> NO bloqueada).
--   13-15) (16,17) billing_status/DNI/cuenta de ingreso: CARD_6 se comporta
--          igual que CARD_1/CARD_3 en los tres ejes.
--   16)    Web + payment_status=PENDING: CARD_6 no exige cuenta todavía
--          (billing_status=NOT_REQUIRED, mismo BUGFIX 57 que las demás).
--   17)    create_sale_exchange: CARD_6 en la venta original -> la operación
--          de reemplazo hereda billing_status=PENDING igual que TRANSFER/CARD_1/CARD_3.
--   18)    (18) Reportes/dashboard: una venta CARD_6 aparece correctamente
--          etiquetada "6 cuotas sin interés" en revenue_by_payment_method.
--   19-22) (20) Regresión completa: CASH/TRANSFER/CARD_1/CARD_3 sin cambios.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(23);

insert into auth.users (id, email) values
  ('c6000000-0000-0000-0000-000000000001', 'admin.card6@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'c6000000-0000-0000-0000-000000000001';
insert into public.profile_locations (profile_id, location_id)
  select 'c6000000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'c6000000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- Catálogo: CD6-N (normal, todas las condiciones), CD6-N2 (normal, solo
-- INSTALLMENTS_6, para el carrito múltiple), CD6-3A/CD6-3B (3x2),
-- CD6-KIT (kit% 25%). Los fixtures nuevos NO reciben el seed automático de
-- INSTALLMENTS_6 de la migración 67 (esa migración ya corrió antes de que
-- este producto existiera) — se configura acá a propósito, vía la misma RPC
-- genérica que usa Administración (eso ES el test 4).
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('CD6-N', 'Card6 normal', 'product', 'Test', true, true, true, true),
  ('CD6-N2', 'Card6 normal 2', 'product', 'Test', true, true, true, true),
  ('CD6-3A', 'Card6 3x2 A', 'product', 'Test', true, true, true, true),
  ('CD6-3B', 'Card6 3x2 B', 'product', 'Test', true, true, true, true),
  ('CD6-KIT', 'Card6 kit 25%', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = sku_val), (select id from price_conditions where code = pc_code), amount)
from (values
  ('CD6-N', 'LIST', 10000), ('CD6-N', 'CASH', 9000), ('CD6-N', 'TRANSFER', 9500),
  ('CD6-N', 'CARD_1', 10000), ('CD6-N', 'INSTALLMENTS_3', 11000), ('CD6-N', 'INSTALLMENTS_6', 12000),
  ('CD6-N2', 'LIST', 5000), ('CD6-N2', 'INSTALLMENTS_6', 6000),
  ('CD6-3A', 'LIST', 8000), ('CD6-3A', 'INSTALLMENTS_6', 8000),
  ('CD6-3B', 'LIST', 9000), ('CD6-3B', 'INSTALLMENTS_6', 9000),
  ('CD6-KIT', 'LIST', 20000), ('CD6-KIT', 'INSTALLMENTS_6', 20000)
) as t(sku_val, pc_code, amount);

select set_stock((select id from stock_locations where code = loc_code), (select id from products where sku = sku_val), 100, 'RECEPTION')
from (values
  ('SED-25', 'CD6-N'), ('SED-25', 'CD6-N2'), ('SED-25', 'CD6-3A'), ('SED-25', 'CD6-3B'), ('SED-25', 'CD6-KIT')
) as t(loc_code, sku_val);

insert into public.customers (full_name, dni) values ('Clienta Card6 (test)', '30888822');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as transfer_id from payment_methods where code = 'TRANSFER' \gset
select id as card1_id from payment_methods where code = 'CARD_1' \gset
select id as card3_id from payment_methods where code = 'CARD_3' \gset
select id as card6_id from payment_methods where code = 'CARD_6' \gset
select id as installments6_pc_id from price_conditions where code = 'INSTALLMENTS_6' \gset
select id as base_pc_id from price_conditions where rule_type = 'BASE' \gset
select id as account_id from payment_accounts where active limit 1 \gset
select id as customer_id from customers where dni = '30888822' \gset

insert into public.promotions (code, name, type, price_condition_id, group_size, priority, stackable) values
  ('CD6-3X2', 'Card6 3x2', 'THREE_FOR_TWO', :'base_pc_id', 3, 10, false);
select set_promotion_products(
  (select id from promotions where code = 'CD6-3X2'),
  array[(select id from products where sku = 'CD6-3A'), (select id from products where sku = 'CD6-3B')]
);
select id as promo_3x2_id from promotions where code = 'CD6-3X2' \gset

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable) values
  ('CD6-KITPROMO', 'Card6 kit 25%', 'KIT_PERCENT', :'base_pc_id', 0.25, 20, false);
select set_promotion_products(
  (select id from promotions where code = 'CD6-KITPROMO'),
  array[(select id from products where sku = 'CD6-KIT')]
);
select id as promo_kit_id from promotions where code = 'CD6-KITPROMO' \gset

-- ===========================================================================
-- Casos 1-2: la condición y el medio de pago existen y están bien asociados.
-- ===========================================================================
select is(
  (select active from payment_methods where code = 'CARD_6'),
  true,
  'Caso 1: CARD_6 existe en payment_methods y está activo'
);

select is(
  (select (pc.rule_type, pc.payment_method_id, pc.discount_percent) from price_conditions pc where pc.code = 'INSTALLMENTS_6'),
  ('PAYMENT_METHOD'::price_rule_type, :'card6_id'::uuid, 0::numeric),
  'Caso 2: INSTALLMENTS_6 es PAYMENT_METHOD, asociada a CARD_6, discount_percent=0 (placeholder neutro)'
);

-- ===========================================================================
-- Caso 3: seed automático de la migración 67 — PROD-VITC (producto real de
-- seed_data, ya existía cuando corrió la migración) tiene INSTALLMENTS_6 = Lista.
-- ===========================================================================
select is(
  (
    select sp.amount
    from product_prices sp
    join product_prices lp on lp.product_id = sp.product_id
    where sp.product_id = (select id from products where sku = 'PROD-VITC')
      and sp.price_condition_id = :'installments6_pc_id'::uuid and sp.active
      and lp.product_id = sp.product_id and lp.price_condition_id = :'base_pc_id'::uuid and lp.active
  ),
  (select amount from product_prices where product_id = (select id from products where sku = 'PROD-VITC')
     and price_condition_id = :'base_pc_id'::uuid and active),
  'Caso 3: seed automático de la migración 67 — INSTALLMENTS_6 sembrada = precio Lista (PROD-VITC)'
);

-- ===========================================================================
-- Caso 4: Administración configura el precio de 6 cuotas con la misma RPC
-- genérica que cualquier otra condición (ya se usó arriba para armar el
-- fixture — se confirma acá explícitamente el resultado persistido).
-- ===========================================================================
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'CD6-N')
     and price_condition_id = :'installments6_pc_id'::uuid and active),
  12000::numeric,
  'Caso 4: Administración configuró el precio de 6 cuotas de CD6-N (set_product_price genérica)'
);

-- ===========================================================================
-- Caso 5: producto individual + CARD_6 -> toma el precio configurado.
-- ===========================================================================
select is(
  (
    select (l ->> 'sale_unit_price')::numeric
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)),
        :'card6_id'
      ) -> 'lines'
    ) l
  ),
  12000::numeric,
  'Caso 5: producto individual + 6 cuotas -> toma el precio de INSTALLMENTS_6'
);

-- ===========================================================================
-- Caso 6: carrito múltiple + CARD_6 -> total = suma de las 2 líneas bajo
-- INSTALLMENTS_6 (12000 + 6000 = 18000), misma lógica que cualquier otra condición.
-- ===========================================================================
select is(
  (
    select (quote_sale(
      jsonb_build_array(
        jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1),
        jsonb_build_object('product_id', (select id from products where sku = 'CD6-N2'), 'quantity', 1)
      ),
      :'card6_id'
    ) ->> 'total')::numeric
  ),
  18000::numeric,
  'Caso 6: carrito múltiple + 6 cuotas -> total correcto (suma de ambas líneas)'
);

-- ===========================================================================
-- Caso 7: producto promocionado (kit% 25%) + CARD_6 -> NO recibe
-- INSTALLMENTS_6 — conserva exclusivamente su precio promocional bajo la
-- condición BASE propia de la promo.
-- ===========================================================================
select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-KIT'), 'quantity', 1)),
        :'card6_id'
      ) -> 'lines'
    ) l
  ),
  :'base_pc_id'::uuid,
  'Caso 7: producto promocionado (kit 25%) + 6 cuotas -> usa la condición BASE de la promo, nunca INSTALLMENTS_6'
);

-- ===========================================================================
-- Caso 8: producto normal junto a uno promocionado + CARD_6 -> el normal SÍ
-- toma INSTALLMENTS_6.
-- ===========================================================================
select is(
  (
    select (l ->> 'applied_price_condition_id')::uuid
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)
        ),
        :'card6_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'CD6-N')
  ),
  :'installments6_pc_id'::uuid,
  'Caso 8: normal junto a promocionado + 6 cuotas -> el normal sí toma INSTALLMENTS_6'
);

-- ===========================================================================
-- Caso 9 — EJEMPLO OBLIGATORIO del pedido: 3x2 + kit -25% + sérum individual,
-- pagado en 6 cuotas. 3x2 mantiene su cálculo, kit mantiene -25%, el
-- individual toma INSTALLMENTS_6.
-- ===========================================================================
select is(
  (
    select jsonb_agg(jsonb_build_object(
      'promo', l ->> 'applied_promotion_id',
      'price_condition', l ->> 'applied_price_condition_id'
    ) order by l ->> 'product_id')
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-3A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)
        ),
        :'card6_id'
      ) -> 'lines'
    ) l
    where (l ->> 'product_id')::uuid = (select id from products where sku = 'CD6-N')
  ),
  jsonb_build_array(jsonb_build_object('promo', null, 'price_condition', :'installments6_pc_id')),
  'Caso 9: 3x2 + kit -25% + normal + 6 cuotas -> el normal SOLO recibe INSTALLMENTS_6 (promos intactas, sin doble beneficio)'
);

select is(
  (
    select count(*)::int
    from jsonb_array_elements(
      quote_sale(
        jsonb_build_array(
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-3A'), 'quantity', 3),
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-KIT'), 'quantity', 1),
          jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)
        ),
        :'card6_id'
      ) -> 'lines'
    ) l
    where l ->> 'applied_promotion_id' is not null
      and (l ->> 'applied_promotion_id')::uuid in (:'promo_3x2_id'::uuid, :'promo_kit_id'::uuid)
  ),
  3,
  'Caso 9b: mismo carrito — 3x2 (2 líneas) + kit (1 línea) siguen tagueadas, 6 cuotas no las tocó'
);

-- ===========================================================================
-- Casos 10-11: promotion_payment_methods + CARD_6 — sin lógica especial,
-- 100% el modelo genérico ya existente (migración 63).
-- ===========================================================================
select set_promotion_payment_methods(:'promo_kit_id', array[:'cash_id'::uuid, :'transfer_id'::uuid]);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-KIT'), :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id', :'account_id'
  ),
  'Caso 10 (13): promo que NO admite CARD_6 (solo Efectivo/Transferencia) -> venta presencial en 6 cuotas rechazada'
);

select set_promotion_payment_methods(:'promo_kit_id', array[:'cash_id'::uuid, :'transfer_id'::uuid, :'card6_id'::uuid]);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-KIT'), :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id', :'account_id'
  ),
  'Caso 11 (14): promo reconfigurada para admitir CARD_6 -> la misma venta ahora se permite'
);

-- ===========================================================================
-- Caso 12 (15): Web conserva EXACTAMENTE la excepción vigente de la
-- migración 63 — la promoción sigue restringida (no admite CARD_6 en su
-- configuración explícita de Sede) pero por canal WEB la validación se
-- saltea igual que para cualquier otro medio.
-- ===========================================================================
select set_promotion_payment_methods(:'promo_kit_id', array[:'cash_id'::uuid, :'transfer_id'::uuid]);

select lives_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid,
      'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'CD6-KIT'), :'sed25_id', :'web_channel_id', :'card6_id', :'customer_id', :'account_id'
  ),
  'Caso 12: WEB + promo que no admite CARD_6 -> NO bloqueada (excepción channel<>WEB de la migración 63, sin cambios)'
);

select set_promotion_payment_methods(:'promo_kit_id', array[:'cash_id'::uuid, :'transfer_id'::uuid, :'card6_id'::uuid]);

-- ===========================================================================
-- Casos 13-15 (16,17): billing_status/DNI/cuenta de ingreso — CARD_6 se
-- comporta exactamente igual que CARD_1/CARD_3.
-- ===========================================================================
select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id', null, null, null, null, now(),
      false, null, null, false, :'account_id'
    ) ->> 'billing_status')
  ),
  'PENDING',
  'Caso 13: venta en 6 cuotas genera billing_status=PENDING, igual que CARD_1/CARD_3/Transferencia'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, null, now(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-N'), :'sed25_id', :'branch_channel_id', :'card6_id', :'account_id'
  ),
  'Caso 14 (16): venta en 6 cuotas sin cliente identificado con DNI -> rechazada (misma regla que las demás tarjetas)'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-N'), :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id'
  ),
  'Caso 15 (17): venta en 6 cuotas sin cuenta de ingreso -> rechazada (misma regla que las demás tarjetas)'
);

-- ===========================================================================
-- Caso 16: Web + payment_status=PENDING -> CARD_6 no exige cuenta todavía
-- (BUGFIX 57, sin cambios, ya genérico por payment_status, no por código).
-- ===========================================================================
select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)),
      :'sed25_id', :'web_channel_id', :'card6_id', :'customer_id', null, null, null, null, now(),
      false, null, null, false, null,
      'PICKUP'::sale_fulfillment_type, 'PENDING'::sale_payment_status
    ) ->> 'billing_status')
  ),
  'NOT_REQUIRED',
  'Caso 16: Web + 6 cuotas + payment_status=PENDING -> billing_status=NOT_REQUIRED todavía (se resuelve al cobrar)'
);

-- ===========================================================================
-- Caso 17: create_sale_exchange hereda requires_billing de CARD_6 igual que
-- las demás tarjetas — la operación de reemplazo queda billing_status=PENDING.
-- ===========================================================================
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)),
  :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id', null, null, null, null, now(),
  false, null, null, false, :'account_id'
) ->> 'sale_id')::uuid as card6_sale_id \gset

select is(
  (
    (create_sale_exchange(
      :'card6_sale_id'::uuid,
      (select id from sale_items where sale_id = :'card6_sale_id'::uuid limit 1),
      1,
      (select id from products where sku = 'CD6-N2'),
      1
    ) ->> 'billing_status')
  ),
  'PENDING',
  'Caso 17: cambio sobre una venta en 6 cuotas -> el reemplazo hereda billing_status=PENDING (create_sale_exchange, igual que las demás tarjetas)'
);

-- ===========================================================================
-- Caso 18: reportes — la venta en 6 cuotas aparece correctamente etiquetada
-- "6 cuotas sin interés" en dashboard_report.revenue_by_payment_method.
-- ===========================================================================
select is(
  (
    select bool_or((row ->> 'payment_method') = '6 cuotas sin interés')
    from jsonb_array_elements(
      dashboard_report(current_date - 1, current_date + 1) -> 'revenue_by_payment_method'
    ) row
  ),
  true,
  'Caso 18: dashboard_report.revenue_by_payment_method etiqueta CARD_6 como "6 cuotas sin interés"'
);

-- ===========================================================================
-- Casos 19-22 (20 del pedido): regresión completa — CASH/TRANSFER/CARD_1/
-- CARD_3 se comportan exactamente igual que antes de esta migración.
-- ===========================================================================
select is(
  ((create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'CD6-N'), 'quantity', 1)),
    :'sed25_id', :'branch_channel_id', :'cash_id'
  ) ->> 'billing_status')),
  'NOT_REQUIRED',
  'Caso 19: regresión Efectivo — sigue sin requerir facturación'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-N'), :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id'
  ),
  'Caso 20: regresión Transferencia — sigue exigiendo cuenta de ingreso'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-N'), :'sed25_id', :'branch_channel_id', :'card1_id', :'customer_id'
  ),
  'Caso 21: regresión 1 pago (CARD_1) — sigue exigiendo cuenta de ingreso'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'CD6-N'), :'sed25_id', :'branch_channel_id', :'card3_id', :'customer_id'
  ),
  'Caso 22: regresión 3 cuotas (CARD_3) — sigue exigiendo cuenta de ingreso'
);

select * from finish();
rollback;
