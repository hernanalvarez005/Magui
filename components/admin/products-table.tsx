"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { createClient } from "@/lib/supabase/client";

interface Product {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  track_stock: boolean;
  commissionable: boolean;
  promo_eligible: boolean;
  default_min_stock: string;
  active: boolean;
  notes: string | null;
  components: string[];
}

export function ProductsTable({ products }: { products: Product[] }) {
  const router = useRouter();
  const [rows, setRows] = useState(products);
  const [savingId, setSavingId] = useState<string | null>(null);

  async function patch(
    id: string,
    values: Partial<Pick<Product, "default_min_stock" | "commissionable" | "promo_eligible" | "active">>
  ) {
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("products").update(values).eq("id", id);
    setSavingId(null);
    if (error) {
      toast.error("No pudimos guardar el cambio.");
      return;
    }
    setRows((prev) => prev.map((p) => (p.id === id ? { ...p, ...values } as Product : p)));
    router.refresh();
  }

  return (
    <div className="overflow-x-auto rounded-xl border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Producto</TableHead>
            <TableHead>Categoría</TableHead>
            <TableHead className="text-right">Mín. stock</TableHead>
            <TableHead>Comisionable</TableHead>
            <TableHead>En promos</TableHead>
            <TableHead>Activo</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((p) => (
            <TableRow key={p.id}>
              <TableCell>
                <p className="font-medium">{p.name}</p>
                <p className="text-xs text-muted-foreground">{p.sku}</p>
                {p.product_type === "kit" || !p.track_stock ? (
                  <div className="mt-1 flex flex-wrap gap-1">
                    <Badge variant="secondary">Kit</Badge>
                    {p.components.length === 0 ? (
                      <Badge variant="destructive">Sin componentes</Badge>
                    ) : (
                      <span className="text-xs text-muted-foreground">{p.components.join(", ")}</span>
                    )}
                  </div>
                ) : null}
              </TableCell>
              <TableCell className="text-sm text-muted-foreground">{p.category ?? "—"}</TableCell>
              <TableCell className="text-right">
                <Input
                  type="number"
                  className="ml-auto h-8 w-20 text-right"
                  defaultValue={p.default_min_stock}
                  disabled={savingId === p.id}
                  onBlur={(e) => {
                    const value = Number(e.target.value);
                    if (!Number.isNaN(value)) patch(p.id, { default_min_stock: String(value) });
                  }}
                />
              </TableCell>
              <TableCell>
                <Switch
                  checked={p.commissionable}
                  disabled={savingId === p.id}
                  onCheckedChange={(v) => patch(p.id, { commissionable: v })}
                />
              </TableCell>
              <TableCell>
                <Switch
                  checked={p.promo_eligible}
                  disabled={savingId === p.id}
                  onCheckedChange={(v) => patch(p.id, { promo_eligible: v })}
                />
              </TableCell>
              <TableCell>
                <Switch
                  checked={p.active}
                  disabled={savingId === p.id}
                  onCheckedChange={(v) => patch(p.id, { active: v })}
                />
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
