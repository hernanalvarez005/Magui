import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

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
 * etc.). wa.me necesita el número en formato internacional sin signos
 * (549 + código de área sin 0 + número sin el 15 que se usaba antes para
 * celulares). Se cubren los casos más comunes de cómo se tipea un celu
 * argentino; si el resultado no abre el chat correcto, se corrige el
 * WhatsApp del cliente en su ficha con el formato completo (+54 9 11...).
 * Null si no hay nada cargado.
 */
export function whatsAppLink(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let digits = raw.replace(/\D/g, "");
  if (digits.length === 0) return null;

  if (digits.startsWith("54")) {
    // Ya viene con código de país. Si es un celu sin el "9" (marcador de
    // móvil que WhatsApp exige para Argentina), se lo agrega.
    const rest = digits.slice(2);
    if (!rest.startsWith("9")) digits = `549${rest}`;
  } else {
    // Sin código de país: se asume número local argentino. Se limpian
    // prefijos que la gente sigue tipeando por costumbre (0 de larga
    // distancia, 15 de celular) antes de anteponer 549.
    digits = digits.replace(/^0/, "").replace(/^(\d{2,4})15/, "$1");
    digits = `549${digits}`;
  }

  return `https://wa.me/${digits}`;
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
