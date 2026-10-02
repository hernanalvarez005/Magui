-- pgTAP: Precio de Lista maestro — recálculo automático AUTO/MANUAL
-- (migración 74). Casos:
--   A. Backfill — todo lo preexistente nace MANUAL, sin cambiar amounts.
--   B. Cascada básica: Lista cambia (AUTO recalcula, MANUAL conserva).
--   C. Cascada básica: % cambia (AUTO recalcula, MANUAL conserva).
--   D. save_price_matrix_changes: overrides manuales y "volver a automático".
--   E. % NULL no participa / producto sin Lista no participa.
--   F. Condición inactiva no participa / oculta pero activa sí participa.
--   G. Condición futura PAYMENT_METHOD, 0 product_prices previos.
--   H. Atomicidad de save_price_matrix_changes.
--   I. Permisos (no-admin).
--   J. create_price_condition genera/no genera AUTO según % y active.
--   K. Transición % no-nulo -> NULL (cierra AUTO, preserva MANUAL) y NULL -> %.
--   L. Reactivación (active false->true) sincroniza AUTO.
--   M. QUANTITY nunca participa.
--   O. Borrado de un precio puntual (p_clears).
--   P. Borrar Precio de Lista cierra TODOS los AUTO dependientes; recargar
--      Lista los regenera; MANUAL siempre intacto.
--   Q. Lista y % cambian juntos en el mismo guardado — AUTO usa ambos
--      valores nuevos.
--   R. Migración 075 — un cambio GLOBAL de % pisa MANUAL (incluido el
--      backfill de la 074) y lo deja AUTO; Lista sigue sin pisar MANUAL.
--      Matriz completa del pedido: casos 1-5, 10, 11 nuevos acá; casos
--      6 (J1/J2), 7 (E2/G3), 8 (F1) y 9 (K1-K3) ya cubiertos arriba, sin
--      duplicar. Incluye integridad histórica (fila vieja cerrada, nunca
--      pisada; venta histórica intacta).
--   N. Helper interno fn_recalculate_auto_prices no ejecutable por PUBLIC/anon/authenticated.
-- Correr con: rebuild local (preamble + seed_026_skus) + pg_prove.
begin;
select plan(81);

-- ---------------------------------------------------------------------------
-- A. Backfill: todo lo que ya existía (seed_data + cualquier fixture de
-- otros tests que haya corrido antes en la misma DB, aunque cada archivo
-- hace rollback de lo propio) nace MANUAL. Se verifica ANTES de insertar
-- nada nuevo en este archivo.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from product_prices where pricing_mode is distinct from 'MANUAL'),
  0,
  'A1: ningún product_prices preexistente (seed + migraciones previas) quedó con pricing_mode distinto de MANUAL'
);

-- ---------------------------------------------------------------------------
-- Fixtures propios.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('aae00000-0000-0000-0000-000000000001', 'admin.apr@test.maguirejuve.com'),
  ('aae00000-0000-0000-0000-000000000002', 'seller.apr@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'aae00000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'aae00000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'aae00000-0000-0000-0000-000000000001', id from public.stock_locations;

set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('APR-A', 'Auto precio A', 'product', 'Test', true, true, true, true),
  ('APR-B', 'Auto precio B', 'product', 'Test', true, true, true, true),
  ('APR-NOLIST', 'Auto precio sin Lista', 'product', 'Test', true, true, true, true);

select set_product_price((select id from products where sku = 'APR-A'), (select id from price_conditions where code = 'LIST'), 100000);
select set_product_price((select id from products where sku = 'APR-B'), (select id from price_conditions where code = 'LIST'), 50000);
-- APR-NOLIST deliberadamente sin Lista.

-- Condición de prueba PAYMENT_METHOD propia, con 15% ya configurado, para no
-- interferir con CASH/TRANSFER reales de otros tests.
insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-PM15', 'Medio de prueba 15%', true, false, 999);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PC15', 'Condición de prueba 15%', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-PM15'), 0.15, 50, false, true
);

-- ---------------------------------------------------------------------------
-- B. Cascada básica — Lista cambia.
-- ---------------------------------------------------------------------------
-- APR-A no tiene todavía ninguna fila bajo APR-PC15 -> el primer cambio de
-- Lista debe CREARLA en AUTO (caso "no existe + Lista + condición activa +
-- % no nulo -> crear").
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 100000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  85000::numeric,
  'B1: Lista $100.000 sin fila previa bajo APR-PC15 (15%) -> se CREA en AUTO, $85.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'B2: la fila recién creada es AUTO'
);

