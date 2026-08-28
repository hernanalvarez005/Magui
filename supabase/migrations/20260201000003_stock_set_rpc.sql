-- =============================================================================
-- Maguirejuve · 19 · RPC set_stock (mejoras — bloque 1)
-- =============================================================================

-- Permite signo libre para ADJUSTMENT_SET (la diferencia puede ser + o -).
alter table public.stock_movements drop constraint stock_movements_sign_matches_type;
alter table public.stock_movements add constraint stock_movements_sign_matches_type check (
  case movement_type
    when 'INITIAL' then true
    when 'PURCHASE' then quantity_delta > 0
    when 'SALE' then quantity_delta < 0
    when 'SALE_CANCEL' then quantity_delta > 0
    when 'ADJUSTMENT_PLUS' then quantity_delta > 0
    when 'ADJUSTMENT_MINUS' then quantity_delta < 0
    when 'ADJUSTMENT_SET' then true
    when 'TRANSFER_OUT' then quantity_delta < 0
    when 'TRANSFER_IN' then quantity_delta > 0
    when 'RETURN' then quantity_delta > 0
    else true
  end
);

create or replace function public.set_stock(
  p_location_id uuid,
  p_product_id uuid,
  p_new_quantity numeric,
  p_reason public.stock_adjustment_reason,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_before numeric;
  v_delta numeric;
  v_movement public.stock_movements;
begin
  select * into v_profile from public.profiles where id = auth.uid();

  if v_profile is null or v_profile.active = false then
    raise exception 'Tu usuario no tiene permiso para operar.';
  end if;

  -- Establecer stock final es EXCLUSIVO de administradores (a diferencia de
  -- adjust_stock, que un seller con can_adjust_stock también puede usar).
  if not public.is_admin() then
    raise exception 'Solo un administrador puede establecer el stock final de un producto.';
  end if;

  if not public.has_location_access(p_location_id) then
    raise exception 'Tu usuario no tiene acceso a esta sucursal.';
  end if;

  if p_new_quantity is null or p_new_quantity < 0 then
    raise exception 'El stock no puede ser negativo.';
  end if;

  if not exists (select 1 from public.products where id = p_product_id and track_stock = true) then
    raise exception 'Este producto no maneja stock propio.';
  end if;

  select coalesce(quantity, 0) into v_before
  from public.inventory_balances
  where location_id = p_location_id and product_id = p_product_id;
  v_before := coalesce(v_before, 0);

  v_delta := p_new_quantity - v_before;

  if v_delta = 0 then
    return jsonb_build_object(
      'movement_id', null, 'stock_before', v_before, 'stock_after', v_before, 'changed', false
    );
  end if;

  v_movement := public.fn_apply_stock_movement(
    p_location_id => p_location_id,
    p_product_id => p_product_id,
    p_movement_type => 'ADJUSTMENT_SET',
    p_quantity_delta => v_delta,
    p_reason => p_reason,
    p_notes => p_notes,
    p_created_by => auth.uid(),
    -- Nunca permitir stock negativo desde acá: si p_new_quantity >= 0 ya lo
    -- garantiza, pero se refuerza explícitamente por claridad.
    p_allow_negative => false
  );

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'set_stock', 'inventory_balances', p_product_id,
    jsonb_build_object(
      'location_id', p_location_id, 'stock_before', v_before, 'stock_after', p_new_quantity,
      'delta', v_delta, 'reason', p_reason
    )
  );

  return jsonb_build_object(
    'movement_id', v_movement.id, 'stock_before', v_before, 'stock_after', p_new_quantity, 'changed', true
  );
end;
$$;

comment on function public.set_stock is
  'Establece el stock final de un producto en una sede. Calcula la diferencia contra el '
  'balance actual y genera un movimiento ADJUSTMENT_SET auditable — nunca hace UPDATE directo '
  'del balance. Exclusivo de administradores (a diferencia de adjust_stock).';

grant execute on function public.set_stock(
  uuid, uuid, numeric, public.stock_adjustment_reason, text
) to authenticated;
