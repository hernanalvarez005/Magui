-- pgTAP: Cambio 1 — email opcional en Nueva Venta (customer-picker-dialog).
-- Reuso total de customers.email (citext, ya existente desde el MVP) y de
-- la deduplicación exclusiva por DNI (customers_dni_unique_idx) — sin
-- migración nueva. Casos:
--   1) Cliente con email se persiste y se recupera correctamente.
--   2) Cliente existente (con email) se recupera por DNI incluyendo su email.
--   3) Dos clientes pueden compartir el mismo email sin conflicto — el
--      email NUNCA participa de la deduplicación (solo el DNI).
--   4) Cliente sin email persiste email = null (no string vacío) — el mismo
--      patrón que ya usa dni/whatsapp.
-- Correr con: scripts/rebuild_test_db.sh + pg_prove localmente.
begin;
select plan(4);

insert into auth.users (id, email) values
  ('ce000000-0000-0000-0000-000000000001', 'admin.customer-email@test.maguirejuve.com');
update public.profiles set role = 'admin', active = true where id = 'ce000000-0000-0000-0000-000000000001';

set role authenticated;
select set_config('request.jwt.claim.sub', 'ce000000-0000-0000-0000-000000000001', false);

-- ===========================================================================
-- Caso 1: cliente con email se persiste y se recupera correctamente.
-- ===========================================================================
insert into public.customers (full_name, dni, email) values ('Clienta Email Uno', '30111222', 'clienta.uno@example.com');

select is(
  (select email from customers where dni = '30111222'),
  'clienta.uno@example.com'::citext,
  'Caso 1: el email se persiste y se recupera tal cual se ingresó'
);

-- ===========================================================================
-- Caso 2: cliente existente (búsqueda por DNI) trae su email junto al resto
-- de sus datos, tal como lo hace customer-picker-dialog al preseleccionar.
-- ===========================================================================
select is(
  (select (full_name, dni, email) from customers where dni = '30111222'),
  ('Clienta Email Uno'::text, '30111222'::text, 'clienta.uno@example.com'::citext),
  'Caso 2: cliente existente con email se recupera completo por DNI'
);

-- ===========================================================================
-- Caso 3: el email NUNCA participa de la deduplicación — dos clientes con
-- DNIs distintos pueden compartir exactamente el mismo email sin conflicto.
-- ===========================================================================
select lives_ok(
  $$insert into public.customers (full_name, dni, email) values ('Clienta Email Dos', '30111223', 'clienta.uno@example.com')$$,
  'Caso 3: dos clientes pueden compartir el mismo email — la deduplicación sigue siendo exclusiva por DNI'
);

-- ===========================================================================
-- Caso 4: cliente sin email persiste email = null (no ''), mismo patrón que
-- ya usan dni/whatsapp — customer-picker-dialog envía `|| null` cuando el
-- campo queda vacío.
-- ===========================================================================
insert into public.customers (full_name, dni, email) values ('Clienta Sin Email', '30111224', null);

select is(
  (select email from customers where dni = '30111224'),
  null::citext,
  'Caso 4: cliente sin email persiste NULL, nunca string vacío'
);

select * from finish();
rollback;