-- Cambiar Lista de nuevo -> recalcula la fila AUTO existente.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 120000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  102000::numeric,
  'B3: Lista $100.000 -> $120.000, AUTO recalcula a $102.000 (15% off)'
);

-- Convertir esa misma celda a MANUAL con un valor explícito, y volver a
-- cambiar Lista: no debe tocarse.
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'),
    'amount', 99999
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'MANUAL',
  'B4: override manual explícito pasa la celda a MANUAL'
);
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'amount', 140000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  99999::numeric,
  'B5: Lista cambia de nuevo ($120.000 -> $140.000) pero la celda es MANUAL -> conserva $99.999'
);

-- ---------------------------------------------------------------------------
-- C. Cascada básica — % cambia (afecta a TODOS los productos AUTO bajo esa condición).
-- ---------------------------------------------------------------------------
-- APR-B: primero generamos su fila AUTO bajo APR-PC15 cambiando Lista.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'), 'amount', 50000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  42500::numeric,
  'C1: APR-B Lista $50.000, 15% -> AUTO $42.500'
);

-- Cambiar el % de APR-PC15 de 15% a 20% -> recalcula APR-B (AUTO) Y también
-- pisa APR-A (MANUAL desde B4/B5): un cambio GLOBAL de % resetea a AUTO
-- incluso filas MANUAL de esa misma condición (migración 075 — antes de
-- este fix, un % nuevo nunca pisaba MANUAL, sin importar la dirección; ver
-- sección R para la matriz completa de este comportamiento).
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.20
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  40000::numeric,
  'C2: % 15%->20% recalcula APR-B (AUTO) a $40.000 (Lista $50.000 vigente)'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  112000::numeric,
  'C3: el mismo cambio GLOBAL de % también pisa APR-A (MANUAL $99.999 desde B4/B5) -> AUTO, Lista $140.000 x 20% = $112.000 (migración 075)'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'C3b: y la fila de APR-A queda marcada AUTO, no MANUAL'
);

-- ---------------------------------------------------------------------------
-- D. "Volver a automático" (individual) — se mantiene intacta tras la 075:
-- sigue siendo la única vía para sacar una excepción MANUAL puntual sin
-- tocar el % global de la condición. Para ejercerla de verdad (y no sobre
-- una fila que C3 ya dejó AUTO), convertimos APR-A a MANUAL de nuevo acá.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'),
    'amount', 88888
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'MANUAL',
  'D0: setup — APR-A vuelve a MANUAL ($88.888) para ejercer "Volver a automático" sobre una excepción real'
);
select save_price_matrix_changes(
  p_reset_to_auto := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15')
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  112000::numeric,
  'D1: "Volver a automático" individual recalcula APR-A con Lista $140.000 (B5) y % 20% (C2) vigentes -> $112.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'D2: y queda marcada AUTO de nuevo'
);

-- ---------------------------------------------------------------------------
-- E. % NULL no participa / producto sin Lista no participa.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', null
  ))
);
select is(
  (select discount_percent from price_conditions where code = 'APR-PC15'),
  null,
  'E1: % puede quedar explícitamente NULL (ya no se fuerza a 0)'
);
-- (el cierre de AUTO por esta transición se prueba en detalle en la sección K)

-- Volver a poner 15% para seguir probando "producto sin Lista".
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.15
  ))
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-NOLIST')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15')
       and active = true),
  0,
  'E2: APR-NOLIST (sin Lista vigente) no recibe ninguna fila AUTO aunque la condición esté activa y con %'
);

-- ---------------------------------------------------------------------------
-- F. Condición inactiva no participa / oculta pero activa sí participa.
-- ---------------------------------------------------------------------------
update public.price_conditions set active = false where code = 'APR-PC15';
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'), 'amount', 60000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  -- $42.500: recalculado por el round-trip NULL->15% de la sección E
  -- (Lista $50.000 vigente en ese momento x 15%), no por este bloque.
  42500::numeric,
  'F1: con APR-PC15 inactiva, cambiar Lista de APR-B NO recalcula esa condición (sigue $42.500, stale a propósito)'
);
update public.price_conditions set active = true, visible_in_price_lookup = false where code = 'APR-PC15';
-- (la reactivación en sí se prueba en detalle en la sección L; acá solo
-- confirmamos que "oculta pero activa" participa normalmente.)
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.25
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  45000::numeric,
  'F2: APR-PC15 oculta (visible_in_price_lookup=false) pero activa SÍ recalcula normalmente (Lista $60.000, 25% -> $45.000)'
);
update public.price_conditions set visible_in_price_lookup = true where code = 'APR-PC15';

