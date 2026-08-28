-- =============================================================================
-- Maguirejuve · 14 · Triggers de auditoría en tablas sensibles editadas directamente
-- =============================================================================
-- Las RPC de negocio (create_sale, cancel_sale, transfer_stock, adjust_stock,
-- set_product_price) ya escriben en audit_logs explícitamente. Estas tablas, en
-- cambio, se editan por UPDATE directo desde /admin (protegido por RLS admin-only),
-- así que un trigger genérico se asegura de que ninguna edición quede sin registrar.

create or replace function public.fn_audit_table_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'update',
    TG_TABLE_NAME,
    new.id,
    jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new))
  );
  return new;
end;
$$;

create trigger trg_audit_price_conditions
  after update on public.price_conditions
  for each row execute function public.fn_audit_table_update();

create trigger trg_audit_products
  after update on public.products
  for each row execute function public.fn_audit_table_update();

create trigger trg_audit_profiles
  after update on public.profiles
  for each row execute function public.fn_audit_table_update();

create trigger trg_audit_doctors
  after update on public.doctors
  for each row execute function public.fn_audit_table_update();
