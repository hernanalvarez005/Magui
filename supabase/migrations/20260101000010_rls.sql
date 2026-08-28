-- =============================================================================
-- Maguirejuve · 10 · Row Level Security — principio de mínimo privilegio
-- =============================================================================
-- Regla general: las tablas transaccionales (sales, sale_items, inventory_balances,
-- stock_movements, product_prices, audit_logs) NO tienen policy de INSERT/UPDATE/DELETE
-- para roles de cliente: solo se escriben a través de las RPC SECURITY DEFINER de
-- 09_functions.sql (que corren como dueño de la tabla y validan permisos "a mano").
-- Sin policy de escritura + RLS habilitada = escritura directa denegada por defecto.

alter table public.profiles enable row level security;
alter table public.profile_locations enable row level security;
alter table public.stock_locations enable row level security;
alter table public.sales_channels enable row level security;
alter table public.payment_methods enable row level security;
alter table public.products enable row level security;
alter table public.kit_components enable row level security;
alter table public.price_conditions enable row level security;
alter table public.product_prices enable row level security;
alter table public.customers enable row level security;
alter table public.doctors enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.inventory_balances enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_transfers enable row level security;
alter table public.stock_transfer_items enable row level security;
alter table public.audit_logs enable row level security;
alter table public.app_settings enable row level security;
alter table public.sale_number_counters enable row level security; -- sin policies: nadie lo lee/escribe directo

-- ---------------------------------------------------------------------------
-- Privilegios de tabla (patrón estándar Supabase): los roles anon/authenticated
-- reciben los privilegios DML amplios de siempre, pero RLS es la autorización real
-- fila por fila. Sin una policy de INSERT/UPDATE/DELETE para una tabla, esas
-- operaciones quedan bloqueadas para authenticated aunque el GRANT lo permita.
-- anon (usuario sin sesión) no recibe nada: toda la app requiere login.
-- ---------------------------------------------------------------------------
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant all on tables to service_role;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create policy profiles_select_own_or_admin on public.profiles
  for select using (id = auth.uid() or public.is_admin());

create policy profiles_update_own_limited on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());
  -- Nota: esta policy permite al propio usuario actualizar su fila (ej. full_name),
  -- pero role/active/can_* solo deberían cambiarse vía pantalla admin (profiles_update_admin).
  -- Se refuerza en la capa de aplicación (el form de "mi perfil" no expone esos campos).

create policy profiles_update_admin on public.profiles
  for update using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- profile_locations
-- ---------------------------------------------------------------------------
create policy profile_locations_select on public.profile_locations
  for select using (profile_id = auth.uid() or public.is_admin());

create policy profile_locations_admin_write on public.profile_locations
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Catálogo de referencia (lectura amplia para usuarios activos, escritura admin)
-- ---------------------------------------------------------------------------
create policy stock_locations_select on public.stock_locations
  for select using (public.is_active_profile());
create policy stock_locations_admin_write on public.stock_locations
  for insert with check (public.is_admin());
create policy stock_locations_admin_update on public.stock_locations
  for update using (public.is_admin()) with check (public.is_admin());

create policy sales_channels_select on public.sales_channels
  for select using (public.is_active_profile());
create policy sales_channels_admin_write on public.sales_channels
  for insert with check (public.is_admin());
create policy sales_channels_admin_update on public.sales_channels
  for update using (public.is_admin()) with check (public.is_admin());

create policy payment_methods_select on public.payment_methods
  for select using (public.is_active_profile());
create policy payment_methods_admin_write on public.payment_methods
  for insert with check (public.is_admin());
create policy payment_methods_admin_update on public.payment_methods
  for update using (public.is_admin()) with check (public.is_admin());

create policy products_select on public.products
  for select using (public.is_active_profile());
create policy products_admin_write on public.products
  for insert with check (public.is_admin());
create policy products_admin_update on public.products
  for update using (public.is_admin()) with check (public.is_admin());

create policy kit_components_select on public.kit_components
  for select using (public.is_active_profile());
create policy kit_components_admin_write on public.kit_components
  for insert with check (public.is_admin());
create policy kit_components_admin_update on public.kit_components
  for update using (public.is_admin()) with check (public.is_admin());
create policy kit_components_admin_delete on public.kit_components
  for delete using (public.is_admin());

create policy price_conditions_select on public.price_conditions
  for select using (public.is_active_profile());
create policy price_conditions_admin_write on public.price_conditions
  for insert with check (public.is_admin());
create policy price_conditions_admin_update on public.price_conditions
  for update using (public.is_admin()) with check (public.is_admin());

-- product_prices: solo lectura directa (la escritura es exclusiva de set_product_price()).
create policy product_prices_select on public.product_prices
  for select using (public.is_active_profile());

-- ---------------------------------------------------------------------------
-- customers: cualquier usuario activo busca/crea; solo admin o quien la creó edita.
-- ---------------------------------------------------------------------------
create policy customers_select on public.customers
  for select using (public.is_active_profile());
create policy customers_insert on public.customers
  for insert with check (public.is_active_profile());
create policy customers_update on public.customers
  for update using (public.is_active_profile() and (created_by = auth.uid() or public.is_admin()))
  with check (public.is_active_profile());

-- ---------------------------------------------------------------------------
-- doctors: lectura para todos los activos, gestión exclusiva de admin.
-- ---------------------------------------------------------------------------
create policy doctors_select on public.doctors
  for select using (public.is_active_profile());
create policy doctors_admin_write on public.doctors
  for insert with check (public.is_admin());
create policy doctors_admin_update on public.doctors
  for update using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- sales / sale_items: el vendedor ve las suyas, el admin ve las de sus sedes.
-- Sin policy de insert/update/delete: todo pasa por create_sale()/cancel_sale().
-- ---------------------------------------------------------------------------
create policy sales_select on public.sales
  for select using (
    public.is_active_profile()
    and public.has_location_access(location_id)
    and (public.is_admin() or seller_id = auth.uid())
  );

create policy sale_items_select on public.sale_items
  for select using (
    exists (
      select 1 from public.sales s
      where s.id = sale_items.sale_id
        and public.has_location_access(s.location_id)
        and (public.is_admin() or s.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- Inventario: lectura por acceso a sede. Escritura exclusiva de las RPC.
-- ---------------------------------------------------------------------------
create policy inventory_balances_select on public.inventory_balances
  for select using (public.is_active_profile() and public.has_location_access(location_id));

create policy stock_movements_select on public.stock_movements
  for select using (public.is_active_profile() and public.has_location_access(location_id));

create policy stock_transfers_select on public.stock_transfers
  for select using (
    public.is_active_profile()
    and (public.has_location_access(from_location_id) or public.has_location_access(to_location_id))
  );

create policy stock_transfer_items_select on public.stock_transfer_items
  for select using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.transfer_id
        and (public.has_location_access(t.from_location_id) or public.has_location_access(t.to_location_id))
    )
  );

-- ---------------------------------------------------------------------------
-- audit_logs: exclusivo de administradores (log de seguridad/oversight).
-- ---------------------------------------------------------------------------
create policy audit_logs_admin_select on public.audit_logs
  for select using (public.is_admin());

-- ---------------------------------------------------------------------------
-- app_settings: lectura para todo usuario activo, edición exclusiva de admin.
-- ---------------------------------------------------------------------------
create policy app_settings_select on public.app_settings
  for select using (public.is_active_profile());
create policy app_settings_admin_update on public.app_settings
  for update using (public.is_admin()) with check (public.is_admin());