-- ---------------------------------------------------------------------------
-- G. Condición futura PAYMENT_METHOD con 0 product_prices previos.
-- ---------------------------------------------------------------------------
insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-FUTURA', 'Condición futura de prueba', true, false, 998);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PCFUTURA', '9 cuotas futura (sin % al crear)', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-FUTURA'), null, 49, false, true
);
select is(
  (select count(*)::int from product_prices where price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA')),
  0,
  'G1: condición futura recién creada sin % -> 0 product_prices (nada que calcular, nada que copiar: origen LIST default no aplica porque no se pasó copy explícito con % — ver J para el camino de creación con %)'
);
-- Asignarle %: debe generar AUTO para los productos CON Lista (APR-A, APR-B), ninguno para APR-NOLIST.
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCFUTURA'), 'discount_percent', 0.05
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA') and active = true),
  133000::numeric,
  'G2: asignar % por primera vez a una condición futura (0 filas previas) genera AUTO para APR-A (Lista $140.000, 5% -> $133.000)'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-NOLIST')
       and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA')),
  0,
  'G3: y ninguna fila para APR-NOLIST (sin Lista vigente)'
);

-- ---------------------------------------------------------------------------
-- H. Atomicidad: un ítem inválido aborta TODO el guardado.
-- ---------------------------------------------------------------------------
select throws_ok(
  format(
    $$select save_price_matrix_changes(
        p_list_price_changes := jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'amount', 999)),
        p_manual_overrides := jsonb_build_array(jsonb_build_object('product_id', '%s'::uuid, 'price_condition_id', '%s'::uuid, 'amount', -5))
      )$$,
    (select id from products where sku = 'APR-B'),
    (select id from products where sku = 'APR-B'),
    (select id from price_conditions where code = 'APR-PC15')
  ),
  'H1: un override inválido (monto negativo) aborta toda la llamada'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where rule_type = 'BASE') and active = true),
  60000::numeric,
  'H2: la Lista de APR-B NO cambió a 999 — el item válido del mismo payload tampoco se guardó (todo o nada)'
);

-- ---------------------------------------------------------------------------
-- I. Permisos — no-admin rechazado.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000002', false);
select throws_ok(
  $$select save_price_matrix_changes(p_list_price_changes := jsonb_build_array(jsonb_build_object('product_id', gen_random_uuid(), 'amount', 100)))$$,
  'I1: un vendedor (no-admin) no puede llamar a save_price_matrix_changes'
);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- J. create_price_condition — genera/no genera AUTO según % y active.
-- ---------------------------------------------------------------------------
select create_price_condition(
  p_name := 'APR 9 cuotas -20%',
  p_discount_percent := 0.20,
  p_requires_billing := false,
  p_location_codes := array[]::text[],
  p_available_web := true,
  p_active := true,
  p_copy_prices_from_code := 'LIST',
  p_priority := 10
);
select is(
  (select amount from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR 9 cuotas -20%')
       and active = true),
  112000::numeric,
  'J1: create_price_condition con 20% genera AUTO inmediatamente (Lista APR-A $140.000 -> $112.000), sin segunda edición'
);
select is(
  (select pricing_mode from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR 9 cuotas -20%')
       and active = true),
  'AUTO',
  'J2: y esa fila nace AUTO'
);

select create_price_condition(
  p_name := 'APR sin porcentaje',
  p_discount_percent := null,
  p_requires_billing := false,
  p_location_codes := array[]::text[],
  p_available_web := true,
  p_active := true,
  p_copy_prices_from_code := 'LIST',
  p_priority := 11
);
select is(
  (select discount_percent from price_conditions where name = 'APR sin porcentaje'),
  null,
  'J3: create_price_condition sin % (NULL explícito) crea la condición con discount_percent NULL de verdad'
);
select is(
  (select count(*)::int from product_prices
     where price_condition_id = (select id from price_conditions where name = 'APR sin porcentaje')),
  0,
  'J4: y SIN % NO copia ni genera nada — nace sin ningún product_prices (ni MANUAL ni AUTO), para que una asignación posterior de % encuentre "ausencia de fila" y pueda generar AUTO'
);

