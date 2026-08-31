-- =============================================================================
-- Maguirejuve · 35 · Promociones: condición de precio base explícita (Bloque B)
-- =============================================================================
-- Pedido: cada promoción debe declarar sobre qué condición de precio (Lista,
-- Transferencia, Efectivo, 3 cuotas, etc.) se aplica su descuento — nunca un
-- string suelto ("Precio Lista"), siempre una relación real contra
-- price_conditions (igual criterio que product_prices.price_condition_id).
--
-- Backfill: las promociones que ya existan quedan ancladas a la condición
-- BASE (Precio Lista) — es el default más seguro y predecible, y coincide
-- con el ejemplo de la sección 7 del pedido. No hay ambigüedad posible
-- porque solo puede existir una fila BASE (price_conditions_one_base).
alter table public.promotions
  add column price_condition_id uuid references public.price_conditions (id) on delete restrict;

update public.promotions
set price_condition_id = (select id from public.price_conditions where rule_type = 'BASE' limit 1)
where price_condition_id is null;

alter table public.promotions
  alter column price_condition_id set not null;

create index promotions_price_condition_id_idx on public.promotions (price_condition_id);

comment on column public.promotions.price_condition_id is
  'Sobre qué condición de precio (price_conditions) se calcula el descuento de esta promoción '
  '— NUNCA sobre la condición que haya resuelto el medio de pago del carrito. Ver fn_apply_promotions.';
