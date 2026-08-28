-- =============================================================================
-- Maguirejuve · 22 · Permitir $0 en sale_items SOLO para ventas sin costo
-- =============================================================================
-- Las ventas normales siguen sin poder tener $0 (fn_pricing_quote exige
-- amount > 0 en product_prices para cualquier condición real). Estos checks
-- a nivel de columna eran demasiado estrictos para admitir el nuevo camino
-- explícito de "venta sin costo", así que se relajan a >= 0 y se agrega un
-- constraint cruzado que ata sale_unit_price = 0 exclusivamente a ventas
-- marcadas is_free_sale = true (vía la FK a sales).

alter table public.sale_items drop constraint sale_items_sale_unit_price_check;
alter table public.sale_items add constraint sale_items_sale_unit_price_check check (sale_unit_price >= 0);

alter table public.sale_items drop constraint sale_items_list_unit_price_check;
alter table public.sale_items add constraint sale_items_list_unit_price_check check (list_unit_price >= 0);

-- Refuerzo: un sale_item con precio $0 solo puede existir si la venta a la
-- que pertenece está marcada explícitamente como sin costo.
create or replace function public.fn_check_sale_item_zero_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.sale_unit_price = 0 and not exists (
    select 1 from public.sales s where s.id = new.sale_id and s.is_free_sale = true
  ) then
    raise exception 'No se puede registrar un precio $0 fuera de una venta sin costo.';
  end if;
  return new;
end;
$$;

create trigger trg_sale_items_no_arbitrary_zero
  before insert on public.sale_items
  for each row execute function public.fn_check_sale_item_zero_price();
