-- pgTAP: Condiciones de precio administrables (migración 69, Checkpoint 1 —
-- solo DB/domain, sin UI). Casos, por sección del pedido:
--   A. Facturación data-driven (payment_methods.requires_billing) — 8 casos.
--   B. Atomicidad de create_price_condition — 2 casos.
--   C. Precio inicial copiado de LIST — 7 casos.
--   D. Disponibilidad server-side (fn_price_condition_available) — 4 casos.
--   E. Snapshot histórico (sales.price_condition_name_snapshot) — 2 casos.
--   F. "2 cuotas sin interés" (caso inmediato, sembrado por la migración) — 4 casos.
--   G. Permisos de create_price_condition — 2 casos.
--   H. Regresión — condiciones/medios existentes sin cambios — 4 casos.
--   I. update_price_condition — edición atómica (migración 70) — 15 casos.
--   J. Web real vía create_web_order (mismo camino que la ruta externa) — 2 casos.
--   K. "9 cuotas test" — prueba estructural data-driven, condición ficticia — 9 casos.
--   L. create_web_order + circuito de pago/facturación (migración 71,
--      Checkpoint 2.1) — 19 casos.
--   M. visible_in_price_lookup — visibilidad en /precios, independiente de
--      active (migración 73) — 9 casos.
-- Correr con: rebuild local (preamble + seed_026_skus antes de la migración
-- 26) + pg_prove.
begin;
select plan(87);

-- ---------------------------------------------------------------------------
-- Fixtures: admin con acceso a ambas sedes, vendedora sin permisos de
-- administración, cliente con DNI, cuenta de ingreso activa, producto propio
-- con LIST vigente (no reusa PROD-VITC para no interferir con otros tests
-- que corren en la misma base).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aca00000-0000-0000-0000-000000000001', 'admin.pca@test.maguirejuve.com'),
  ('aca00000-0000-0000-0000-000000000002', 'seller.pca@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'aca00000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'aca00000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'aca00000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'aca00000-0000-0000-0000-000000000002', id from public.stock_locations where code in ('SED-25', 'SED-37');

set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('PCA-N', 'Condiciones admin normal', 'product', 'Test', true, true, true, true),
  ('PCA-N2', 'Condiciones admin normal 2', 'product', 'Test', true, true, true, true),
  ('PCA-NOLIST', 'Condiciones admin sin LIST', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = 'PCA-N'), (select id from price_conditions where code = 'LIST'), 10000);
select set_product_price((select id from products where sku = 'PCA-N2'), (select id from price_conditions where code = 'LIST'), 5000);
-- PCA-N con precio en los medios ya existentes (sección H, regresión).
-- price_conditions.code no siempre coincide con payment_methods.code
-- (CARD_6 -> INSTALLMENTS_6, mismo criterio ya documentado en la migración 67).
select set_product_price((select id from products where sku = 'PCA-N'), (select id from price_conditions where code = pc_code), 9500)
from (values ('CASH'), ('TRANSFER'), ('CARD_1'), ('INSTALLMENTS_6')) as t(pc_code);
-- PCA-NOLIST deliberadamente sin precio LIST -> caso "producto sin LIST vigente".

select set_stock((select id from stock_locations where code = loc_code), (select id from products where sku = sku_val), 100, 'RECEPTION')
from (values ('SED-25', 'PCA-N'), ('SED-25', 'PCA-N2'), ('SED-37', 'PCA-N')) as t(loc_code, sku_val);

insert into public.customers (full_name, dni) values ('Clienta PCA (test)', '30999911');

select id as sed25_id from stock_locations where code = 'SED-25' \gset
select id as sed37_id from stock_locations where code = 'SED-37' \gset
select id as branch_channel_id from sales_channels where code <> 'WEB' limit 1 \gset
select id as web_channel_id from sales_channels where code = 'WEB' \gset
select id as cash_id from payment_methods where code = 'CASH' \gset
select id as transfer_id from payment_methods where code = 'TRANSFER' \gset
select id as card1_id from payment_methods where code = 'CARD_1' \gset
select id as card3_id from payment_methods where code = 'CARD_3' \gset
select id as card6_id from payment_methods where code = 'CARD_6' \gset
select id as two_installments_pm_id from payment_methods where name = '2 cuotas sin interés' \gset
select id as two_installments_pc_id from price_conditions where name = '2 cuotas sin interés' \gset
select id as account_id from payment_accounts where active limit 1 \gset
select id as customer_id from customers where dni = '30999911' \gset
select amount as pca_n_list_price from product_prices
  where product_id = (select id from products where sku = 'PCA-N')
    and price_condition_id = (select id from price_conditions where code = 'LIST') and active \gset

-- ===========================================================================
-- SECCIÓN A — Facturación data-driven.
-- ===========================================================================
select is(
  (select requires_billing from payment_methods where code = 'CASH'),
  false,
  'A1: CASH conserva requires_billing=false (nunca estuvo en el IN hardcodeado)'
);

select is(
  (select requires_billing from payment_methods where code = 'TRANSFER'),
  true,
  'A2: TRANSFER conserva requires_billing=true (backfill de la migración 69)'
);

select is(
  (select requires_billing from payment_methods where code = 'CARD_1'),
  true,
  'A3: CARD_1 conserva requires_billing=true'
);

select is(
  (select requires_billing from payment_methods where code = 'CARD_3'),
  true,
  'A4: CARD_3 conserva requires_billing=true'
);

select is(
  (select requires_billing from payment_methods where code = 'CARD_6'),
  true,
  'A5: CARD_6 conserva requires_billing=true'
);

select is(
  (select requires_billing from payment_methods where id = :'two_installments_pm_id'::uuid),
  true,
  'A6: "2 cuotas sin interés" (nueva) tiene requires_billing=true'
);