-- Secuencia explícita pedida: crear sin % -> 0 filas -> asignar 20% ->
-- AUTO creados para todos los productos con Lista, importe correcto.
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where name = 'APR sin porcentaje'),
  p_name := 'APR sin porcentaje',
  p_discount_percent := 0.20,
  p_requires_billing := false,
  p_priority := 11,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select amount from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR sin porcentaje')
       and active = true),
  112000::numeric,
  'J5: NULL->20% sobre la condición recién creada (0 filas previas) genera AUTO para APR-A (Lista $140.000 -> $112.000)'
);
select is(
  (select pricing_mode from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where name = 'APR sin porcentaje')
       and active = true),
  'AUTO',
  'J6: y nace AUTO, no MANUAL'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-NOLIST')
       and price_condition_id = (select id from price_conditions where name = 'APR sin porcentaje')),
  0,
  'J7: APR-NOLIST (sin Lista vigente) sigue sin recibir ninguna fila'
);

-- ---------------------------------------------------------------------------
-- K. Transición % no-nulo -> NULL (cierra AUTO, preserva MANUAL) y NULL -> %.
-- ---------------------------------------------------------------------------
-- Estado antes de este bloque: APR-PC15 (15%, activa). APR-A es AUTO ($112.000
-- por la reactivación/recalc de D1 y F/G de arriba — recalculamos explícito
-- para dejar el escenario limpio) y le agregamos un segundo producto MANUAL.
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := 0.15,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'),
    'amount', 77777
  ))
);
select ok(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true) = 'AUTO',
  'K0: setup — APR-A sigue AUTO bajo APR-PC15'
);

select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := null,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select count(*)::int from product_prices
     where price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true and pricing_mode = 'AUTO'),
  0,
  'K1: % 15%->NULL vía update_price_condition cierra TODAS las filas AUTO vigentes de la condición'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  77777::numeric,
  'K2: la fila MANUAL de APR-B se preserva intacta ante la misma transición'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-A')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  0,
  'K3: y no se crea ningún AUTO nuevo para APR-A — queda sin precio vigente bajo esa condición hasta que vuelva a tener %'
);

select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%',
  p_discount_percent := 0.30,
  p_requires_billing := false,
  p_priority := 50,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  98000::numeric,
  'K4: NULL->30% vía update_price_condition vuelve a generar AUTO para APR-A (Lista $140.000 -> $98.000)'
);
-- K5/K6: la MISMA llamada (update_price_condition es un cambio GLOBAL de %)
-- también pisa el MANUAL de APR-B (desde K, $77.777) -> AUTO con la Lista
-- vigente ($60.000 desde F1) x 30% = $42.000 (migración 075, caso #5 de la
-- matriz del pedido: "mismo comportamiento vía update_price_condition").
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  42000::numeric,
  'K5: APR-B (MANUAL $77.777) también se pisa con el mismo cambio global de % -> AUTO, Lista $60.000 x 30% = $42.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  'AUTO',
  'K6: y queda marcada AUTO, no MANUAL'
);

-- ---------------------------------------------------------------------------
-- L. Reactivación (active false->true) sincroniza AUTO. APR-B ya no tiene
-- ninguna fila MANUAL entrando a esta sección (K5/K6 la pisó a AUTO) — la
-- reactivación la recalcula igual que a cualquier AUTO, sin ninguna
-- diferencia de comportamiento (la "A" de la sección L original ya no
-- aplica: no queda ningún MANUAL para preservar en este escenario).
-- ---------------------------------------------------------------------------
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%', p_discount_percent := 0.30, p_requires_billing := false,
  p_priority := 50, p_active := false, p_location_codes := array[]::text[], p_available_web := true
);
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'), 'amount', 200000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  98000::numeric,
  'L1: con APR-PC15 inactiva, cambiar Lista de APR-A no la recalcula (sigue $98.000, stale)'
);
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PC15'),
  p_name := 'Condición de prueba 15%', p_discount_percent := 0.30, p_requires_billing := false,
  p_priority := 50, p_active := true, p_location_codes := array[]::text[], p_available_web := true
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-A')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  140000::numeric,
  'L2: reactivar (false->true) sincroniza AUTO con la Lista vigente ($200.000, 30% -> $140.000), aunque el % no cambió'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-B')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  42000::numeric,
  'L3: APR-B sigue AUTO en $42.000 (K5/K6) — la reactivación la recalcula igual (Lista $60.000 x 30%), sin cambios'
);

