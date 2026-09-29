import { describe, expect, it } from "vitest";

import { sortConditionsForMatrix } from "@/lib/pricing/condition-order";

// Checkpoint Final, Hallazgo C: la Matriz admin ordenaba condiciones con
// CONDITION_ORDER.indexOf(code) — un code no listado daba -1, que ordena
// ANTES que "Lista" (bug real, ya había pasado una vez con CARD_1). Se
// reemplaza por orden data-driven (rule_type='BASE' ancla primero, el resto
// por priority ascendente) — nunca una lista de codes que mantener a mano.

function cond(code: string, rule_type: string, priority: number) {
  return { code, rule_type, priority };
}

describe("sortConditionsForMatrix", () => {
  it("Lista (BASE) siempre queda primera, sin importar su priority numérica", () => {
    const result = sortConditionsForMatrix([
      cond("CASH", "PAYMENT_METHOD", 3),
      cond("LIST", "BASE", 9), // priority más alta de todas -> sin el pin explícito, quedaría última
      cond("TRANSFER", "PAYMENT_METHOD", 4),
    ]);
    expect(result[0].code).toBe("LIST");
  });

  it("el resto se ordena por priority ascendente (misma semántica que fn_pricing_quote)", () => {
    const result = sortConditionsForMatrix([
      cond("CARD_1", "PAYMENT_METHOD", 6),
      cond("CASH", "PAYMENT_METHOD", 3),
      cond("LIST", "BASE", 9),
      cond("TRANSFER", "PAYMENT_METHOD", 4),
      cond("INSTALLMENTS_6", "PAYMENT_METHOD", 7),
    ]);
    expect(result.map((c) => c.code)).toEqual(["LIST", "CASH", "TRANSFER", "CARD_1", "INSTALLMENTS_6"]);
  });

  it("una condición futura (code desconocido) se ordena por su priority real — nunca antes de Lista por defecto ni al final por desconocida", () => {
    const result = sortConditionsForMatrix([
      cond("LIST", "BASE", 9),
      cond("CASH", "PAYMENT_METHOD", 3),
      cond("PC-9cuotas", "PAYMENT_METHOD", 8), // condición nueva, auto-placement la deja justo antes de Lista
    ]);
    expect(result.map((c) => c.code)).toEqual(["LIST", "CASH", "PC-9cuotas"]);
    // Sobre todo: nunca -1 ganando por indexOf ausente (el bug original).
    expect(result[0].code).not.toBe("PC-9cuotas");
  });

  it("2 cuotas sin interés (code autogenerado) se ordena entre Lista y las demás según su priority real, sin agregarlo a ninguna lista", () => {
    const result = sortConditionsForMatrix([
      cond("LIST", "BASE", 9),
      cond("INSTALLMENTS_6", "PAYMENT_METHOD", 7),
      cond("PC-2cuotas", "PAYMENT_METHOD", 8),
    ]);
    expect(result.map((c) => c.code)).toEqual(["LIST", "INSTALLMENTS_6", "PC-2cuotas"]);
  });

  it("no muta el array original", () => {
    const input = [cond("LIST", "BASE", 9), cond("CASH", "PAYMENT_METHOD", 3)];
    const originalOrder = input.map((c) => c.code);
    sortConditionsForMatrix(input);
    expect(input.map((c) => c.code)).toEqual(originalOrder);
  });
});
