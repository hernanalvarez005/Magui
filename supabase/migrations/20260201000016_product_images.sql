-- =============================================================================
-- Maguirejuve · 32 · Foto de producto/kit
-- =============================================================================
-- Bucket público de Storage (foto de producto no es información sensible —
-- se necesita poder mostrarla directo con <img src> en el selector de Nueva
-- Venta sin armar URLs firmadas). Lectura pública, escritura exclusiva de
-- admin — mismo criterio de permisos que ya rige el resto del catálogo
-- (products_admin_write/update en 20260101000010_rls.sql).
--
-- NOTA: storage.buckets/storage.objects son infraestructura propia de
-- Supabase (no existen en un Postgres local pelado) — a diferencia del resto
-- de las migraciones de este proyecto, esta no se pudo validar contra
-- rebuild_test_db.sh. La sintaxis sigue el patrón estándar documentado por
-- Supabase para políticas de Storage; conviene confirmar en el dashboard
-- (Storage → product-images → Policies) después de aplicarla en producción.
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

create policy product_images_public_read on storage.objects
  for select using (bucket_id = 'product-images');

create policy product_images_admin_insert on storage.objects
  for insert with check (bucket_id = 'product-images' and public.is_admin());

create policy product_images_admin_update on storage.objects
  for update using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());

create policy product_images_admin_delete on storage.objects
  for delete using (bucket_id = 'product-images' and public.is_admin());

-- ---------------------------------------------------------------------------
-- products.image_url: esta sí es una columna normal, validada como el resto.
-- Null = sin foto, la UI cae al ícono genérico que ya existía.
-- ---------------------------------------------------------------------------
alter table public.products add column image_url text;

comment on column public.products.image_url is
  'URL pública del bucket product-images. Null = sin foto (ícono genérico en la UI). '
  'Se administra desde /admin/productos y /admin/kits — no hay RPC dedicada: '
  'products_admin_update ya cubre esta columna igual que el resto del catálogo.';
