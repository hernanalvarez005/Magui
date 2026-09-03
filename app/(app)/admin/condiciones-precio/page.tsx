import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PriceConditionsTable } from "@/components/admin/price-conditions-table";

export const metadata: Metadata = { title: "Condiciones de precio" };

export default async function AdminPriceConditionsPage() {
  const supabase = await createClient();

  const [{ data: conditions }, { data: paymentMethods }] = await Promise.all([
    // rule_type=QUANTITY dejó de ser una condición de precio administrable
    // acá — migró a Promociones (tipo QUANTITY_DISCOUNT). Las filas legacy
    // (QTY_2/QTY_3_PLUS) siguen existiendo, desactivadas, únicamente para no
    // romper la integridad de sale_items históricos — nunca se muestran acá.
    supabase
      .from("price_conditions")
      .select("id, code, name, rule_type, payment_method_id, min_units, discount_percent, priority, combinable, active")
      .neq("rule_type", "QUANTITY")
      .order("priority"),
    supabase.from("payment_methods").select("id, name"),
  ]);
  const pmMap = new Map((paymentMethods ?? []).map((p) => [p.id, p.name]));

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Estas condiciones resuelven el PRECIO BASE (según medio de pago o cantidad) — no se
        acumulan entre sí: para un carrito dado, gana la de menor número de prioridad cuya regla
        matchea. Las promociones (3x2, duo, kits) son otra cosa y se administran en Promociones;
        se aplican después, sobre el precio que ya resolvió esta pantalla.
      </p>
      <PriceConditionsTable
        conditions={(conditions ?? []).map((c) => ({
          ...c,
          paymentMethodName: c.payment_method_id ? pmMap.get(c.payment_method_id) : undefined,
        }))}
      />
    </div>
  );
}
