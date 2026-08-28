import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { UsersTable } from "@/components/admin/users-table";

export const metadata: Metadata = { title: "Usuarios" };

export default async function AdminUsersPage() {
  const supabase = await createClient();

  const [{ data: profiles }, { data: locations }, { data: profileLocations }] = await Promise.all([
    supabase
      .from("profiles")
      .select("id, full_name, role, active, can_view_financial_reports, can_adjust_stock")
      .order("full_name"),
    supabase.from("stock_locations").select("id, code, name").eq("active", true).order("name"),
    supabase.from("profile_locations").select("profile_id, location_id"),
  ]);

  const locationsByProfile = new Map<string, string[]>();
  for (const pl of profileLocations ?? []) {
    const list = locationsByProfile.get(pl.profile_id) ?? [];
    list.push(pl.location_id);
    locationsByProfile.set(pl.profile_id, list);
  }

  return (
    <UsersTable
      users={(profiles ?? []).map((p) => ({ ...p, locationIds: locationsByProfile.get(p.id) ?? [] }))}
      locations={locations ?? []}
    />
  );
}