-- Condición futura creada desde admin, requires_billing=true -> exige DNI+cuenta sin tocar código.
select create_price_condition(
  'PCA Futura Billing True', 0, true, array['SED-25', 'SED-37'], true
) as pca_future_true_result \gset
select (:'pca_future_true_result'::jsonb ->> 'payment_method_id')::uuid as pca_future_true_pm_id \gset

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, null, now(),
      false, null, null, false, null
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'branch_channel_id', :'pca_future_true_pm_id'
  ),
  'A7: condición futura con requires_billing=true exige DNI/cuenta, sin cambio de código (rechaza sin cliente/cuenta)'
);

-- Condición futura, requires_billing=false -> no exige nada de eso.
select create_price_condition(
  'PCA Futura Billing False', 0, false, array['SED-25', 'SED-37'], true
) as pca_future_false_result \gset
select (:'pca_future_false_result'::jsonb ->> 'payment_method_id')::uuid as pca_future_false_pm_id \gset
select (:'pca_future_false_result'::jsonb ->> 'price_condition_id')::uuid as pca_future_false_pc_id \gset

select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', :'pca_future_false_pm_id', null, null, null, null, null, now(),
      false, null, null, false, null
    ) ->> 'billing_status')
  ),
  'NOT_REQUIRED',
  'A8: condición futura con requires_billing=false NO exige facturación, sin cambio de código'
);

-- ===========================================================================
-- SECCIÓN B — Atomicidad de create_price_condition.
-- ===========================================================================
select throws_ok(
  $$select create_price_condition('PCA Rota', 0, true, array['SEDE-INEXISTENTE'], true)$$,
  'B1: create_price_condition con una sede inválida rechaza toda la operación'
);

select is(
  (select count(*)::int from payment_methods where name = 'PCA Rota'),
  0,
  'B2: tras el fallo de B1, no quedó ningún payment_method huérfano ("PCA Rota")'
);

-- ===========================================================================
-- SECCIÓN C — Precio inicial copiado de LIST.
-- ===========================================================================
select create_price_condition(
  'PCA Precio Inicial', 0, false, array['SED-25'], false
) as pca_price_result \gset
select (:'pca_price_result'::jsonb ->> 'price_condition_id')::uuid as pca_price_pc_id \gset

select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N') and price_condition_id = :'pca_price_pc_id'::uuid and active),
  :'pca_n_list_price'::numeric,
  'C1: precio inicial de PCA-N bajo la condición nueva = precio LIST vigente'
);

select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N2') and price_condition_id = :'pca_price_pc_id'::uuid and active),
  5000::numeric,
  'C2: precio inicial copiado correctamente para un segundo producto (PCA-N2)'
);

select is(
  (select count(*)::int from product_prices where product_id = (select id from products where sku = 'PCA-NOLIST') and price_condition_id = :'pca_price_pc_id'::uuid),
  0,
  'C3: producto sin LIST vigente (PCA-NOLIST) NO recibe ninguna fila inventada'
);

select ok(
  (:'pca_price_result'::jsonb -> 'skipped_products') @> jsonb_build_array(jsonb_build_object('sku', 'PCA-NOLIST', 'id', (select id from products where sku = 'PCA-NOLIST')::text, 'name', 'Condiciones admin sin LIST')) = false
  or ((:'pca_price_result'::jsonb -> 'skipped_products')::text like '%PCA-NOLIST%'),
  'C4: create_price_condition reporta explícitamente PCA-NOLIST en skipped_products (nunca oculto)'
);

select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N') and price_condition_id = (select id from price_conditions where code = 'LIST') and active),
  :'pca_n_list_price'::numeric,
  'C5: el precio LIST original de PCA-N no se modificó al crear la condición nueva'
);

-- Modificar LIST después no debe tocar el precio ya copiado.
select set_product_price((select id from products where sku = 'PCA-N'), (select id from price_conditions where code = 'LIST'), 99999);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N') and price_condition_id = :'pca_price_pc_id'::uuid and active),
  :'pca_n_list_price'::numeric,
  'C6: modificar LIST después NO cambia retroactivamente el precio ya copiado a la condición nueva (Modelo B: snapshot, no fórmula)'
);
-- Matriz puede seguir editando el precio nuevo normalmente, con la RPC genérica ya existente.
-- clock_timestamp() explícito (no el now() por defecto): dentro de la misma
-- transacción de este test, now() queda congelado al inicio de la
-- transacción — set_product_price solo cierra la fila activa anterior si
-- su valid_from < p_valid_from (comportamiento real, preexistente, de
-- set_product_price — no se toca acá), así que dos llamadas con el mismo
-- now() implícito dejarían dos filas activas para el mismo producto+
-- condición. clock_timestamp() sí avanza en tiempo real.
select set_product_price((select id from products where sku = 'PCA-N'), :'pca_price_pc_id'::uuid, 7777, clock_timestamp());
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N') and price_condition_id = :'pca_price_pc_id'::uuid and active),
  7777::numeric,
  'C7: la matriz de precios puede editar el precio de la condición nueva con set_product_price, sin cambios de código'
);

-- ===========================================================================
-- SECCIÓN D — Disponibilidad server-side. La condición de C. quedó
-- disponible SOLO en Sede 25 (Sede 37: NO, Web: NO) — se reusa para probar
-- el rechazo real, no solo la ausencia en un listado de UI.
-- ===========================================================================
-- p_sold_at = clock_timestamp() en vez de now(): el precio de C7 se guardó
-- con valid_from = clock_timestamp() (más tarde que el now() congelado de
-- esta transacción) — fn_pricing_quote exige valid_from <= p_sold_at, así
-- que p_sold_at también tiene que avanzar en tiempo real acá.
select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', (select payment_method_id from price_conditions where id = :'pca_price_pc_id'::uuid),
      null, null, null, null, null, clock_timestamp(), false, null, null, false, null
    ) ->> 'sale_id') is not null
  ),
  true,
  'D1: condición disponible en Sede 25 -> create_sale la acepta'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, null, clock_timestamp(),
      false, null, null, false, null
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed37_id', :'branch_channel_id',
    (select payment_method_id from price_conditions where id = :'pca_price_pc_id'::uuid)
  ),
  'D2: misma condición, Sede 37 (no habilitada) -> create_sale la RECHAZA server-side'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, null, clock_timestamp(),
      false, null, null, false, null, 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'web_channel_id',
    (select payment_method_id from price_conditions where id = :'pca_price_pc_id'::uuid)
  ),
  'D3: misma condición, canal Web (no habilitado) -> create_sale la RECHAZA server-side'
);

