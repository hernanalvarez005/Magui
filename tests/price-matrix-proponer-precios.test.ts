import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

// MAGUI REJUVE — BLOQUE FINAL, sección 4 (eliminar "Proponer precios" de
// Administración > Precios). No se puede montar PriceMatrix acá (usa
// createClient/useRouter del entorno Next) — se audita el código fuente
// directamente: la funcionalidad vieja (botón/estado/función) tiene que
// haber desaparecido POR COMPLETO, y el motor automático (Efectivo/
// Transferencia + edición manual) tiene que seguir intacto — ver
// tests/discount-suggestion.test.ts y tests/price-matrix-changes.test.ts
// para la cobertura de ESE cálculo, sin tocar acá.
const source = readFileSync(resolve(__dirname, "../components/admin/price-matrix.tsx"), "utf-8");

describe("PriceMatrix — 'Proponer precios' eliminado (sección 4 del pedido)", () => {
  it("no queda el texto del botón 'Proponer precios'", () => {
    expect(source).not.toContain("Proponer precios");
  });

  it("no queda la función applyProposal ni su estado (proposeConditionId/proposePercent)", () => {
    expect(source).not.toContain("applyProposal");
    expect(source).not.toContain("proposeConditionId");
    expect(source).not.toContain("proposePercent");
  });

  it("no quedó el import de Wand2 (ícono exclusivo del botón eliminado)", () => {
    expect(source).not.toContain("Wand2");
  });

  it("el cálculo automático desde Lista (Efectivo/Transferencia) sigue presente", () => {
    expect(source).toContain("suggestForProduct");
    expect(source).toContain("handleListChange");
    expect(source).toContain("handlePercentChange");
    expect(source).toContain("suggestDiscountedPrice");
  });

  it("la edición manual y el guardado siguen presentes — ahora vía la RPC única y atómica save_price_matrix_changes (migración 74, Precio de Lista maestro), ya no set_product_price/clear_product_price por celda", () => {
    expect(source).toContain("save_price_matrix_changes");
    expect(source).not.toContain("set_product_price");
    expect(source).not.toContain("clear_product_price");
    expect(source).toContain("handleSave");
  });
});
