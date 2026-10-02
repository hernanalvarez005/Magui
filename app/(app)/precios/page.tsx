import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { activePromotionsQuery } from "@/lib/promotions/active-promotions";
import { PreciosView } from "@/components/precios/precios-view";

export const metadata: Metadata = { title: "Precios" };

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
      // Data-driven (cierre de inconsistencia post-release): antes filtraba
      // por un allowlist fijo de codes (DISPLAY_CODES), que dejaba afuera
      // cualquier condición nueva creada desde /admin/condiciones-precio
      // (ej. "2 cuotas sin interés"). La exclusión real que hacía falta
      // siempre fue por rule_type: QUANTITY (QTY_2/QTY_3_PLUS) no es "el
      // precio de este producto" sino un descuento por cantidad — hoy
      // migrado por completo a Promociones y desactivado permanentemente
      // (20260201000046_quantity_discount_deactivate_legacy.sql). Toda
      // condición creable desde el admin es siempre PAYMENT_METHOD
      // (create_price_condition la hardcodea así) — filtrar por rule_type
      // en vez de code hace que esta pantalla nunca vuelva a quedar
      // desactualizada por una condición nueva. Mismo criterio que ya usa
      // /admin/precios (lib/pricing/condition-order.ts).
      //
      // visible_in_price_lookup (migración 73): eje independiente de active
      // — Administración puede ocultar una condición de ESTA pantalla sin
      // afectar su venta. BASE (Lista) ignora la columna acá mismo, a
      // propósito: el .or() la incluye siempre sin importar su valor — es
      // el precio de referencia, nunca tiene sentido esconderlo, y no hay
      // ningún control en el admin para ponerle false (ver migración 73).
      supabase
        .from("price_conditions")
        .select("id, code, name, rule_type, priority")
        .eq("active", true)
        .in("rule_type", ["BASE", "PAYMENT_METHOD"])
        .or("rule_type.eq.BASE,visible_in_price_lookup.eq.true"),
      // Sin filtrar por condición: además de las que se muestran como
      // columnas, hace falta el precio bajo la condición base que declare
      // CADA promoción (puede ser cualquiera) para calcular "Precio promo"
      // (sección 9).
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