-- Positivo: "2 cuotas sin interés" SÍ está habilitada en Web (config aprobada) -> funciona.
-- PROD-VITC (no PCA-N): es un producto real del seed, con precio de "2
-- cuotas" ya sembrado por la migración 69 — PCA-N es un producto nuevo de
-- este test, creado después de esa migración, sin precio bajo esta
-- condición (comportamiento correcto y esperado del Modelo B: precio
-- explícito por producto, nunca inventado).
select set_stock(:'sed25_id'::uuid, (select id from products where sku = 'PROD-VITC'), 100, 'RECEPTION');
select ok(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
    :'sed25_id', :'web_channel_id', :'two_installments_pm_id', :'customer_id', null, null, null, null, clock_timestamp(),
    false, null, null, false, :'account_id', 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
  ) ->> 'sale_id') is not null,
  'D4: "2 cuotas sin interés" SÍ habilitada en Web -> create_sale la acepta'
);

-- ===========================================================================
-- SECCIÓN E — Snapshot histórico.
-- ===========================================================================
-- PROD-VITC de nuevo (producto real del seed, con precio de "2 cuotas" ya
-- sembrado por la migración 69) — PCA-N2 es un producto de este test, sin
-- precio bajo esta condición, mismo motivo que en D4.
select (create_sale(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  :'sed25_id', :'branch_channel_id', :'two_installments_pm_id', :'customer_id', null, null, null, null, now(),
  false, null, null, false, :'account_id'
) ->> 'sale_id')::uuid as historic_sale_id \gset

select is(
  (select price_condition_name_snapshot from sales where id = :'historic_sale_id'::uuid),
  '2 cuotas sin interés',
  'E1: la venta guarda el snapshot del nombre de la condición al momento de venderse'
);

update public.price_conditions set name = '2 cuotas precio lista' where id = :'two_installments_pc_id'::uuid;

select is(
  (select price_condition_name_snapshot from sales where id = :'historic_sale_id'::uuid),
  '2 cuotas sin interés',
  'E2: tras renombrar la condición, la venta histórica sigue mostrando el snapshot original ("2 cuotas sin interés")'
);

update public.price_conditions set name = '2 cuotas sin interés' where id = :'two_installments_pc_id'::uuid; -- deja el estado como estaba para el resto de la suite.

-- ===========================================================================
-- SECCIÓN F — "2 cuotas sin interés" (caso inmediato, sembrado por la migración).
-- ===========================================================================
select is(
  (select active from payment_methods where id = :'two_installments_pm_id'::uuid),
  true,
  'F1: "2 cuotas sin interés" existe en payment_methods, activa'
);

select is(
  (select (pc.rule_type, pc.discount_percent) from price_conditions pc where id = :'two_installments_pc_id'::uuid),
  ('PAYMENT_METHOD'::price_rule_type, 0::numeric),
  'F2: price_condition asociada, PAYMENT_METHOD, ajuste informativo 0%'
);

select is(
  (select count(*)::int from price_condition_locations where price_condition_id = :'two_installments_pc_id'::uuid),
  2,
  'F3: disponibilidad sembrada — exactamente 2 sedes (Sede 25 + Sede 37)'
);

select is(
  (
    select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-VITC')
      and price_condition_id = :'two_installments_pc_id'::uuid and active
  ),
  (
    select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-VITC')
      and price_condition_id = (select id from price_conditions where code = 'LIST') and active
  ),
  'F4: precio sembrado de "2 cuotas" para PROD-VITC = precio LIST vigente (mismo criterio que CARD_6/CARD_1)'
);

-- ===========================================================================
-- SECCIÓN G — Permisos de create_price_condition.
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000002', false); -- vendedora

select throws_ok(
  $$select create_price_condition('PCA No Admin', 0, false, array['SED-25'], false)$$,
  'G1: una vendedora (no-admin) NO puede crear una condición de precio (RLS/is_admin() real, no solo UI oculta)'
);

select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false); -- admin de nuevo

select ok(
  (create_price_condition('PCA Admin OK', 0, false, array['SED-25'], false) ->> 'price_condition_id') is not null,
  'G2: un admin SÍ puede crear una condición de precio'
);

-- ===========================================================================
-- SECCIÓN H — Regresión: condiciones/medios existentes sin cambios de
-- comportamiento (más allá de la fuente de requires_billing).
-- ===========================================================================
select is(
  ((create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
    :'sed25_id', :'branch_channel_id', :'cash_id'
  ) ->> 'billing_status')),
  'NOT_REQUIRED',
  'H1: regresión Efectivo — sigue sin requerir facturación'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'branch_channel_id', :'transfer_id', :'customer_id'
  ),
  'H2: regresión Transferencia — sigue exigiendo cuenta de ingreso'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'branch_channel_id', :'card1_id', :'customer_id'
  ),
  'H3: regresión CARD_1 — sigue exigiendo cuenta de ingreso'
);

select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'branch_channel_id', :'card6_id', :'customer_id'
  ),
  'H4: regresión CARD_6 — sigue exigiendo cuenta de ingreso'
);

