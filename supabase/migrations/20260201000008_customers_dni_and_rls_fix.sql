-- =============================================================================
-- Maguirejuve · 24 · Clientes: DNI normalizado + fix bug de edición (bloque 3)
-- =============================================================================
-- El índice único de DNI YA existe (customers_dni_unique_idx, desde el MVP).
-- Lo que faltaba: normalizar antes de comparar ("32.123.456" y "32123456" hoy
-- se guardan como strings distintos, así que la unicidad no detecta ese
-- duplicado). Se agrega un trigger que normaliza (solo dígitos) antes de
-- guardar — corre en INSERT y UPDATE, cubre cualquier vía de entrada.

create or replace function public.fn_normalize_dni()
returns trigger
language plpgsql
as $$
begin
  if new.dni is not null then
    new.dni := regexp_replace(new.dni, '[^0-9]', '', 'g');
    if new.dni = '' then
      new.dni := null;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_customers_normalize_dni
  before insert or update on public.customers
  for each row execute function public.fn_normalize_dni();

-- ---------------------------------------------------------------------------
-- BUG REAL: la policy de UPDATE solo dejaba editar al creador o a un admin.
-- Cualquier otra vendedora que corrige el DNI de un cliente ve la operación
-- "aplicada" en el toast (supabase-js no marca error cuando RLS filtra el
-- UPDATE a 0 filas), pero en la base no cambia nada. Los clientes no son
-- información sensible por vendedor — cualquier usuario activo puede
-- editarlos (igual que ya puede crearlos). La eliminación (soft delete) sigue
-- siendo exclusiva de admin, pero vía una RPC dedicada, no vía esta policy.
-- ---------------------------------------------------------------------------
drop policy customers_update on public.customers;
create policy customers_update on public.customers
  for update using (public.is_active_profile())
  with check (public.is_active_profile());

-- ---------------------------------------------------------------------------
-- deactivate_customer: soft delete exclusivo de admin. Nunca hard delete —
-- preserva la referencia en ventas históricas.
-- ---------------------------------------------------------------------------
create or replace function public.deactivate_customer(p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede eliminar clientes.';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'El cliente no existe.';
  end if;

  update public.customers set active = false where id = p_customer_id;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'deactivate_customer', 'customers', p_customer_id, '{}'::jsonb);

  return jsonb_build_object('customer_id', p_customer_id, 'active', false);
end;
$$;

comment on function public.deactivate_customer is
  'Soft delete: active=false. Nunca hard delete — preserva sales.customer_id de '
  'ventas históricas. Restaurable reactivando active=true (UPDATE directo, admin).';

grant execute on function public.deactivate_customer(uuid) to authenticated;
