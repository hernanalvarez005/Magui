import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { ProductsTable } from "@/components/admin/products-table";

export const metadata: Metadata = { title: "Productos" };

export default async function AdminProductsPage() {
  const supabase = await createClient();

  const [{ data: products }, { data: kitComponents }] = await Promise.all([
    supabase
      .from("products")
      .select("id, sku, name, product_type, category, track_stock, commissionable, promo_eligible, default_min_stock, active, notes")
      .order("name"),
    supabase.from("kit_components").select("kit_product_id, component_product_id, quantity"),
  ]);

  const { data: allProducts } = await supabase.from("products").select("id, name");
  const nameById = new Map((allProducts ?? []).map((p) => [p.id, p.name]));

  const componentsByKit = new Map<string, string[]>();
  for (const kc of kitComponents ?? []) {
    const list = componentsByKit.get(kc.kit_product_id) ?? [];
    list.push(`${kc.quantity}× ${nameById.get(kc.component_product_id) ?? kc.component_product_id}`);
    componentsByKit.set(kc.kit_product_id, list);
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Un producto inactivo desaparece de Nueva Venta pero conserva todo su historial. Los kits
        muestran su composición (definida en <code>kit_components</code>, no editable acá).
      </p>
      <ProductsTable
        products={(products ?? []).map((p) => ({
          ...p,
          components: componentsByKit.get(p.id) ?? [],
        }))}
      />
    </div>
  );
}
