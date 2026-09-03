/**
 * Espejo en TypeScript del motor de precios (`fn_pricing_quote` en
 * supabase/migrations/20260101000009_functions.sql). Implementa exactamente la misma
 * regla de negocio para poder testearla sin base de datos (ver tests/pricing.test.ts)
 * y para compartir tipos entre frontend y backend.
 *
 * IMPORTANTE: esto NO decide ventas reales. La única fuente de verdad en producción es
 * la función SQL, invocada vía la RPC `quote_sale` (preview) y `create_sale` (confirmación).
 * Ver docs/pricing.md.
 */

import type { PricingItemInput, PricingLine, PricingQuoteResult } from "@/types/database";

export interface PricingProduct {
  id: string;
  sku: string;
  name: string;
  active: boolean;
  promo_eligible: boolean;
  commissionable: boolean;
}

export interface PricingCondition {
  id: string;
  code: string;
  name: string;
  // 'QUANTITY' migró a Promociones (tipo QUANTITY_DISCOUNT en fn_apply_promotions,
  // sin espejo en este archivo — igual que 3x2/duo%/kit%, que tampoco lo tienen).
  // Este mirror deliberadamente ya no modela esa rama: fn_pricing_quote real
  // tampoco la resuelve más (ver 20260201000045_quantity_discount_pricing_quote.sql).
  rule_type: "BASE" | "PAYMENT_METHOD";
  payment_method_id: string | null;
  discount_percent: number | null;
  priority: number;
  active: boolean;
}

export interface PricingPrice {
  product_id: string;
  price_condition_id: string;
  amount: number;
  active: boolean;
  valid_from: string; // ISO
  valid_until: string | null; // ISO
}

export interface PricingCatalog {
  products: PricingProduct[];
  conditions: PricingCondition[];
  prices: PricingPrice[];
}

function round2(n: number): number {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

function findCurrentPrice(
  catalog: PricingCatalog,
  productId: string,
  conditionId: string,
  soldAt: Date
): number | null {
  const candidates = catalog.prices.filter(
    (p) =>
      p.product_id === productId &&
      p.price_condition_id === conditionId &&
      p.active &&
      p.amount > 0 &&
      new Date(p.valid_from).getTime() <= soldAt.getTime() &&
      (p.valid_until === null || new Date(p.valid_until).getTime() > soldAt.getTime())
  );
  if (candidates.length === 0) return null;
  // La vigencia más reciente gana (debería haber una sola activa por diseño).
  candidates.sort((a, b) => new Date(b.valid_from).getTime() - new Date(a.valid_from).getTime());
  return candidates[0].amount;
}

export function quoteSale(
  catalog: PricingCatalog,
  items: PricingItemInput[],
  paymentMethodId: string,
  soldAt: Date = new Date()
): PricingQuoteResult {
  if (!items || items.length === 0) {
    return { ok: false, error_message: "El carrito está vacío." };
  }

  const distinctProductIds = new Set(items.map((i) => i.product_id));
  if (distinctProductIds.size !== items.length) {
    return { ok: false, error_message: "Hay un producto duplicado en el carrito." };
  }

  if (items.some((i) => !i.quantity || i.quantity <= 0)) {
    return { ok: false, error_message: "Hay una cantidad inválida en el carrito." };
  }

  const productsById = new Map(catalog.products.map((p) => [p.id, p]));

  for (const item of items) {
    const product = productsById.get(item.product_id);
    if (!product || !product.active) {
      return {
        ok: false,
        error_message: "Uno de los productos del carrito no existe o está inactivo.",
      };
    }
  }

  const winningCondition = catalog.conditions
    .filter((c) => c.active)
    .filter((c) => {
      if (c.rule_type === "BASE") return true;
      if (c.rule_type === "PAYMENT_METHOD") return c.payment_method_id === paymentMethodId;
      return false;
    })
    .sort((a, b) => a.priority - b.priority)[0];

  if (!winningCondition) {
    return { ok: false, error_message: "No hay ninguna condición de precio activa configurada." };
  }

  const baseCondition = catalog.conditions.find((c) => c.rule_type === "BASE");

  const lines: PricingLine[] = [];
  let subtotal = 0;
  let total = 0;
  let discountTotal = 0;
  let surchargeTotal = 0;

  for (const item of items) {
    const product = productsById.get(item.product_id)!;

    const saleUnitPrice = findCurrentPrice(catalog, item.product_id, winningCondition.id, soldAt);
    if (saleUnitPrice === null) {
      return {
        ok: false,
        error_message: `Este producto no tiene precio configurado para ${winningCondition.name}: ${product.name}.`,
      };
    }

    const listPriceRaw = baseCondition
      ? findCurrentPrice(catalog, item.product_id, baseCondition.id, soldAt)
      : null;
    const listUnitPrice = listPriceRaw ?? saleUnitPrice;

    const lineListTotal = round2(listUnitPrice * item.quantity);
    const lineTotal = round2(saleUnitPrice * item.quantity);
    // Una condición más cara que Lista (ej. cuotas) es un recargo comercial
    // válido, no un error — complementarios y siempre >= 0, sumados desde
    // las líneas (nunca derivados como subtotal - total). Mismo criterio que
    // fn_pricing_quote (ver supabase/migrations/*_pricing_surcharge_*).
    const lineDiscount = round2(Math.max((listUnitPrice - saleUnitPrice) * item.quantity, 0));
    const lineSurcharge = round2(Math.max((saleUnitPrice - listUnitPrice) * item.quantity, 0));

    subtotal += lineListTotal;
    total += lineTotal;
    discountTotal += lineDiscount;
    surchargeTotal += lineSurcharge;

    lines.push({
      product_id: item.product_id,
      sku: product.sku,
      name: product.name,
      quantity: item.quantity,
      list_unit_price: listUnitPrice,
      sale_unit_price: saleUnitPrice,
      line_list_total: lineListTotal,
      line_discount: lineDiscount,
      line_surcharge: lineSurcharge,
      line_total: lineTotal,
      commissionable: product.commissionable,
      applied_price_condition_id: winningCondition.id,
    });
  }

  const explanation =
    winningCondition.rule_type === "BASE"
      ? "Precio lista"
      : winningCondition.discount_percent && winningCondition.discount_percent > 0
        ? `${winningCondition.name} — ${Math.round(winningCondition.discount_percent * 100)}% OFF`
        : winningCondition.name;

  return {
    ok: true,
    error_message: null,
    applied_price_condition_id: winningCondition.id,
    applied_price_condition_code: winningCondition.code,
    applied_price_condition_name: winningCondition.name,
    explanation,
    subtotal: round2(subtotal),
    discount_total: round2(discountTotal),
    surcharge_total: round2(surchargeTotal),
    total: round2(total),
    lines,
  };
}

/** Comisión de una venta: solo sobre líneas commissionable, nunca sobre el total. */
export function calculateCommission(lines: PricingLine[], commissionPercent: number): number {
  const commissionableTotal = lines
    .filter((l) => l.commissionable)
    .reduce((acc, l) => acc + l.line_total, 0);
  return round2(commissionableTotal * commissionPercent);
}
