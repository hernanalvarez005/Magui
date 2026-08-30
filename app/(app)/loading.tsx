import { Skeleton } from "@/components/ui/skeleton";

// Boundary del segmento (app)/ — cubre el único tramo que ningún loading.tsx
// de pantalla puntual puede cubrir: la primera vez que se monta el layout
// compartido (justo después del login, o F5/URL directa a una ruta
// protegida), mientras getCurrentProfile() + la query de sedes de
// app/(app)/layout.tsx todavía no resolvieron. En navegación interna con el
// layout ya montado, este archivo no interviene — el App Router reutiliza el
// layout sin pedirlo de nuevo (partial rendering), así que ahí el loading.tsx
// de cada pantalla puntual alcanza solo. Ver el análisis de flujo de
// navegación (perf/system-audit) para el detalle de ambos escenarios.
//
// No conoce todavía perfil/rol/sedes reales — calca el "chrome" fijo de
// AppShell (sidebar + header) con skeletons en vez de datos, para que no
// haya salto visual cuando el AppShell real se monta encima.
export default function AppShellLoading() {
  return (
    <div className="flex min-h-screen w-full">
      <aside className="hidden w-64 shrink-0 flex-col border-r border-border bg-card md:flex">
        <div className="flex items-center gap-2.5 px-5 py-5">
          <Skeleton className="size-9 shrink-0 rounded-xl" />
          <div className="space-y-1.5">
            <Skeleton className="h-3.5 w-24" />
            <Skeleton className="h-3 w-16" />
          </div>
        </div>
        <nav className="flex flex-1 flex-col gap-1 px-3">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="flex items-center gap-3 px-3 py-2.5">
              <Skeleton className="size-4.5 shrink-0 rounded" />
              <Skeleton className="h-3.5 w-24" />
            </div>
          ))}
        </nav>
        <div className="border-t border-border p-3">
          <div className="flex items-center gap-3 px-3 py-2.5">
            <Skeleton className="size-4.5 shrink-0 rounded" />
            <Skeleton className="h-3.5 w-20" />
          </div>
        </div>
      </aside>

      <div className="flex min-h-screen flex-1 flex-col">
        <header className="sticky top-0 z-30 flex h-14 shrink-0 items-center justify-between border-b border-border bg-card/95 px-4 backdrop-blur md:h-16 md:px-6">
          <div className="flex items-center gap-2 md:hidden">
            <Skeleton className="size-8 shrink-0 rounded-lg" />
            <Skeleton className="h-3.5 w-24" />
          </div>
          <Skeleton className="hidden h-3.5 w-32 md:block" />
          <Skeleton className="size-8 shrink-0 rounded-full" />
        </header>

        <main className="flex-1 space-y-4 p-4 pb-20 md:p-6 md:pb-6">
          <Skeleton className="h-6 w-40" />
          <Skeleton className="h-32 w-full" />
        </main>

        <nav className="safe-bottom fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 gap-1 border-t border-border bg-card/95 px-2 py-2 backdrop-blur md:hidden">
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="flex flex-col items-center gap-1 py-1">
              <Skeleton className="size-5 rounded" />
              <Skeleton className="h-2 w-8" />
            </div>
          ))}
        </nav>
      </div>
    </div>
  );
}
