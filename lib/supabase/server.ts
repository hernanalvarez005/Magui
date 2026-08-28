import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import { createClient as createSupabaseJsClient } from "@supabase/supabase-js";

import type { Database } from "@/types/database";

/**
 * Cliente Supabase para Server Components, Server Actions y Route Handlers.
 * `cookies()` es async desde Next.js 15+ (Async Request APIs).
 *
 * El `set` puede fallar si se llama desde un Server Component puro (no se pueden
 * escribir cookies fuera de una Server Action / Route Handler) — se ignora a
 * propósito porque proxy.ts ya se encarga de refrescar la sesión en cada request.
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) => {
              cookieStore.set(name, value, options);
            });
          } catch {
            // Ver comentario arriba: no-op en Server Components de solo lectura.
          }
        },
      },
    }
  );
}

/**
 * Cliente con privilegios de service_role. SOLO server-side (route handlers /
 * integraciones), NUNCA importar desde un componente que pueda renderizar en
 * el cliente. No usa cookies: no representa a un usuario logueado.
 */
export function createServiceRoleClient() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY no está configurada.");
  }
  return createSupabaseJsClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
