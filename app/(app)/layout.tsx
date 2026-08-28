import { getCurrentProfile } from "@/lib/auth/get-profile";
import { AppShell } from "@/components/layout/app-shell";
import { createClient } from "@/lib/supabase/server";

export default async function AppLayout({ children }: LayoutProps<"/">) {
  const profile = await getCurrentProfile();

  const supabase = await createClient();
  const { data: locations } = await supabase
    .from("stock_locations")
    .select("name")
    .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"]);

  const locationLabel =
    locations && locations.length > 0
      ? locations.map((l) => l.name).join(" · ")
      : "Sin sucursales asignadas";

  return (
    <AppShell fullName={profile.fullName} role={profile.role} locationLabel={locationLabel}>
      {children}
    </AppShell>
  );
}
