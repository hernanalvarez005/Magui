-- =============================================================================
-- Maguirejuve · 12 · Seed inicial (datos de producción reales, no ficticios)
-- =============================================================================
-- Idempotente: se puede correr más de una vez sin duplicar filas.
-- - Catálogo/config: `on conflict (code|sku) do nothing`.
-- - Precios: solo se insertan si el producto+condición nunca tuvo un precio cargado
--   (así una re-corrida nunca pisa un precio que un admin ya haya versionado).
-- - Stock inicial y el movimiento histórico: protegidos por un guard que corre una única vez.

-- ---------------------------------------------------------------------------
-- Sedes
-- ---------------------------------------------------------------------------
insert into public.stock_locations (code, short_code, name, type) values
  ('SED-37', '37', 'Clínica 37', 'branch'),
  ('SED-25', '25', 'Clínica 25', 'branch')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Canales de venta
-- ---------------------------------------------------------------------------
insert into public.sales_channels (code, name, sort_order) values
  ('BRANCH', 'Sucursal', 1),
  ('WEB', 'Web', 2)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Medios de pago
-- ---------------------------------------------------------------------------
insert into public.payment_methods (code, name, sort_order) values
  ('CASH', 'Efectivo', 1),
  ('TRANSFER', 'Transferencia', 2),
  ('CARD_3', '3 cuotas sin interés', 3)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Condiciones de precio (precedencia inicial vía "priority", editable sin deploy)
-- ---------------------------------------------------------------------------
insert into public.price_conditions (code, name, rule_type, payment_method_id, min_units, discount_percent, priority, combinable)
values
  ('LIST', 'Precio lista', 'BASE', null, null, null, 6, false),
  ('TRANSFER', 'Transferencia', 'PAYMENT_METHOD', (select id from public.payment_methods where code = 'TRANSFER'), null, 0.10, 4, false),
  ('CASH', 'Efectivo', 'PAYMENT_METHOD', (select id from public.payment_methods where code = 'CASH'), null, 0.15, 3, false),
  ('INSTALLMENTS_3', '3 cuotas sin interés', 'PAYMENT_METHOD', (select id from public.payment_methods where code = 'CARD_3'), null, 0, 5, false),
  ('QTY_2', '2 productos', 'QUANTITY', null, 2, 0.20, 2, false),
  ('QTY_3_PLUS', '3 productos o más', 'QUANTITY', null, 3, 0.25, 1, false)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Productos
-- ---------------------------------------------------------------------------
insert into public.products (sku, name, product_type, category, track_stock, commissionable, promo_eligible, default_min_stock, active, notes) values
  ('PROD-VITC', 'Sérum Vitamina C', 'product', 'Sérum', true, true, true, 10, true, null),
  ('PROD-NIAC', 'Sérum de Niacinamida', 'product', 'Sérum', true, true, true, 10, true, null),
  ('PROD-OJOS', 'Contorno de ojos', 'product', 'Crema', true, true, true, 10, true, null),
  ('PROD-ANTI', 'Crema antiage', 'product', 'Crema', true, true, true, 10, true, null),
  ('PROD-SENS', 'Crema pieles sensibles', 'product', 'Crema', true, true, true, 10, true, null),
  ('PROD-ESP', 'Espuma de limpieza', 'product', 'Limpieza', true, true, true, 10, true, null),
  ('ACC-NEC', 'Neceser Magui', 'accessory', 'Accesorio', true, true, true, 5, true,
    'Lista de precios incompleta en la base original: solo tiene Transferencia y Efectivo.'),
  ('ACC-PADS1', 'Pads Magui Premium', 'accessory', 'Accesorio', true, true, true, 5, true, null),
  ('ACC-PADS2', 'Pads Magui Premium x 2', 'accessory', 'Accesorio', false, true, true, 0, true,
    'Combo: descuenta 2 × ACC-PADS1 (ver kit_components).'),
  ('KIT-VN', 'Kit Vitamina C + Niacinamida', 'kit', 'Kit', false, true, true, 0, true, null),
  ('KIT-ECN', 'Kit Espuma + Vitamina C + Crema Antiedad + Niacinamida', 'kit', 'Kit', false, true, true, 0, true, null),
  ('KIT-EACP', 'Kit Espuma + Antiedad + Crema Pieles Sensibles (revisar)', 'kit', 'Kit', false, true, true, 0, false,
    'INACTIVO: composición inconsistente en la base original. Revisar y confirmar antes de activar.'),
  ('KIT-EVSPC', 'Kit Espuma + Vitamina C + Crema Pieles Sensibles + Contorno', 'kit', 'Kit', false, true, true, 0, true, null),
  ('KIT-ESOC', 'Kit Espuma + Crema Pieles Sensibles + Contorno de ojos', 'kit', 'Kit', false, true, true, 0, true, null)
