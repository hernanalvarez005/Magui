import { createBrowserClient } from "@supabase/ssr";

import type { Database } from "@/types/database";

/**
 * Cliente Supabase para Client Components. Usa la publishable key (segura para
 * el navegador) — nunca la service_role.
 */
export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!
  );
}
