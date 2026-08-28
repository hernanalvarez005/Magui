import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PromotionsTable } from "@/components/admin/promotions-table";

export const metadata: Metadata = { title: "Promociones" };

export default async function AdminPromotionsPage() {
  const supabase = await createClient();

  const [{ data: promotions }, { data: promotionProducts }, { data: products }] = await Promise.all([
    supabase
      .from("promotions")
      .select(
        "id, code, name, type, discount_percent, group_size, priority, stackable, active, valid_from, valid_until, notes"
      )
      .order("priority"),
    supabase.from("promotion_products").select("promotion_id, product_id"),
    supabase.from("products").select("id, sku, name, product_type").eq("active", true).order("name"),
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
        Se evalúan sobre el precio ya resuelto por Condiciones de precio (medio de pago/cantidad),
        nunca antes. Un producto pertenece a lo sumo a una promoción activa a la vez. Si una
        promoción no combinable matchea el carrito, gana ella sola; si no, se aplican todas las
        combinables que matcheen.
      </p>
      <PromotionsTable
        promotions={(promotions ?? []).map((p) => ({
          ...p,
          productIds: productsByPromotion.get(p.id) ?? [],
        }))}
        products={products ?? []}
      />
    </div>
  );
}
