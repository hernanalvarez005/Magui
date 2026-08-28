import "server-only";

import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import type { AppRole } from "@/types/database";

export interface CurrentProfile {
  id: string;
  email: string | null;
  fullName: string;
  role: AppRole;
  active: boolean;
  canViewFinancialReports: boolean;
  canAdjustStock: boolean;
  locationIds: string[];
}

/**
 * Perfil del usuario logueado + sedes a las que tiene acceso. `proxy.ts` ya
 * garantiza que hay un usuario autenticado en toda ruta protegida, pero acá
 * validamos además que el profile exista y esté activo (defensa en profundidad:
 * RLS es la autoridad real, esto es para no renderizar una UI rota).
 */
export async function getCurrentProfile(): Promise<CurrentProfile> {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile, error } = await supabase
    .from("profiles")
    .select("id, full_name, role, active, can_view_financial_reports, can_adjust_stock")
    .eq("id", user.id)
    .maybeSingle();

  if (error || !profile || !profile.active) {
    await supabase.auth.signOut();
    redirect("/login?error=inactive");
  }

  const { data: locations } = await supabase
    .from("profile_locations")
    .select("location_id")
    .eq("profile_id", user.id);

  return {
    id: profile.id,
    email: user.email ?? null,
    fullName: profile.full_name,
    role: profile.role,
    active: profile.active,
    canViewFinancialReports: profile.can_view_financial_reports,
    canAdjustStock: profile.can_adjust_stock,
    locationIds: (locations ?? []).map((l) => l.location_id),
  };
}
