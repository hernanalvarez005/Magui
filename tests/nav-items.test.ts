import { describe, expect, it } from "vitest";

import { navItems } from "@/components/layout/nav-items";

// MAGUI REJUVE — BLOQUE FINAL, sección 3 (mover "Precios" en la navegación
// de vendedoras). navItems es una única lista compartida entre roles
// (filtrada por `roles` en app-shell.tsx, nunca duplicada) — estos tests
// verifican el ORDEN dentro de esa lista, que es lo que determina el orden
// visual real en la sidebar/nav.
describe("navItems — orden de navegación (sección 3 del pedido)", () => {
  it("Precios queda INMEDIATAMENTE debajo de Nueva venta", () => {
    const nuevaVentaIdx = navItems.findIndex((i) => i.href === "/ventas/nueva");
    const preciosIdx = navItems.findIndex((i) => i.href === "/precios");
    expect(nuevaVentaIdx).toBeGreaterThanOrEqual(0);
    expect(preciosIdx).toBe(nuevaVentaIdx + 1);
  });

  it("no hay una entrada de Precios duplicada", () => {
    const preciosEntries = navItems.filter((i) => i.href === "/precios");
    expect(preciosEntries).toHaveLength(1);
  });

  it("Precios sigue visible para los 3 roles (sin filtro `roles`, igual que antes)", () => {
    const precios = navItems.find((i) => i.href === "/precios")!;
    expect(precios.roles).toBeUndefined();
  });

  it("el resto de la navegación no se duplicó (cada href aparece una sola vez)", () => {
    const hrefs = navItems.map((i) => i.href);
    expect(new Set(hrefs).size).toBe(hrefs.length);
  });
});
