import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PromotionsTable } from "@/components/admin/promotions-table";

export const metadata: Metadata = { title: "Promociones" };

export default async function AdminPromotionsPage() {
  const supabase = await createClient();

  const [{ data: promotions }, { data: promotionProducts }, { data: products }, { data: priceConditions }] =
    await Promise.all([
      supabase
        .from("promotions")
        .select(
          "id, code, name, type, price_condition_id, discount_percent, group_size, minimum_quantity, priority, stackable, active, valid_from, valid_until, notes"
        )
        .order("priority"),
      supabase.from("promotion_products").select("promotion_id, product_id"),
      supabase.from("products").select("id, sku, name, product_type").eq("active", true).order("name"),
      supabase.from("price_conditions").select("id, name").eq("active", true).order("priority"),
    ]);

  const productsByPromotion = new Map<string, string[]>();
  for (const pp of promotionProducts ?? []) {
    const list = productsByPromotion.get(pp.promotion_id) ?? [];
    list.push(pp.product_id);
    productsByPromotion.set(pp.promotion_id, list);
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Cada promoción calcula su descuento sobre SU PROPIA condición de precio base — nunca sobre
        la que haya resuelto el medio de pago del carrito. Una venta con promoción usa
        exclusivamente el precio de la promoción: no se combina con transferencia, efectivo, cuotas
        ni ningún otro descuento. Un producto pertenece a lo sumo a una promoción activa a la vez.
        Si una promoción no combinable matchea el carrito, gana ella sola; si no, se aplican todas
        las combinables que matcheen.
      </p>
      <PromotionsTable
        promotions={(promotions ?? []).map((p) => ({
          ...p,
          productIds: productsByPromotion.get(p.id) ?? [],
        }))}
        products={products ?? []}
        priceConditions={priceConditions ?? []}
      />
    </div>
  );
}