-- ---------------------------------------------------------------------------
-- M. QUANTITY nunca participa (ni aunque tuviera % y estuviera activa).
-- ---------------------------------------------------------------------------
insert into public.price_conditions (code, name, rule_type, min_units, discount_percent, priority, combinable, active)
values ('APR-QTY', 'Cantidad de prueba', 'QUANTITY', 5, 0.50, 60, false, true);
-- Dispara la cascada por el camino público (el helper nunca es invocable
-- directamente, ver sección N) cambiando la Lista de APR-A — toca a TODAS
-- las condiciones PAYMENT_METHOD elegibles, así que si el filtro de
-- rule_type fuera laxo (ej. <> 'BASE'), APR-QTY recibiría una fila acá.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-A'), 'amount', 210000
  ))
);
select is(
  (select count(*)::int from product_prices where price_condition_id = (select id from price_conditions where code = 'APR-QTY')),
  0,
  'M1: una condición QUANTITY activa con % configurado NUNCA recibe filas de product_prices vía el helper (rule_type exacto PAYMENT_METHOD, nunca <> BASE)'
);

-- ---------------------------------------------------------------------------
-- O. Borrado de precios (p_clears) — mismo mecanismo que clear_product_price,
-- nunca inserta una fila nueva, nunca $0.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_clears := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-B'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15')
  ))
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-B')
       and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  0,
  'O1: p_clears cierra la vigencia activa sin insertar ninguna fila nueva (nunca $0)'
);

-- ---------------------------------------------------------------------------
-- P. Borrar Precio de Lista (p_clears sobre BASE) cierra TODOS los AUTO
-- dependientes del producto — nunca puede quedar un AUTO vendible derivado
-- de una Lista inexistente. Preserva MANUAL. Recargar Lista los regenera
-- (vía la misma cascada del paso 3, sin lógica paralela).
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active)
values ('APR-CLR', 'Auto precio clear', 'product', 'Test', true, true, true, true);

insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-PMMANUAL', 'Medio manual de prueba', true, false, 997);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PCMANUAL', 'Condición manual de prueba', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-PMMANUAL'), 0.10, 51, false, true
);

select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-CLR'), 'amount', 200000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  140000::numeric,
  'P1: setup — APR-CLR Lista $200.000 genera AUTO (condición A, APR-PC15 30%) = $140.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA') and active = true),
  'AUTO',
  'P2: setup — APR-CLR también AUTO bajo condición B (APR-PCFUTURA)'
);

select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-CLR'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCMANUAL'),
    'amount', 55555
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCMANUAL') and active = true),
  'MANUAL',
  'P3: setup — APR-CLR MANUAL ($55.555) bajo condición C (APR-PCMANUAL)'
);

-- Borrar Precio de Lista.
select save_price_matrix_changes(
  p_clears := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-CLR'),
    'price_condition_id', (select id from price_conditions where rule_type = 'BASE')
  ))
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-CLR')
       and price_condition_id = (select id from price_conditions where rule_type = 'BASE') and active = true),
  0,
  'P4: Lista deja de estar vigente para APR-CLR'
);
select is(
  (select count(*)::int from product_prices
     where product_id = (select id from products where sku = 'APR-CLR') and pricing_mode = 'AUTO' and active = true),
  0,
  'P5: TODOS los AUTO de APR-CLR (condiciones A y B, cualquier condición) dejan de estar vigentes — ninguno vendible derivado de una Lista inexistente'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCMANUAL') and active = true),
  55555::numeric,
  'P6: el MANUAL de APR-CLR (condición C) permanece intacto'
);

-- Volver a cargar Precio Lista.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-CLR'), 'amount', 300000
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  210000::numeric,
  'P7: recargar Lista ($300.000) regenera AUTO para la condición A (PAYMENT_METHOD activa con %) = $210.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCFUTURA') and active = true),
  'AUTO',
  'P8: y también se regenera la condición B'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCMANUAL') and active = true),
  55555::numeric,
  'P9: y el MANUAL (condición C) sigue intacto después de recargar Lista'
);

