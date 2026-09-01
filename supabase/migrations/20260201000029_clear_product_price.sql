-- =============================================================================
-- Maguirejuve · Bugfix — Precios: "No hay cambios para guardar"
-- =============================================================================
-- PASO 0 (auditoría, resumen — ver informe completo entregado al usuario):
--   Causa raíz real del bug era 100% frontend (components/admin/price-matrix.tsx):
--   la detección de "hay cambios" para habilitar el botón (dirtyCount) usaba
--   un filtro, y el guardado (handleSave) usaba OTRO filtro ligeramente
--   distinto que además excluía explícitamente los campos vacíos
--   (`value.trim() !== ""`). Resultado: borrar un precio SÍ contaba para
--   habilitar "Guardar cambios (1)", pero al guardar ese campo vacío quedaba
--   afuera del payload — si era el único cambio, handleSave veía 0 filas
--   para persistir y mostraba "No hay cambios para guardar" a pesar de que
--   sí había una edición real. Se corrige unificando la detección en una
--   sola función pura (lib/pricing/price-matrix-changes.ts), usada tanto
--   para el conteo/resaltado como para el guardado — ya no pueden divergir.
--
--   Pero además: el frontend no tenía NINGÚN camino para persistir un
--   precio borrado — set_product_price() exige p_amount > 0 (nunca
--   $0/negativo/null) y no existía ninguna otra función para desactivar un
--   precio sin insertar uno nuevo. "Borrar un precio" es una operación
--   legítima (sección 4 del pedido) que hasta ahora no tenía backend.
--
--   Estrategia elegida (una de las 3 explícitamente ofrecidas en el pedido:
--   "eliminar/desactivar la vigencia") — reutiliza EXACTAMENTE el mismo
--   mecanismo de versionado que ya usa set_product_price(): cierra la
--   vigencia activa (valid_until = now, active = false) sin insertar una
--   fila nueva. No hay UPDATE destructivo, no se borra ninguna fila, y
--   sale_items ya guarda su propio snapshot (list_unit_price, sale_unit_price,
--   etc.) — nunca una referencia viva a product_prices — así que esto no
--   toca ninguna venta histórica, igual que set_product_price().
create or replace function public.clear_product_price(
  p_product_id uuid,
  p_price_condition_id uuid,
  p_valid_from timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Tu usuario no tiene permiso para modificar precios.';
  end if;

  update public.product_prices
  set valid_until = p_valid_from, active = false
  where product_id = p_product_id
    and price_condition_id = p_price_condition_id
    and active = true
    and valid_from < p_valid_from;

  insert into public.audit_logs (user_id, action, entity_type, entity_id, metadata)
  values (
    auth.uid(), 'clear_product_price', 'products', p_product_id,
    jsonb_build_object('price_condition_id', p_price_condition_id)
  );
end;
$$;

comment on function public.clear_product_price(uuid, uuid, timestamptz) is
  'Desactiva la vigencia activa de un precio (sin insertar una fila nueva) — "borrar un precio" en el '
  'formulario de Administración → Precios. La condición vuelve a mostrarse como "Sin configurar", nunca '
  'como $0. No afecta sale_items de ventas históricas (snapshot propio, no referencia viva).';

grant execute on function public.clear_product_price(uuid, uuid, timestamptz) to authenticated;
