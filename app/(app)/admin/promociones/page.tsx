import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PromotionsTable } from "@/components/admin/promotions-table";

export const metadata: Metadata = { title: "Promociones" };

export default async function AdminPromotionsPage() {
  const supabase = await createClient();

  const { data: conditions } = await supabase
    .from("price_conditions")
    .select("id, code, name, rule_type, payment_method_id, min_units, discount_percent, priority, combinable, active")
    .order("priority");

  const { data: paymentMethods } = await supabase.from("payment_methods").select("id, name");
  const pmMap = new Map((paymentMethods ?? []).map((p) => [p.id, p.name]));

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Las condiciones no se acumulan: para un carrito dado, gana la de menor número de prioridad
        cuya regla matchea. Cambiar la prioridad reordena la precedencia sin tocar código.
      </p>
      <PromotionsTable
        conditions={(conditions ?? []).map((c) => ({
          ...c,
          paymentMethodName: c.payment_method_id ? pmMap.get(c.payment_method_id) : undefined,
        }))}
      />
    </div>
  );
}