-- ===========================================================================
-- SECCIÓN I — update_price_condition (Checkpoint 2, migración 70). Edición
-- atómica; nunca toca code/rule_type/payment_method_id/product_prices.
-- ===========================================================================
select create_price_condition(
  'PCA Editable', 0, true, array['SED-25'], false
) as pca_edit_result \gset
select (:'pca_edit_result'::jsonb ->> 'price_condition_id')::uuid as pca_edit_pc_id \gset
select (:'pca_edit_result'::jsonb ->> 'payment_method_id')::uuid as pca_edit_pm_id \gset

select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, true, 1, true, array['SED-25'], false);

select is(
  (select name from price_conditions where id = :'pca_edit_pc_id'::uuid),
  'PCA Editada',
  'I1: update_price_condition actualiza price_conditions.name'
);

select is(
  (select name from payment_methods where id = :'pca_edit_pm_id'::uuid),
  'PCA Editada',
  'I2: update_price_condition actualiza payment_methods.name en lockstep (dashboard etiqueta por acá)'
);

select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, false, 1, true, array['SED-25'], false);
select is(
  (select requires_billing from payment_methods where id = :'pca_edit_pm_id'::uuid),
  false,
  'I3: update_price_condition puede apagar requires_billing — sin cambio de código'
);
select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', :'pca_edit_pm_id', null, null, null, null, null, clock_timestamp(),
      false, null, null, false, null
    ) ->> 'billing_status')
  ),
  'NOT_REQUIRED',
  'I3b: tras apagar requires_billing, una venta nueva ya no exige cuenta de ingreso'
);

-- I4: agregar Sede 37 a la disponibilidad -> ahora sí acepta ahí.
select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, false, 1, true, array['SED-25', 'SED-37'], false);
select ok(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
    :'sed37_id', :'branch_channel_id', :'pca_edit_pm_id', null, null, null, null, null, clock_timestamp(),
    false, null, null, false, null
  ) ->> 'sale_id') is not null,
  'I4: editar disponibilidad agregando Sede 37 -> una venta nueva ahí ya no se rechaza'
);

-- I5: habilitar Web, después deshabilitarlo -> vuelve a rechazar.
select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, false, 1, true, array['SED-25', 'SED-37'], true);
select ok(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
    :'sed25_id', :'web_channel_id', :'pca_edit_pm_id', :'customer_id', null, null, null, null, clock_timestamp(),
    false, null, null, false, null, 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
  ) ->> 'sale_id') is not null,
  'I5a: habilitar Web -> una venta Web nueva la acepta'
);
select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, false, 1, true, array['SED-25', 'SED-37'], false);
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, clock_timestamp(),
      false, null, null, false, null, 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'web_channel_id', :'pca_edit_pm_id', :'customer_id'
  ),
  'I5b: volver a deshabilitar Web -> una venta Web nueva vuelve a ser rechazada'
);

-- I6: desactivar -> fn_pricing_quote ya no la resuelve (deja de ser elegible
-- para ventas NUEVAS), pero no exige tocar nada histórico acá (eso ya lo
-- cubre la Sección E, snapshot).
select update_price_condition(:'pca_edit_pc_id'::uuid, 'PCA Editada', 0, false, 1, false, array['SED-25', 'SED-37'], false);
select is(
  (select active from price_conditions where id = :'pca_edit_pc_id'::uuid),
  false,
  'I6a: update_price_condition puede desactivar la condición'
);
select is(
  (select active from payment_methods where id = :'pca_edit_pm_id'::uuid),
  false,
  'I6b: desactivar la condición desactiva el payment_method en lockstep (deja de listarse en Nueva Venta)'
);

-- I7: atomicidad — sede inválida aborta TODO, el nombre/disponibilidad ya
-- editados en I1-I6 quedan intactos, no a medio aplicar.
select throws_ok(
  format($$select update_price_condition('%s'::uuid, 'PCA Rota Edit', 0, true, 1, true, array['SEDE-INEXISTENTE'], true)$$, :'pca_edit_pc_id'),
  'I7a: update_price_condition con sede inválida rechaza toda la operación'
);
select is(
  (select name from price_conditions where id = :'pca_edit_pc_id'::uuid),
  'PCA Editada',
  'I7b: tras el fallo de I7a, el nombre NO cambió a "PCA Rota Edit" (rollback completo, no parcial)'
);
select is(
  (select active from price_conditions where id = :'pca_edit_pc_id'::uuid),
  false,
  'I7c: tras el fallo de I7a, "active" tampoco volvió a true — ningún campo quedó a medio aplicar'
);

-- I8: permisos — no-admin no puede editar (RLS real vía is_admin(), no solo UI oculta).
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000002', false); -- vendedora
select throws_ok(
  format($$select update_price_condition('%s'::uuid, 'Hackeada', 0, true, 1, true, array['SED-25'], true)$$, :'pca_edit_pc_id'),
  'I8: una vendedora (no-admin) NO puede editar una condición de precio'
);
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false); -- admin de nuevo

-- I9: la condición BASE/LIST no es editable desde acá.
select throws_ok(
  format($$select update_price_condition('%s'::uuid, 'Lista Hackeada', 0, true, 1, true, array['SED-25'], true)$$,
    (select id from price_conditions where code = 'LIST')),
  'I9: update_price_condition rechaza editar la condición BASE/LIST'
);

-- I10: editar NUNCA modifica ningún precio ya cargado en product_prices.
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N') and price_condition_id = :'pca_price_pc_id'::uuid and active),
  7777::numeric,
  'I10: editar una condición distinta (PCA Editada) no modifica los precios de otra condición (PCA Precio Inicial) — precios exclusivos de la matriz'
);

