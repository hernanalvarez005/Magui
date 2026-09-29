/**
 * Nombre histórico de la condición de precio en la ficha de venta (Checkpoint
 * Final, Hallazgo A). Aislado en su propio archivo para poder testear la
 * regla sin levantar sale-detail-view.tsx completo — mismo criterio que
 * payment-account-alias.ts/web-fulfillment.ts.
 */

/**
 * sales.price_condition_name_snapshot (migración 69) es la foto del nombre
 * al momento de la venta — nunca se reescribe si la condición se renombra
 * después (update_price_condition). NULL solo puede pasar por dos motivos
 * legítimos, nunca "se olvidó completar": (1) venta anterior a la migración
 * 69 (backfill retroactivo deliberadamente nunca hecho — no hay forma real
 * de saber cómo se llamaba la condición en ese momento); (2) 100% precio
 * manual, sin ninguna condición resuelta. Para (1) cae al JOIN en vivo
 * contra price_conditions.name (la única fuente disponible para esas
 * ventas); si tampoco hay condición vigente para hacer ese JOIN, no hay
 * nombre que mostrar.
 */
export function resolveDisplayedConditionName(params: {
  snapshot: string | null;
  liveConditionName: string | null | undefined;
}): string | null {
  return params.snapshot ?? params.liveConditionName ?? null;
}
