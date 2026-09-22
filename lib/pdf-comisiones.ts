// Nota deliberada (mismo criterio que lib/xlsx-ventas.ts): NO importa
// "server-only" — es un módulo puro (sin I/O, sin secretos) cubierto por
// tests/pdf-comisiones.test.ts con vitest en Node plano. El único llamador
// real es app/api/export/comisiones-doctora/[doctorId]/pdf/route.ts, que sí
// es server-only y es quien lee el logo del disco (fs) y se lo pasa como
// bytes — este módulo nunca toca el filesystem.
import { jsPDF } from "jspdf";
import autoTable from "jspdf-autotable";

import { formatCurrency, formatDate } from "@/lib/utils";
import type { DoctorSalesDetail } from "@/types/database";

export interface ComisionesPdfOptions {
  from: string;
  to: string;
  /** Inyectable para tests — default new Date(). Hora de negocio (Buenos Aires) la aplica formatDate. */
  generatedAt?: Date;
  /** Bytes PNG del logo (public/brand/logo.png). Si se omite, el PDF se genera sin logo — nunca falla por esto. */
  logoPng?: Uint8Array;
}

/** "10.00" -> "10,00%" — mismo criterio de coma decimal argentina que formatCurrency. */
function formatPercent(value: number): string {
  return `${value.toFixed(2).replace(".", ",")}%`;
}