on conflict (sku) do nothing;

-- ---------------------------------------------------------------------------
-- Composición de kits/combos
-- ---------------------------------------------------------------------------
insert into public.kit_components (kit_product_id, component_product_id, quantity)
select k.id, c.id, v.qty
from (values
  ('ACC-PADS2', 'ACC-PADS1', 2),
  ('KIT-VN', 'PROD-VITC', 1),
  ('KIT-VN', 'PROD-NIAC', 1),
  ('KIT-ECN', 'PROD-ESP', 1),
  ('KIT-ECN', 'PROD-VITC', 1),
  ('KIT-ECN', 'PROD-ANTI', 1),
  ('KIT-ECN', 'PROD-NIAC', 1),
  ('KIT-EVSPC', 'PROD-ESP', 1),
  ('KIT-EVSPC', 'PROD-VITC', 1),
  ('KIT-EVSPC', 'PROD-SENS', 1),
  ('KIT-EVSPC', 'PROD-OJOS', 1),
  ('KIT-ESOC', 'PROD-ESP', 1),
  ('KIT-ESOC', 'PROD-SENS', 1),
  ('KIT-ESOC', 'PROD-OJOS', 1)
) as v(kit_sku, component_sku, qty)
join public.products k on k.sku = v.kit_sku
join public.products c on c.sku = v.component_sku
on conflict (kit_product_id, component_product_id) do nothing;

-- ---------------------------------------------------------------------------
-- Lista de precios inicial (sección 10 del prompt maestro).
-- null/0 = condición NO DISPONIBLE para ese producto (nunca se interpreta como $0).
-- ---------------------------------------------------------------------------
with raw (sku, list, transfer, cash, installments3, qty2, qty3plus) as (
  values
    ('PROD-VITC', 45300.00, 40770.00, 38500.00, 45300.00, 36240.00, 33975.00),
    ('PROD-NIAC', 42500.00, 38250.00, 36100.00, 42500.00, 34000.00, 31875.00),
    ('PROD-OJOS', 41000.00, 36900.00, 34850.00, 41000.00, 32800.00, 30750.00),
    ('PROD-ANTI', 45000.00, 40500.00, 38250.00, 45000.00, 36000.00, 33750.00),
    ('PROD-SENS', 43000.00, 38700.00, 36500.00, 43000.00, 34400.00, 32250.00),
    ('PROD-ESP', 36000.00, 32400.00, 30600.00, 36000.00, 28800.00, 27000.00),
    ('ACC-NEC', null, 27450.00, 25900.00, null, null, null),
    ('ACC-PADS1', 8000.00, 7200.00, 6800.00, 8000.00, 6400.00, 6000.00),
    ('ACC-PADS2', 16000.00, 14400.00, 13600.00, 16000.00, 12800.00, 12000.00),
    ('KIT-VN', 83410.00, 75069.00, 71000.00, 83410.00, 66728.00, 62557.50),
    ('KIT-ECN', 198300.00, 178470.00, 170000.00, 198300.00, 158640.00, 148725.00),
    ('KIT-EACP', 159400.00, 143460.00, 135500.00, 159400.00, 127520.00, 119550.00),
    ('KIT-EVSPC', 156100.00, 140490.00, 133000.00, 156100.00, 124880.00, 117075.00),
    ('KIT-ESOC', 113050.00, 101745.00, 96000.00, 113050.00, 90440.00, 84787.50)
),
unpivoted as (
  select sku, 'LIST' as condition_code, list as amount from raw
  union all select sku, 'TRANSFER', transfer from raw
  union all select sku, 'CASH', cash from raw
  union all select sku, 'INSTALLMENTS_3', installments3 from raw
  union all select sku, 'QTY_2', qty2 from raw
  union all select sku, 'QTY_3_PLUS', qty3plus from raw
)
insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
select p.id, pc.id, u.amount, timestamptz '2026-08-01 00:00:00-03'
from unpivoted u
join public.products p on p.sku = u.sku
join public.price_conditions pc on pc.code = u.condition_code
where u.amount is not null
  and u.amount > 0
  and not exists (
    select 1 from public.product_prices existing
    where existing.product_id = p.id and existing.price_condition_id = pc.id
  );

