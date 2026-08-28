-- =============================================================================
-- Maguirejuve · 27 · sale_items: snapshot de promoción aplicada (bloque 7)
-- =============================================================================
-- Igual que applied_price_condition_id: se guarda la foto de qué promoción
-- (si hubo) se aplicó a cada línea. Editar o desactivar una promoción más
-- adelante NUNCA cambia esto — es historia, no una referencia "viva".
alter table public.sale_items
  add column applied_promotion_id uuid references public.promotions (id),
  add column promotion_discount numeric(14, 2) not null default 0 check (promotion_discount >= 0);

comment on column public.sale_items.applied_promotion_id is
  'Snapshot: qué promoción generó esta línea (o la unidad gratis de un 3x2). '
  'Null si la línea no tuvo promoción. Nunca se recalcula retroactivamente.';
comment on column public.sale_items.promotion_discount is
  'Cuánto de line_discount vino específicamente de la promoción (además del '
  'descuento ya resuelto por price_conditions). Para reportes de impacto de promos.';

-- El único tipo de promoción que puede dejar sale_unit_price en $0 es
-- THREE_FOR_TWO (la unidad más barata sale gratis). DUO_PERCENT/KIT_PERCENT
-- tienen un tope de 90% (ver promotions_discount_percent_shape), así que
-- nunca llegan a $0. Se extiende el guardia de "venta sin costo" del bloque 2
-- para permitir también este caso legítimo.
create or replace function public.fn_check_sale_item_zero_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sale_unit_price = 0
     and not exists (select 1 from public.sales s where s.id = new.sale_id and s.is_free_sale = true)
     and not exists (
       select 1 from public.promotions p
       where p.id = new.applied_promotion_id and p.type = 'THREE_FOR_TWO'
     )
  then
    raise exception
      'No se puede registrar un precio $0 fuera de una venta sin costo o una unidad gratis de promoción 3x2.';
  end if;
  return new;
end;
$$;
