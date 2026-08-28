-- =============================================================================
-- Maguirejuve · 25 · Fix RLS: autoescalada de privilegios en profiles (bloque 6)
-- =============================================================================
-- BUG DE SEGURIDAD REAL detectado al revisar RLS para la administración de
-- usuarios: la policy profiles_update_own_limited solo exige `id = auth.uid()`.
-- Postgres RLS no restringe columnas — cualquier usuario autenticado puede
-- hoy, llamando a supabase-js directamente (sin pasar por la UI), hacer
-- `update profiles set role = 'admin', active = true where id = auth.uid()`
-- y la policy lo deja pasar. El comentario original de esa policy decía que
-- esto se reforzaba "en la capa de aplicación" (el form no expone esos
-- campos), lo cual NUNCA alcanza como control de seguridad real.
--
-- Postgres no permite columnas restringidas dentro de una policy USING/WITH
-- CHECK (WITH CHECK solo ve NEW, no puede comparar contra OLD). El patrón
-- correcto es un trigger BEFORE UPDATE que compare OLD vs NEW y rechace el
-- cambio si quien no es admin toca su PROPIA fila para cambiar role/active/
-- can_view_financial_reports/can_adjust_stock.
--
-- Se restringe solo cuando auth.uid() no es null Y coincide con la fila que
-- se está editando (autoescalada real desde el navegador, vía authenticated).
-- Cuando auth.uid() es null (service_role — createUserAction activa el
-- profile recién creado con la service role key, que nunca se expone al
-- navegador — o una sesión directa por SQL Editor/psql para tareas de
-- mantenimiento, incluida el alta del primer admin) el trigger no interviene:
-- ese camino ya es de por sí privilegiado y no pasa por RLS de usuario final.
create or replace function public.fn_prevent_self_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and old.id = auth.uid() and not public.is_admin() then
    if new.role is distinct from old.role
        or new.active is distinct from old.active
        or new.can_view_financial_reports is distinct from old.can_view_financial_reports
        or new.can_adjust_stock is distinct from old.can_adjust_stock
    then
      raise exception 'No podés modificar tu propio rol o permisos. Pedile a un administrador.';
    end if;
  end if;
  return new;
end;
$$;

comment on function public.fn_prevent_self_privilege_escalation is
  'Bloquea que un usuario no-admin cambie su propio role/active/can_* aunque '
  'llame a la tabla profiles directamente (defensa en profundidad: la policy '
  'profiles_update_own_limited por sí sola no restringe columnas). No aplica '
  'cuando auth.uid() es null (service_role, SQL Editor, tareas de mantenimiento).';

create trigger trg_profiles_prevent_self_privilege_escalation
  before update on public.profiles
  for each row execute function public.fn_prevent_self_privilege_escalation();
