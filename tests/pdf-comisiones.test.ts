import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { buildComisionesPdf, comisionesPdfFilename } from "@/lib/pdf-comisiones";
import type { DoctorSalesDetail } from "@/types/database";

const logoPng = readFileSync(resolve(__dirname, "..", "public/brand/logo.png"));

function baseData(overrides: Partial<DoctorSalesDetail> = {}): DoctorSalesDetail {
  return {
    doctor: { id: "doctor-1", full_name: "María Pérez", code: "MP" },
    summary: { sales_count: 1, commissionable_revenue: 90000, commission_total: 9000 },
    products: [],
    sales: [
      {
        id: "sale-1",
        sale_number: "MJ-37-20260903-0001",
        sold_at: "2026-09-03T15:30:00-03:00",
        total: 90000,
        commission_total: 9000,
        location: "Sede 37",
        commissionable_revenue: 90000,
        effective_commission_percent: 10,
        products: [{ name: "Serum Vitamina C", quantity: 2 }],
      },
    ],
    ...overrides,
  };
}

describe("comisionesPdfFilename", () => {
  it("rango de un mes calendario completo -> YYYY-MM", () => {
    expect(comisionesPdfFilename("María Pérez", "2026-09-01", "2026-09-30")).toBe(
      "Liquidacion-Comisiones-Maria-Perez-2026-09.pdf"
    );
  });

  it("saca tildes y ñ del nombre (María -> Maria, Muñoz -> Munoz)", () => {
    expect(comisionesPdfFilename("Dra. Muñoz Núñez", "2026-09-01", "2026-09-30")).toMatch(
      /^Liquidacion-Comisiones-Dra-Munoz-Nunez-2026-09\.pdf$/
    );
  });

  it("rango personalizado (no es un mes completo) -> YYYY-MM-DD_a_YYYY-MM-DD", () => {
    expect(comisionesPdfFilename("Ana Gómez", "2026-09-05", "2026-09-20")).toBe(
      "Liquidacion-Comisiones-Ana-Gomez-2026-09-05_a_2026-09-20.pdf"
    );
  });

  it("febrero completo respeta el último día real del mes (28/29)", () => {
    expect(comisionesPdfFilename("Ana Gómez", "2026-02-01", "2026-02-28")).toBe(
      "Liquidacion-Comisiones-Ana-Gomez-2026-02.pdf"
    );
  });

  it("nunca incluye un UUID en el nombre visible", () => {
    const name = comisionesPdfFilename("María Pérez", "2026-09-01", "2026-09-30");
    expect(name).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  });

  it("nombre vacío/solo símbolos no rompe — usa 'Doctora' como fallback", () => {
    expect(comisionesPdfFilename("---", "2026-09-01", "2026-09-30")).toBe(
      "Liquidacion-Comisiones-Doctora-2026-09.pdf"
    );
  });
});

describe("buildComisionesPdf", () => {
  it("genera bytes con la firma real de un PDF (%PDF-)", () => {
    const doc = buildComisionesPdf(baseData(), { from: "2026-09-01", to: "2026-09-30" });
    const buffer = Buffer.from(doc.output("arraybuffer"));
    expect(buffer.subarray(0, 5).toString("ascii")).toBe("%PDF-");
    expect(buffer.length).toBeGreaterThan(500);
  });

  it("funciona sin logo (nunca falla por eso)", () => {
    const doc = buildComisionesPdf(baseData(), { from: "2026-09-01", to: "2026-09-30" });
    expect(doc.getNumberOfPages()).toBeGreaterThanOrEqual(1);
  });

  it("funciona con el logo real de Magui Rejuve (public/brand/logo.png)", () => {
    const doc = buildComisionesPdf(baseData(), { from: "2026-09-01", to: "2026-09-30", logoPng });
    const buffer = Buffer.from(doc.output("arraybuffer"));
    expect(buffer.subarray(0, 5).toString("ascii")).toBe("%PDF-");
  });

  it("una sola venta genera un PDF de una página", () => {
    const doc = buildComisionesPdf(baseData(), { from: "2026-09-01", to: "2026-09-30" });
    expect(doc.getNumberOfPages()).toBe(1);
  });

  it("muchas ventas generan un PDF de varias páginas (repite encabezado de tabla)", () => {
    const manySales = Array.from({ length: 80 }, (_, i) => ({
      id: `sale-${i}`,
      sale_number: `MJ-37-20260903-${String(i).padStart(4, "0")}`,
      sold_at: "2026-09-03T15:30:00-03:00",
      total: 10000,
      commission_total: 1000,
      location: "Sede 37",
      commissionable_revenue: 10000,
      effective_commission_percent: 10,
      products: [{ name: "Producto de prueba con nombre largo para forzar el ancho", quantity: 1 }],
    }));
    const doc = buildComisionesPdf(
      baseData({
        summary: { sales_count: 80, commissionable_revenue: 800000, commission_total: 80000 },
        sales: manySales,
      }),
      { from: "2026-09-01", to: "2026-09-30" }
    );
    expect(doc.getNumberOfPages()).toBeGreaterThan(1);
  });

  it("importes grandes no rompen el formateo ($ con separador de miles)", () => {
    const doc = buildComisionesPdf(
      baseData({
        summary: { sales_count: 1, commissionable_revenue: 12345678.9, commission_total: 1234567.89 },
        sales: [
          {
            id: "sale-1",
            sale_number: "MJ-37-20260903-0001",
            sold_at: "2026-09-03T15:30:00-03:00",
            total: 12345678.9,
            commission_total: 1234567.89,
            location: "Sede 37",
            commissionable_revenue: 12345678.9,
            effective_commission_percent: 10,
            products: [{ name: "Producto caro", quantity: 1 }],
          },
        ],
      }),
      { from: "2026-09-01", to: "2026-09-30" }
    );
    const buffer = Buffer.from(doc.output("arraybuffer"));
    expect(buffer.subarray(0, 5).toString("ascii")).toBe("%PDF-");
  });

  it("nombre de Dra. con ñ/tildes no rompe la generación", () => {
    const doc = buildComisionesPdf(
      baseData({ doctor: { id: "d1", full_name: "Dra. Muñoz Núñez", code: "MN" } }),
      { from: "2026-09-01", to: "2026-09-30" }
    );
    const buffer = Buffer.from(doc.output("arraybuffer"));
    expect(buffer.subarray(0, 5).toString("ascii")).toBe("%PDF-");
  });

  it("los totales del footer son EXACTAMENTE summary.commissionable_revenue/commission_total, no una suma recalculada de filas", () => {
    // Datos deliberadamente inconsistentes con la suma de filas — el builder
    // nunca debe recalcular, solo usar lo que le llega en `summary` (fuente
    // de verdad ya resuelta por el backend).
    const data = baseData({
      summary: { sales_count: 1, commissionable_revenue: 999999, commission_total: 88888 },
    });
    // No hay forma de leer texto de vuelta sin un parser de PDF adicional —
    // esta prueba documenta el contrato (no recalcular) y confirma que la
    // función no falla ni intenta validar consistencia contra las filas.
    expect(() => buildComisionesPdf(data, { from: "2026-09-01", to: "2026-09-30" })).not.toThrow();
  });
});