-- ---------------------------------------------------------------------------
-- Q. Lista y % cambian juntos en el mismo guardado — el AUTO final tiene
-- que usar AMBOS valores nuevos, nunca uno nuevo y el otro anterior.
-- ---------------------------------------------------------------------------
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-CLR'), 'amount', 400000
  )),
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PC15'), 'discount_percent', 0.10
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-CLR')
     and price_condition_id = (select id from price_conditions where code = 'APR-PC15') and active = true),
  360000::numeric,
  'Q1: Lista $300.000->$400.000 y % 30%->10% en el MISMO guardado -> AUTO = $400.000 x 90% = $360.000 (ni $400.000x70%=$280.000 con el % viejo, ni $300.000x90%=$270.000 con la Lista vieja)'
);

-- ---------------------------------------------------------------------------
-- R. Migración 075 — matriz completa del bug reportado en producción: un
-- cambio GLOBAL de % tiene que pisar MANUAL (incluido el backfill de la
-- 074) y dejarlo AUTO; Lista sigue sin pisar MANUAL nunca. Fixtures propias
-- (APR-R1/R2/R3, APR-PCR) para no depender del estado acumulado de A-Q.
-- Casos 6 (create_price_condition con % -> AUTO: J1/J2), 7 (producto sin
-- Lista: E2/G3), 8 (condición inactiva: F1) y 9 (%->NULL cierra AUTO,
-- preserva MANUAL: K1-K3) ya están cubiertos arriba sin cambios de
-- comportamiento — no se duplican acá.
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, active) values
  ('APR-R1', 'Auto precio R1', 'product', 'Test', true, true, true, true),
  ('APR-R2', 'Auto precio R2', 'product', 'Test', true, true, true, true),
  ('APR-R3', 'Auto precio R3 (sin Lista)', 'product', 'Test', true, true, true, true);

insert into public.payment_methods (code, name, active, requires_billing, sort_order)
values ('APR-PMR', 'Medio de prueba R', true, false, 996);
insert into public.price_conditions (code, name, rule_type, payment_method_id, discount_percent, priority, combinable, active)
values (
  'APR-PCR', 'Condición de prueba R 10%', 'PAYMENT_METHOD',
  (select id from payment_methods where code = 'APR-PMR'), 0.10, 52, false, true
);

-- Setup: Lista R1=$100.000, R2=$200.000 -> genera AUTO para ambas bajo APR-PCR (10%).
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'APR-R1'), 'amount', 100000),
    jsonb_build_object('product_id', (select id from products where sku = 'APR-R2'), 'amount', 200000)
  )
);
-- R1 pasa a MANUAL (excepción puntual) para armar el escenario "A-MANUAL + B-AUTO" del caso 1.
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'),
    'amount', 77001
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'MANUAL',
  'R0: setup — R1 es MANUAL ($77.001), R2 sigue AUTO — escenario de partida del caso 1'
);

-- -----------------------------------------------------------------------
-- Caso 1: % global (10%->20%) sobre A-MANUAL + B-AUTO -> ambos AUTO con el nuevo valor.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'), 'discount_percent', 0.20
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  80000::numeric,
  'R1: caso 1 — R1 (MANUAL $77.001) pisado por el % global 10%->20% -> AUTO, Lista $100.000 x 20% = $80.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'AUTO',
  'R2: caso 1 — y queda AUTO, no MANUAL'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  160000::numeric,
  'R3: caso 1 — R2 (ya AUTO) también recalcula, Lista $200.000 x 20% = $160.000'
);

-- -----------------------------------------------------------------------
-- Caso 2: editar R1 individualmente después -> R1 MANUAL, R2 sigue AUTO.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'),
    'amount', 81234
  ))
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'MANUAL',
  'R4: caso 2 — editar R1 individualmente la vuelve MANUAL ($81.234)'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  160000::numeric,
  'R5: caso 2 — R2 no se toca por la edición individual de R1, sigue AUTO en $160.000'
);

-- -----------------------------------------------------------------------
-- Caso 3: cambiar SOLO Lista (ambos productos) -> la excepción MANUAL de R1
-- persiste, R2 (AUTO) recalcula.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(
    jsonb_build_object('product_id', (select id from products where sku = 'APR-R1'), 'amount', 150000),
    jsonb_build_object('product_id', (select id from products where sku = 'APR-R2'), 'amount', 250000)
  )
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  81234::numeric,
  'R6: caso 3 — cambiar solo Lista NO toca la excepción MANUAL de R1, sigue en $81.234'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'MANUAL',
  'R7: caso 3 — y sigue MANUAL'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  200000::numeric,
  'R8: caso 3 — R2 (AUTO) recalcula con la nueva Lista $250.000 x 20% = $200.000'
);

