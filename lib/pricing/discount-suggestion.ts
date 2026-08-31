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
