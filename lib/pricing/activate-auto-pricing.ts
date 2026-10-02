import { suggestDiscountedPrice } from "@/lib/pricing/discount-suggestion";

/**
 * "Activar automático" por condición (bootstrap de AUTO sobre lo histórico
 * que la migración 74 dejó en MANUAL, sin tocar celda por celda) —
 * components/admin/activate-auto-pricing-dialog.tsx. Calcula, para UNA
 * condición, qué productos son elegibles para el preview y qué precio
 * automático les correspondería — misma fórmula suggestDiscountedPrice que
 * ya usa la Matriz, ningún cálculo nuevo. Aislado en su propio archivo para
 * poder testearlo con Vitest sin montar el diálogo (igual que
 * price-matrix-changes.ts).
 */

export interface ActivateAutoPricingProduct {
  id: string;
  sku: string;
  name: string;
}

export interface ActivateAutoPricingPrice {
  product_id: string;
  price_condition_id: string;
  amount: string | number;
  pricing_mode: "AUTO" | "MANUAL";
}

export interface EligibleAutoPricingRow {
  product_id: string;
  sku: string;
  name: string;
  list_amount: number;
  current_amount: number | null;
  auto_amount: number;
}

/**
 * Elegible = tiene Lista vigente Y (no tiene precio bajo esta condición, O
 * lo tiene en MANUAL). Un producto AUTO bajo esta condición, o sin Lista,
 * nunca aparece — ni para mostrarlo tildado ni destildado.
 */
export function computeEligibleAutoPricingRows(
  products: ActivateAutoPricingProduct[],
  prices: ActivateAutoPricingPrice[],
  listConditionId: string | undefined,
  conditionId: string,
  discountPercent: number
): EligibleAutoPricingRow[] {
  if (!listConditionId) return [];

  const listByProduct = new Map<string, number>();
  const currentByProduct = new Map<string, { amount: number; mode: "AUTO" | "MANUAL" }>();
  for (const p of prices) {
    if (p.price_condition_id === listConditionId) {
      listByProduct.set(p.product_id, Number(p.amount));
    } else if (p.price_condition_id === conditionId) {
      currentByProduct.set(p.product_id, { amount: Number(p.amount), mode: p.pricing_mode });
    }
  }

  const eligible: EligibleAutoPricingRow[] = [];
  for (const product of products) {
    const listAmount = listByProduct.get(product.id);
    if (listAmount === undefined) continue;
    const current = currentByProduct.get(product.id);
    if (current?.mode === "AUTO") continue;
    eligible.push({
      product_id: product.id,
      sku: product.sku,
      name: product.name,
      list_amount: listAmount,
      current_amount: current?.amount ?? null,
      auto_amount: suggestDiscountedPrice(listAmount, discountPercent * 100),
    });
  }
  return eligible;
}
