import type { Metadata } from "next";

import { createClient, createServiceRoleClient } from "@/lib/supabase/server";
import { UsersTable } from "@/components/admin/users-table";

export const metadata: Metadata = { title: "Usuarios" };

export default async function AdminUsersPage() {
  const supabase = await createClient();

  // El email vive solo en auth.users (profiles nunca tuvo esa columna), así
  // que hace falta la Auth Admin API para mostrarlo — es una llamada aparte
  // (otro cliente, otro servicio), independiente de las tres de abajo, así
  // que va en el mismo Promise.all en vez de esperarlas primero. Si falta la
  // service role key en este ambiente, la pantalla sigue funcionando sin
  // emails en vez de romperse — el resto de administración no depende de esto.
  async function fetchEmails() {
    const emailById = new Map<string, string>();
    try {
      const serviceClient = createServiceRoleClient();
      const { data } = await serviceClient.auth.admin.listUsers({ perPage: 1000 });
      for (const u of data?.users ?? []) {
        if (u.email) emailById.set(u.id, u.email);
      }
    } catch {
      // Sin SUPABASE_SERVICE_ROLE_KEY configurada: se sigue mostrando la lista sin email.
    }
    return emailById;
  }

  const [{ data: profiles }, { data: locations }, { data: profileLocations }, emailById] = await Promise.all([
    supabase
      .from("profiles")
      .select("id, full_name, role, active, can_view_financial_reports, can_adjust_stock")
      .order("full_name"),
    supabase.from("stock_locations").select("id, code, name").eq("active", true).order("name"),
    supabase.from("profile_locations").select("profile_id, location_id"),
    fetchEmails(),
  ]);

  const locationsByProfile = new Map<string, string[]>();
  for (const pl of profileLocations ?? []) {
    const list = locationsByProfile.get(pl.profile_id) ?? [];
    list.push(pl.location_id);
    locationsByProfile.set(pl.profile_id, list);
  }

  return (
    <UsersTable
      users={(profiles ?? []).map((p) => ({
        ...p,
        email: emailById.get(p.id) ?? "",
        locationIds: locationsByProfile.get(p.id) ?? [],
      }))}
      locations={locations ?? []}
    />
  );
}
