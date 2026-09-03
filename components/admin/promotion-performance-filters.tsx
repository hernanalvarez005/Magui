"use client";

import { useRouter, useSearchParams } from "next/navigation";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { todayInBuenosAires } from "@/lib/utils";

// Mismo patrón de presets + inputs de fecha que DashboardFilters — acá sin
// sede/canal porque el rendimiento de promociones no se filtra por eso (una
// promoción no está atada a una sucursal). Preserva el resto de los
// searchParams (ej. "tab") al navegar, para no perder la pestaña activa.
function toISODate(d: Date) {
  return d.toISOString().slice(0, 10);
}

const PRESETS = [
  {
    label: "Últimos 30 días",
    range: () => {
      const d = new Date();
      d.setDate(d.getDate() - 29);
      return { from: toISODate(d), to: todayInBuenosAires() };
    },
  },
  {
    label: "Este mes",
    range: () => {
      const now = new Date();
      const first = new Date(now.getFullYear(), now.getMonth(), 1);
      return { from: toISODate(first), to: todayInBuenosAires() };
    },
  },
  {
    label: "Últimos 12 meses",
    range: () => {
      const d = new Date();
      d.setFullYear(d.getFullYear() - 1);
      return { from: toISODate(d), to: todayInBuenosAires() };
    },
  },
];

export function PromotionPerformanceFilters({ basePath = "/admin/promociones" }: { basePath?: string }) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setParams(patch: Record<string, string | null>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(patch)) {
      if (value) params.set(key, value);
      else params.delete(key);
    }
    router.push(`${basePath}?${params.toString()}`);
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap gap-2">
        {PRESETS.map((preset) => (
          <Button
            key={preset.label}
            type="button"
            variant="outline"
            size="sm"
            className="rounded-full"
            onClick={() => setParams(preset.range())}
          >
            {preset.label}
          </Button>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-2 sm:w-80">
        <Input
          type="date"
          defaultValue={searchParams.get("from") ?? ""}
          onChange={(e) => setParams({ from: e.target.value || null })}
        />
        <Input
          type="date"
          defaultValue={searchParams.get("to") ?? ""}
          onChange={(e) => setParams({ to: e.target.value || null })}
        />
      </div>
    </div>
  );
}
