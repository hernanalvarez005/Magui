/**
 * Formas de pago habilitadas por promoción (migración 63) — reglas puras de
 * Nueva Venta, aisladas para poder testearlas sin levantar todo
 * new-sale-cart.tsx (mismo criterio que web-fulfillment.ts).
 *
 * El backend (fn_create_sale_core) es la autoridad real — esto es
 * exclusivamente una capa de UX para avisar ANTES de confirmar, nunca
 * reemplaza la validación del servidor. Solo aplica a ventas presenciales
 * (canal <> WEB); el caller decide no usar estas funciones para Web.
 */

export interface PromotionPaymentMethodsLookup {
  /** id de promoción -> ids de medios de pago permitidos. Una promoción
   * ausente de este mapa, o con array vacío, es "legacy sin configurar" —
   * no restringe nada (ver 20260201000063_promotion_payment_methods.sql). */
  get(promotionId: string): string[] | undefined;
}

/**
 * Dado el conjunto de promociones ganadoras en el carrito (applied_promotion_id
 * distintos de las líneas del quote), devuelve el conjunto de medios de pago
 * válidos, o `null` si no hay ninguna restricción activa (todos los medios
 * siguen disponibles — sin promoción, o solo promociones legacy sin
 * configurar). Nunca devuelve un array vacío como "sin restricción": un
 * array vacío significa intersección vacía (ninguna combinación posible).
 */
export function computeAllowedPaymentMethodIds(
  appliedPromotionIds: readonly (string | null | undefined)[],
  paymentMethodIdsByPromotion: PromotionPaymentMethodsLookup
): string[] | null {
  const distinctPromotionIds = Array.from(new Set(appliedPromotionIds.filter((id): id is string => !!id)));

  let intersection: string[] | null = null;
  for (const promotionId of distinctPromotionIds) {
    const allowed = paymentMethodIdsByPromotion.get(promotionId);
    if (!allowed || allowed.length === 0) continue; // legacy sin configurar: no restringe

    intersection = intersection === null ? allowed : intersection.filter((id) => allowed.includes(id));
  }

  return intersection;
}

/** Envoltorio conveniente de computeAllowedPaymentMethodIds a partir de un
 * Map<string, string[]> plano (lo que trae el server component). */
export function mapToLookup(map: Map<string, string[]>): PromotionPaymentMethodsLookup {
  return { get: (id) => map.get(id) };
}
