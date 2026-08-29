/**
 * fetch() con un techo duro de tiempo — sin esto, una llamada a Supabase
 * (Auth o la base) que tarda de más deja al navegador esperando sin ningún
 * límite: eso es exactamente lo que se percibe como "la navegación se
 * cuelga". Se usa como el `fetch` de todos los clientes Supabase de la app
 * (proxy.ts corre esto en CADA navegación, así que es el punto más crítico).
 *
 * Al vencer el timeout se aborta la request — supabase-js recibe un error
 * de fetch normal (AbortError), no una promesa que nunca resuelve. El
 * código que ya maneja errores de auth (proxy.ts los trata como "sin
 * sesión", getCurrentProfile ahora también) lo atrapa en vez de quedarse
 * esperando.
 */
export function fetchWithTimeout(timeoutMs: number): typeof fetch {
  return (input, init) => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);

    // supabase-js no manda su propia signal hoy, pero por las dudas: si
    // alguna vez lo hace, que cualquiera de las dos (la del caller o la
    // nuestra) pueda abortar.
    const externalSignal = init?.signal;
    if (externalSignal) {
      if (externalSignal.aborted) controller.abort();
      else externalSignal.addEventListener("abort", () => controller.abort(), { once: true });
    }

    return fetch(input, { ...init, signal: controller.signal }).finally(() => clearTimeout(timeout));
  };
}
