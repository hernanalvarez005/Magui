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
 * hardcodeada: ["CASH", "TRANSFER"]) en /admin/precios. Toda condición que
 * no sea BASE (Lista no tiene % propio — es la referencia 0%) puede
 * configurar su discount_percent, sin importar code/nombre — una condición
 * nueva creada desde /admin/condiciones-precio (ej. una futura "9 cuotas
 * sin interés", code autogenerado) queda incluida automáticamente.
 */
export function isDiscountConfigurable(condition: { rule_type: string }): boolean {
  return condition.rule_type !== "BASE";
}
