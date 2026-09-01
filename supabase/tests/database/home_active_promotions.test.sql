-- pgTAP: Ajuste — promociones vigentes en la Home del vendedor. La Home y
-- /precios usan literalmente la misma consulta de vigencia
-- (activePromotionsQuery(), lib/promotions/active-promotions.ts) — este
-- archivo prueba esa consulta a nivel base, incluyendo el caso que
-- ninguno de los tests anteriores cubría todavía: una promoción FUTURA
-- (valid_from en el futuro) no debe aparecer. El resto de casos ya
-- covered por vigencia/participantes/permisos en
-- precios_consulta.test.sql se reejercitan acá de forma mínima porque la
-- Home es una pantalla nueva con su propio PASO 0 de tests pedido, sin
-- duplicar la profundidad ya alcanzada allá.
-- Correr con: supabase test db  (requiere Supabase CLI + Docker)
begin;
select plan(8);

insert into auth.users (id, email) values
  ('f7000000-0000-0000-0000-000000000001', 'admin.home@test.maguirejuve.com'),
  ('f7000000-0000-0000-0000-000000000002', 'seller.home@test.maguirejuve.com');

update public.profiles set role = 'admin', active = true where id = 'f7000000-0000-0000-0000-000000000001';
update public.profiles set role = 'seller', active = true where id = 'f7000000-0000-0000-0000-000000000002';
insert into public.profile_locations (profile_id, location_id)
  select 'f7000000-0000-0000-0000-000000000001', id from public.stock_locations;
insert into public.profile_locations (profile_id, location_id)
  select 'f7000000-0000-0000-0000-000000000002', id from public.stock_locations where code = 'SED-25';

set role authenticated;
select set_config('request.jwt.claim.sub', 'f7000000-0000-0000-0000-000000000001', false);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-HOME-ACTIVE', 'Kit% vigente (Home)', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.25, 70, false, true, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-HOME-ACTIVE'),
  array[(select id from products where sku = 'PROD-ESP')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-HOME-FUTURE', 'Kit% futura (Home)', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.30, 71, false, true, now() + interval '7 days', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-HOME-FUTURE'),
  array[(select id from products where sku = 'PROD-ANTI')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-HOME-EXPIRED', 'Kit% vencida (Home)', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.35, 72, false, true, now() - interval '30 days', now() - interval '1 day');
select set_promotion_products(
  (select id from promotions where code = 'TEST-HOME-EXPIRED'),
  array[(select id from products where sku = 'PROD-SENS')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-HOME-INACTIVE', 'Kit% desactivada (Home)', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.40, 73, false, false, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-HOME-INACTIVE'),
  array[(select id from products where sku = 'PROD-OJOS')]
);

insert into public.promotions (code, name, type, price_condition_id, discount_percent, priority, stackable, active, valid_from, valid_until)
values ('TEST-HOME-MULTI', 'Kit% varios kits (Home)', 'KIT_PERCENT', (select id from price_conditions where rule_type = 'BASE'), 0.20, 74, false, true, now() - interval '1 day', null);
select set_promotion_products(
  (select id from promotions where code = 'TEST-HOME-MULTI'),
  array[(select id from products where sku = 'KIT-VN'), (select id from products where sku = 'KIT-ECN')]
);

-- ---------------------------------------------------------------------------
-- Home 1: una promoción activa y vigente aparece (mismo WHERE que
-- activePromotionsQuery()).
-- ---------------------------------------------------------------------------
select ok(
  exists(
    select 1 from promotions
    where code = 'TEST-HOME-ACTIVE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Home 1: una promoción vigente pasa el filtro que usa la Home'
);

-- ---------------------------------------------------------------------------
-- Home 2: una promoción FUTURA (valid_from todavía no llegó) NO aparece —
-- caso nuevo, no cubierto por los tests de /precios.
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-HOME-FUTURE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Home 2: una promoción futura (valid_from adelante) no pasa el filtro'
);

-- ---------------------------------------------------------------------------
-- Home 3: una promoción vencida no aparece.
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-HOME-EXPIRED' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Home 3: una promoción vencida no pasa el filtro'
);

-- ---------------------------------------------------------------------------
-- Home 4: una promoción desactivada no aparece.
-- ---------------------------------------------------------------------------
select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-HOME-INACTIVE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Home 4: una promoción desactivada no pasa el filtro'
);

-- ---------------------------------------------------------------------------
-- Home 5: con varias promociones vigentes a la vez, todas pasan el filtro
-- (ACTIVE + MULTI, ambas vigentes; FUTURE/EXPIRED/INACTIVE quedan afuera).
-- ---------------------------------------------------------------------------
select is(
  (
    select count(*)::int from promotions
    where code in ('TEST-HOME-ACTIVE', 'TEST-HOME-FUTURE', 'TEST-HOME-EXPIRED', 'TEST-HOME-INACTIVE', 'TEST-HOME-MULTI')
      and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  2,
  'Home 5: de 5 promociones de fixture, exactamente las 2 vigentes pasan el filtro'
);

-- ---------------------------------------------------------------------------
-- Home 6: productos participantes correctos para una promoción con varios
-- kits asociados (mismo join que resolvePromotionParticipants()).
-- ---------------------------------------------------------------------------
select is(
  (
    select array_agg(p.sku order by p.sku)
    from promotion_products pp
    join products p on p.id = pp.product_id
    where pp.promotion_id = (select id from promotions where code = 'TEST-HOME-MULTI')
  ),
  array['KIT-ECN', 'KIT-VN'],
  'Home 6: los participantes resueltos son exactamente los 2 kits asociados, ninguno de más ni de menos'
);

-- ---------------------------------------------------------------------------
-- Home 7: la vendedora no puede modificar una promoción mostrada en Home
-- (mismo criterio que ya se prueba para /precios — RLS deja el UPDATE en 0
-- filas).
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f7000000-0000-0000-0000-000000000002', false);

update public.promotions set discount_percent = 0.99 where code = 'TEST-HOME-ACTIVE';

select is(
  (select discount_percent from promotions where code = 'TEST-HOME-ACTIVE'),
  0.25,
  'Home 7: la vendedora no puede modificar una promoción — el UPDATE queda en 0 filas por RLS'
);

-- ---------------------------------------------------------------------------
-- Home 8: un cambio administrativo (desactivar/reactivar) se refleja de
-- inmediato en el mismo filtro — no hay caché propia de Home que invalidar.
-- ---------------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', 'f7000000-0000-0000-0000-000000000001', false);

update public.promotions set active = false where code = 'TEST-HOME-ACTIVE';

select ok(
  not exists(
    select 1 from promotions
    where code = 'TEST-HOME-ACTIVE' and active = true and valid_from <= now()
      and (valid_until is null or valid_until > now())
  ),
  'Home 8: al desactivarla, deja de pasar el filtro en la siguiente consulta — sin caché que invalidar'
);

select * from finish();
rollback;
