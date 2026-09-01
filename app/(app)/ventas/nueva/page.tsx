import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { getCurrentProfile } from "@/lib/auth/get-profile";
import { createClient } from "@/lib/supabase/server";
import { NewSaleClient } from "@/components/sales/new-sale-client";
import { EmptyState } from "@/components/shared/empty-state";

export const metadata: Metadata = { title: "Nueva venta" };

export default async function NewSalePage() {
  const profile = await getCurrentProfile();

  // Defensa en profundidad: el rol viewer (solo lectura) ya no ve este link
  // en la navegación, y create_sale lo rechaza en el backend — esto evita
  // además que llegue por URL directa a un formulario que no va a poder usar.
  if (profile.role === "viewer") {
    redirect("/ventas");
  }

  const supabase = await createClient();

  const [
    { data: locations },
    { data: channels },
    { data: paymentMethods },
    { data: paymentAccounts },
    { data: doctors },
    { data: products },
    { data: kitComponents },
    { data: promotions },
  ] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, code, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .eq("active", true)
      .order("name"),
    supabase.from("sales_channels").select("id, code, name").eq("active", true).order("sort_order"),
    supabase.from("payment_methods").select("id, code, name").eq("active", true).order("sort_order"),
    supabase.from("payment_accounts").select("id, code, name").eq("active", true).order("sort_order"),
    supabase.from("doctors").select("id, code, full_name").eq("active", true).order("full_name"),
    // display_order: orden visual pedido por el negocio (productos, después
    // kits, después accesorios) — cambio EXCLUSIVAMENTE de esta pantalla, ver
    // 20260201000026_product_display_order.sql. name como segundo criterio,
    // para que un producto nuevo sin display_order asignado (default al
    // final) quede alfabético contra el resto que tampoco lo tiene.
    supabase
      .from("products")
      .select("id, sku, name, product_type, category, track_stock, image_url")
      .eq("active", true)
      .order("display_order")
      .order("name"),
    supabase.from("kit_components").select("kit_product_id, component_product_id, quantity"),
    // Solo para mostrar el texto ("Promoción aplicada: 20% OFF" / "3x2") en el
    // carrito — la elegibilidad real (vigencia, exclusividad) la resuelve
    // siempre el servidor en quote_sale/create_sale, nunca el frontend.
    supabase.from("promotions").select("id, name, type, discount_percent, group_size").eq("active", true),
  ]);

  if (!locations || locations.length === 0) {
    return (
      <EmptyState
        title="No tenés sucursales asignadas"
        description="Pedile a un administrador que te habilite el acceso a al menos una sucursal para poder vender."
      />
    );
  }

  // "Qué incluye" cada kit, para mostrarlo directo en la tarjeta al armar la
  // venta — sin esto había que ir a Administración → Kits para saberlo.
  // products de arriba ya trae el nombre de TODOS los productos (kits
  // incluidos), no hace falta pedirle esa tabla a la base una segunda vez.
  const nameById = new Map((products ?? []).map((p) => [p.id, p.name]));
  const kitContents = new Map<string, string[]>();
  for (const kc of kitComponents ?? []) {
    const list = kitContents.get(kc.kit_product_id) ?? [];
    list.push(`${kc.quantity}× ${nameById.get(kc.component_product_id) ?? "?"}`);
    kitContents.set(kc.kit_product_id, list);
  }

  return (
    <NewSaleClient
      seller={{ id: profile.id, fullName: profile.fullName }}
      locations={locations}
      channels={channels ?? []}
      paymentMethods={paymentMethods ?? []}
      paymentAccounts={paymentAccounts ?? []}
      doctors={doctors ?? []}
      products={(products ?? []).map((p) => ({ ...p, kitContents: kitContents.get(p.id) ?? null }))}
      promotions={promotions ?? []}
      isAdmin={profile.role === "admin"}
    />
  );
}