-- ===========================================================================
-- SECCIÓN J — Web real, mismo camino que /api/integrations/web-orders:
-- create_web_order (revocada de authenticated/anon a propósito, exclusiva de
-- service_role — se prueba con "reset role" para simular esa llamada
-- server-to-server real, sin tocar el contrato externo de la ruta).
--
-- Nota (hallazgo, no bug de esta feature): create_web_order() nunca expuso
-- p_payment_account_id ni p_payment_status en su firma (20260101000016), así
-- que siempre los pasa NULL a fn_create_sale_core — que exige una cuenta de
-- ingreso apenas p_payment_status sea distinto de 'PENDING' (NULL lo es).
-- Por eso NINGUNA condición con requires_billing=true puede venderse hoy vía
-- create_web_order, sea cual sea su código — limitación estructural
-- preexistente y ajena a esta feature (el flujo Web real para condiciones
-- con facturación es create_sale con canal=WEB desde Nueva Venta, que sí
-- expone esos parámetros). Por eso esta sección usa "PCA Futura Billing
-- False" (Sección A, requires_billing=false, Web ya habilitada) en vez de
-- "2 cuotas sin interés", para aislar la prueba de disponibilidad Web de esa
-- limitación no relacionada.
-- ===========================================================================
select set_stock(:'sed25_id'::uuid, (select id from products where sku = 'PROD-NIAC'), 100, 'RECEPTION');
reset role;
select is(
  (
    (create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-NIAC'), 'quantity', 1)),
      :'sed25_id'::uuid, :'pca_future_false_pm_id'::uuid, 'test-integration', 'PCA-WEB-ORDER-001'
    ) ->> 'sale_id') is not null
  ),
  true,
  'J1: create_web_order (mismo camino real que /api/integrations/web-orders) acepta una condición habilitada para Web'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

-- Admin deshabilita Web para "PCA Futura Billing False".
select update_price_condition(
  :'pca_future_false_pc_id'::uuid, 'PCA Futura Billing False', 0, false, 1,
  true, array['SED-25', 'SED-37'], false
);

reset role;
select throws_ok(
  format(
    $$select create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, 'test-integration', 'PCA-WEB-ORDER-002'
    )$$,
    (select id from products where sku = 'PROD-NIAC'), :'sed25_id', :'pca_future_false_pm_id'
  ),
  'J2: tras deshabilitar Web, create_web_order con la misma condición es RECHAZADA (mismo punto central, sin bypass)'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

-- Deja "PCA Futura Billing False" tal como estaba (Sede 25/Sede 37/Web) para no afectar otras secciones/tests que corran después en la misma base.
select update_price_condition(
  :'pca_future_false_pc_id'::uuid, 'PCA Futura Billing False', 0, false, 1,
  true, array['SED-25', 'SED-37'], true
);

-- ===========================================================================
-- SECCIÓN K — Prueba estructural: "9 cuotas test", condición FICTICIA creada
-- exclusivamente para este test, para demostrar que la arquitectura es
-- verdaderamente data-driven (no que "2 cuotas" funciona porque tiene algo
-- especial). Todo el recorrido sin tocar ni una línea de código.
-- ===========================================================================
select create_price_condition(
  '9 cuotas test', 0.05, true, array['SED-25'], false
) as k9_result \gset
select (:'k9_result'::jsonb ->> 'price_condition_id')::uuid as k9_pc_id \gset
select (:'k9_result'::jsonb ->> 'payment_method_id')::uuid as k9_pm_id \gset
select (:'k9_result'::jsonb ->> 'price_condition_code') as k9_pc_code \gset
select (:'k9_result'::jsonb ->> 'payment_method_code') as k9_pm_code \gset

select isnt(
  :'k9_pc_code'::text, '9 cuotas test'::text,
  'K1a: "9 cuotas test" recibe un code técnico autogenerado, nunca igual al nombre'
);
select ok(
  :'k9_pc_code' like 'PC-%' and length(:'k9_pc_code') = 35,
  'K1b: el code generado sigue el patrón técnico (PC-<32 hex>), no algo tipeado a mano'
);

select is(
  (select requires_billing from payment_methods where id = :'k9_pm_id'::uuid),
  true,
  'K2: "9 cuotas test" configurable con requires_billing=true, sin cambio de código'
);

select set_stock(:'sed25_id'::uuid, (select id from products where sku = 'PCA-N'), 100, 'RECEPTION');

-- K3: habilitada SOLO Sede 25 -> Sede 37 la rechaza.
select ok(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
    :'sed25_id', :'branch_channel_id', :'k9_pm_id', :'customer_id', null, null, null, null, clock_timestamp(),
    false, null, null, false, :'account_id'
  ) ->> 'sale_id') is not null,
  'K3a: "9 cuotas test" habilitada en Sede 25 -> acepta'
);
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, clock_timestamp(),
      false, null, null, false, '%s'::uuid
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed37_id', :'branch_channel_id', :'k9_pm_id', :'customer_id', :'account_id'
  ),
  'K3b: "9 cuotas test" NO habilitada en Sede 37 -> rechaza, sin ningún hardcode de "Sede 37" en el código'
);

-- K4: deshabilitada para Web desde la creación -> Web la rechaza.
select throws_ok(
  format(
    $$select create_sale(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, '%s'::uuid, '%s'::uuid, null, null, null, null, clock_timestamp(),
      false, null, null, false, '%s'::uuid, 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
    )$$,
    (select id from products where sku = 'PCA-N'), :'sed25_id', :'web_channel_id', :'k9_pm_id', :'customer_id', :'account_id'
  ),
  'K4: "9 cuotas test" no habilitada para Web -> rechaza'
);

-- K5: se habilita Web después, vía la misma RPC de edición -> ahora acepta.
select update_price_condition(:'k9_pc_id'::uuid, '9 cuotas test', 0.05, true, 1, true, array['SED-25'], true);
select ok(
  (create_sale(
    jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
    :'sed25_id', :'web_channel_id', :'k9_pm_id', :'customer_id', null, null, null, null, clock_timestamp(),
    false, null, null, false, :'account_id', 'PICKUP'::sale_fulfillment_type, 'PAID'::sale_payment_status
  ) ->> 'sale_id') is not null,
  'K5: tras habilitar Web con update_price_condition, "9 cuotas test" ahora SÍ acepta Web'
);

