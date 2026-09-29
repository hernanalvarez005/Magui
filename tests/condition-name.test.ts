import { describe, expect, it } from "vitest";

import { resolveDisplayedConditionName } from "@/lib/sales/condition-name";

// Checkpoint Final, Hallazgo A: la ficha de venta debe preferir el snapshot
// histórico (sales.price_condition_name_snapshot, migración 69) sobre el
// nombre vigente de la condición — para no reescribir cómo se muestra una
// venta ya hecha si la condición se renombra después (update_price_condition).

describe("resolveDisplayedConditionName", () => {
  it("venta con snapshot: muestra el snapshot, nunca el nombre vigente", () => {
    expect(
      resolveDisplayedConditionName({
        snapshot: "2 cuotas sin interés",
        liveConditionName: "2 cuotas precio lista", // renombrada después — no debe ganar
      })
    ).toBe("2 cuotas sin interés");
  });

  it("snapshot NULL (venta anterior a la migración 69): usa el fallback del JOIN en vivo", () => {
    expect(
      resolveDisplayedConditionName({
        snapshot: null,
        liveConditionName: "Transferencia",
      })
    ).toBe("Transferencia");
  });

  it("rename posterior no altera el nombre mostrado en una venta con snapshot ya guardado", () => {
    // La venta se hizo cuando la condición se llamaba "2 cuotas sin interés".
    // update_price_condition la renombra después a "2 cuotas promo verano" —
    // el snapshot de esa venta puntual nunca cambia, sigue mostrando el original.
    const atSaleTime = resolveDisplayedConditionName({
      snapshot: "2 cuotas sin interés",
      liveConditionName: "2 cuotas sin interés",
    });
    const afterRename = resolveDisplayedConditionName({
      snapshot: "2 cuotas sin interés", // la columna en sales nunca se reescribe
      liveConditionName: "2 cuotas promo verano", // esto es lo único que cambió
    });
    expect(atSaleTime).toBe("2 cuotas sin interés");
    expect(afterRename).toBe("2 cuotas sin interés");
  });

  it("ambos NULL (100% precio manual, sin condición resuelta, o venta histórica sin condición vigente): null", () => {
    expect(resolveDisplayedConditionName({ snapshot: null, liveConditionName: null })).toBeNull();
    expect(resolveDisplayedConditionName({ snapshot: null, liveConditionName: undefined })).toBeNull();
  });
});
