-- =============================================================================
-- Maguirejuve · 42 · Orden visual de productos en Nueva Venta (Bloque D)
-- =============================================================================
-- Cambio EXCLUSIVAMENTE visual — ninguna lógica de precios, stock, kits,
-- promociones, IDs ni componentes se toca acá. Solo afecta el ORDER BY de la
-- query de /ventas/nueva; ninguna otra pantalla (Administración → Productos,
-- reportes, Lista de Precios) cambia su orden.
--
-- Arquitectura: display_order global (numeric-int simple, con huecos de 10
-- entre cada valor para poder insertar productos nuevos en el medio más
-- adelante desde Administración sin renumerar todo) en vez de
-- "product_type/category + display_order" — alcanza porque el orden pedido
-- es una única secuencia plana (productos, después kits, después
-- accesorios), no requiere agrupar por tipo en la query.
--
-- Regla para productos nuevos (sin display_order explícito): quedan al
-- final, ordenados alfabéticamente entre sí — el default de la columna
-- (9999) es mayor a cualquier valor asignado acá abajo, y la query de
-- Nueva Venta siempre hace ORDER BY display_order, name.
alter table public.products
  add column display_order integer not null default 9999;

comment on column public.products.display_order is
  'Orden visual en la grilla de Nueva Venta ÚNICAMENTE — ninguna otra pantalla lo usa. '
  'Huecos de a 10 para poder insertar productos nuevos en el medio sin renumerar. '
  'Un producto sin valor explícito (default 9999) queda al final, alfabético entre sí.';

create index products_display_order_idx on public.products (display_order, name);

-- ---------------------------------------------------------------------------
-- Verificación previa: los 19 SKU de abajo tienen que existir tal cual en
-- esta base — si alguno no aparece (typo, producto dado de baja, etc.), la
-- migration se corta ACÁ, antes de tocar ninguna fila, en vez de aplicar un
-- orden parcial silenciosamente incorrecto.
-- ---------------------------------------------------------------------------
do $$
declare
  v_found int;
begin
  select count(*) into v_found from public.products where sku in (
    '0016', '0006', 'PROD-VITC', '0002', '0014', '0015', '0004', '0005', '0017', '0003',
    '0008', '0018', '0009', '0010', '0011', '0012', 'NECE', 'ACC-PADS1', 'ACC-PADS2'
  );
  if v_found <> 19 then
    raise exception
      'Orden inicial de productos: se esperaban 19 SKU y se encontraron %. Revisar antes de aplicar.',
      v_found;
  end if;
end;
$$;

-- Orden pedido (secciones 25/26/27 del pedido), mapeado por SKU real —
-- verificado contra el catálogo vigente de la base, no adivinado por nombre.
update public.products p
set display_order = v.display_order
from (values
  -- Productos individuales
  ('0016', 10),        -- Agua Termal
  ('0006', 20),         -- Espuma de limpieza
  ('PROD-VITC', 30),    -- Sérum Vitamina C
  ('0002', 40),         -- Sérum de Niacinamida
  ('0014', 50),         -- Serum Exfoliante
  ('0015', 60),         -- Serum Acido Hialuronico
  ('0004', 70),         -- Crema antiage
  ('0005', 80),         -- Crema pieles sensibles
  ('0017', 90),         -- Cremas pieles grasas
  ('0003', 100),        -- Contorno de ojos
  -- Kits
  ('0008', 110),        -- DUO LUMINOSIDAD Y EQUILIBRIO
  ('0018', 120),        -- DUO CONTROL Y RENOVACION - PIELES GRASAS
  ('0009', 130),        -- KIT ANTIAGE COMPLETO
  ('0010', 140),        -- KIT ANTIAGE ESENCIAL
  ('0011', 150),        -- KIT PIEL SENSIBLE COMPLETA
  ('0012', 160),        -- KIT PIEL SENSIBLES ESENCIAL
  -- Accesorios
  ('NECE', 170),        -- Neceser Magui
  ('ACC-PADS1', 180),   -- Pads Magui Premium
  ('ACC-PADS2', 190)    -- Pads Magui Premium x 2
) as v(sku, display_order)
where p.sku = v.sku;
