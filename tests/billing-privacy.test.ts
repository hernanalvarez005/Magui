import { describe, expect, it } from "vitest";

import {
  HIDE_HOME_BILLING_AMOUNTS_KEY,
  MASKED_AMOUNT_PLACEHOLDER,
  displayAmount,
  readHideBillingAmounts,
  writeHideBillingAmounts,
} from "@/lib/dashboard/billing-privacy";

// Ajuste UX — Ocultar/mostrar importes de Facturación en Inicio. Reglas
// puras (lectura/escritura de la preferencia + qué texto mostrar), sin
// depender de `window` real — se le pasa un mock de Storage.

function fakeStorage(initial: Record<string, string> = {}) {
  const store = { ...initial };
  return {
    getItem: (key: string) => (key in store ? store[key] : null),
    setItem: (key: string, value: string) => {
      store[key] = value;
    },
    _store: store,
  };
}

describe("readHideBillingAmounts", () => {
  it("sin storage (ej. SSR), devuelve false", () => {
    expect(readHideBillingAmounts(null)).toBe(false);
    expect(readHideBillingAmounts(undefined)).toBe(false);
  });

  it("sin ninguna preferencia guardada todavía, devuelve false (visible por defecto)", () => {
    expect(readHideBillingAmounts(fakeStorage())).toBe(false);
  });

  it("con 'true' guardado, devuelve true", () => {
    expect(readHideBillingAmounts(fakeStorage({ [HIDE_HOME_BILLING_AMOUNTS_KEY]: "true" }))).toBe(true);
  });

  it("con 'false' guardado, devuelve false", () => {
    expect(readHideBillingAmounts(fakeStorage({ [HIDE_HOME_BILLING_AMOUNTS_KEY]: "false" }))).toBe(false);
  });

  it("si getItem tira una excepción (modo privado, storage deshabilitado), devuelve false sin romper", () => {
    const throwingStorage = {
      getItem: () => {
        throw new Error("SecurityError");
      },
    };
    expect(readHideBillingAmounts(throwingStorage)).toBe(false);
  });
});

describe("writeHideBillingAmounts", () => {
  it("persiste 'true'/'false' como string bajo la clave esperada", () => {
    const storage = fakeStorage();
    writeHideBillingAmounts(storage, true);
    expect(storage._store[HIDE_HOME_BILLING_AMOUNTS_KEY]).toBe("true");
    writeHideBillingAmounts(storage, false);
    expect(storage._store[HIDE_HOME_BILLING_AMOUNTS_KEY]).toBe("false");
  });

  it("sin storage, no rompe (no-op)", () => {
    expect(() => writeHideBillingAmounts(null, true)).not.toThrow();
    expect(() => writeHideBillingAmounts(undefined, true)).not.toThrow();
  });

  it("si setItem tira una excepción (cuota llena), no rompe", () => {
    const throwingStorage = {
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
    };
    expect(() => writeHideBillingAmounts(throwingStorage, true)).not.toThrow();
  });
});

describe("displayAmount", () => {
  it("oculto: siempre el mismo placeholder, sin importar el importe real", () => {
    expect(displayAmount("$ 123.456,78", true)).toBe(MASKED_AMOUNT_PLACEHOLDER);
    expect(displayAmount("$ 0,00", true)).toBe(MASKED_AMOUNT_PLACEHOLDER);
  });

  it("visible: devuelve el importe formateado tal cual", () => {
    expect(displayAmount("$ 123.456,78", false)).toBe("$ 123.456,78");
  });
});
