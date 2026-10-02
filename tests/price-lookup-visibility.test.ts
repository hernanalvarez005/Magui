import { describe, expect, it } from "vitest";

import { isPriceConditionVisibleForRole } from "@/lib/pricing/price-lookup-visibility";

// Ajuste post-release — visible_in_price_lookup afecta EXCLUSIVAMENTE a
// vendedoras (seller/viewer). Administración siempre ve el set completo en
// /precios, independientemente de la columna. BASE siempre visible para
// los tres roles. Nunca mira code/nombre — una condición PAYMENT_METHOD
// futura cae automáticamente bajo la misma regla.
describe("isPriceConditionVisibleForRole", () => {
  const paymentMethod = (visible: boolean) => ({ rule_type: "PAYMENT_METHOD", visible_in_price_lookup: visible });
  const base = (visible: boolean) => ({ rule_type: "BASE", visible_in_price_lookup: visible });

  it("admin + visible=true -> visible", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(true), "admin")).toBe(true);
  });

  it("admin + visible=false -> visible (bypass total)", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(false), "admin")).toBe(true);
  });

  it("seller + visible=true -> visible", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(true), "seller")).toBe(true);
  });

  it("seller + visible=false -> oculto", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(false), "seller")).toBe(false);
  });

  it("viewer + visible=true -> visible (mismo comportamiento que seller)", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(true), "viewer")).toBe(true);
  });

  it("viewer + visible=false -> oculto (mismo comportamiento que seller)", () => {
    expect(isPriceConditionVisibleForRole(paymentMethod(false), "viewer")).toBe(false);
  });

  it("BASE siempre visible para los tres roles, sin importar visible_in_price_lookup", () => {
    for (const role of ["admin", "seller", "viewer"] as const) {
      expect(isPriceConditionVisibleForRole(base(true), role)).toBe(true);
      expect(isPriceConditionVisibleForRole(base(false), role)).toBe(true);
    }
  });

  it("condición PAYMENT_METHOD futura (code desconocido, nunca agregado a ningún allowlist) respeta exactamente la misma regla — nunca mira code/nombre", () => {
    const futura = { rule_type: "PAYMENT_METHOD", visible_in_price_lookup: false };
    expect(isPriceConditionVisibleForRole(futura, "admin")).toBe(true);
    expect(isPriceConditionVisibleForRole(futura, "seller")).toBe(false);
    expect(isPriceConditionVisibleForRole(futura, "viewer")).toBe(false);
  });
});
