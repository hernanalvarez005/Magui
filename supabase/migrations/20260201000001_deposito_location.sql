-- =============================================================================
-- Maguirejuve · 17 · Ubicación "Depósito" (mejoras — bloque 1)
-- =============================================================================
-- La arquitectura de stock_locations ya es genérica (no hardcodeada): agregar
-- una ubicación nueva es solo un dato, no requiere cambios de esquema.
-- Representa las cremas guardadas actualmente en lo de Guille.

insert into public.stock_locations (code, short_code, name, type, active)
values ('DEP', 'DEP', 'Depósito', 'warehouse', true)
on conflict (code) do nothing;

-- Los admins actuales (con acceso a todas las sedes existentes) reciben acceso
-- automático al nuevo depósito, para no tener que reconfigurar permisos a mano.
-- Los vendedores mantienen exactamente el acceso que ya tenían (no se les
-- otorga Depósito salvo que un admin lo asigne explícitamente desde /admin/usuarios).
insert into public.profile_locations (profile_id, location_id)
select p.id, dep.id
from public.profiles p
cross join (select id from public.stock_locations where code = 'DEP') dep
where p.role = 'admin'
on conflict do nothing;