-- ---------------------------------------------------------------------------
-- Doctoras (comisión inicial 20%)
-- ---------------------------------------------------------------------------
insert into public.doctors (code, full_name, commission_percent) values
  ('DRA-BERNARDO', 'Dra. Bernardo', 0.20),
  ('DRA-PEREZ', 'Dra. Pérez', 0.20),
  ('DRA-BAIGORRIA', 'Dra. Baigorria', 0.20),
  ('DRA-AMOREO', 'Dra. Amoreo', 0.20),
  ('DRA-MARCIA', 'Dra. Marcia', 0.20),
  ('DRA-GIORDANO', 'Dra. Giordano', 0.20),
  ('DRA-DIMOTTA', 'Dra. Dimotta', 0.20)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Stock inicial + movimiento histórico posterior (sección 17).
-- Guard: corre una única vez (busca la referencia de esta migración).
-- ---------------------------------------------------------------------------
do $$
declare
  v_already_seeded boolean;
  v_loc_37 uuid;
  v_loc_25 uuid;
  v_row record;
begin
  select exists (
    select 1 from public.stock_movements where reference = 'SEED-INITIAL-2026'
  ) into v_already_seeded;

  if v_already_seeded then
    return;
  end if;

  select id into v_loc_37 from public.stock_locations where code = 'SED-37';
  select id into v_loc_25 from public.stock_locations where code = 'SED-25';

  for v_row in
    select * from (values
      ('PROD-VITC', 17), ('PROD-NIAC', 47), ('PROD-OJOS', 55),
      ('PROD-SENS', 43), ('PROD-ANTI', 48), ('PROD-ESP', 11)
    ) as t(sku, qty)
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_loc_37,
      p_product_id => (select id from public.products where sku = v_row.sku),
      p_movement_type => 'INITIAL',
      p_quantity_delta => v_row.qty::numeric,
      p_reference => 'SEED-INITIAL-2026',
      p_notes => 'Migración de stock inicial desde Excel/AppSheet — Sede 37.',
      p_allow_negative => true
    );
  end loop;

  for v_row in
    select * from (values
      ('PROD-VITC', 15), ('PROD-NIAC', 23), ('PROD-OJOS', 12),
      ('PROD-ANTI', 17), ('PROD-SENS', 20), ('PROD-ESP', 14)
    ) as t(sku, qty)
  loop
    perform public.fn_apply_stock_movement(
      p_location_id => v_loc_25,
      p_product_id => (select id from public.products where sku = v_row.sku),
      p_movement_type => 'INITIAL',
      p_quantity_delta => v_row.qty::numeric,
      p_reference => 'SEED-INITIAL-2026',
      p_notes => 'Migración de stock inicial desde Excel/AppSheet — Sede 25.',
      p_allow_negative => true
    );
  end loop;

  -- Movimiento posterior real registrado en la base original: Sede 25, Vitamina C, +20,
  -- 25/08/2026 22:32 (America/Argentina/Buenos_Aires). Stock resultante 25/VITC = 15 + 20 = 35.
  perform public.fn_apply_stock_movement(
    p_location_id => v_loc_25,
    p_product_id => (select id from public.products where sku = 'PROD-VITC'),
    p_movement_type => 'PURCHASE',
    p_quantity_delta => 20,
    p_reference => 'MIGRACION-APPSHEET-2026-08-25',
    p_notes => 'Ingreso registrado en la base histórica (AppSheet) el 25/08/2026 22:32.',
    p_allow_negative => true
  );

  update public.stock_movements
  set occurred_at = timestamptz '2026-08-25 22:32:00-03'
  where reference = 'MIGRACION-APPSHEET-2026-08-25';
end;
$$;
