import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PriceMatrix } from "@/components/admin/price-matrix";
import { sortConditionsForMatrix } from "@/lib/pricing/condition-order";

export const metadata: Metadata = { title: "Precios" };

// QTY_2/QTY_3_PLUS ya no aparecen acá: la query de abajo solo trae condiciones
// active=true, y esas dos quedaron desactivadas (migraron a Promociones,
// tipo QUANTITY_DISCOUNT — ver 20260201000046_quantity_discount_deactivate_legacy.sql).
//
// Orden de columnas: ver lib/pricing/condition-order.ts (Checkpoint Final,
// Hallazgo C) — data-driven por rule_type/priority, ya no una lista de codes
// hardcodeada (BUGFIX 67 documentaba el mismo bug para CARD_1, resuelto acá
// de raíz en vez de agregar cada code nuevo a mano).

export default async function AdminPricesPage() {
  const supabase = await createClient();

  const [{ data: products }, { data: conditions }, { data: prices }] = await Promise.all([
    supabase.from("products").select("id, sku, name, active").order("name"),
    supabase.from("price_conditions").select("id, code, name, rule_type, priority, discount_percent").eq("active", true),
    supabase
      .from("product_prices")
      .select("id, product_id, price_condition_id, amount, pricing_mode")
      .eq("active", true),
  ]);

  const orderedConditions = sortConditionsForMatrix(conditions ?? []);

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Editar un precio nunca pisa el histórico: se cierra la vigencia anterior y se crea una versión
        nueva. Precio de Lista es el precio maestro: cambiarlo recalcula todo el renglón del producto
        a automático (AUTO), para cada condición con % configurado — incluso si tenía excepciones
        Manual. Cambiar el % de una condición recalcula toda esa columna de la misma forma. Editar una
        celda puntual crea una excepción Manual, que dura hasta el próximo cambio de Lista o de esa
        condición — tocá el badge para volverla a automático antes. Una condición sin % configurado
        nunca se toca sola. Todo se guarda en un solo paso, atómico.
      </p>
      <PriceMatrix
        products={products ?? []}
        conditions={orderedConditions}
        prices={prices ?? []}
      />
    </div>
  );
}
