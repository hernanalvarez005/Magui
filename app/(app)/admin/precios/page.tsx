import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PriceMatrix } from "@/components/admin/price-matrix";

export const metadata: Metadata = { title: "Precios" };

// QTY_2/QTY_3_PLUS ya no aparecen acá: la query de abajo solo trae condiciones
// active=true, y esas dos quedaron desactivadas (migraron a Promociones,
// tipo QUANTITY_DISCOUNT — ver 20260201000046_quantity_discount_deactivate_legacy.sql).
//
// BUGFIX 67: CARD_1 no estaba en esta lista desde que se agregó
// (20260201000007) — como el comparador usa indexOf (que da -1 para lo que
// no está en el array), CARD_1 ordenaba SIEMPRE PRIMERO, antes de "Lista",
// por accidente (-1 < cualquier índice real). Orden final, explícito,
// alineado con el mismo orden que ya usaba /precios (DISPLAY_CODES en
// precios-view.tsx): Lista, Efectivo, Transferencia, 1 pago, 3 cuotas,
// 6 cuotas — ninguna condición activa queda fuera de la lista.
const CONDITION_ORDER = ["LIST", "CASH", "TRANSFER", "CARD_1", "INSTALLMENTS_3", "INSTALLMENTS_6"];

export default async function AdminPricesPage() {
  const supabase = await createClient();

  const [{ data: products }, { data: conditions }, { data: prices }] = await Promise.all([
    supabase.from("products").select("id, sku, name, active").order("name"),
    supabase.from("price_conditions").select("id, code, name, priority, discount_percent").eq("active", true),
    supabase
      .from("product_prices")
      .select("id, product_id, price_condition_id, amount")
      .eq("active", true),
  ]);

  const orderedConditions = (conditions ?? []).sort(
    (a, b) => CONDITION_ORDER.indexOf(a.code) - CONDITION_ORDER.indexOf(b.code)
  );

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Editar un precio nunca pisa el histórico: se cierra la vigencia anterior y se crea una versión
        nueva. Las ventas ya confirmadas mantienen el precio con el que se vendieron. El % de Efectivo
        y Transferencia solo sugiere un precio al cambiar la Lista o el propio %: el valor final que se
        guarda y se usa al vender es siempre el que quede escrito en la celda, redondeos incluidos.
      </p>
      <PriceMatrix
        products={products ?? []}
        conditions={orderedConditions}
        prices={prices ?? []}
      />
    </div>
  );
}
