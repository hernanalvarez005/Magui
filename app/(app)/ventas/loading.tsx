import { Skeleton } from "@/components/ui/skeleton";

// Calca SalesFilters + SalesTable (tabla desktop / cards mobile) + paginación.
// Bloque 2 del plan de auditoría (perf/system-audit) — no toca el fetch.
export default function SalesListLoading() {
  return (
    <div className="flex flex-col gap-5 p-4 md:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="space-y-1.5">
          <Skeleton className="h-6 w-24" />
          <Skeleton className="h-4 w-56" />
        </div>
        <div className="flex gap-2">
          <Skeleton className="h-9 w-36" />
          <Skeleton className="h-9 w-36" />
        </div>
      </div>

      <div className="flex flex-wrap gap-2">
        <Skeleton className="h-9 w-24" />
        <Skeleton className="h-9 w-24" />
        <Skeleton className="h-9 w-32" />
        <Skeleton className="h-9 w-32" />
        <Skeleton className="h-9 w-40" />
      </div>

      <div className="hidden overflow-hidden rounded-xl border border-border bg-card lg:block">
        <div className="grid grid-cols-11 gap-3 border-b border-border px-4 py-3">
          {Array.from({ length: 11 }).map((_, i) => (
            <Skeleton key={i} className="h-3 w-full" />
          ))}
        </div>
        {Array.from({ length: 8 }).map((_, row) => (
          <div key={row} className="grid grid-cols-11 gap-3 border-b border-border px-4 py-3.5 last:border-0">
            {Array.from({ length: 11 }).map((_, col) => (
              <Skeleton key={col} className="h-3.5 w-full" />
            ))}
          </div>
        ))}
      </div>

      <div className="flex flex-col gap-2 lg:hidden">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3.5">
            <div className="flex items-start justify-between">
              <div className="space-y-1.5">
                <Skeleton className="h-4 w-24" />
                <Skeleton className="h-3 w-28" />
              </div>
              <Skeleton className="h-5 w-20 rounded-full" />
            </div>
            <div className="flex items-center justify-between">
              <Skeleton className="h-3 w-32" />
              <Skeleton className="h-4 w-16" />
            </div>
          </div>
        ))}
      </div>

      <div className="flex items-center justify-between">
        <Skeleton className="h-4 w-40" />
        <div className="flex gap-2">
          <Skeleton className="h-9 w-20" />
          <Skeleton className="h-9 w-20" />
        </div>
      </div>
    </div>
  );
}