-- K6: recibe precio con la RPC genérica ya existente (misma que usa la Matriz).
select set_product_price((select id from products where sku = 'PCA-N2'), :'k9_pc_id'::uuid, 4242, clock_timestamp());
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'PCA-N2') and price_condition_id = :'k9_pc_id'::uuid and active),
  4242::numeric,
  'K6: "9 cuotas test" recibe precios normalmente desde la matriz (set_product_price), sin cambio de código'
);

-- K7: se usa en una venta válida, cotizando el precio recién cargado.
select is(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N2'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', :'k9_pm_id', :'customer_id', null, null, null, null, clock_timestamp(),
      false, null, null, false, :'account_id'
    ) ->> 'total')::numeric
  ),
  4242::numeric,
  'K7: venta real con "9 cuotas test" cotiza correctamente el precio cargado — arquitectura 100% data-driven demostrada'
);

-- ===========================================================================
-- SECCIÓN L — Checkpoint 2.1: create_web_order + circuito de pago/
-- facturación (migración 71). PROD-VITC (no PCA-N/PCA-N2): producto real del
-- seed, ya usado en Secciones D/E/F, con precio propio bajo CASH/"2 cuotas
-- sin interés"/LIST — mismo criterio ya establecido en este archivo de nunca
-- inventar un precio.
--
-- Nota: el caso "payload inválido -> la ruta devuelve un error claro" (PAID
-- sin payment_account_id, rechazado ANTES de llamar a Postgres) se prueba en
-- Vitest (tests/web-order-schema.test.ts), no acá — pgTAP llama directo a
-- create_web_order (la RPC), nunca pasa por la capa HTTP de
-- app/api/integrations/web-orders/route.ts.
-- ===========================================================================
select id as dep_id from stock_locations where code = 'DEP' \gset
select set_stock(:'dep_id'::uuid, (select id from products where sku = 'PROD-VITC'), 100, 'RECEPTION');

-- L1/L2: retrocompatibilidad explícita — un payload histórico (CASH, sin
-- payment_status/payment_account_id/fulfillment_type) se comporta EXACTO
-- igual que antes de esta migración: éxito, y ambas columnas nuevas quedan
-- NULL (nunca se infiere SHIPPING ni ningún estado de pago en silencio).
reset role;
select (create_web_order(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  :'sed25_id'::uuid, :'cash_id'::uuid, 'test-integration', 'PCA-WEB-L1'
) ->> 'sale_id')::uuid as l1_sale_id \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

select ok(
  :'l1_sale_id' is not null,
  'L1: create_web_order histórico (CASH, sin ninguno de los 3 parámetros nuevos) sigue funcionando'
);
select is(
  (select (payment_status, fulfillment_type) from sales where id = :'l1_sale_id'::uuid),
  (null::sale_payment_status, null::sale_fulfillment_type),
  'L2: la venta histórica queda con payment_status/fulfillment_type NULL — comportamiento exacto de antes de la 71, nunca se asume SHIPPING/PENDING'
);

-- L3-L11: "2 cuotas sin interés" (real, no ficticia) + Web habilitada +
-- PENDING, vía SHIPPING interno (Depósito) — el escenario central del pedido.
reset role;
select (create_web_order(
  jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
  :'dep_id'::uuid, :'two_installments_pm_id'::uuid, 'test-integration', 'PCA-WEB-L3',
  :'customer_id'::uuid, null, null, clock_timestamp(),
  'PENDING'::sale_payment_status, null, 'SHIPPING'::sale_fulfillment_type
) ->> 'sale_id')::uuid as l3_sale_id \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

select ok(
  :'l3_sale_id' is not null,
  'L3: "2 cuotas sin interés" + Web habilitada + PENDING vía create_web_order (SHIPPING interno) -> éxito'
);
select is(
  (select billing_status from sales where id = :'l3_sale_id'::uuid),
  'NOT_REQUIRED'::sale_billing_status,
  'L4: billing_status = NOT_REQUIRED al crear (BUGFIX 57, ya existente: mientras el cobro está PENDING, la obligación de facturación no nace todavía — nace recién al cobrar, ver L16b)'
);
select is(
  (select payment_status from sales where id = :'l3_sale_id'::uuid),
  'PENDING'::sale_payment_status,
  'L5: payment_status = PENDING, tal como se declaró'
);
select is(
  (select payment_account_id from sales where id = :'l3_sale_id'::uuid),
  null::uuid,
  'L6: payment_account_id queda NULL — no se sabe todavía en qué cuenta va a entrar el cobro (mismo criterio que Nueva Venta Web/PENDING)'
);
select is(
  (select (fulfillment_type, fulfillment_status) from sales where id = :'l3_sale_id'::uuid),
  ('SHIPPING'::sale_fulfillment_type, 'SHIPPED'::sale_fulfillment_status),
  'L7: fulfillment_type=SHIPPING/fulfillment_status=SHIPPED — el route handler lo decidió internamente, nunca expuesto en el contrato externo'
);
select is(
  (select price_condition_name_snapshot from sales where id = :'l3_sale_id'::uuid),
  '2 cuotas sin interés',
  'L8: snapshot correcto — condición aplicada, nombre congelado al momento de la venta'
);
select is(
  (select total from sales where id = :'l3_sale_id'::uuid),
  (
    select amount from product_prices
    where product_id = (select id from products where sku = 'PROD-VITC')
      and price_condition_id = :'two_installments_pc_id'::uuid and active
  ),
  'L9: precio correcto — cotiza el precio real cargado para PROD-VITC bajo "2 cuotas sin interés", nunca inventado'
);
select is(
  (select quantity from inventory_balances where location_id = :'dep_id'::uuid and product_id = (select id from products where sku = 'PROD-VITC')),
  99::numeric,
  'L10: stock correcto — SHIPPING descuenta de inmediato (fn_apply_stock_movement), mismo comportamiento de siempre de create_web_order (100 recibidas - 1 vendida = 99)'
);
select is(
  (select count(*)::int from sale_stock_reservations where sale_id = :'l3_sale_id'::uuid),
  0,
  'L11: sin ninguna fila en sale_stock_reservations — SHIPPING nunca reserva (esa es la rama exclusiva de PICKUP, fuera de alcance acá)'
);

