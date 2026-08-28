-- =============================================================================
-- Maguirejuve · 20 · Venta sin costo (mejoras — bloque 2)
-- =============================================================================
-- Regalo / muestra / canje / cortesía / otro. NO se resuelve con un precio $0
-- manual: es una modalidad explícita que el motor de precios reconoce.

create type public.free_sale_reason as enum ('GIFT', 'SAMPLE', 'EXCHANGE', 'COURTESY', 'OTHER');

alter table public.sales
  add column is_free_sale boolean not null default false,
  add column free_sale_reason public.free_sale_reason,
  add column free_sale_notes text;

alter table public.sales
  add constraint sales_free_sale_requires_reason
    check (not is_free_sale or free_sale_reason is not null);

alter table public.sales
  add constraint sales_non_free_sale_no_reason
    check (is_free_sale or (free_sale_reason is null and free_sale_notes is null));

-- Nunca debe generarse comisión sobre una entrega sin costo (salvo que en el
-- futuro se configure explícitamente otra regla — hoy no existe esa regla).
alter table public.sales
  add constraint sales_free_sale_no_commission
    check (not is_free_sale or commission_total = 0);

comment on column public.sales.is_free_sale is
  'Entrega sin costo (regalo/muestra/canje/cortesía/otro). Descuenta stock igual que una '
  'venta normal, pero total = 0 y no genera comisión. Se distingue de la facturación real '
  'en los reportes (docs/pricing.md).';
