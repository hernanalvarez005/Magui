"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, Plus } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import { ProductFormDialog } from "@/components/admin/product-form-dialog";

interface Product {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  unit: string;
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
  // `products` es la fuente de verdad (viene del Server Component y se
  // renueva con router.refresh()). Los toggles rápidos solo guardan un
  // override local para no esperar el refresh visualmente; se descarta solo
  // cuando llega el próximo `products` con el valor ya actualizado.
  const [overrides, setOverrides] = useState<Record<string, Partial<Product>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Product | "new" | null>(null);
  const rows = products.map((p) => ({ ...p, ...overrides[p.id] }));

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
    setOverrides((prev) => ({ ...prev, [id]: { ...prev[id], ...values } }));
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex justify-end">
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> Nuevo producto
        </Button>
      </div>

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
              <TableHead className="text-right">Editar</TableHead>
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
                    onCheckedChange={(v) => {
                      if (!v && !window.confirm(`¿Desactivar "${p.name}"? Deja de aparecer en Nueva Venta.`)) return;
                      patch(p.id, { active: v });
                    }}
                  />
                </TableCell>
                <TableCell className="text-right">
                  <Button variant="ghost" size="icon" onClick={() => setEditing(p)}>
                    <Pencil className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <ProductFormDialog
          product={editing === "new" ? null : editing}
          open
          onOpenChange={(o) => !o && setEditing(null)}
          onSaved={() => {
            setEditing(null);
            router.refresh();
          }}
        />
      ) : null}
    </div>
  );
}
