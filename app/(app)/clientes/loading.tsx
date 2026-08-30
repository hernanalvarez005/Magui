import { Skeleton } from "@/components/ui/skeleton";

// Calca CustomersView: buscador+botón, checkbox de inactivos, grilla de
// tarjetas de cliente (1/2/3 columnas según viewport).
// Bloque 2 del plan de auditoría (perf/system-audit) — no toca el fetch.
export default function CustomersLoading() {
  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="space-y-1.5">
        <Skeleton className="h-6 w-20" />
        <Skeleton className="h-4 w-52" />
      </div>

      <div className="flex flex-col gap-4">
        <div className="flex flex-wrap gap-2">
          <Skeleton className="h-10 min-w-48 flex-1" />
          <Skeleton className="h-10 w-28" />
        </div>

        <Skeleton className="h-4 w-40" />

        <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 9 }).map((_, i) => (
            <div key={i} className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3.5">
              <Skeleton className="h-4 w-32" />
              <Skeleton className="h-3 w-40" />
              <Skeleton className="h-3 w-28" />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
