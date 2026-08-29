import { createBrowserClient } from "@supabase/ssr";

import { fetchWithTimeout } from "@/lib/supabase/fetch-with-timeout";
import type { Database } from "@/types/database";

/**
 * Cliente Supabase para Client Components. Usa la publishable key (segura para
 * el navegador) — nunca la service_role.
 */
export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    // Ver fetch-with-timeout.ts: un botón (login, confirmar venta, etc.) que
    // queda esperando una respuesta que nunca llega es indistinguible de la
    // app "colgada" para quien lo está usando.
    { global: { fetch: fetchWithTimeout(8000) } }
  );
}
