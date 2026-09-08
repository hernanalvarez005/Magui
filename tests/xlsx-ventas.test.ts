import { describe, expect, it } from "vitest";
import ExcelJS from "exceljs";

import {
  buenosAiresExcelDate,
  buildVentasWorkbook,
  formatProductsCell,
  groupProductsBySale,
  type VentaExportRow,
} from "@/lib/xlsx-ventas";

// Bloque 2 — exportación XLSX de /api/export/ventas. Columnas, en orden:
// Fecha | N° de venta | Cliente | DNI | Productos | Forma de pago | Cuenta |
// Importe | Sede | Vendedora | Dra. | Estado.
const COL = {
  fecha: 1,
  saleNumber: 2,
  cliente: 3,
  dni: 4,
  productos: 5,
  formaPago: 6,
  cuenta: 7,
  importe: 8,
  sede: 9,
  vendedora: 10,
  dra: 11,
  estado: 12,
} as const;

function baseRow(overrides: Partial<VentaExportRow> = {}): VentaExportRow {
  return {
    soldAt: "2026-09-03T15:30:00-03:00",
    saleNumber: "MJ-37-20260903-0001",
    customerName: "Juana Pérez",
    customerDni: "30111222",
    products: [{ name: "Serum Vitamina C", quantity: 2 }],
    paymentMethodName: "Efectivo",
    accountName: null,
    total: 45000,
    locationName: "Sede 37",
    sellerName: "María Vendedora",
    doctorName: "Dra. Gómez",
    status: "confirmed",
    ...overrides,
  };
}

/** Arma el workbook y devuelve la hoja "Ventas" recargada desde el buffer real (round-trip). */
async function buildAndReload(rows: VentaExportRow[]) {
  const workbook = await buildVentasWorkbook(rows);
  const buffer = await workbook.xlsx.writeBuffer();
  const reloaded = new ExcelJS.Workbook();
  await reloaded.xlsx.load(buffer);
  const sheet = reloaded.getWorksheet("Ventas");
  if (!sheet) throw new Error("no se encontró la hoja Ventas");
  return sheet;
}

describe("formatProductsCell — celda descriptiva de Productos", () => {
  it("un solo producto", () => {
    expect(formatProductsCell([{ name: "Serum Vitamina C", quantity: 2 }])).toBe("2x Serum Vitamina C");
  });

  it("múltiples productos se unen con ' | '", () => {
    expect(
      formatProductsCell([
        { name: "Serum Vitamina C", quantity: 2 },
        { name: "Crema Antiage", quantity: 1 },
      ])
    ).toBe("2x Serum Vitamina C | 1x Crema Antiage");
  });

  it("cantidad no entera se muestra sin ceros de más", () => {
    expect(formatProductsCell([{ name: "Aceite corporal", quantity: 1.5 }])).toBe("1.5x Aceite corporal");
  });

  it("sin productos, celda vacía", () => {
    expect(formatProductsCell([])).toBe("");
  });
});

describe("groupProductsBySale — sale_items comerciales, kits sin explotar", () => {
  it("agrupa varias líneas del mismo producto en una sola entrada (ej. split de promoción 3x2)", () => {
    const productNameById = new Map([["prod-1", "Serum Vitamina C"]]);
    const grouped = groupProductsBySale(
      [
        { sale_id: "sale-1", product_id: "prod-1", quantity: "1" }, // gratis
        { sale_id: "sale-1", product_id: "prod-1", quantity: "2" }, // pagas en grupo
        { sale_id: "sale-1", product_id: "prod-1", quantity: "1" }, // excedente
      ],
      productNameById
    );
    expect(grouped.get("sale-1")).toEqual([{ name: "Serum Vitamina C", quantity: 4 }]);
  });

  it("un kit aparece como un único product_id, nunca explotado a componentes", () => {
    const productNameById = new Map([["kit-1", "Kit Rejuvenecimiento"]]);
    const grouped = groupProductsBySale(
      [{ sale_id: "sale-1", product_id: "kit-1", quantity: "1" }],
      productNameById
    );
    expect(grouped.get("sale-1")).toEqual([{ name: "Kit Rejuvenecimiento", quantity: 1 }]);
  });

  it("separa correctamente por venta cuando hay varias", () => {
    const productNameById = new Map([
      ["prod-1", "Serum Vitamina C"],
      ["prod-2", "Crema Antiage"],
    ]);
    const grouped = groupProductsBySale(
      [
        { sale_id: "sale-1", product_id: "prod-1", quantity: "2" },
        { sale_id: "sale-2", product_id: "prod-2", quantity: "1" },
      ],
      productNameById
    );
    expect(grouped.get("sale-1")).toEqual([{ name: "Serum Vitamina C", quantity: 2 }]);
    expect(grouped.get("sale-2")).toEqual([{ name: "Crema Antiage", quantity: 1 }]);
  });

  it("orden alfabético determinístico dentro de una venta", () => {
    const productNameById = new Map([
      ["prod-1", "Serum Vitamina C"],
      ["prod-2", "Aceite corporal"],
    ]);
    const grouped = groupProductsBySale(
      [
        { sale_id: "sale-1", product_id: "prod-1", quantity: "1" },
        { sale_id: "sale-1", product_id: "prod-2", quantity: "1" },
      ],
      productNameById
    );
    expect(grouped.get("sale-1")?.map((p) => p.name)).toEqual(["Aceite corporal", "Serum Vitamina C"]);
  });
});