-- -----------------------------------------------------------------------
-- Caso 4: cambiar el % de nuevo (20%->25%) -> A y B quedan ambos AUTO.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'), 'discount_percent', 0.25
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  112500::numeric,
  'R9: caso 4 — R1 (MANUAL $81.234) pisado de nuevo, Lista $150.000 x 25% = $112.500'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'AUTO',
  'R10: caso 4 — R1 queda AUTO'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  187500::numeric,
  'R11: caso 4 — R2 también recalcula, Lista $250.000 x 25% = $187.500'
);

-- -----------------------------------------------------------------------
-- Caso 5: mismo comportamiento vía update_price_condition (no solo
-- save_price_matrix_changes/Matriz).
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'),
    'amount', 99111
  ))
);
select update_price_condition(
  p_price_condition_id := (select id from price_conditions where code = 'APR-PCR'),
  p_name := 'Condición de prueba R 10%',
  p_discount_percent := 0.30,
  p_requires_billing := false,
  p_priority := 52,
  p_active := true,
  p_location_codes := array[]::text[],
  p_available_web := true
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  105000::numeric,
  'R12: caso 5 — update_price_condition (25%->30%) también pisa el MANUAL de R1 ($99.111), Lista $150.000 x 30% = $105.000'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'AUTO',
  'R13: caso 5 — y queda AUTO'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  175000::numeric,
  'R14: caso 5 — R2 también recalcula vía update_price_condition, Lista $250.000 x 30% = $175.000'
);

-- -----------------------------------------------------------------------
-- Caso 10: % = 0 es un porcentaje válido (no "sin configurar") y recalcula
-- toda la columna a AUTO, incluido lo que fuera MANUAL.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'),
    'amount', 55555
  ))
);
select save_price_matrix_changes(
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'), 'discount_percent', 0
  ))
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  150000::numeric,
  'R15: caso 10 — % = 0 pisa el MANUAL de R1 ($55.555), Lista $150.000 x 0% = $150.000 (precio = Lista)'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'AUTO',
  'R16: caso 10 — y queda AUTO'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  250000::numeric,
  'R17: caso 10 — R2 también recalcula a Lista x 0% = Lista ($250.000)'
);

-- -----------------------------------------------------------------------
-- Caso 11 + integridad histórica: Lista y % cambian en el MISMO guardado
-- sobre una celda MANUAL -> usa la Lista nueva y el % nuevo, resultado AUTO.
-- La fila MANUAL vieja se cierra (nunca se pisa su amount/valid_from), la
-- nueva nace AUTO, y una venta histórica que referenciaba el precio MANUAL
-- viejo queda intacta.
-- -----------------------------------------------------------------------
select save_price_matrix_changes(
  p_manual_overrides := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'),
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'),
    'amount', 44444
  ))
);

-- Captura la fila MANUAL vigente ANTES del guardado combinado, para
-- verificar después que nunca se pisa (solo se cierra).
select id as r1_before_id, valid_from as r1_before_valid_from
from public.product_prices
where product_id = (select id from products where sku = 'APR-R1')
  and price_condition_id = (select id from price_conditions where code = 'APR-PCR')
  and active = true \gset

-- Venta histórica que referenció ese precio MANUAL ($44.444) — snapshot
-- inmutable (sale_items), tiene que seguir intacta después del recálculo.
-- reset role (mismo patrón que pricing_surcharge.test.sql): el insert directo
-- es solo fixture de este test, no pasa por ninguna RPC — RLS de sales/
-- sale_items bloquea el insert directo como authenticated.
reset role;
insert into public.sales (
  sale_number, sold_at, location_id, sales_channel_id, seller_id, payment_method_id,
  subtotal, discount_total, total, status
) values (
  'MJ-APR075-TEST-0001', now() - interval '3 days',
  (select id from stock_locations where code = 'DEP'),
  (select id from sales_channels limit 1),
  'aae00000-0000-0000-0000-000000000002',
  (select id from payment_methods where code = 'CASH'),
  150000.00, 105556.00, 44444.00, 'confirmed'
) returning id as r11_sale_id \gset

