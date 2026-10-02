/**
 * Resuelve el número nacional argentino (siempre 10 dígitos: área 2-4 +
 * abonado) a partir de cualquier forma en la que alguien haya tipeado un
 * WhatsApp — con o sin código de país, con o sin el 0 de larga distancia,
 * con o sin el "15" histórico de celular, con espacios/guiones/paréntesis.
 *
 * Aislado en su propio archivo para poder testearlo sin levantar
 * lib/utils.ts completo (mismo criterio que lib/precios-sort.ts).
 *
 * Bug real corregido acá: un número ya canónico de 10 dígitos (ej.
 * "2215575069" = área 221 + abonado 5575069) podía perder 2 dígitos si el
 * abonado empezaba casualmente con "15" — la regex vieja no distinguía eso
 * del "15" histórico real. La regla correcta no depende de ninguna
 * característica en particular: un nacional argentino SIEMPRE tiene 10
 * dígitos: nunca se le saca nada. El formato histórico (área + 15 + abonado)
 * SIEMPRE tiene 12: ahí, y solo ahí, tiene sentido buscar el "15" a sacar.
 */

/**
 * Converge cualquier variante a un "candidato nacional": saca el código de
 * país (54) y el 9 de celular si están, o el 0 de larga distancia si no
 * hay código de país. Ninguna rama corta temprano — el candidato siempre
 * sigue de largo hacia la etapa que decide sobre el "15" histórico, sin
 * importar si el input traía código de país o no (ahí estaba el bug de la
 * primera propuesta: la rama "54" hacía return antes de llegar a esa etapa).
 */
function toNationalCandidate(digits: string): string {
  if (digits.startsWith("54")) {
    const rest = digits.slice(2);
    return rest.startsWith("9") ? rest.slice(1) : rest;
  }
  return digits.replace(/^0/, "");
}

/**
 * El "15" histórico (área + 15 + abonado) solo se intenta sacar cuando el
 * candidato tiene EXACTAMENTE 12 dígitos — nunca si ya son 10. Un candidato
 * de 12 dígitos que, sacando el "15", no quede en exactamente 10, se
 * devuelve sin tocar (no es el patrón esperado, no se fuerza nada).
 */
function stripHistoricalFifteen(candidate: string): string {
  if (candidate.length !== 12) return candidate;
  const withoutFifteen = candidate.replace(/^(\d{2,4})15/, "$1");
  return withoutFifteen.length === 10 ? withoutFifteen : candidate;
}

/** Número nacional argentino (10 dígitos) o null si no se puede resolver uno válido. */
export function resolveArgentinaNationalNumber(raw: string | null | undefined): string | null {
  const digits = raw?.replace(/\D/g, "") ?? "";
  if (!digits) return null;

  const candidate = stripHistoricalFifteen(toNationalCandidate(digits));
  return candidate.length === 10 ? candidate : null;
}

/**
 * Número completo para wa.me (549 + nacional de 10 dígitos). Null si no se
 * pudo resolver un nacional válido — nunca fabrica un número a partir de
 * una longitud que no corresponde a ningún formato argentino real.
 */
export function resolveArgentinaWhatsAppNumber(raw: string | null | undefined): string | null {
  const national = resolveArgentinaNationalNumber(raw);
  return national ? `549${national}` : null;
}
