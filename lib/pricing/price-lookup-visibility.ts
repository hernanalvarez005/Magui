import type { AppRole } from "@/types/database";

/**
 * /precios (consulta de precios) — visible_in_price_lookup afecta
 * EXCLUSIVAMENTE a vendedoras. Administración siempre ve todas las
 * condiciones activas (BASE + PAYMENT_METHOD), independientemente de esta
 * columna — para eso visita /admin/precios y /admin/condiciones-precio,
 * que ya traían el set completo y no cambian con esto.
 *
 * admin: bypass total. seller/viewer: BASE siempre + PAYMENT_METHOD solo
 * si visible_in_price_lookup=true. Solo mira rule_type — nunca code/nombre
 * — así que una condición futura cae bajo la misma regla automáticamente.
 *
 * Aislado en su propio archivo, puro y testeable con Vitest, sin montar
 * app/(app)/precios/page.tsx — mismo patrón que isDiscountConfigurable /
 * sortConditionsForMatrix.
 */
export function isPriceConditionVisibleForRole(
  condition: { rule_type: string; visible_in_price_lookup: boolean },
  role: AppRole
): boolean {
  if (role === "admin") return true;
  if (condition.rule_type === "BASE") return true;
  return condition.visible_in_price_lookup;
}
