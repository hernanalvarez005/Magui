-- =============================================================================
-- Maguirejuve · 23 · Medio de pago "Tarjeta de crédito — 1 pago" (bloque 2)
-- =============================================================================
-- No se hardcodea la regla en componentes: se resuelve como dato (precios =
-- precio de lista, igual que 3 cuotas) directamente en product_prices, así el
-- motor de precios existente lo maneja sin lógica especial. Un admin puede
-- después darle un precio propio desde /admin/precios como cualquier condición.

insert into public.payment_methods (code, name, sort_order) values
  ('CARD_1', 'Tarjeta de crédito — 1 pago', 4)
on conflict (code) do nothing;

-- Reordeno prioridades para insertar CARD_1 entre INSTALLMENTS_3 (5) y LIST (6),
-- sin tocar la precedencia relativa de las condiciones existentes.
update public.price_conditions set priority = 7 where code = 'LIST';

insert into public.price_conditions (code, name, rule_type, payment_method_id, min_units, discount_percent, priority, combinable)
values (
  'CARD_1', 'Tarjeta de crédito — 1 pago', 'PAYMENT_METHOD',
  (select id from public.payment_methods where code = 'CARD_1'),
  null, 0, 6, false
)
on conflict (code) do nothing;

-- Precio inicial = precio de lista para todo producto que ya tenga LIST
-- (dato, no código — editable después sin deploy).
insert into public.product_prices (product_id, price_condition_id, amount, valid_from)
select pp.product_id, (select id from public.price_conditions where code = 'CARD_1'), pp.amount, pp.valid_from
from public.product_prices pp
join public.price_conditions lc on lc.id = pp.price_condition_id and lc.code = 'LIST'
where pp.active = true
  and not exists (
    select 1 from public.product_prices existing
    where existing.product_id = pp.product_id
      and existing.price_condition_id = (select id from public.price_conditions where code = 'CARD_1')
  );
