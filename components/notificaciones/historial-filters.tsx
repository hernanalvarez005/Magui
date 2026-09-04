"use client";

import { Search } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";

import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

interface LocationOption {
  id: string;
  code: string;
  name: string;
}

/**
 * Filtros de Historial (BLOQUE E), mismo patrón que sales-filters.tsx /
 * customers-view.tsx: cada cambio escribe en la URL (searchParams) y
 * navega — el server component (page.tsx) vuelve a llamar web_order_history
 * con los filtros resueltos. Nunca filtra en el cliente sobre datos ya
 * traídos (evita "mostrar 20, filtrar a 3" — cada filtro es un pedido
 * nuevo al backend, que es quien realmente sabe qué puede ver el usuario).
 */
export function HistorialFilters({ locations }: { locations: LocationOption[] }) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setParams(patch: Record<string, string | null>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(patch)) {
      if (value && value !== "all") params.set(key, value);
      else params.delete(key);
    }
    params.delete("page");
    router.push(`/notificaciones/historial?${params.toString()}`);
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="Cliente, DNI o número de venta…"
          className="pl-9"
          defaultValue={searchParams.get("q") ?? ""}
          onChange={(e) => setParams({ q: e.target.value || null })}
        />
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
            <SelectValue placeholder="Sede" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todas las sedes</SelectItem>
            {locations.map((l) => (
              <SelectItem key={l.id} value={l.id}>
                {l.name}
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
            <SelectItem value="DELIVERED">Entregado</SelectItem>
            <SelectItem value="SHIPPED">Enviado</SelectItem>
            <SelectItem value="CANCELLED">Anulado</SelectItem>
          </SelectContent>
        </Select>
      </div>
    </div>
  );
}
