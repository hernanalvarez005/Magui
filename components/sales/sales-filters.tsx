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
import { cn, todayInBuenosAires } from "@/lib/utils";

function toISODate(d: Date) {
  return d.toISOString().slice(0, 10);
}

function startOfWeek(d: Date) {
  const day = d.getDay();
  const diff = (day === 0 ? -6 : 1) - day; // lunes como inicio de semana
  const monday = new Date(d);
  monday.setDate(d.getDate() + diff);
  return monday;
}

const PRESETS = [
  {
    label: "Hoy",
    range: () => {
      const today = todayInBuenosAires();
      return { from: today, to: today };
    },
  },
  {
    label: "Ayer",
    range: () => {
      const d = new Date();
      d.setDate(d.getDate() - 1);
      const iso = toISODate(d);
      return { from: iso, to: iso };
    },
  },
  {
    label: "Esta semana",
    range: () => {
      const now = new Date();
      return { from: toISODate(startOfWeek(now)), to: todayInBuenosAires() };
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

export function SalesFilters({
  locations,
  channels,
  paymentMethods,
  doctors,
  sellers,
}: {
  locations: { id: string; name: string }[];
  channels: { id: string; name: string }[];
  paymentMethods: { id: string; name: string }[];
  doctors: { id: string; full_name: string }[];
  sellers: { id: string; full_name: string }[] | null;
}) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setParams(patch: Record<string, string | null>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(patch)) {
      if (value && value !== "all") params.set(key, value);
      else params.delete(key);
    }
    params.delete("page");
    router.push(`/ventas?${params.toString()}`);
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
            className={cn("rounded-full")}
            onClick={() => {
              const { from, to } = preset.range();
              setParams({ from, to });
            }}
          >
            {preset.label}
          </Button>
        ))}
      </div>

      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6">
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
        <Select
          defaultValue={searchParams.get("payment") ?? "all"}
          onValueChange={(v) => setParams({ payment: v })}
        >
          <SelectTrigger>
            <SelectValue placeholder="Medio de pago" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos los medios</SelectItem>
            {paymentMethods.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select defaultValue={searchParams.get("status") ?? "all"} onValueChange={(v) => setParams({ status: v })}>
          <SelectTrigger>
            <SelectValue placeholder="Estado" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            <SelectItem value="confirmed">Confirmadas</SelectItem>
            <SelectItem value="cancelled">Canceladas</SelectItem>
            <SelectItem value="replaced">Reemplazadas por un cambio</SelectItem>
          </SelectContent>
        </Select>
        <Select defaultValue={searchParams.get("doctor") ?? "all"} onValueChange={(v) => setParams({ doctor: v })}>
          <SelectTrigger>
            <SelectValue placeholder="Doctora" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todas</SelectItem>
            {doctors.map((d) => (
              <SelectItem key={d.id} value={d.id}>
                {d.full_name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {sellers ? (
          <Select defaultValue={searchParams.get("seller") ?? "all"} onValueChange={(v) => setParams({ seller: v })}>
            <SelectTrigger>
              <SelectValue placeholder="Vendedor/a" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos</SelectItem>
              {sellers.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.full_name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        ) : null}
      </div>
    </div>
  );
}
