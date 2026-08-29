import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { fetchWithTimeout } from "@/lib/supabase/fetch-with-timeout";

/**
 * Refresca la sesión de Supabase en cada request (patrón SSR recomendado).
 * Se llama desde proxy.ts (el "middleware" de Next.js 16). También protege
 * las rutas de la app: sin sesión válida, redirige a /login.
 */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
      // Esto corre en CADA navegación (ver comentario en fetch-with-timeout.ts)
      // — es el punto donde más se nota un Supabase Auth lento.
      global: { fetch: fetchWithTimeout(8000) },
    }
  );

  // IMPORTANTE: no eliminar. getUser() revalida el token contra Supabase Auth
  // (a diferencia de getSession(), que solo lee la cookie sin validar).
  // Se envuelve en try/catch para que una caída momentánea de Supabase Auth no
  // tire un 500 en cada request: en ese caso se trata como "sin sesión" (falla
  // hacia el estado más restrictivo, no hacia acceso libre).
  let user = null;
  try {
    const { data } = await supabase.auth.getUser();
    user = data.user;
  } catch {
    user = null;
  }

  const { pathname } = request.nextUrl;
  const isPublicRoute = pathname.startsWith("/login") || pathname.startsWith("/api/integrations");
  const isAsset = pathname.startsWith("/_next") || pathname.startsWith("/favicon") || pathname.includes(".");

  if (!user && !isPublicRoute && !isAsset) {
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("next", pathname);
    return NextResponse.redirect(loginUrl);
  }

  if (user && pathname.startsWith("/login")) {
    return NextResponse.redirect(new URL("/", request.url));
  }

  return response;
}
