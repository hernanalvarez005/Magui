/**
 * Sugerencia de precio a partir de la Lista y el % de descuento configurado
 * en price_conditions.discount_percent (Bloque E — Precios automáticos por
 * porcentaje + edición manual).
 *
 * Es SOLO una sugerencia de administración, para precargar el formulario de
 * /admin/precios y recalcularlo al cambiar la Lista o el %. NUNCA es la
 * fuente de verdad de una venta: fn_pricing_quote / fn_apply_promotions no
 * la ejecutan ni la conocen, solo leen product_prices.amount ya persistido
 * (el precio final que Administración haya guardado, redondeos incluidos).
 */
export function suggestDiscountedPrice(listAmount: number, discountPercent: number): number {
  const raw = listAmount * (1 - discountPercent / 100);
  return Math.round((raw + Number.EPSILON) * 100) / 100;
}

/**
 * Checkpoint Precios — reemplaza SUGGESTABLE_CODES (allowlist de codes
 * hardcodeada: ["CASH", "TRANSFER"]) en /admin/precios. rule_type ===
 * "PAYMENT_METHOD" exacto (no "!== BASE") — mismo criterio exacto que usa
 * el backend (fn_recalculate_auto_prices, migración 74) para decidir qué
 * participa del recálculo automático. Antes había una asimetría: el
 * frontend permitía configurar % en cualquier no-BASE (incluiría QUANTITY
 * si alguna vez se reactivara), mientras el backend solo recalculaba
 * PAYMENT_METHOD — ahora ambos usan el mismo criterio, sin asumir nada de
 * un rule_type futuro. Una condición nueva creada desde
 * /admin/condiciones-precio (ej. una futura "9 cuotas sin interés", code
 * autogenerado) queda incluida automáticamente porque sigue siendo
 * PAYMENT_METHOD, nunca por su code/nombre.
 */
export function isDiscountConfigurable(condition: { rule_type: string }): boolean {
  return condition.rule_type === "PAYMENT_METHOD";
}
