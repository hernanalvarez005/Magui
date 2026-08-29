import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { ProductsTable } from "@/components/admin/products-table";

export const metadata: Metadata = { title: "Productos" };

export default async function AdminProductsPage() {
  const supabase = await createClient();

  const [{ data: products }, { data: kitComponents }] = await Promise.all([
    supabase
      .from("products")
      .select("id, sku, name, product_type, category, unit, track_stock, commissionable, promo_eligible, default_min_stock, active, notes, image_url")
      .order("name"),
    supabase.from("kit_components").select("kit_product_id, component_product_id, quantity"),
  ]);

  // products de arriba ya trae id + name de TODOS los productos (no filtra
  // por active) — alcanza para armar el nombre de cada componente de kit,
  // no hace falta pedirle la misma tabla a la base una segunda vez.
  const nameById = new Map((products ?? []).map((p) => [p.id, p.name]));

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
        se crean y editan en Kits — acá solo se muestra su composición actual, de referencia.
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
