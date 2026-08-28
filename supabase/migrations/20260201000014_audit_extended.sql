-- =============================================================================
-- Maguirejuve · 30 · Auditoría extendida (bloque 10)
-- =============================================================================
-- fn_audit_table_update() (fase original) solo cubría UPDATE en 4 tablas.
-- Repasando la lista de "acciones sensibles" del prompt de mejoras
-- (set stock, CRUD de productos/kits/promociones, alta/baja de clientes,
-- edición/baja/cambio de rol de usuarios, cancelación de ventas) quedaban
-- huecos reales:
--   - alta de un producto nuevo (solo se auditaba la edición)
--   - toda la composición de un kit (kit_components no tenía ningún trigger)
--   - clientes: alta y edición (solo la baja, vía deactivate_customer, se
--     auditaba explícitamente)
--   - promociones y su composición (tablas nuevas de este mismo trabajo)
-- set_stock, cancel_sale, deactivate_customer y la baja/alta de usuarios via
-- profiles ya se auditaban (RPCs explícitas + trg_audit_profiles). No se
-- tocan esos triggers existentes — se agregan los que faltaban, con una
-- función genérica nueva que sí sabe manejar INSERT/UPDATE/DELETE (la
-- original revienta con OLD en un INSERT).
create or replace function public.fn_audit_table_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entity_id uuid;
  v_metadata jsonb;
begin
  if TG_OP = 'DELETE' then
    v_entity_id := old.id;
    v_metadata := jsonb_build_object('before', to_jsonb(old), 'after', null);
  elsif TG_OP = 'INSERT' then
    v_entity_id := new.id;
    v_metadata := jsonb_build_object('before', null, 'after', to_jsonb(new));
  else
    v_entity_id := new.id;
    v_metadata := jsonb_build_object('before', to_jsonb(old), 'after', to_jsonb(new));
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), lower(TG_OP), TG_TABLE_NAME, v_entity_id, v_metadata);

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

comment on function public.fn_audit_table_change is
  'Igual que fn_audit_table_update pero genérica para INSERT/UPDATE/DELETE. '
  'No reemplaza a la original (sus 4 triggers existentes siguen igual) — es '
  'para las tablas que hasta ahora no tenían ningún trigger de auditoría.';

create trigger trg_audit_products_insert
  after insert on public.products
  for each row execute function public.fn_audit_table_change();

create trigger trg_audit_customers
  after insert or update on public.customers
  for each row execute function public.fn_audit_table_change();

create trigger trg_audit_kit_components
  after insert or update or delete on public.kit_components
  for each row execute function public.fn_audit_table_change();

create trigger trg_audit_promotions
  after insert or update on public.promotions
  for each row execute function public.fn_audit_table_change();

create trigger trg_audit_promotion_products
  after insert or delete on public.promotion_products
  for each row execute function public.fn_audit_table_change();
