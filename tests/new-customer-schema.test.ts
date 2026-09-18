import { describe, expect, it } from "vitest";

import { newCustomerSchema } from "@/lib/validation/sale";

// Cambio 1 (email opcional en Nueva Venta) — reglas puras del schema.
// La persistencia real (null cuando está vacío, sin cambios en la
// deduplicación por DNI) se valida en supabase/tests/database/.

const base = { full_name: "Clienta de prueba" };

describe("newCustomerSchema — email", () => {
  it("email vacío es válido (el campo es opcional)", () => {
    const result = newCustomerSchema.safeParse({ ...base, email: "" });
    expect(result.success).toBe(true);
  });

  it("email ausente es válido (nunca obligatorio)", () => {
    const result = newCustomerSchema.safeParse({ ...base });
    expect(result.success).toBe(true);
  });

  it("email válido pasa la validación", () => {
    const result = newCustomerSchema.safeParse({ ...base, email: "clienta@example.com" });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.email).toBe("clienta@example.com");
    }
  });

  it("email inválido es rechazado", () => {
    const result = newCustomerSchema.safeParse({ ...base, email: "no-es-un-email" });
    expect(result.success).toBe(false);
  });

  it("un DNI o whatsapp ausente no afecta la validación del email (son independientes)", () => {
    const result = newCustomerSchema.safeParse({ ...base, email: "clienta@example.com", dni: "", whatsapp: "" });
    expect(result.success).toBe(true);
  });
});