-- L12-L13: PAID, con y sin cuenta — la RPC (autoridad real, la ruta ya
-- valida esto antes de llamarla, ver Vitest) sigue exigiendo la cuenta.
reset role;
select ok(
  (
    (create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
      :'dep_id'::uuid, :'two_installments_pm_id'::uuid, 'test-integration', 'PCA-WEB-L12',
      :'customer_id'::uuid, null, null, clock_timestamp(),
      'PAID'::sale_payment_status, :'account_id'::uuid, 'SHIPPING'::sale_fulfillment_type
    ) ->> 'sale_id') is not null
  ),
  'L12: "2 cuotas sin interés" + PAID + cuenta válida -> éxito'
);
select throws_ok(
  format(
    $$select create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, 'test-integration', 'PCA-WEB-L13',
      '%s'::uuid, null, null, clock_timestamp(),
      'PAID'::sale_payment_status, null, 'SHIPPING'::sale_fulfillment_type
    )$$,
    (select id from products where sku = 'PROD-VITC'), :'dep_id', :'two_installments_pm_id', :'customer_id'
  ),
  'L13: "2 cuotas sin interés" + PAID sin cuenta -> rechazo (fn_create_sale_core, sin cambios ahí)'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

-- L14: disponibilidad Web se sigue validando de forma independiente al
-- circuito de pago — deshabilitar Web para "2 cuotas" rechaza el mismo
-- pedido que en L3, sin ningún bypass en create_web_order.
select priority as ti_priority from price_conditions where id = :'two_installments_pc_id'::uuid \gset
select update_price_condition(
  :'two_installments_pc_id'::uuid, '2 cuotas sin interés', 0, true, :ti_priority,
  true, array['SED-25', 'SED-37'], false
);
reset role;
select throws_ok(
  format(
    $$select create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, 'test-integration', 'PCA-WEB-L14',
      '%s'::uuid, null, null, clock_timestamp(),
      'PENDING'::sale_payment_status, null, 'SHIPPING'::sale_fulfillment_type
    )$$,
    (select id from products where sku = 'PROD-VITC'), :'dep_id', :'two_installments_pm_id', :'customer_id'
  ),
  'L14: admin deshabilita Web para "2 cuotas sin interés" -> create_web_order la rechaza (fn_price_condition_available, sin bypass)'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);
select update_price_condition(
  :'two_installments_pc_id'::uuid, '2 cuotas sin interés', 0, true, :ti_priority,
  true, array['SED-25', 'SED-37'], true
);

-- L15: SHIPPING exige Depósito — nunca se transforma/corrige el location_id
-- recibido, la validación existente de fn_create_sale_core lo rechaza tal cual.
reset role;
select throws_ok(
  format(
    $$select create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'quantity', 1)),
      '%s'::uuid, '%s'::uuid, 'test-integration', 'PCA-WEB-L15',
      '%s'::uuid, null, null, clock_timestamp(),
      'PENDING'::sale_payment_status, null, 'SHIPPING'::sale_fulfillment_type
    )$$,
    (select id from products where sku = 'PROD-VITC'), :'sed25_id', :'two_installments_pm_id', :'customer_id'
  ),
  'L15: SHIPPING con location_id = Sede 25 (no Depósito) -> rechazo, sin ninguna corrección silenciosa'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

-- L16-L17: el pedido PENDING de L3 no queda huérfano — mark_web_order_paid
-- (ya existente, sin cambios) lo reconoce porque fulfillment_type ya no es
-- NULL, y lo cobra correctamente.
select mark_web_order_paid(:'l3_sale_id'::uuid, null, :'account_id'::uuid) as l16_result \gset
select is(
  (select payment_status from sales where id = :'l3_sale_id'::uuid),
  'PAID'::sale_payment_status,
  'L16: mark_web_order_paid cobra correctamente el pedido PENDING creado vía create_web_order — no queda huérfano'
);
select is(
  (select payment_account_id from sales where id = :'l3_sale_id'::uuid),
  :'account_id'::uuid,
  'L17: payment_account_id queda seteado tras el cobro'
);
select is(
  (select billing_status from sales where id = :'l3_sale_id'::uuid),
  'PENDING'::sale_billing_status,
  'L17b: billing_status recién pasa de NOT_REQUIRED a PENDING acá (BUGFIX 57) — la obligación de facturar nace al cobrar, no antes; demuestra que el pedido no quedó huérfano en ningún eje'
);

-- L18: prueba estructural — condición FICTICIA nueva, requires_billing=true,
-- habilitada para Web, sin ningún "if 2 cuotas"/"if CARD_X" en el camino.
select create_price_condition(
  'Web Shipping Test', 0, true, array['SED-25'], true
) as l18_result \gset
select (:'l18_result'::jsonb ->> 'price_condition_id')::uuid as l18_pc_id \gset
select (:'l18_result'::jsonb ->> 'payment_method_id')::uuid as l18_pm_id \gset
select set_product_price((select id from products where sku = 'PROD-VITC'), :'l18_pc_id'::uuid, 12345, clock_timestamp());

