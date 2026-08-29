-- =============================================================================
-- Maguirejuve · 33 · Historial de compras por cliente
-- =============================================================================
-- Se pidió "historial de compras del cliente: fecha y productos comprados",
-- visible desde la ficha del cliente. sales_select (RLS estándar) restringe
-- a un vendedor no-admin a ver solo SUS PROPIAS ventas — correcto para el
-- listado general de /ventas (ahí el alcance es "mi actividad"), pero acá el
-- alcance es distinto: es la historia DEL CLIENTE, útil para cualquier
-- vendedora que lo esté atendiendo, no solo quien le vendió la última vez.
-- Por eso esto es una RPC dedicada (no una consulta directa a `sales`, que
-- quedaría recortada por esa policy) — visible a cualquier usuario activo,
-- sin filtrar por seller_id, pero sí respetando el acceso por sede
-- (has_location_access) como el resto del sistema. Solo ventas confirmadas
-- (una cancelada ya no es, en los hechos, algo que el cliente "compró").
create or replace function public.customer_purchase_history(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
begin
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile is null or not v_profile.active then
    raise exception 'Tu usuario no tiene permiso para ver esta información.';
  end if;

  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception 'El cliente no existe.';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'sale_id', s.id,
          'sale_number', s.sale_number,
          'sold_at', s.sold_at,
          'location_name', l.name,
          'seller_name', p.full_name,
          'total', s.total,
          'is_free_sale', s.is_free_sale,
          'stock_skipped', s.stock_skipped,
          'items', t.items
        )
        order by s.sold_at desc
      )
      from public.sales s
      join public.stock_locations l on l.id = s.location_id
      left join public.profiles p on p.id = s.seller_id
      join lateral (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'product_id', si.product_id,
              'name', pr.name,
              'sku', pr.sku,
              'quantity', si.quantity,
              'line_total', si.line_total
            )
            order by pr.name
          ),
          '[]'::jsonb
        ) as items
        from public.sale_items si
        join public.products pr on pr.id = si.product_id
        where si.sale_id = s.id
      ) t on true
      where s.customer_id = p_customer_id
        and s.status = 'confirmed'
        and public.has_location_access(s.location_id)
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.customer_purchase_history is
  'Historial de compras de un cliente (fecha, sede, vendedora, productos) — '
  'a diferencia de sales_select (RLS), no se recorta por seller_id: cualquier '
  'usuario activo con acceso a la sede ve la historia completa del cliente, '
  'porque el alcance acá es el cliente, no "mis propias ventas". Solo ventas '
  'confirmadas.';

grant execute on function public.customer_purchase_history(uuid) to authenticated;
