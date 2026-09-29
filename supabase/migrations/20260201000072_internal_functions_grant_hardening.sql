-- =============================================================================
-- Maguirejuve · 72 · Endurecimiento de grants — funciones internas y create_web_order
-- =============================================================================
-- Migración forward-only, exclusivamente de permisos. No redefine ningún
-- cuerpo de función, no toca tablas, no toca RLS, no toca 069/070/071.
--
-- Contexto: en todo el historial de este repo, cada `revoke execute` sobre
-- estas cinco funciones usó únicamente `from public`. Eso alcanza en un
-- Postgres estándar (el default de Postgres es otorgar EXECUTE a PUBLIC al
-- crear una función; revocárselo a PUBLIC deja a cualquier rol sin acceso,
-- salvo que tenga un grant propio). Verificado en producción (Supabase) que
-- create_web_order, fn_create_sale_core y fn_apply_stock_movement quedaron
-- con EXECUTE otorgado explícitamente a `authenticated`/`anon` además de
-- PUBLIC — un mecanismo del proyecto Supabase, no versionado ni reproducible
-- desde las migraciones de este repo, que un `revoke ... from public` no
-- deshace. `fn_next_sale_number` y `fn_pricing_quote` también aparecieron
-- expuestas en producción pese a no tener ningún DROP+CREATE reciente en su
-- historial — confirma que el mecanismo no depende únicamente de un
-- DROP+CREATE local; puede reaplicarse a nivel de proyecto Supabase por vías
-- no visibles desde el repo.
--
-- Esta migración es la corrección reproducible: nombra explícitamente los
-- tres roles en cada revoke, sin asumir que el estado previo sea inseguro —
-- es igual de correcta si la base ya tenía los permisos corregidos a mano
-- (ver sección "Idempotencia" en el checkpoint) que si viene del estado
-- inseguro original.
--
-- Firmas verificadas contra el schema vigente (pg_get_function_identity_arguments
-- sobre una reconstrucción limpia 001..071) antes de escribir este archivo.
-- =============================================================================

revoke execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz,
  public.sale_payment_status, uuid, public.sale_fulfillment_type
) from public, authenticated, anon;

grant execute on function public.create_web_order(
  jsonb, uuid, uuid, text, text, uuid, uuid, text, timestamptz,
  public.sale_payment_status, uuid, public.sale_fulfillment_type
) to service_role;

revoke execute on function public.fn_create_sale_core(
  uuid, jsonb, uuid, uuid, uuid, uuid, uuid, text, text, text,
  timestamptz, boolean, public.free_sale_reason, text, boolean, uuid,
  public.sale_fulfillment_type, public.sale_payment_status
) from public, authenticated, anon;

revoke execute on function public.fn_apply_stock_movement(
  uuid, uuid, public.stock_movement_type, numeric, uuid, uuid, text,
  public.stock_adjustment_reason, text, uuid, boolean, uuid
) from public, authenticated, anon;

revoke execute on function public.fn_next_sale_number(
  uuid, timestamptz
) from public, authenticated, anon;

revoke execute on function public.fn_pricing_quote(
  jsonb, uuid, timestamptz, boolean
) from public, authenticated, anon;
