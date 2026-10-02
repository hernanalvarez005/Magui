import { describe, expect, it } from "vitest";

import { computeEligibleAutoPricingRows } from "@/lib/pricing/activate-auto-pricing";

// "Activar automático" por condición — bootstrap de AUTO sobre lo histórico
// que la migración 74 dejó en MANUAL (components/admin/activate-auto-pricing-dialog.tsx).
// La escritura real (p_reset_to_auto -> save_price_matrix_changes) ya está
// cubierta en pgTAP; acá se cubre específicamente el cálculo de elegibles
// del preview — selección parcial y producto sin Lista.
describe("computeEligibleAutoPricingRows", () => {
  const LIST_ID = "list-condition";
  const COND_ID = "cond-15pct";

  const products = [
    { id: "p1", sku: "SKU-1", name: "Producto 1" },
    { id: "p2", sku: "SKU-2", name: "Producto 2" },
    { id: "p3", sku: "SKU-3", name: "Producto 3 (sin Lista)" },
    { id: "p4", sku: "SKU-4", name: "Producto 4 (ya AUTO)" },
  ];

  const prices = [
    { product_id: "p1", price_condition_id: LIST_ID, amount: "100000", pricing_mode: "MANUAL" as const },
    { product_id: "p1", price_condition_id: COND_ID, amount: "99999", pricing_mode: "MANUAL" as const },
    { product_id: "p2", price_condition_id: LIST_ID, amount: "50000", pricing_mode: "MANUAL" as const },
    // p2 no tiene fila bajo COND_ID -> "Sin configurar".
    // p3 no tiene ninguna fila bajo LIST_ID -> sin Lista.
    { product_id: "p4", price_condition_id: LIST_ID, amount: "80000", pricing_mode: "MANUAL" as const },
    { product_id: "p4", price_condition_id: COND_ID, amount: "68000", pricing_mode: "AUTO" as const },
  ];

  it("incluye un producto con Lista y la condición en MANUAL, con el precio automático calculado", () => {
    const rows = computeEligibleAutoPricingRows(products, prices, LIST_ID, COND_ID, 0.15);
    const p1 = rows.find((r) => r.product_id === "p1");
    expect(p1).toBeDefined();
    expect(p1!.current_amount).toBe(99999);
    expect(p1!.auto_amount).toBe(85000);
  });

  it("incluye un producto con Lista y sin ninguna fila bajo la condición (Sin configurar)", () => {
    const rows = computeEligibleAutoPricingRows(products, prices, LIST_ID, COND_ID, 0.15);
    const p2 = rows.find((r) => r.product_id === "p2");
    expect(p2).toBeDefined();
    expect(p2!.current_amount).toBeNull();
    expect(p2!.auto_amount).toBe(42500);
  });

  it("excluye un producto SIN Precio de Lista vigente — nunca aparece, ni para tildar ni para destildar", () => {
    const rows = computeEligibleAutoPricingRows(products, prices, LIST_ID, COND_ID, 0.15);
    expect(rows.find((r) => r.product_id === "p3")).toBeUndefined();
  });

  it("excluye un producto que YA está AUTO bajo esta condición — no hay nada que activar", () => {
    const rows = computeEligibleAutoPricingRows(products, prices, LIST_ID, COND_ID, 0.15);
    expect(rows.find((r) => r.product_id === "p4")).toBeUndefined();
  });

  it("selección parcial: el llamador decide qué elegibles tildar — la función solo informa, nunca selecciona por su cuenta", () => {
    const rows = computeEligibleAutoPricingRows(products, prices, LIST_ID, COND_ID, 0.15);
    // Simula "p1 tildado, p2 destildado" — el payload de p_reset_to_auto lo
    // arma el componente a partir de un Set de selección, nunca de "rows"
    // completo; acá solo confirmamos que ambos quedan disponibles para esa
    // decisión (ninguno se auto-excluye por sí solo).
    expect(rows.map((r) => r.product_id).sort()).toEqual(["p1", "p2"]);
  });

  it("condición BASE desconocida (listConditionId undefined) no rompe — devuelve vacío en vez de fallar", () => {
    expect(computeEligibleAutoPricingRows(products, prices, undefined, COND_ID, 0.15)).toEqual([]);
  });
});
