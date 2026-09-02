import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { CambiosHub } from "@/components/cambios/cambios-hub";

export const metadata: Metadata = { title: "Cambios / Devoluciones" };

export default async function CambiosPage() {
  const profile = await getCurrentProfile();

  // Defensa en profundidad: el rol viewer (solo lectura) ya no ve este link
  // en la navegación, y create_sale_exchange/create_sale_return lo rechazan
  // en el backend — esto evita además que llegue por URL directa a un flujo
  // que no va a poder usar.
  if (profile.role === "viewer") {
    redirect("/ventas");
  }

  const supabase = await createClient();

  const [{ data: products }, { data: kitComponents }] = await Promise.all([
    // Mismo criterio que Nueva Venta (display_order, después nombre) — es el
    // catálogo del que se elige "lo que el cliente se lleva".
    supabase
      .from("products")
      .select("id, sku, name, product_type, category, track_stock, image_url")
      .eq("active", true)
      .order("display_order")
      .order("name"),
    supabase.from("kit_components").select("kit_product_id, component_product_id, quantity"),
  ]);

  const nameById = new Map((products ?? []).map((p) => [p.id, p.name]));
  const kitContents = new Map<string, string[]>();
  for (const kc of kitComponents ?? []) {
    const list = kitContents.get(kc.kit_product_id) ?? [];
    list.push(`${kc.quantity}× ${nameById.get(kc.component_product_id) ?? "?"}`);
    kitContents.set(kc.kit_product_id, list);
  }

  return (
    <CambiosHub
      products={(products ?? []).map((p) => ({ ...p, kitContents: kitContents.get(p.id) ?? null }))}
    />
  );
}
