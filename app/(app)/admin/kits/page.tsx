import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { KitsTable } from "@/components/admin/kits-table";

export const metadata: Metadata = { title: "Kits" };

export default async function AdminKitsPage() {
  const supabase = await createClient();

  const [{ data: kits }, { data: components }, { data: allKitComponents }] = await Promise.all([
    supabase
      .from("products")
      .select("id, sku, name, category, commissionable, promo_eligible, active, notes")
      .eq("product_type", "kit")
      .order("name"),
    // Solo productos que trackean stock propio pueden ser componentes: la
    // disponibilidad del kit se calcula a partir de inventory_balances de
    // sus componentes (fn_kit_buildable_qty), así que un producto sin stock
    // propio (otro kit, un combo) rompería ese cálculo.
    supabase
      .from("products")
      .select("id, sku, name, unit")
      .eq("track_stock", true)
      .eq("active", true)
      .order("name"),
    supabase.from("kit_components").select("id, kit_product_id, component_product_id, quantity"),
  ]);

  const componentsByKit = new Map<string, { id: string; component_product_id: string; quantity: string }[]>();
  for (const kc of allKitComponents ?? []) {
    const list = componentsByKit.get(kc.kit_product_id) ?? [];
    list.push({ id: kc.id, component_product_id: kc.component_product_id, quantity: kc.quantity });
    componentsByKit.set(kc.kit_product_id, list);
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Un kit vende varios productos juntos como una unidad. Su stock nunca es un número propio:
        se calcula a partir del stock disponible de cada componente. Cambiar la composición no
        afecta ventas ya confirmadas — quedan con la foto de lo que se vendió en su momento.
      </p>
      <KitsTable
        kits={(kits ?? []).map((k) => ({
          ...k,
          components: componentsByKit.get(k.id) ?? [],
        }))}
        candidates={components ?? []}
      />
    </div>
  );
}
