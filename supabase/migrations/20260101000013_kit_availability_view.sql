-- =============================================================================
-- Maguirejuve · 13 · Vista de disponibilidad de kits (para /stock y /ventas/nueva)
-- =============================================================================
-- security_invoker = true: la vista respeta el RLS de inventory_balances del
-- usuario que consulta (no del dueño de la vista). Requiere Postgres >= 15.

create view public.kit_availability
with (security_invoker = true) as
select
  k.id as kit_product_id,
  k.sku as kit_sku,
  k.name as kit_name,
  sl.id as location_id,
  sl.code as location_code,
  public.fn_kit_buildable_qty(k.id, sl.id) as buildable_qty
from public.products k
cross join public.stock_locations sl
where k.product_type = 'kit'
   or exists (select 1 from public.kit_components kc where kc.kit_product_id = k.id);

comment on view public.kit_availability is
  'Cuántas unidades de cada kit se pueden armar hoy en cada sede, según el componente '
  'limitante. Nunca se persiste: se calcula al vuelo desde inventory_balances.';

-- ---------------------------------------------------------------------------
-- Vista de estado de stock (OK / bajo / sin stock) por sede+producto, para /stock.
-- ---------------------------------------------------------------------------
create view public.product_stock_status
with (security_invoker = true) as
select
  p.id as product_id,
  p.sku,
  p.name,
  p.category,
  sl.id as location_id,
  sl.code as location_code,
  coalesce(ib.quantity, 0) as quantity,
  coalesce(ib.min_stock_override, p.default_min_stock) as min_stock,
  case
    when coalesce(ib.quantity, 0) <= 0 then 'sin_stock'
    when coalesce(ib.quantity, 0) <= coalesce(ib.min_stock_override, p.default_min_stock) then 'bajo'
    else 'ok'
  end as status
from public.products p
cross join public.stock_locations sl
left join public.inventory_balances ib on ib.product_id = p.id and ib.location_id = sl.id
where p.track_stock = true;

comment on view public.product_stock_status is
  'Estado de stock (ok/bajo/sin_stock) por sede y producto trackeable. Solo para productos '
  'con track_stock = true; los kits usan kit_availability.';
