import { describe, expect, it } from "vitest";

import { normalizeDni } from "@/lib/utils";

// Bloque B — sección 36 del pedido. normalizeDni() es lo que corre en el
// propio onChange del input de DNI (Nueva Venta y ficha de cliente): no hay
// onPaste/onKeyDown separado — pegar (Ctrl+V/Cmd+V/"Pegar" en mobile) ya
// dispara onChange como cualquier otro cambio, así que esta única función
// cubre escribir Y pegar por igual.
describe("normalizeDni — Bloque B (facturación + DNI)", () => {
  it("escribir un DNI ya limpio lo deja igual", () => {
    expect(normalizeDni("30111222")).toBe("30111222");
  });

  it("pegar con puntos (30.111.222) normaliza a solo dígitos", () => {
    expect(normalizeDni("30.111.222")).toBe("30111222");
  });

  it("pegar con espacios (30 111 222) normaliza a solo dígitos", () => {
    expect(normalizeDni("30 111 222")).toBe("30111222");
  });

  it("pegar con puntos y espacios mezclados normaliza igual", () => {
    expect(normalizeDni("30.111 222")).toBe("30111222");
  });

  it("un DNI vacío normaliza a string vacío (nunca rompe)", () => {
    expect(normalizeDni("")).toBe("");
  });
});
