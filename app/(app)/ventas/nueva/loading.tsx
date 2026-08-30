import { Skeleton } from "@/components/ui/skeleton";

// Calca la estructura real de NewSaleClient (header sticky + grilla de
// productos) para que no haya salto visual cuando llegan los datos.
// Bloque 2 del plan de auditoría (perf/system-audit) — no toca el fetch.
export default function NewSalePageLoading() {
  return (
    <div className="flex flex-col gap-4 pb-40 md:pb-8">
      <div className="sticky top-14 z-20 flex flex-col gap-3 border-b border-border bg-background/95 px-4 pb-3 pt-3 backdrop-blur md:top-16 md:px-6">
        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-1.5">
            <Skeleton className="h-5 w-28" />
            <Skeleton className="h-3 w-20" />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-2">
          <div className="flex flex-col gap-1">
            <Skeleton className="h-3 w-10" />
            <Skeleton className="h-10 w-full" />
          </div>
          <div className="flex flex-col gap-1">
            <Skeleton className="h-3 w-14" />
            <Skeleton className="h-10 w-full" />
          </div>
        </div>

        <Skeleton className="h-11 w-full" />
        <Skeleton className="h-10 w-full" />
      </div>

      <div className="grid grid-cols-2 gap-3 px-4 sm:grid-cols-3 lg:grid-cols-4 md:px-6">
        {Array.from({ length: 8 }).map((_, i) => (
          <div key={i} className="flex flex-col gap-2 rounded-xl border border-border bg-card p-3.5 shadow-sm">
            <div className="flex items-start gap-2.5">
              <Skeleton className="size-11 shrink-0 rounded-lg" />
              <div className="min-w-0 flex-1 space-y-1.5">
                <Skeleton className="h-3.5 w-full max-w-28" />
                <Skeleton className="h-3 w-16" />
              </div>
            </div>
            <div className="flex items-center justify-between gap-2">
              <Skeleton className="h-4 w-14" />
              <Skeleton className="h-4 w-12" />
            </div>
            <Skeleton className="h-8 w-full rounded-md" />
          </div>
        ))}
      </div>
    </div>
  );
}
