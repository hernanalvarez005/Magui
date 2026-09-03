"use client";

import { useSyncExternalStore } from "react";

/**
 * true/false según si el viewport matchea el media query dado, actualizado
 * en vivo (resize/rotación). useSyncExternalStore (no useState+useEffect):
 * es exactamente el caso de uso que resuelve — suscribirse a una fuente de
 * verdad externa al render de React (matchMedia) sin el flash de un estado
 * inicial incorrecto ni un setState síncrono dentro de un efecto. Con SSR,
 * el snapshot del servidor es `false` (mobile-first) y se corrige apenas
 * hidrata.
 */
export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const mql = window.matchMedia(query);
      mql.addEventListener("change", onChange);
      return () => mql.removeEventListener("change", onChange);
    },
    () => window.matchMedia(query).matches,
    () => false
  );
}
