import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { activePromotionsQuery } from "@/lib/promotions/active-promotions";
import { PreciosView } from "@/components/precios/precios-view";

export const metadata: Metadata = { title: "Precios" };

// Mismas 5 condiciones pedidas para esta pantalla (sección 6 del pedido),
// en el orden que pide el mockup — es solo el orden de columnas de ESTA
// vista, no reemplaza ni duplica el orden que usa Administración → Precios
// (que muestra todas las condiciones, incluidas QTY_2/QTY_3_PLUS, que acá
// no aportan valor porque no son "el precio de este producto" sino un
// descuento por cantidad).
const DISPLAY_CODES = ["LIST", "CASH", "TRANSFER", "CARD_1", "INSTALLMENTS_3"];

export default async function PreciosPage() {
  const supabase = await createClient();

  // Fuente única de verdad: las mismas tablas que usa Administración
  // (products, price_conditions, product_prices, promotions,
  // promotion_products) — sin tabla ni caché propia para esta pantalla
  // (sección 17 del pedido). RLS ya permite lectura a cualquier perfil
  // activo (seller/viewer/admin) en las 5 — no hace falta RLS nueva
  // (sección 24), ver informe.
  //
  // "Vigente" para promociones: activePromotionsQuery() — misma función que
  // usa la Home del vendedor, para que las dos pantallas nunca diverjan en
  // qué cuenta como vigente (ajuste "promociones en Home").
  const [{ data: products }, { data: priceConditions }, { data: productPrices }, { data: promotions }] =
    await Promise.all([
      supabase
        .from("products")
        .select("id, sku, name, product_type")
        .eq("active", true)
        .order("display_order")
        .order("name"),
      supabase.from("price_conditions").select("id, code, name").eq("active", true).in("code", DISPLAY_CODES),
      // Sin filtrar por condición: además de las 5 que se muestran como
      // columnas, hace falta el precio bajo la condición base que declare
      // CADA promoción (puede ser cualquiera, no solo una de las 5) para
      // calcular "Precio promo" (sección 9).
      supabase.from("product_prices").select("product_id, price_condition_id, amount").eq("active", true),
      activePromotionsQuery(supabase),
    ]);

  const promotionIds = (promotions ?? []).map((p) => p.id);
  const { data: promotionProducts } = promotionIds.length
    ? await supabase.from("promotion_products").select("promotion_id, product_id").in("promotion_id", promotionIds)
    : { data: [] as { promotion_id: string; product_id: string }[] };

  return (
    <div className="flex flex-col gap-4 p-4 md:p-6">
      <div>
        <h1 className="text-xl font-semibold">Precios</h1>
        <p className="text-sm text-muted-foreground">Consultá precios y promociones vigentes.</p>
      </div>

      <PreciosView
        products={products ?? []}
        priceConditions={priceConditions ?? []}
        productPrices={productPrices ?? []}
        promotions={promotions ?? []}
        promotionProducts={promotionProducts ?? []}
      />
    </div>
  );
}