insert into public.sale_items (
  sale_id, product_id, quantity, list_unit_price, sale_unit_price,
  line_list_total, line_discount, line_total, applied_price_condition_id, commissionable
) values (
  :'r11_sale_id', (select id from products where sku = 'APR-R1'), 1, 150000.00, 44444.00,
  150000.00, 105556.00, 44444.00, (select id from price_conditions where code = 'APR-PCR'), true
) returning id as r11_sale_item_id \gset

set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

-- Lista y % cambian juntos, en el mismo guardado.
select save_price_matrix_changes(
  p_list_price_changes := jsonb_build_array(jsonb_build_object(
    'product_id', (select id from products where sku = 'APR-R1'), 'amount', 160000
  )),
  p_percent_changes := jsonb_build_array(jsonb_build_object(
    'price_condition_id', (select id from price_conditions where code = 'APR-PCR'), 'discount_percent', 0.40
  ))
);

select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  96000::numeric,
  'R18: caso 11 — Lista $150k->$160k y % 0%->40% en el MISMO guardado -> AUTO = $160.000 x 60% = $96.000 (nunca $90.000 con la Lista vieja, ni $160.000 con el % viejo, ni $150.000 con ambos viejos)'
);
select is(
  (select pricing_mode from product_prices where product_id = (select id from products where sku = 'APR-R1')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  'AUTO',
  'R19: caso 11 — y la excepción MANUAL de R1 queda convertida a AUTO'
);
select is(
  (select amount from product_prices where product_id = (select id from products where sku = 'APR-R2')
     and price_condition_id = (select id from price_conditions where code = 'APR-PCR') and active = true),
  150000::numeric,
  'R20: caso 11 — R2 también recalcula (su Lista no cambió), $250.000 x 60% = $150.000'
);

-- Integridad histórica — la fila vieja (MANUAL $44.444) NUNCA se pisa: se
-- cierra (valid_until/active), nunca se le muta el amount ni el valid_from.
select is(
  (select amount from public.product_prices where id = :'r1_before_id'),
  44444::numeric,
  'R21: integridad histórica — la fila MANUAL vieja de R1 conserva su amount original ($44.444), nunca se pisa con UPDATE destructivo'
);
select is(
  (select valid_from from public.product_prices where id = :'r1_before_id')::text,
  :'r1_before_valid_from',
  'R22: integridad histórica — y conserva también su valid_from original'
);
select is(
  (select active from public.product_prices where id = :'r1_before_id'),
  false,
  'R23: integridad histórica — la fila vieja queda cerrada (active=false)'
);
select ok(
  (select valid_until from public.product_prices where id = :'r1_before_id') is not null,
  'R24: integridad histórica — y con un valid_until asignado (cierre explícito, no un borrado)'
);

-- La fila nueva (AUTO $96.000) es una fila DISTINTA, nunca la misma reutilizada.
select id as r1_after_id, valid_from as r1_after_valid_from
from public.product_prices
where product_id = (select id from products where sku = 'APR-R1')
  and price_condition_id = (select id from price_conditions where code = 'APR-PCR')
  and active = true \gset

select isnt(
  :'r1_after_id'::uuid,
  :'r1_before_id'::uuid,
  'R25: integridad histórica — la fila AUTO nueva tiene un id distinto de la fila MANUAL vieja (nunca se reutiliza la misma fila)'
);
select ok(
  (select valid_until from public.product_prices where id = :'r1_before_id') <= :'r1_after_valid_from'::timestamptz,
  'R26: integridad histórica — la vigencia de la fila nueva empieza en o después del cierre de la vieja (sin solaparse)'
);

-- Y la venta histórica que referenciaba el precio MANUAL viejo sigue
-- exactamente igual — sale_items nunca se recalcula.
select is(
  (select sale_unit_price from public.sale_items where id = :'r11_sale_item_id'),
  44444::numeric,
  'R27: integridad histórica — la venta histórica (sale_items) que referenciaba el precio MANUAL viejo sigue intacta, nunca se recalculó'
);

-- ---------------------------------------------------------------------------
-- N. Helper interno — no ejecutable por PUBLIC/anon/authenticated directamente.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$select fn_recalculate_auto_prices(array[]::uuid[], array[]::uuid[], now())$$,
  'N1: fn_recalculate_auto_prices no es ejecutable directamente por un admin autenticado (sin grant explícito) — solo invocable desde otra función de este esquema'
);

set role authenticated;
select set_config('request.jwt.claim.sub', 'aae00000-0000-0000-0000-000000000001', false);

select * from finish();
rollback;