/** "2" -> "2", "2.50" -> "2.5" — igual criterio que formatQuantity de lib/xlsx-ventas.ts. */
function formatQuantity(quantity: number): string {
  if (Number.isInteger(quantity)) return String(quantity);
  return quantity.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

/** "2x Serum Vitamina C | 1x Crema Antiage" — mismo criterio que formatProductsCell de lib/xlsx-ventas.ts. */
function formatProductsCell(products: { name: string; quantity: number }[]): string {
  if (products.length === 0) return "—";
  return products.map((p) => `${formatQuantity(p.quantity)}x ${p.name}`).join(" | ");
}

/**
 * "María Pérez", "2026-09-01", "2026-09-30" -> "Liquidacion-Comisiones-Maria-Perez-2026-09.pdf"
 * Sin tildes/ñ ni caracteres no seguros para nombre de archivo, nunca un UUID.
 * Si el rango es exactamente un mes calendario, usa "YYYY-MM"; si no, usa
 * "YYYY-MM-DD_a_YYYY-MM-DD" (rango personalizado).
 */
export function comisionesPdfFilename(doctorFullName: string, from: string, to: string): string {
  const slug =
    doctorFullName
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "") // saca acentos/diacríticos (María -> Maria, así también Ñ vía NFD+combining tilde)
      .replace(/[^a-zA-Z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "Doctora";

  const isFullMonth = (() => {
    const fromDate = new Date(`${from}T00:00:00Z`);
    const toDate = new Date(`${to}T00:00:00Z`);
    if (fromDate.getUTCDate() !== 1) return false;
    const lastDayOfMonth = new Date(Date.UTC(fromDate.getUTCFullYear(), fromDate.getUTCMonth() + 1, 0)).getUTCDate();
    return (
      toDate.getUTCFullYear() === fromDate.getUTCFullYear() &&
      toDate.getUTCMonth() === fromDate.getUTCMonth() &&
      toDate.getUTCDate() === lastDayOfMonth
    );
  })();

  const period = isFullMonth ? from.slice(0, 7) : `${from}_a_${to}`;

  return `Liquidacion-Comisiones-${slug}-${period}.pdf`;
}

const MARGIN = 15;
const PAGE_WIDTH = 210; // A4 mm
const PAGE_HEIGHT = 297;

/**
 * Arma el PDF de liquidación de comisiones a partir de la MISMA estructura
 * que ya devuelve doctor_sales_detail (migración 68) — cero cálculo nuevo
 * acá, solo presentación. TOTAL VENDIDO COMISIONABLE = summary.commissionable_revenue
 * y TOTAL A PAGAR = summary.commission_total, tal cual llegan, nunca sumados
 * a mano sobre las filas.
 */
export function buildComisionesPdf(data: DoctorSalesDetail, options: ComisionesPdfOptions): jsPDF {
  const doc = new jsPDF({ unit: "mm", format: "a4" });
  const generatedAt = options.generatedAt ?? new Date();

  let cursorY = MARGIN;

  if (options.logoPng) {
    try {
      doc.addImage(options.logoPng, "PNG", MARGIN, cursorY, 28, 20);
    } catch {
      // Un logo corrupto/ilegible nunca debe romper la generación de la liquidación.
    }
  }

  const textX = options.logoPng ? MARGIN + 34 : MARGIN;
  doc.setFont("helvetica", "bold");
  doc.setFontSize(18);
  doc.setTextColor(30, 30, 30);
  doc.text("LIQUIDACIÓN DE COMISIONES", textX, cursorY + 8);

  doc.setFont("helvetica", "normal");
  doc.setFontSize(11);
  doc.setTextColor(60, 60, 60);
  doc.text(`Dra. ${data.doctor.full_name}`, textX, cursorY + 16);
  doc.text(`Período: ${formatDate(options.from)} al ${formatDate(options.to)}`, textX, cursorY + 22);
  doc.setFontSize(9);
  doc.setTextColor(120, 120, 120);
  doc.text(`Generado: ${formatDate(generatedAt)}`, textX, cursorY + 28);

  cursorY += 36;
  doc.setDrawColor(210, 210, 210);
  doc.line(MARGIN, cursorY, PAGE_WIDTH - MARGIN, cursorY);
  cursorY += 6;

  const body = data.sales.map((sale) => [
    formatDate(sale.sold_at),
    sale.sale_number,
    formatProductsCell(sale.products),
    formatCurrency(sale.commissionable_revenue),
    formatPercent(sale.effective_commission_percent),
    formatCurrency(sale.commission_total),
  ]);

  autoTable(doc, {
    startY: cursorY,
    margin: { left: MARGIN, right: MARGIN, bottom: 20 },
    head: [["Fecha", "N° de venta", "Productos", "Importe comisionable", "%", "Comisión"]],
    body,
    theme: "grid",
    styles: { font: "helvetica", fontSize: 9, cellPadding: 2.5, textColor: [40, 40, 40] },
    headStyles: { fillColor: [235, 235, 235], textColor: [30, 30, 30], fontStyle: "bold" },
    columnStyles: {
      0: { cellWidth: 22 },
      1: { cellWidth: 26 },
      2: { cellWidth: "auto" },
      3: { cellWidth: 32, halign: "right" },
      4: { cellWidth: 16, halign: "right" },
      5: { cellWidth: 28, halign: "right" },
    },
    showHead: "everyPage",
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- lastAutoTable lo agrega el plugin en runtime, sin tipo propio expuesto.
  const finalY: number = (doc as any).lastAutoTable?.finalY ?? cursorY;
  const totalsHeight = 30;
  let totalsY = finalY + 10;
  if (totalsY + totalsHeight > PAGE_HEIGHT - MARGIN) {
    doc.addPage();
    totalsY = MARGIN;
  }

  doc.setDrawColor(210, 210, 210);
  doc.line(MARGIN, totalsY - 4, PAGE_WIDTH - MARGIN, totalsY - 4);

  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  doc.setTextColor(80, 80, 80);
  doc.text("TOTAL VENDIDO COMISIONABLE", MARGIN, totalsY + 4);
  doc.setFont("helvetica", "bold");
  doc.text(formatCurrency(data.summary.commissionable_revenue), PAGE_WIDTH - MARGIN, totalsY + 4, { align: "right" });

  doc.setFont("helvetica", "bold");
  doc.setFontSize(14);
  doc.setTextColor(20, 20, 20);
  doc.text("TOTAL A PAGAR", MARGIN, totalsY + 16);
  doc.text(formatCurrency(data.summary.commission_total), PAGE_WIDTH - MARGIN, totalsY + 16, { align: "right" });

  const totalPages = doc.getNumberOfPages();
  for (let i = 1; i <= totalPages; i++) {
    doc.setPage(i);
    doc.setFont("helvetica", "normal");
    doc.setFontSize(8);
    doc.setTextColor(150, 150, 150);
    doc.text(`Magui Rejuve — Página ${i} de ${totalPages}`, PAGE_WIDTH / 2, PAGE_HEIGHT - 8, { align: "center" });
  }

  return doc;
}
