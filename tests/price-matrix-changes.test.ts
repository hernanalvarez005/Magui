import { describe, expect, it } from "vitest";

import {
  classifyDirtyPriceCells,
  isPriceCellDirty,
  normalizePriceInput,
} from "@/lib/pricing/price-matrix-changes";

describe("normalizePriceInput", () => {
  it("un valor vacío (o solo espacios) normaliza a 'empty', nunca a 0", () => {
    expect(normalizePriceInput("")).toEqual({ kind: "empty" });
    expect(normalizePriceInput("   ")).toEqual({ kind: "empty" });
  });

  it("un número válido normaliza a 'value'", () => {
    expect(normalizePriceInput("31000")).toEqual({ kind: "value", amount: 31000 });
    expect(normalizePriceInput(" 31000.50 ")).toEqual({ kind: "value", amount: 31000.5 });
  });

  it("texto no numérico, cero o negativo normaliza a 'invalid'", () => {
    expect(normalizePriceInput("abc")).toEqual({ kind: "invalid" });
    expect(normalizePriceInput("0")).toEqual({ kind: "invalid" });
    expect(normalizePriceInput("-100")).toEqual({ kind: "invalid" });
  });
});

describe("isPriceCellDirty", () => {
  it("Caso F: Lista modificada (30000 -> 31000) se detecta como cambio", () => {
    expect(isPriceCellDirty("31000", 30000)).toBe(true);
  });

  it("Caso D/E: Efectivo o Transferencia modificados se detectan igual", () => {
    expect(isPriceCellDirty("38500", 40770)).toBe(true);
  });

  it("Caso B: un precio existente que se deja vacío se detecta como cambio", () => {
    expect(isPriceCellDirty("", 30000)).toBe(true);
  });

  it("Caso C: un campo vacío que recibe un valor se detecta como cambio", () => {
    expect(isPriceCellDirty("30000", undefined)).toBe(true);
    expect(isPriceCellDirty("30000", null)).toBe(true);
  });

  it("sin cambio real: el mismo valor (como string) no se detecta como dirty", () => {
    expect(isPriceCellDirty("30000", 30000)).toBe(false);
  });

  it("un campo que nunca tuvo precio y sigue vacío no es un cambio", () => {
    expect(isPriceCellDirty("", undefined)).toBe(false);
  });

  it("formatos distintos del mismo número (decimales de más) no cuentan como cambio", () => {
    expect(isPriceCellDirty("30000.00", 30000)).toBe(false);
    expect(isPriceCellDirty("  30000  ", 30000)).toBe(false);
  });
});

describe("classifyDirtyPriceCells", () => {
  it("Caso A/F: modificar Lista clasifica en toSave con el monto normalizado", () => {
    const edited = new Map([["p1:list", "31000"]]);
    const original = new Map([["p1:list", 30000]]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([{ key: "p1:list", amount: 31000 }]);
    expect(result.toClear).toEqual([]);
    expect(result.invalid).toEqual([]);
  });

  it("Caso B: borrar un precio existente clasifica en toClear (nunca se guarda $0)", () => {
    const edited = new Map([["p1:cash", ""]]);
    const original = new Map([["p1:cash", 30000]]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toClear).toEqual([{ key: "p1:cash" }]);
    expect(result.toSave).toEqual([]);
  });

  it("Caso C: agregar un precio donde estaba vacío clasifica en toSave", () => {
    const edited = new Map([["p1:transfer", "30000"]]);
    const original = new Map<string, number>(); // no había fila -> "Sin configurar"
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([{ key: "p1:transfer", amount: 30000 }]);
  });

  it("Caso J: un valor recalculado automáticamente que difiere del original también se detecta", () => {
    // Simula lo que hace suggestForProduct(): escribe en `edited` un monto
    // sugerido sin que el admin haya tipeado nada a mano.
    const edited = new Map([["p1:cash", "36000"]]); // sugerido tras subir Lista
    const original = new Map([["p1:cash", 29700]]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([{ key: "p1:cash", amount: 36000 }]);
  });

  it("Caso J+edición manual: el admin corrige el valor sugerido antes de guardar", () => {
    // El Map solo guarda el último valor tipeado — la sugerencia automática
    // (36000) fue sobrescrita por la edición manual posterior (37500).
    const edited = new Map([["p1:cash", "37500"]]);
    const original = new Map([["p1:cash", 29700]]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([{ key: "p1:cash", amount: 37500 }]);
  });

  it("un valor inválido (texto, 0, negativo) se reporta aparte y no se intenta guardar", () => {
    const edited = new Map([["p1:list", "abc"]]);
    const original = new Map([["p1:list", 30000]]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.invalid).toEqual([{ key: "p1:list", rawValue: "abc" }]);
    expect(result.toSave).toEqual([]);
    expect(result.toClear).toEqual([]);
  });

  it("Caso 10: sin cambios reales, las tres listas quedan vacías", () => {
    const edited = new Map([
      ["p1:list", "30000"],
      ["p1:cash", "30000.00"], // mismo valor, formateado distinto
      ["p2:list", ""], // nunca tuvo precio, sigue vacío
    ]);
    const original = new Map([
      ["p1:list", 30000],
      ["p1:cash", 30000],
    ]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([]);
    expect(result.toClear).toEqual([]);
    expect(result.invalid).toEqual([]);
  });

  it("mezcla de varios cambios reales a la vez, cada uno en su grupo correcto", () => {
    const edited = new Map([
      ["p1:list", "31000"], // modificado -> toSave
      ["p1:cash", ""], // borrado -> toClear
      ["p2:transfer", "30000"], // nuevo -> toSave
      ["p3:list", "0"], // inválido -> invalid
      ["p4:list", "30000"], // sin cambio real -> ningún grupo
    ]);
    const original = new Map([
      ["p1:list", 30000],
      ["p1:cash", 29700],
      ["p3:list", 45000],
      ["p4:list", 30000],
    ]);
    const result = classifyDirtyPriceCells(edited, original);
    expect(result.toSave).toEqual([
      { key: "p1:list", amount: 31000 },
      { key: "p2:transfer", amount: 30000 },
    ]);
    expect(result.toClear).toEqual([{ key: "p1:cash" }]);
    expect(result.invalid).toEqual([{ key: "p3:list", rawValue: "0" }]);
  });
});
