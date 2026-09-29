import { describe, expect, it } from "vitest";

import { resolveWebOrderFulfillmentType, webOrderSchema } from "@/lib/validation/web-order";

// Checkpoint 2.1 — circuito de pago/facturación de POST /api/integrations/web-orders.
// Ver lib/validation/web-order.ts y la migración 20260201000071.

const basePayload = {
  external_source: "test-integration",
  external_order_id: "ORDER-001",
  location_id: "00000000-0000-4000-8000-000000000001",
  payment_method_id: "00000000-0000-4000-8000-000000000002",
  items: [{ product_id: "00000000-0000-4000-8000-000000000003", quantity: 1 }],
};

describe("webOrderSchema", () => {
  it("acepta un payload histórico, sin ninguno de los campos nuevos (retrocompatibilidad)", () => {
    const parsed = webOrderSchema.safeParse(basePayload);
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.payment_status).toBeUndefined();
      expect(parsed.data.payment_account_id).toBeUndefined();
    }
  });

  it("acepta payment_status=PENDING sin payment_account_id", () => {
    const parsed = webOrderSchema.safeParse({ ...basePayload, payment_status: "PENDING" });
    expect(parsed.success).toBe(true);
  });

  it("acepta payment_status=PENDING con payment_account_id informado (fn_create_sale_core ya lo admite tal cual)", () => {
    const parsed = webOrderSchema.safeParse({
      ...basePayload,
      payment_status: "PENDING",
      payment_account_id: "00000000-0000-4000-8000-000000000004",
    });
    expect(parsed.success).toBe(true);
  });

  it("acepta payment_status=PAID con payment_account_id", () => {
    const parsed = webOrderSchema.safeParse({
      ...basePayload,
      payment_status: "PAID",
      payment_account_id: "00000000-0000-4000-8000-000000000004",
    });
    expect(parsed.success).toBe(true);
  });

  it("rechaza payment_status=PAID sin payment_account_id, con un mensaje claro", () => {
    const parsed = webOrderSchema.safeParse({ ...basePayload, payment_status: "PAID" });
    expect(parsed.success).toBe(false);
    if (!parsed.success) {
      expect(parsed.error.issues[0]?.path).toEqual(["payment_account_id"]);
      expect(parsed.error.issues[0]?.message).toMatch(/payment_account_id/);
    }
  });

  it("rechaza un payment_status fuera del enum", () => {
    const parsed = webOrderSchema.safeParse({ ...basePayload, payment_status: "REFUNDED" });
    expect(parsed.success).toBe(false);
  });

  it("sigue rechazando un payload sin items", () => {
    const parsed = webOrderSchema.safeParse({ ...basePayload, items: [] });
    expect(parsed.success).toBe(false);
  });
});

describe("resolveWebOrderFulfillmentType", () => {
  it("resuelve SHIPPING cuando el payload declara payment_status", () => {
    expect(resolveWebOrderFulfillmentType({ payment_status: "PENDING" })).toBe("SHIPPING");
    expect(resolveWebOrderFulfillmentType({ payment_status: "PAID" })).toBe("SHIPPING");
  });

  it("resuelve null (comportamiento histórico) cuando el payload no declara payment_status", () => {
    expect(resolveWebOrderFulfillmentType({ payment_status: undefined })).toBeNull();
  });
});