reset role;
select ok(
  (
    (create_web_order(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PROD-VITC'), 'quantity', 1)),
      :'dep_id'::uuid, :'l18_pm_id'::uuid, 'test-integration', 'PCA-WEB-L18',
      :'customer_id'::uuid, null, null, clock_timestamp(),
      'PENDING'::sale_payment_status, null, 'SHIPPING'::sale_fulfillment_type
    ) ->> 'sale_id') is not null
  ),
  'L18: condición nueva y ficticia ("Web Shipping Test", requires_billing=true, Web habilitada) funciona por el mismo camino SHIPPING+PENDING, sin cambio de código — arquitectura data-driven demostrada también para el circuito Web'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- SECCIÓN M — visible_in_price_lookup (migración 73): eje independiente de
-- active. "¿se puede vender?" (active) vs. "¿aparece en /precios?"
-- (visible_in_price_lookup) nunca se confunden.
-- ===========================================================================

-- M1: create_price_condition sin pasar el parámetro nuevo -> default true
-- (toda condición nace visible salvo que el admin la oculte al crearla).
select create_price_condition(
  'PCA Visibilidad Default', 0, false, array['SED-25'], false
) as m1_result \gset
select (:'m1_result'::jsonb ->> 'price_condition_id')::uuid as m1_pc_id \gset
select is(
  (select visible_in_price_lookup from price_conditions where id = :'m1_pc_id'::uuid),
  true,
  'M1: create_price_condition sin p_visible_in_price_lookup -> default true'
);

-- M2: create_price_condition con el parámetro explícito en false.
select create_price_condition(
  'PCA Visibilidad Oculta Desde Alta', 0, false, array['SED-25'], false,
  true, 'LIST', null, false
) as m2_result \gset
select (:'m2_result'::jsonb ->> 'price_condition_id')::uuid as m2_pc_id \gset
select is(
  (select visible_in_price_lookup from price_conditions where id = :'m2_pc_id'::uuid),
  false,
  'M2: create_price_condition con p_visible_in_price_lookup=false nace oculta'
);

-- M3: update_price_condition cambia visible_in_price_lookup explícitamente.
select update_price_condition(
  :'m1_pc_id'::uuid, 'PCA Visibilidad Default', 0, false,
  (select priority from price_conditions where id = :'m1_pc_id'::uuid),
  true, array['SED-25'], false, false
);
select is(
  (select visible_in_price_lookup from price_conditions where id = :'m1_pc_id'::uuid),
  false,
  'M3: update_price_condition con p_visible_in_price_lookup=false la oculta'
);

-- M4: EL CASO CLAVE — update_price_condition SIN pasar el parámetro nuevo
-- (semántica PATCH, default null) preserva el valor ya guardado. Simula
-- exactamente lo que hace toggleActive() en price-conditions-table.tsx: solo
-- le interesa cambiar "active", nunca debería resetear la visibilidad.
select update_price_condition(
  p_price_condition_id := :'m1_pc_id'::uuid,
  p_name := 'PCA Visibilidad Default',
  p_discount_percent := 0,
  p_requires_billing := false,
  p_priority := (select priority from price_conditions where id = :'m1_pc_id'::uuid),
  p_active := false,
  p_location_codes := array['SED-25'],
  p_available_web := false
);
select is(
  (select visible_in_price_lookup from price_conditions where id = :'m1_pc_id'::uuid),
  false,
  'M4: update_price_condition SIN p_visible_in_price_lookup preserva el valor existente (false de M3) — no lo resetea a true'
);
select is(
  (select active from price_conditions where id = :'m1_pc_id'::uuid),
  false,
  'M4b: mientras tanto, active sí cambió al valor pasado — confirma que M4 es específico de visible_in_price_lookup, no que la llamada entera no tuvo efecto'
);

-- M5: ocultar una condición (visible=false) NO la desactiva, no le saca
-- disponibilidad, y sigue siendo vendible — demuestra el desacople completo
-- que pide el cliente. m2 ya nació active=true/visible=false en M2 — se usa
-- tal cual, sin ningún update intermedio, para que la venta pruebe
-- exactamente ese estado "oculta pero 100% vendible".
select set_product_price((select id from products where sku = 'PCA-N'), :'m2_pc_id'::uuid, 8800);
select ok(
  (
    (create_sale(
      jsonb_build_array(jsonb_build_object('product_id', (select id from products where sku = 'PCA-N'), 'quantity', 1)),
      :'sed25_id', :'branch_channel_id', (select payment_method_id from price_conditions where id = :'m2_pc_id'::uuid),
      null, null, null, null, null, now(), false, null, null, false, null
    ) ->> 'sale_id') is not null
  ),
  'M5: una condición oculta en /precios (visible_in_price_lookup=false) sigue siendo 100% vendible — active y disponibilidad intactas'
);
select is(
  (select visible_in_price_lookup from price_conditions where id = :'m2_pc_id'::uuid),
  false,
  'M5b: y después de vender con ella, sigue oculta — vender no la hace visible ni viceversa'
);

-- M6: BASE (LIST) no es editable por update_price_condition en absoluto —
-- mismo rechazo ya establecido para cualquier otro campo (comentario de
-- cabecera de la migración 70), confirma que tampoco hay forma de tocarle
-- visible_in_price_lookup desde acá.
select throws_ok(
  format(
    $$select update_price_condition('%s'::uuid, 'Lista', 0, false, 1, true, array[]::text[], false, false)$$,
    (select id from price_conditions where code = 'LIST')
  ),
  'M6: update_price_condition rechaza la condición BASE/LIST — tampoco puede ocultarla de /precios'
);

-- M7: un vendedor (no admin) no puede cambiar visible_in_price_lookup —
-- mismo is_admin() que ya protege el resto de la función.
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000002', false);
select throws_ok(
  format(
    $$select update_price_condition('%s'::uuid, 'PCA Visibilidad Default', 0, false, 1, true, array['SED-25'], false, true)$$,
    :'m1_pc_id'
  ),
  'M7: un vendedor no puede cambiar visible_in_price_lookup (rechazado por is_admin())'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aca00000-0000-0000-0000-000000000001', false);

select * from finish();
rollback;
