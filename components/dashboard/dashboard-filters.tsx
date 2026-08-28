"use client";

import { useRouter, useSearchParams } from "next/navigation";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { todayInBuenosAires } from "@/lib/utils";

function toISODate(d: Date) {
  return d.toISOString().slice(0, 10);
}

const PRESETS = [
  {
    label: "Hoy",
    range: () => ({ from: todayInBuenosAires(), to: todayInBuenosAires() }),
  },
  {
    label: "Últimos 7 días",
    range: () => {
      const d = new Date();
      d.setDate(d.getDate() - 6);
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
];

export function DashboardFilters({
  locations,
  channels,
}: {
  locations: { id: string; name: string }[];
  channels: { id: string; name: string }[];
}) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setParams(patch: Record<string, string | null>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(patch)) {
      if (value && value !== "all") params.set(key, value);
      else params.delete(key);
    }
    router.push(`/dashboard?${params.toString()}`);
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
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
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
        <Select defaultValue={searchParams.get("location") ?? "all"} onValueChange={(v) => setParams({ location: v })}>
          <SelectTrigger>
            <SelectValue placeholder="Sucursal" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todas las sucursales</SelectItem>
            {locations.map((l) => (
              <SelectItem key={l.id} value={l.id}>
                {l.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select defaultValue={searchParams.get("channel") ?? "all"} onValueChange={(v) => setParams({ channel: v })}>
          <SelectTrigger>
            <SelectValue placeholder="Canal" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos los canales</SelectItem>
            {channels.map((c) => (
              <SelectItem key={c.id} value={c.id}>
                {c.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
    </div>
  );
}
