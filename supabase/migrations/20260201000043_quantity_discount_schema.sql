-- =============================================================================
-- Maguirejuve · 46 · Condiciones QUANTITY -> Promociones — schema (paso 2/5)
-- =============================================================================
-- Reutiliza discount_percent (ya existe, mismo campo que KIT_PERCENT/
-- DUO_PERCENT — sección 27 del pedido: "no crear duplicados"). Lo único
-- nuevo es minimum_quantity: no hay ningún campo existente con esa
-- semántica (group_size es "cada cuántas unidades hay 1 gratis" en 3x2 —
-- conceptualmente distinto de "a partir de cuántas unidades se activa el
-- % de descuento", aunque ambos sean un entero).
alter table public.promotions
  add column minimum_quantity int;

comment on column public.promotions.minimum_quantity is
  'Exclusivo de QUANTITY_DISCOUNT: cantidad mínima de UNIDADES participantes (suma de '
  'cantidades entre los productos de la promoción, nunca cantidad de SKUs distintos) para que '
  'se active el % de descuento. Ej: minimum_quantity=2, discount_percent=0.20 -> '
  '"Llevando 2 productos, 20% OFF". Completamente editable por Administración, nunca hardcodeado.';

alter table public.promotions drop constraint promotions_discount_percent_shape;
alter table public.promotions
  add constraint promotions_discount_percent_shape check (
    (type = 'THREE_FOR_TWO' and discount_percent is null)
    or (type in ('DUO_PERCENT', 'KIT_PERCENT', 'QUANTITY_DISCOUNT') and discount_percent is not null
        and discount_percent > 0 and discount_percent <= 0.9)
  );

alter table public.promotions
  add constraint promotions_minimum_quantity_shape check (
    (type <> 'QUANTITY_DISCOUNT' and minimum_quantity is null)
    or (type = 'QUANTITY_DISCOUNT' and minimum_quantity is not null and minimum_quantity >= 1)
  );

comment on table public.promotions is
  'Promociones centralizadas (3x2 / duo% / kit% / cantidad%). Nunca se borra una fila: '
  'sale_items.applied_promotion_id de ventas históricas depende de que el id '
  'siga existiendo — se desactiva (active=false) en su lugar.';