describe("buenosAiresExcelDate — fecha de pared en horario de negocio", () => {
  it("un timestamp -03:00 se preserva tal cual (no se corre de día)", () => {
    const date = buenosAiresExcelDate("2026-09-03T23:30:00-03:00");
    expect(date.getUTCFullYear()).toBe(2026);
    expect(date.getUTCMonth()).toBe(8); // septiembre, 0-indexed
    expect(date.getUTCDate()).toBe(3);
    expect(date.getUTCHours()).toBe(23);
    expect(date.getUTCMinutes()).toBe(30);
  });

  it("un timestamp UTC se convierte a horario de Buenos Aires (UTC-3)", () => {
    // 02:00 UTC del día 4 = 23:00 del día 3 en Buenos Aires.
    const date = buenosAiresExcelDate("2026-09-04T02:00:00Z");
    expect(date.getUTCDate()).toBe(3);
    expect(date.getUTCHours()).toBe(23);
  });

  it("medianoche no se muestra como '24:00' (guardia contra el bug de ICU)", () => {
    const date = buenosAiresExcelDate("2026-09-03T03:00:00Z"); // 00:00 en Buenos Aires
    expect(date.getUTCHours()).toBe(0);
  });
});

describe("buildVentasWorkbook — estructura del archivo", () => {
  it("encabezados en el orden pedido, cada uno en su columna", async () => {
    const sheet = await buildAndReload([baseRow()]);
    const header = sheet.getRow(1);
    expect(header.getCell(COL.fecha).value).toBe("Fecha");
    expect(header.getCell(COL.saleNumber).value).toBe("N° de venta");
    expect(header.getCell(COL.cliente).value).toBe("Cliente");
    expect(header.getCell(COL.dni).value).toBe("DNI");
    expect(header.getCell(COL.productos).value).toBe("Productos");
    expect(header.getCell(COL.formaPago).value).toBe("Forma de pago");
    expect(header.getCell(COL.cuenta).value).toBe("Cuenta");
    expect(header.getCell(COL.importe).value).toBe("Importe");
    expect(header.getCell(COL.sede).value).toBe("Sede");
    expect(header.getCell(COL.vendedora).value).toBe("Vendedora");
    expect(header.getCell(COL.dra).value).toBe("Dra.");
    expect(header.getCell(COL.estado).value).toBe("Estado");
  });

  it("una fila por venta", async () => {
    const sheet = await buildAndReload([
      baseRow({ saleNumber: "MJ-37-1" }),
      baseRow({ saleNumber: "MJ-37-2" }),
    ]);
    expect(sheet.rowCount).toBe(3); // encabezado + 2 ventas
  });

  it("venta normal: todas las columnas con el valor esperado", async () => {
    const sheet = await buildAndReload([baseRow()]);
    const row = sheet.getRow(2);
    expect(row.getCell(COL.saleNumber).value).toBe("MJ-37-20260903-0001");
    expect(row.getCell(COL.cliente).value).toBe("Juana Pérez");
    expect(row.getCell(COL.dni).value).toBe("30111222");
    expect(row.getCell(COL.productos).value).toBe("2x Serum Vitamina C");
    expect(row.getCell(COL.formaPago).value).toBe("Efectivo");
    expect(row.getCell(COL.sede).value).toBe("Sede 37");
    expect(row.getCell(COL.vendedora).value).toBe("María Vendedora");
    expect(row.getCell(COL.dra).value).toBe("Dra. Gómez");
    expect(row.getCell(COL.estado).value).toBe("Confirmada");
  });

  it("múltiples productos en una venta quedan en una sola celda descriptiva", async () => {
    const sheet = await buildAndReload([
      baseRow({
        products: [
          { name: "Serum Vitamina C", quantity: 2 },
          { name: "Crema Antiage", quantity: 1 },
        ],
      }),
    ]);
    expect(sheet.getRow(2).getCell(COL.productos).value).toBe("2x Serum Vitamina C | 1x Crema Antiage");
  });

  it("kit: aparece como una sola línea con su propio nombre, no explotado", async () => {
    const sheet = await buildAndReload([baseRow({ products: [{ name: "Kit Rejuvenecimiento", quantity: 1 }] })]);
    expect(sheet.getRow(2).getCell(COL.productos).value).toBe("1x Kit Rejuvenecimiento");
  });

  it("cliente sin DNI: celda vacía, no null/undefined literal", async () => {
    const sheet = await buildAndReload([baseRow({ customerDni: null })]);
    expect(sheet.getRow(2).getCell(COL.dni).value).toBe("");
  });

  it("cliente sin identificar: Cliente y DNI vacíos", async () => {
    const sheet = await buildAndReload([baseRow({ customerName: null, customerDni: null })]);
    expect(sheet.getRow(2).getCell(COL.cliente).value).toBe("");
    expect(sheet.getRow(2).getCell(COL.dni).value).toBe("");
  });

  it("efectivo: sin Cuenta, columna vacía", async () => {
    const sheet = await buildAndReload([baseRow({ paymentMethodName: "Efectivo", accountName: null })]);
    const row = sheet.getRow(2);
    expect(row.getCell(COL.formaPago).value).toBe("Efectivo");
    expect(row.getCell(COL.cuenta).value).toBe("");
  });

  it("transferencia con cuenta: columna Cuenta con el nombre real", async () => {
    const sheet = await buildAndReload([
      baseRow({ paymentMethodName: "Transferencia", accountName: "Mercado Pago" }),
    ]);
    const row = sheet.getRow(2);
    expect(row.getCell(COL.formaPago).value).toBe("Transferencia");
    expect(row.getCell(COL.cuenta).value).toBe("Mercado Pago");
  });

  it("tarjeta: forma de pago correcta", async () => {
    const sheet = await buildAndReload([baseRow({ paymentMethodName: "Tarjeta 3 cuotas" })]);
    expect(sheet.getRow(2).getCell(COL.formaPago).value).toBe("Tarjeta 3 cuotas");
  });

  it("vendedora presente", async () => {
    const sheet = await buildAndReload([baseRow({ sellerName: "Ana Vendedora" })]);
    expect(sheet.getRow(2).getCell(COL.vendedora).value).toBe("Ana Vendedora");
  });

  it("Dra. presente", async () => {
    const sheet = await buildAndReload([baseRow({ doctorName: "Dra. Rodríguez" })]);
    expect(sheet.getRow(2).getCell(COL.dra).value).toBe("Dra. Rodríguez");
  });

  it("Dra. ausente: celda vacía", async () => {
    const sheet = await buildAndReload([baseRow({ doctorName: null })]);
    expect(sheet.getRow(2).getCell(COL.dra).value).toBe("");
  });

  it("venta replaced: Estado traducido con la misma fuente que el badge del listado", async () => {
    const sheet = await buildAndReload([baseRow({ status: "replaced" })]);
    expect(sheet.getRow(2).getCell(COL.estado).value).toBe("Reemplazada");
  });

  it("venta cancelled: Estado traducido", async () => {
    const sheet = await buildAndReload([baseRow({ status: "cancelled" })]);
    expect(sheet.getRow(2).getCell(COL.estado).value).toBe("Cancelada");
  });

  it("caracteres ñ/tildes sobreviven intactos (Cliente y Productos)", async () => {
    const sheet = await buildAndReload([
      baseRow({
        customerName: "Ñañez Muñoz, María José",
        products: [{ name: "Peeling de acción rápida (año 1)", quantity: 1 }],
      }),
    ]);
    const row = sheet.getRow(2);
    expect(row.getCell(COL.cliente).value).toBe("Ñañez Muñoz, María José");
    expect(row.getCell(COL.productos).value).toBe("1x Peeling de acción rápida (año 1)");
  });

  it("Importe es un valor numérico real, no un string con '$'", async () => {
    const sheet = await buildAndReload([baseRow({ total: 45300.5 })]);
    const value = sheet.getRow(2).getCell(COL.importe).value;
    expect(typeof value).toBe("number");
    expect(value).toBe(45300.5);
  });

  it("Fecha es un valor de tipo fecha real (round-trip como Date)", async () => {
    const sheet = await buildAndReload([baseRow({ soldAt: "2026-09-03T15:30:00-03:00" })]);
    const value = sheet.getRow(2).getCell(COL.fecha).value;
    expect(value).toBeInstanceOf(Date);
  });

  it("DNI queda con formato de columna Texto ('@') — nunca se reinterpreta como número", async () => {
    const sheet = await buildAndReload([baseRow({ customerDni: "00030111222" })]);
    expect(sheet.getColumn(COL.dni).numFmt).toBe("@");
    // El propio dato conserva los ceros a la izquierda tal cual — es texto,
    // no un número que Excel podría normalizar.
    expect(sheet.getRow(2).getCell(COL.dni).value).toBe("00030111222");
  });

  it("autofiltro cubre el rango completo de columnas", async () => {
    // Antes de escribir/releer, ExcelJS expone el rango como objeto
    // {from, to}; al recargar desde el buffer real vuelve como referencia
    // de rango "A1:L1" (12 columnas: Fecha..Estado) — se valida esta última,
    // que es lo que efectivamente queda escrito en el archivo.
    const sheet = await buildAndReload([baseRow()]);
    expect(sheet.autoFilter).toBe("A1:L1");
  });

  it("primera fila queda congelada", async () => {
    const sheet = await buildAndReload([baseRow()]);
    const view = sheet.views?.[0];
    expect(view).toMatchObject({ state: "frozen", ySplit: 1 });
  });

  it("encabezado en negrita", async () => {
    const sheet = await buildAndReload([baseRow()]);
    expect(sheet.getRow(1).font?.bold).toBe(true);
  });
});
