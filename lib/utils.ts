import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

import { resolveArgentinaWhatsAppNumber } from "@/lib/argentina-phone";
import type { SaleStatus } from "@/types/database";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

const currencyFormatter = new Intl.NumberFormat("es-AR", {
  style: "currency",
  currency: "ARS",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** Formatea un numeric(14,2) de la DB (viene como string o number) a "$ 45.300,00". */
export function formatCurrency(amount: number | string | null | undefined): string {
  if (amount === null || amount === undefined) return "—";
  const value = typeof amount === "string" ? Number(amount) : amount;
  if (Number.isNaN(value)) return "—";
  return currencyFormatter.format(value);
}

const dateTimeFormatter = new Intl.DateTimeFormat("es-AR", {
  timeZone: "America/Argentina/Buenos_Aires",
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

const dateFormatter = new Intl.DateTimeFormat("es-AR", {
  timeZone: "America/Argentina/Buenos_Aires",
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
});

export function formatDateTime(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const date = typeof value === "string" ? new Date(value) : value;
  if (Number.isNaN(date.getTime())) return "—";
  return dateTimeFormatter.format(date);
}

export function formatDate(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const date = typeof value === "string" ? new Date(value) : value;
  if (Number.isNaN(date.getTime())) return "—";
  return dateFormatter.format(date);
}

/**
 * Arma el link de "click to chat" de WhatsApp (wa.me) a partir de lo que
 * haya cargado en customers.whatsapp — un campo de texto libre, sin formato
 * forzado (se tipea "11 2233-4455", "011-2233-4455", "+54 9 11 2233 4455",
 * etc.). La normalización real vive en resolveArgentinaWhatsAppNumber()
 * (lib/argentina-phone.ts) — acá no se repite ningún algoritmo, solo se arma
 * la URL. Null si no hay nada cargado o si no se pudo resolver un número
 * argentino válido (nunca se fabrica un link a partir de una longitud que
 * no corresponde a ningún formato real).
 */
export function whatsAppLink(raw: string | null | undefined): string | null {
  const number = resolveArgentinaWhatsAppNumber(raw);
  return number ? `https://wa.me/${number}` : null;
}

/**
 * Deja solo dígitos ("32.123.456" o "32 123 456" -> "32123456") — mismo
 * criterio que fn_normalize_dni() en la base. Se usa en el propio onChange
 * de los inputs de DNI (nunca en un onPaste separado: pegar ya dispara
 * onChange, así que alcanza con esto para cubrir escribir y pegar por igual,
 * sin bloquear ningún evento).
 */
export function normalizeDni(value: string): string {
  return value.replace(/[^0-9]/g, "");
}

/**
 * Etiqueta legible de sales.status — única fuente de verdad, reutilizada por
 * el badge del listado de Ventas (components/sales/sales-table.tsx) y por la
 * exportación XLSX (lib/xlsx-ventas.ts), para que ambos lugares digan
 * exactamente lo mismo ante el mismo status. sale-detail-view.tsx usa un
 * texto más descriptivo a propósito para esa pantalla puntual (ej. "Anulada
 * / Reemplazada por cambio") — no comparte esta función porque su contexto
 * (detalle de una venta) amerita más contexto que un badge de tabla o una
 * celda de export.
 */
export function saleStatusLabel(status: SaleStatus): string {
  if (status === "cancelled") return "Cancelada";
  if (status === "replaced") return "Reemplazada";
  if (status === "returned") return "Devuelta";
  if (status === "draft") return "Borrador";
  return "Confirmada";
}

/** Fecha de "hoy" en zona horaria de negocio, como YYYY-MM-DD, para filtros de reportes. */
export function todayInBuenosAires(): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const y = parts.find((p) => p.type === "year")?.value;
  const m = parts.find((p) => p.type === "month")?.value;
  const d = parts.find((p) => p.type === "day")?.value;
  return `${y}-${m}-${d}`;
}
