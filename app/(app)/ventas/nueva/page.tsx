import type { Metadata } from "next";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { NewSaleClient } from "@/components/sales/new-sale-client";
import { EmptyState } from "@/components/shared/empty-state";

export const metadata: Metadata = { title: "Nueva venta" };

export default async function NewSalePage() {
  const profile = await getCurrentProfile();
  const supabase = await createClient();

  const [{ data: locations }, { data: channels }, { data: paymentMethods }, { data: doctors }, { data: products }] =
    await Promise.all([
      supabase
        .from("stock_locations")
        .select("id, code, name")
        .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
        .eq("active", true)
        .order("name"),
      supabase.from("sales_channels").select("id, code, name").eq("active", true).order("sort_order"),
      supabase.from("payment_methods").select("id, code, name").eq("active", true).order("sort_order"),
      supabase.from("doctors").select("id, code, full_name").eq("active", true).order("full_name"),
      supabase
        .from("products")
        .select("id, sku, name, product_type, category, track_stock")
        .eq("active", true)
        .order("name"),
    ]);

  if (!locations || locations.length === 0) {
    return (
      <EmptyState
        title="No tenés sucursales asignadas"
        description="Pedile a un administrador que te habilite el acceso a al menos una sucursal para poder vender."
      />
    );
  }

  return (
    <NewSaleClient
      seller={{ id: profile.id, fullName: profile.fullName }}
      locations={locations}
      channels={channels ?? []}
      paymentMethods={paymentMethods ?? []}
      doctors={doctors ?? []}
      products={products ?? []}
    />
  );
}
