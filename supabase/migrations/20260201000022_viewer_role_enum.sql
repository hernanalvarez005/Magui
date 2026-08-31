-- =============================================================================
-- Maguirejuve · 38 · Rol "viewer" (modo observador / solo lectura) — paso 1/2
-- =============================================================================
-- Un nuevo valor de enum con ALTER TYPE ... ADD VALUE no puede usarse en la
-- misma transacción en la que se agrega (restricción de Postgres). Este
-- archivo va SOLO — todo lo que usa 'viewer' (helpers, RLS, RPCs) vive en la
-- migration siguiente (20260201000023), aplicada por separado.
alter type public.app_role add value 'viewer';
