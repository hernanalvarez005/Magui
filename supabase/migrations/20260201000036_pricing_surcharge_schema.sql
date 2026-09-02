-- =============================================================================
-- Maguirejuve · Recargo comercial: una condición de pago más cara que Lista
-- es una condición comercial VÁLIDA, no una excepción — schema (paso 1/2)
-- =============================================================================
-- PASO 0 (auditoría entregada al usuario, aprobada — Opción B): hoy
-- line_discount/discount_total se calculan como resta simple (lista - venta)
-- sin piso en 0, y sales_total_consistency (total = subtotal - discount_total)
-- solo puede restar — no hay forma de representar un recargo. Con eso, CUALQUIER
-- venta bajo una condición más cara que Lista (ej. 3 cuotas $33.000 contra
-- Lista $30.000) rompe line_discount >= 0 / discount_total >= 0 en el INSERT.
-- No es cosmético: hoy esa venta directamente no se puede crear.
--
-- Semántica nueva, explícita y simétrica:
--   line_discount   = GREATEST((list_unit_price - sale_unit_price) * quantity, 0)
--   line_surcharge  = GREATEST((sale_unit_price - list_unit_price) * quantity, 0)
--   discount_total  = SUM(line_discount)   -- sumado desde las líneas, NUNCA subtotal-total
--   surcharge_total = SUM(line_surcharge)  -- ídem
--   total           = SUM(line_total)      -- sin cambios, ya era así
--   total = subtotal - discount_total + surcharge_total
--
-- Ventas históricas: imposible que ya exista una fila con sale_unit_price >
-- list_unit_price (el INSERT fallaba). Se verifica explícitamente abajo antes
-- de tocar nada, y las columnas nuevas se agregan not null default 0 — todas
-- las filas existentes quedan en 0/0, sin ningún UPDATE aparte.

do $$
declare
  v_bad_count int;
begin
  select count(*) into v_bad_count
  from public.sale_items
  where sale_unit_price > list_unit_price;

  if v_bad_count > 0 then
    raise exception
      'Se encontraron % sale_items con sale_unit_price > list_unit_price antes de agregar el recargo — revisar antes de continuar (no debería ser posible con las constraints actuales).',
      v_bad_count;
  end if;
end
$$;

alter table public.sale_items
  add column line_surcharge numeric(14, 2) not null default 0 check (line_surcharge >= 0);

comment on column public.sale_items.line_surcharge is
  'Cuánto de esta línea está por ENCIMA del precio de Lista (recargo real de la condición '
  'aplicada, ej. cuotas más caras que Lista) — GREATEST((sale_unit_price - list_unit_price) * '
  'quantity, 0). Complementario de line_discount: nunca los dos > 0 a la vez en la misma línea.';

alter table public.sale_items
  add constraint sale_items_discount_surcharge_consistency
  check (line_total = line_list_total - line_discount + line_surcharge);

alter table public.sales
  add column surcharge_total numeric(14, 2) not null default 0 check (surcharge_total >= 0);

comment on column public.sales.surcharge_total is
  'Suma de line_surcharge de todas las líneas — SIEMPRE sumado desde las líneas, nunca derivado '
  'como total-subtotal. Representa cuánto de esta venta está por encima del precio de Lista '
  '(ej. una condición de cuotas más cara que Lista es una condición comercial válida, no un error).';

alter table public.sales drop constraint sales_total_consistency;
alter table public.sales
  add constraint sales_total_consistency
  check (total = subtotal - discount_total + surcharge_total);
