/**
 * Espejo en TypeScript de la expansión de kits usada por create_sale()/cancel_sale()
 * en SQL (ver supabase/migrations/20260101000009_functions.sql). Sirve para mostrar en
 * la UI cuánto stock real se va a descontar, y para testear la lógica sin base de datos.
 * La validación real y autoritativa ocurre siempre server-side, dentro de la transacción.
 */

import type { PricingItemInput } from "@/types/database";

export interface KitComponent {
  kit_product_id: string;
  component_product_id: string;
  quantity: number;
}

export interface TrackedProduct {
  id: string;
  track_stock: boolean;
}

/**
 * Expande un carrito a la cantidad requerida por producto "base" (con stock propio),
 * agregando kits en sus componentes. Si un producto se vende suelto Y como parte de un
 * kit en el mismo carrito, se suman ambos requerimientos.
 */
export function expandCartToRequiredStock(
  items: PricingItemInput[],
  products: TrackedProduct[],
  kitComponents: KitComponent[]
): Map<string, number> {
  const productsById = new Map(products.map((p) => [p.id, p]));
  const required = new Map<string, number>();

  const addRequired = (productId: string, qty: number) => {
    required.set(productId, (required.get(productId) ?? 0) + qty);
  };

  for (const item of items) {
    const product = productsById.get(item.product_id);
    if (!product) continue;

    if (product.track_stock) {
      addRequired(item.product_id, item.quantity);
      continue;
    }

    const components = kitComponents.filter((kc) => kc.kit_product_id === item.product_id);
    for (const component of components) {
      addRequired(component.component_product_id, item.quantity * component.quantity);
    }
  }

  return required;
}

export interface StockCheckResult {
  ok: boolean;
  missing?: { product_id: string; available: number; required: number };
}

/** Verifica que el saldo disponible (mapa product_id -> cantidad) alcance lo requerido. */
export function checkStockAvailability(
  required: Map<string, number>,
  available: Map<string, number>,
  allowNegative = false
): StockCheckResult {
  if (allowNegative) return { ok: true };

  for (const [productId, requiredQty] of required.entries()) {
    const availableQty = available.get(productId) ?? 0;
    if (availableQty < requiredQty) {
      return { ok: false, missing: { product_id: productId, available: availableQty, required: requiredQty } };
    }
  }
  return { ok: true };
}

/** Cuántas unidades de un kit se pueden armar hoy, según el componente limitante. */
export function kitBuildableQty(
  kitProductId: string,
  kitComponents: KitComponent[],
  available: Map<string, number>
): number {
  const components = kitComponents.filter((kc) => kc.kit_product_id === kitProductId);
  if (components.length === 0) return 0;
  return Math.min(
    ...components.map((c) => Math.floor((available.get(c.component_product_id) ?? 0) / c.quantity))
  );
}
