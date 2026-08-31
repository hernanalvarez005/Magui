-- =============================================================================
-- Maguirejuve · 40 · Facturación pendiente + cuenta de ingreso — schema (Bloque A)
-- =============================================================================
-- Concepto: la facturación es un workflow ADMINISTRATIVO sobre una venta que
-- ya existe (ya cobrada, ya descontó stock) — nunca una venta nueva ni un
-- estado comercial. sales.status ('confirmed'/'cancelled') y
-- sales.billing_status son ejes independientes: una venta puede ser
-- confirmed + PENDING de facturar al mismo tiempo, sin contradicción.
--
-- payment_accounts: entidad configurable (igual criterio que
-- payment_methods/price_conditions) en vez de texto libre — para poder
-- agregar cuentas bancarias nuevas sin tocar código.
create table public.payment_accounts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

comment on table public.payment_accounts is
  'Cuenta donde ingresó el dinero de una venta (Mercado Pago, Banco Galicia, futuras cuentas). '
  'Concepto DISTINTO de payment_methods (forma de pago: transferencia, tarjeta, efectivo) — '
  'nunca se mezclan: una transferencia puede entrar por Mercado Pago o por Banco Galicia.';

insert into public.payment_accounts (code, name, sort_order) values
  ('MERCADO_PAGO', 'Mercado Pago', 1),
  ('BANCO_GALICIA', 'Banco Galicia', 2);

alter table public.payment_accounts enable row level security;

create policy payment_accounts_select on public.payment_accounts
  for select using (public.is_active_profile());
create policy payment_accounts_admin_write on public.payment_accounts
  for insert with check (public.is_admin());
create policy payment_accounts_admin_update on public.payment_accounts
  for update using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Estado de facturación. NUNCA un booleano is_invoiced: existe un tercer
-- caso real (venta que directamente no requiere control de facturación,
-- ej. efectivo) que un booleano no puede representar sin ambigüedad.
-- ---------------------------------------------------------------------------
create type public.sale_billing_status as enum ('NOT_REQUIRED', 'PENDING', 'INVOICED');

alter table public.sales
  add column payment_account_id uuid references public.payment_accounts (id) on delete restrict,
  add column billing_status public.sale_billing_status not null default 'NOT_REQUIRED',
  add column invoiced_at timestamptz,
  add column invoiced_by uuid references public.profiles (id);

comment on column public.sales.payment_account_id is
  'Cuenta donde ingresó el dinero — distinta de payment_method_id (forma de pago). '
  'Solo se completa para las formas de pago que la requieren (ver fn_create_sale_core).';
comment on column public.sales.billing_status is
  'Workflow administrativo, independiente de sales.status (comercial). Se decide '
  'SIEMPRE en el backend al confirmar la venta (fn_create_sale_core), nunca lo elige el frontend.';

alter table public.sales
  add constraint sales_billing_invoiced_consistency check (
    (billing_status = 'INVOICED' and invoiced_at is not null and invoiced_by is not null)
    or (billing_status <> 'INVOICED' and invoiced_at is null and invoiced_by is null)
  );

-- Backfill seguro: TODO lo histórico queda NOT_REQUIRED (ya es el default de
-- la columna, este UPDATE es redundante pero explícito para que quede
-- documentado en el diff) — nunca se infiere retroactivamente Mercado
-- Pago/Banco Galicia porque esa información no existe en el historial.
update public.sales set billing_status = 'NOT_REQUIRED' where billing_status = 'NOT_REQUIRED';

-- Índice parcial para la consulta real de /admin/facturacion: pendientes de
-- una venta confirmada, ordenadas por fecha (la más antigua primero).
create index sales_billing_pending_idx
  on public.sales (sold_at)
  where status = 'confirmed' and billing_status = 'PENDING';

comment on index public.sales_billing_pending_idx is
  'Cubre exactamente el query de /admin/facturacion (Pendientes): '
  'status=confirmed AND billing_status=PENDING ORDER BY sold_at ASC.';
