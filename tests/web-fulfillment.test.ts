import { describe, expect, it } from "vitest";

import {
  computeRequiresPaymentAccountNow,
  paymentMethodRequiresBilling,
  resolveFulfillmentLocationId,
  resolveFulfillmentType,
} from "@/lib/sales/web-fulfillment";

// BLOQUE C (circuito Ventas Web) — reglas puras de Nueva Venta Web.
// Ver informe entregado al usuario para el detalle de UX/flujo completo.

describe("resolveFulfillmentType", () => {
  it("PICKUP_25 y PICKUP_37 resuelven a PICKUP", () => {
    expect(resolveFulfillmentType("PICKUP_25")).toBe("PICKUP");
    expect(resolveFulfillmentType("PICKUP_37")).toBe("PICKUP");
  });
  it("SHIPPING resuelve a SHIPPING", () => {
    expect(resolveFulfillmentType("SHIPPING")).toBe("SHIPPING");
  });
  it("sin elegir nada, resuelve null (nunca un default implícito)", () => {
    expect(resolveFulfillmentType("")).toBeNull();
  });
});

describe("resolveFulfillmentLocationId", () => {
  const locations = [
    { id: "id-25", code: "SED-25" },
    { id: "id-37", code: "SED-37" },
    { id: "id-dep", code: "DEP" },
  ];

  it("PICKUP_25 resuelve al id de SED-25, nunca a otra sede", () => {
    expect(resolveFulfillmentLocationId("PICKUP_25", locations)).toBe("id-25");
  });
  it("PICKUP_37 resuelve al id de SED-37", () => {
    expect(resolveFulfillmentLocationId("PICKUP_37", locations)).toBe("id-37");
  });
  it("SHIPPING resuelve SIEMPRE a Depósito, nunca a una sede de retiro", () => {
    expect(resolveFulfillmentLocationId("SHIPPING", locations)).toBe("id-dep");
  });
  it("sin elegir nada, no resuelve ninguna sede", () => {
    expect(resolveFulfillmentLocationId("", locations)).toBeUndefined();
  });
  it("si el usuario no tiene acceso a la sede necesaria, devuelve undefined (nunca inventa un id)", () => {
    expect(resolveFulfillmentLocationId("SHIPPING", [{ id: "id-25", code: "SED-25" }])).toBeUndefined();
  });
});

describe("computeRequiresPaymentAccountNow", () => {
  it("venta presencial con medio de pago que factura: sigue exigiendo cuenta (sin cambios)", () => {
    expect(computeRequiresPaymentAccountNow({ requiresBilling: true, isWeb: false, paymentStatus: "PAID" })).toBe(true);
  });
  it("medio de pago que no factura (efectivo): nunca exige cuenta, sea Web o no", () => {
    expect(computeRequiresPaymentAccountNow({ requiresBilling: false, isWeb: true, paymentStatus: "PENDING" })).toBe(false);
  });
  it("pedido Web ya PAGADO: sigue exigiendo cuenta igual que una venta presencial", () => {
    expect(computeRequiresPaymentAccountNow({ requiresBilling: true, isWeb: true, paymentStatus: "PAID" })).toBe(true);
  });
  it("pedido Web PENDIENTE de cobro: NO exige la cuenta todavía — se completa al cobrar", () => {
    expect(computeRequiresPaymentAccountNow({ requiresBilling: true, isWeb: true, paymentStatus: "PENDING" })).toBe(false);
  });
});

describe("paymentMethodRequiresBilling", () => {
  it("Transferencia/1 pago/3 cuotas facturan", () => {
    expect(paymentMethodRequiresBilling("TRANSFER")).toBe(true);
    expect(paymentMethodRequiresBilling("CARD_1")).toBe(true);
    expect(paymentMethodRequiresBilling("CARD_3")).toBe(true);
  });
  it("Efectivo no factura", () => {
    expect(paymentMethodRequiresBilling("CASH")).toBe(false);
  });
  it("sin medio de pago elegido todavía, no factura (nunca undefined = true)", () => {
    expect(paymentMethodRequiresBilling(undefined)).toBe(false);
    expect(paymentMethodRequiresBilling(null)).toBe(false);
  });
});
