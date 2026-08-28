-- =============================================================================
-- Maguirejuve · 11 · Índices de performance
-- =============================================================================
-- (Los índices de unicidad/lookup específicos de cada dominio ya se crearon junto
-- a su tabla. Acá van los pedidos explícitamente para las consultas más frecuentes.)

create index sales_sold_at_idx on public.sales (sold_at desc);
create index sales_location_id_idx on public.sales (location_id);
create index sales_seller_id_idx on public.sales (seller_id);
create index sales_customer_id_idx on public.sales (customer_id) where customer_id is not null;
create index sales_doctor_id_idx on public.sales (doctor_id) where doctor_id is not null;
create index sales_status_idx on public.sales (status);
create index sales_channel_idx on public.sales (sales_channel_id);
create index sales_location_sold_at_idx on public.sales (location_id, sold_at desc);

create index sale_items_sale_id_idx on public.sale_items (sale_id);
create index sale_items_product_id_idx on public.sale_items (product_id);

create index stock_movements_location_id_idx on public.stock_movements (location_id);
create index stock_movements_product_id_idx on public.stock_movements (product_id);
create index stock_movements_occurred_at_idx on public.stock_movements (occurred_at desc);
create index stock_movements_location_product_idx on public.stock_movements (location_id, product_id, occurred_at desc);
create index stock_movements_sale_id_idx on public.stock_movements (sale_id) where sale_id is not null;
create index stock_movements_transfer_id_idx on public.stock_movements (transfer_id) where transfer_id is not null;

create index product_prices_product_id_idx on public.product_prices (product_id);

-- inventory_balances ya tiene PK (location_id, product_id); útil para "stock bajo".
create index inventory_balances_product_idx on public.inventory_balances (product_id);

create index products_active_idx on public.products (active) where active = true;
create index products_type_idx on public.products (product_type);

create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id);
create index audit_logs_created_at_idx on public.audit_logs (created_at desc);
