"use client";

import { useRouter, useSearchParams } from "next/navigation";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

const TYPE_LABELS: Record<string, string> = {
  INITIAL: "Carga inicial",
  PURCHASE: "Ingreso de mercadería",
  SALE: "Venta",
  SALE_CANCEL: "Cancelación de venta",
  ADJUSTMENT_PLUS: "Ajuste (+)",
  ADJUSTMENT_MINUS: "Ajuste (−)",
  TRANSFER_OUT: "Transferencia (salida)",
  TRANSFER_IN: "Transferencia (entrada)",
  RETURN: "Devolución",
};

export function MovementFilters({
  locations,
  products,
  types,
}: {
  locations: { id: string; name: string }[];
  products: { id: string; name: string }[];
  types: string[];
}) {
  const router = useRouter();
  const searchParams = useSearchParams();

  function setParam(key: string, value: string | null) {
    const params = new URLSearchParams(searchParams.toString());
    if (value && value !== "all") params.set(key, value);
    else params.delete(key);
    params.delete("page");
    router.push(`/stock/movimientos?${params.toString()}`);
  }

  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
      <div className="flex flex-col gap-1">
        <Label className="text-xs text-muted-foreground">Desde</Label>
        <Input type="date" defaultValue={searchParams.get("from") ?? ""} onChange={(e) => setParam("from", e.target.value || null)} />
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs text-muted-foreground">Hasta</Label>
        <Input type="date" defaultValue={searchParams.get("to") ?? ""} onChange={(e) => setParam("to", e.target.value || null)} />
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs text-muted-foreground">Sucursal</Label>
        <Select defaultValue={searchParams.get("location") ?? "all"} onValueChange={(v) => setParam("location", v)}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todas</SelectItem>
            {locations.map((l) => (
              <SelectItem key={l.id} value={l.id}>
                {l.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs text-muted-foreground">Producto</Label>
        <Select defaultValue={searchParams.get("product") ?? "all"} onValueChange={(v) => setParam("product", v)}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            {products.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs text-muted-foreground">Tipo</Label>
        <Select defaultValue={searchParams.get("type") ?? "all"} onValueChange={(v) => setParam("type", v)}>
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            {types.map((t) => (
              <SelectItem key={t} value={t}>
                {TYPE_LABELS[t] ?? t}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
    </div>
  );
}

export { TYPE_LABELS };
