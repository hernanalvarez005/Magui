import type { Metadata } from "next";

import { createClient } from "@/lib/supabase/server";
import { PriceConditionsTable } from "@/components/admin/price-conditions-table";

export const metadata: Metadata = { title: "Condiciones de precio" };

export default async function AdminPriceConditionsPage() {
  const supabase = await createClient();

  const [
    { data: conditions },
    { data: paymentMethods },
    { data: locationRows },
    { data: channelRows },
    { data: branchLocations },
  ] = await Promise.all([
    // rule_type=QUANTITY dejó de ser una condición de precio administrable
    // acá — migró a Promociones (tipo QUANTITY_DISCOUNT). Las filas legacy
    // (QTY_2/QTY_3_PLUS) siguen existiendo, desactivadas, únicamente para no
    // romper la integridad de sale_items históricos — nunca se muestran acá.
    supabase
      .from("price_conditions")
      .select("id, code, name, rule_type, payment_method_id, discount_percent, priority, active")
      .neq("rule_type", "QUANTITY")
      .order("priority"),
    supabase.from("payment_methods").select("id, name, requires_billing"),
    supabase.from("price_condition_locations").select("price_condition_id, location_id"),
    supabase.from("price_condition_sales_channels").select("price_condition_id, sales_channel_id"),
    // Solo sedes físicas (type=branch) — mismo criterio que create_price_condition/
    // update_price_condition (Depósito nunca es una opción configurable desde acá).
    supabase.from("stock_locations").select("id, code, name").eq("type", "branch").eq("active", true).order("name"),
  ]);

  const { data: webChannel } = await supabase.from("sales_channels").select("id").eq("code", "WEB").maybeSingle();

  const pmById = new Map((paymentMethods ?? []).map((p) => [p.id, p]));
  const locationById = new Map((branchLocations ?? []).map((l) => [l.id, l]));

  const locationCodesByConditionId: Record<string, string[]> = {};
  const locationNamesByConditionId: Record<string, string[]> = {};
  for (const row of locationRows ?? []) {
    const loc = locationById.get(row.location_id);
    if (!loc) continue; // Depósito u otra sede no-branch: no se muestra/edita acá.
    (locationCodesByConditionId[row.price_condition_id] ??= []).push(loc.code);
    (locationNamesByConditionId[row.price_condition_id] ??= []).push(loc.name);
  }
  const webConditionIds = new Set(
    (channelRows ?? []).filter((row) => row.sales_channel_id === webChannel?.id).map((row) => row.price_condition_id)
  );

  const rows = (conditions ?? []).map((c) => {
    const pm = c.payment_method_id ? pmById.get(c.payment_method_id) : undefined;
    return {
      id: c.id,
      code: c.code,
      name: c.name,
      is_base: c.rule_type === "BASE",
      active: c.active,
      discount_percent: c.discount_percent,
      requires_billing: pm?.requires_billing ?? false,
      priority: c.priority,
      location_codes: locationCodesByConditionId[c.id] ?? [],
      location_names: locationNamesByConditionId[c.id] ?? [],
      available_web: webConditionIds.has(c.id),
    };
  });

  const listPriority = rows.find((r) => r.is_base)?.priority ?? 1;

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Estas condiciones resuelven el PRECIO BASE (según medio de pago) — no se acumulan entre
        sí: para una venta dada, gana la de menor número de prioridad cuya regla matchea. Las
        promociones (3x2, duo, kits) son otra cosa y se administran en Promociones; se aplican
        después, sobre el precio que ya resolvió esta pantalla.
      </p>
      <PriceConditionsTable
        conditions={rows}
        branchLocations={(branchLocations ?? []).map((l) => ({ code: l.code, name: l.name }))}
        listPriority={listPriority}
      />
    </div>
  );
}
