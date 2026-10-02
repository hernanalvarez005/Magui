import { describe, expect, it } from "vitest";

import { isDiscountConfigurable, suggestDiscountedPrice } from "@/lib/pricing/discount-suggestion";

// Bloque E — Precios automáticos por porcentaje + edición manual.
// Casos 1, 2, 5 y 6 de la sección 16 del pedido (la sugerencia matemática;
// los casos de persistencia/venta/promoción van en supabase/tests/database).
describe("suggestDiscountedPrice — sugerencia de precio (Bloque E)", () => {
  it("Caso 1: Lista 33.000 + Efectivo 10% -> sugerencia 29.700", () => {
    expect(suggestDiscountedPrice(33000, 10)).toBe(29700);
  });

  it("Caso 2: Lista 33.000 + Transferencia 8% -> sugerencia 30.360", () => {
    expect(suggestDiscountedPrice(33000, 8)).toBe(30360);
  });

  it("Caso 5: cambia la Lista (33.000 -> 40.000) con Efectivo 10% -> nueva sugerencia 36.000", () => {
    expect(suggestDiscountedPrice(40000, 10)).toBe(36000);
  });

  it("Caso 6: cambia el % (10% -> 15%) con Lista 40.000 -> nueva sugerencia 34.000", () => {
    expect(suggestDiscountedPrice(40000, 15)).toBe(34000);
  });

  it("0% de descuento devuelve exactamente la Lista", () => {
    expect(suggestDiscountedPrice(45300, 0)).toBe(45300);
  });

  it("redondea a 2 decimales", () => {
    expect(suggestDiscountedPrice(10000, 33)).toBe(6700);
    expect(suggestDiscountedPrice(999, 10)).toBe(899.1);
  });

  // Paridad preview (frontend) <-> fn_recalculate_auto_prices (SQL,
  // migración 74): round(lista * (1 - %), 2) en numeric de Postgres —
  // decimal exacto, redondea mitades lejos de cero. Para montos siempre
  // positivos (todo este dominio) coincide con Math.round de JS, que
  // también redondea mitades hacia +Infinity = lejos de cero en positivos.
  // Verificado empíricamente contra psql (round(numeric, 2)) para estos 4
  // casos, incluido un empate exacto en el 3er decimal (123457 x 12.5% =
  // 108024.875, redondea a .88 en ambos lados) — documentado acá en vez de
  // cambiar la fórmula, porque ya son matemáticamente idénticos.
  it("paridad con SQL: 100000 x 15% = 85000 (sin decimales, caso trivial)", () => {
    expect(suggestDiscountedPrice(100000, 15)).toBe(85000);
  });

  it("paridad con SQL: 99999 x 15% = 84999.15", () => {
    expect(suggestDiscountedPrice(99999, 15)).toBe(84999.15);
  });

  it("paridad con SQL: 123457 x 12.5% = 108024.88 (empate exacto en el 3er decimal, .875 -> redondea lejos de cero)", () => {
    expect(suggestDiscountedPrice(123457, 12.5)).toBe(108024.88);
  });

  it("paridad con SQL: 87543 x 7.25% = 81196.13", () => {
    expect(suggestDiscountedPrice(87543, 7.25)).toBe(81196.13);
  });
});

// Checkpoint Precios — reemplaza SUGGESTABLE_CODES (allowlist hardcodeada
// ["CASH", "TRANSFER"]) en /admin/precios por un criterio data-driven:
// rule_type === "PAYMENT_METHOD" exacto, sin importar code/nombre. Migración
// 74 (recálculo automático AUTO/MANUAL): el backend usa el mismo criterio
// exacto para decidir qué participa de la cascada — antes el frontend era
// más laxo ("!== BASE"), ahora ambos coinciden a propósito.
describe("isDiscountConfigurable", () => {
  it("BASE (Lista) nunca tiene % propio", () => {
    expect(isDiscountConfigurable({ rule_type: "BASE" })).toBe(false);
  });

  it("CASH y TRANSFER (ya lo tenían) siguen pudiendo configurarlo", () => {
    expect(isDiscountConfigurable({ rule_type: "PAYMENT_METHOD" })).toBe(true);
  });

  it("una condición de cuotas (CARD_1/3/6, antes excluida por no estar en el allowlist) también puede", () => {
    expect(isDiscountConfigurable({ rule_type: "PAYMENT_METHOD" })).toBe(true);
  });

  it("una condición futura con rule_type PAYMENT_METHOD (code desconocido, nunca agregado a ningún allowlist) también puede — demuestra que es data-driven", () => {
    expect(isDiscountConfigurable({ rule_type: "PAYMENT_METHOD" })).toBe(true);
  });

  it("QUANTITY no muestra % ni participa del recálculo automático — mismo criterio exacto que el backend", () => {
    expect(isDiscountConfigurable({ rule_type: "QUANTITY" })).toBe(false);
  });
});
