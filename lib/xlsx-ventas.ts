// Nota deliberada: a diferencia de lib/csv.ts, este módulo NO importa
// "server-only" — sus funciones son puras (sin I/O, sin secretos) y las
// cubre tests/xlsx-ventas.test.ts con vitest, que corre en Node plano sin
// las condiciones de resolución de Next.js. "server-only" siempre lanza
// fuera de ese contexto (ver node_modules/server-only/index.js), así que
// marcarlo acá haría fallar los tests. El route handler que sí es
// server-only (app/api/export/ventas/route.ts) es el único llamador real.
import ExcelJS from "exceljs";

import { saleStatusLabel } from "@/lib/utils";
import type { SaleStatus } from "@/types/database";

export interface VentaExportProduct {
  name: string;
  quantity: number;
}

export interface VentaExportRow {
  /** ISO timestamp de sales.sold_at. */
  soldAt: string;
  saleNumber: string;
  customerName: string | null;
  customerDni: string | null;
  /** Ya agrupados por producto (un kit ES un product_id propio — nunca se explota a componentes). */
  products: VentaExportProduct[];
  paymentMethodName: string | null;
  accountName: string | null;
  total: number;
  locationName: string | null;
  sellerName: string | null;
  doctorName: string | null;
  status: SaleStatus;
}

const COLUMNS: { header: string; key: string; width: number }[] = [
  { header: "Fecha", key: "fecha", width: 18 },
  { header: "N° de venta", key: "saleNumber", width: 22 },
  { header: "Cliente", key: "cliente", width: 26 },
  { header: "DNI", key: "dni", width: 14 },
  { header: "Productos", key: "productos", width: 50 },
  { header: "Forma de pago", key: "formaPago", width: 18 },
  { header: "Cuenta", key: "cuenta", width: 18 },
  { header: "Importe", key: "importe", width: 14 },
  { header: "Sede", key: "sede", width: 16 },
  { header: "Vendedora", key: "vendedora", width: 20 },
  { header: "Dra.", key: "dra", width: 20 },
  { header: "Estado", key: "estado", width: 16 },
];

/** "2" -> "2", "2.50" -> "2.5", "1.00" -> "1" — cantidades enteras no muestran decimales de más. */
function formatQuantity(quantity: number): string {
  if (Number.isInteger(quantity)) return String(quantity);
  return quantity.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

/** "2x Serum Vitamina C | 1x Crema Antiage" — una sola celda descriptiva por venta. */
export function formatProductsCell(products: VentaExportProduct[]): string {
  return products.map((p) => `${formatQuantity(p.quantity)}x ${p.name}`).join(" | ");
}

export interface SaleItemForExport {
  sale_id: string;
  product_id: string;
  quantity: number | string;
}

/**
 * Agrupa sale_items COMERCIALES (nunca sale_item_net — eso es neto de
 * devoluciones, un concepto distinto — ni kit_components: un kit nunca se
 * explota, es su propio product_id) por venta y producto, sumando
 * cantidades. Un mismo producto puede tener más de una línea dentro de la
 * misma venta (ej. una promoción 3x2 parte el producto en "gratis" +
 * "pagas en grupo" + "excedente", migración 064) — acá quedan sumadas en
 * una sola entrada, para no repetir el producto en la celda de Productos.
 */
export function groupProductsBySale(
  items: SaleItemForExport[],
  productNameById: Map<string, string>
): Map<string, VentaExportProduct[]> {
  const bySale = new Map<string, Map<string, number>>();
  for (const item of items) {
    let bucket = bySale.get(item.sale_id);
    if (!bucket) {
      bucket = new Map();
      bySale.set(item.sale_id, bucket);
    }
    const name = productNameById.get(item.product_id) ?? "";
    bucket.set(name, (bucket.get(name) ?? 0) + Number(item.quantity));
  }

  const result = new Map<string, VentaExportProduct[]>();
  for (const [saleId, productMap] of bySale) {
    result.set(
      saleId,
      Array.from(productMap.entries())
        .map(([name, quantity]) => ({ name, quantity }))
        // Orden determinístico (alfabético) — no depende del orden en que
        // Supabase devuelva las filas de sale_items.
        .sort((a, b) => a.name.localeCompare(b.name, "es"))
    );
  }
  return result;
}

/**
 * Convierte un timestamp ISO a un Date "de pared" en horario de Buenos
 * Aires, pero construido con componentes UTC — así lo escribe ExcelJS
 * (usa los getters UTC del Date para armar el serial de fecha de Excel).
 * Sin este truco, la celda mostraría la hora en el huso horario del
 * proceso que generó el archivo, no la hora de negocio real de la venta
 * (mismo criterio que todayInBuenosAires() en lib/utils.ts).
 */
export function buenosAiresExcelDate(iso: string): Date {
  const date = new Date(iso);
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? "0");
  return new Date(Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), 0));
}

/**
 * Arma el workbook completo de /api/export/ventas: una fila por venta, en
 * el orden de columnas pedido. Fecha tipada como fecha real, Importe como
 * número real, DNI forzado a texto (evita que Excel le recorte ceros a la
 * izquierda o lo pase a notación científica), autofiltro sobre el rango
 * completo, primera fila congelada. Estado usa saleStatusLabel — misma
 * fuente de verdad que el badge del listado en pantalla.
 */
export async function buildVentasWorkbook(rows: VentaExportRow[]): Promise<ExcelJS.Workbook> {
  const workbook = new ExcelJS.Workbook();
  const sheet = workbook.addWorksheet("Ventas");
  sheet.columns = COLUMNS;

  for (const row of rows) {
    sheet.addRow({
      fecha: buenosAiresExcelDate(row.soldAt),
      saleNumber: row.saleNumber,
      cliente: row.customerName ?? "",
      dni: row.customerDni ?? "",
      productos: formatProductsCell(row.products),
      formaPago: row.paymentMethodName ?? "",
      cuenta: row.accountName ?? "",
      importe: row.total,
      sede: row.locationName ?? "",
      vendedora: row.sellerName ?? "",
      dra: row.doctorName ?? "",
      estado: saleStatusLabel(row.status),
    });
  }

  const columnIndex = (key: string) => COLUMNS.findIndex((c) => c.key === key) + 1;
  sheet.getColumn(columnIndex("fecha")).numFmt = "dd/mm/yyyy hh:mm";
  sheet.getColumn(columnIndex("importe")).numFmt = "#,##0.00";
  // '@' = formato Texto: DNI nunca se reinterpreta como número al reabrir/editar.
  sheet.getColumn(columnIndex("dni")).numFmt = "@";

  sheet.getRow(1).font = { bold: true };
  sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: COLUMNS.length } };
  sheet.views = [{ state: "frozen", ySplit: 1 }];

  return workbook;
}

export function xlsxResponse(filename: string, buffer: ExcelJS.Buffer): Response {
  return new Response(buffer, {
    headers: {
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename="${filename}"`,
    },
  });
}
