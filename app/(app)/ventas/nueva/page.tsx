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
    { data: promotionPaymentMethods },
    { data: activePriceConditions },
    { data: priceConditionLocations },
    { data: priceConditionSalesChannels },
  ] = await Promise.all([
    supabase
      .from("stock_locations")
      .select("id, code, name")
      .in("id", profile.locationIds.length > 0 ? profile.locationIds : ["00000000-0000-0000-0000-000000000000"])
      .eq("active", true)
      .order("name"),
    supabase.from("sales_channels").select("id, code, name").eq("active", true).order("sort_order"),
    supabase.from("payment_methods").select("id, code, name").eq("active", true).order("sort_order"),
    // alias viene junto con el listado inicial — nunca una consulta extra
    // al elegir cuenta en el selector (sección 15 del pedido).
    supabase.from("payment_accounts").select("id, code, name, alias").eq("active", true).order("sort_order"),
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
    supabase
      .from("promotions")
      .select("id, name, type, discount_percent, group_size, minimum_quantity")
      .eq("active", true),
    // [] para una promoción = sin restricción configurada (legacy, admite
    // cualquier medio) — ver 20260201000063_promotion_payment_methods.sql.
    // Solo se usa para avisar en la UI (§7/§8 del pedido); el backend
    // (fn_create_sale_core) es la autoridad real, canal <> WEB únicamente.
    supabase.from("promotion_payment_methods").select("promotion_id, payment_method_id"),
    // Disponibilidad de condiciones de precio por sede/canal (migración 69/70,
    // Checkpoint 2 — Condiciones de precio administrables). Un medio de pago
    // sin fila acá (ej. Efectivo) no tiene condición propia y cae siempre al
    // precio LIST/BASE, sin restricción. 100% data-driven: crear una condición
    // nueva desde /admin/condiciones-precio la hace aparecer o desaparecer acá
    // sin ningún cambio de código — misma autoridad que valida el servidor en
    // fn_create_sale_core (fn_price_condition_available).
    supabase.from("price_conditions").select("id, payment_method_id").eq("rule_type", "PAYMENT_METHOD").eq("active", true),
    supabase.from("price_condition_locations").select("price_condition_id, location_id"),
    supabase.from("price_condition_sales_channels").select("price_condition_id, sales_channel_id"),
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

  // Web es exclusivo de admin — un vendedor nunca la ve como opción (el
  // backend la vuelve a rechazar igual si se manipula la request, ver
  // 20260201000028_web_channel_admin_only.sql). El canal sigue existiendo
  // en el modelo de datos, solo se oculta del selector para este rol.
  const allowedChannels = (channels ?? []).filter((c) => profile.role === "admin" || c.code !== "WEB");

  // promotion_id -> ids de medios de pago permitidos. Ausente/[] = legacy
  // sin configurar, no restringe nada (mismo criterio que /admin/promociones).
  const promotionPaymentMethodIds: Record<string, string[]> = {};
  for (const ppm of promotionPaymentMethods ?? []) {
    (promotionPaymentMethodIds[ppm.promotion_id] ??= []).push(ppm.payment_method_id);
  }

  // Disponibilidad de condiciones de precio por medio de pago (ver comentario
  // arriba, en el Promise.all). webChannelId sale de "channels" sin filtrar
  // (antes de allowedChannels) porque price_condition_sales_channels puede
  // tener una fila para Web aunque este vendedor no la vea como opción.
  const webChannelId = (channels ?? []).find((c) => c.code === "WEB")?.id ?? null;
  const locationIdsByPriceConditionId = new Map<string, string[]>();
  for (const row of priceConditionLocations ?? []) {
    const list = locationIdsByPriceConditionId.get(row.price_condition_id) ?? [];
    list.push(row.location_id);
    locationIdsByPriceConditionId.set(row.price_condition_id, list);
  }
  const webPriceConditionIds = new Set(
    (priceConditionSalesChannels ?? [])
      .filter((row) => row.sales_channel_id === webChannelId)
      .map((row) => row.price_condition_id)
  );
  const priceConditionAvailability = (activePriceConditions ?? [])
    .filter((pc): pc is typeof pc & { payment_method_id: string } => pc.payment_method_id !== null)
    .map((pc) => ({
      paymentMethodId: pc.payment_method_id,
      locationIds: locationIdsByPriceConditionId.get(pc.id) ?? [],
      web: webPriceConditionIds.has(pc.id),
    }));

  return (
    <NewSaleClient
      seller={{ id: profile.id, fullName: profile.fullName }}
      locations={locations}
      channels={allowedChannels}
      paymentMethods={paymentMethods ?? []}
      paymentAccounts={paymentAccounts ?? []}
      doctors={doctors ?? []}
      products={(products ?? []).map((p) => ({ ...p, kitContents: kitContents.get(p.id) ?? null }))}
      promotions={promotions ?? []}
      promotionPaymentMethodIds={promotionPaymentMethodIds}
      priceConditionAvailability={priceConditionAvailability}
      isAdmin={profile.role === "admin"}
    />
  );
}
