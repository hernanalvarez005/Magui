"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Pencil, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { cn } from "@/lib/utils";
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
  image_url: string | null;
  components: string[];
  /** Kits ACTIVOS de los que este producto es componente — alimenta la
   * advertencia al desactivar (sección 6 del pedido). */
  activeKits: string[];
}

type StatusFilter = "all" | "active" | "inactive";

const STATUS_FILTERS: { value: StatusFilter; label: string }[] = [
  { value: "all", label: "Todos" },
  { value: "active", label: "Activos" },
  { value: "inactive", label: "Inactivos" },
];

export function ProductsTable({ products }: { products: Product[] }) {
  const router = useRouter();
  // `products` es la fuente de verdad (viene del Server Component y se
  // renueva con router.refresh()). Los toggles rápidos solo guardan un
  // override local para no esperar el refresh visualmente; se descarta solo
  // cuando llega el próximo `products` con el valor ya actualizado.
  const [overrides, setOverrides] = useState<Record<string, Partial<Product>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Product | "new" | null>(null);
  const [deactivateTarget, setDeactivateTarget] = useState<Product | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<Product | null>(null);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");

  const rows = products.map((p) => ({ ...p, ...overrides[p.id] }));
  const filteredRows = useMemo(
    () =>
      rows.filter((p) => {
        if (statusFilter === "active") return p.active;
        if (statusFilter === "inactive") return !p.active;
        return true;
      }),
    [rows, statusFilter]
  );

  async function patch(
    id: string,
    values: Partial<Pick<Product, "default_min_stock" | "commissionable" | "promo_eligible">>
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

  async function handleReactivate(product: Product) {
    setSavingId(product.id);
    const supabase = createClient();
    const { error } = await supabase.rpc("reactivate_product", { p_product_id: product.id });
    setSavingId(null);
    if (error) {
      toast.error(error.message);
      return;
    }
    setOverrides((prev) => ({ ...prev, [product.id]: { ...prev[product.id], active: true } }));
    toast.success(`"${product.name}" está activo de nuevo.`);
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-lg bg-muted p-1">
          {STATUS_FILTERS.map((f) => (
            <button
              key={f.value}
              type="button"
              onClick={() => setStatusFilter(f.value)}
              className={cn(
                "rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
                statusFilter === f.value
                  ? "bg-background text-foreground shadow-sm"
                  : "text-muted-foreground hover:text-foreground"
              )}
            >
              {f.label}
            </button>
          ))}
        </div>
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
              <TableHead>Estado</TableHead>
              <TableHead className="text-right">Acciones</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filteredRows.map((p) => (
              <TableRow key={p.id}>
                <TableCell>
                  <div className="flex items-center gap-2.5">
                    <div className="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded-md border border-border bg-muted">
                      {p.image_url ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={p.image_url} alt="" loading="lazy" className="size-full object-cover" />
                      ) : (
                        <span className="text-xs text-muted-foreground">{p.sku.slice(0, 2)}</span>
                      )}
                    </div>
                    <div>
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
                    </div>
                  </div>
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
                  <div className="flex items-center gap-2">
                    <Switch
                      checked={p.active}
                      disabled={savingId === p.id}
                      onCheckedChange={(v) => {
                        if (v) handleReactivate(p);
                        else setDeactivateTarget(p);
                      }}
                    />
                    <Badge variant={p.active ? "success" : "secondary"}>{p.active ? "Activo" : "Inactivo"}</Badge>
                  </div>
                </TableCell>
                <TableCell className="text-right">
                  <div className="flex justify-end gap-1">
                    <Button variant="ghost" size="icon" onClick={() => setEditing(p)}>
                      <Pencil className="size-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="text-destructive hover:text-destructive"
                      onClick={() => setDeleteTarget(p)}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                </TableCell>
              </TableRow>
            ))}
            {filteredRows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} className="py-6 text-center text-sm text-muted-foreground">
                  No hay productos que coincidan con este filtro.
                </TableCell>
              </TableRow>
            ) : null}
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

      {deactivateTarget ? (
        <DeactivateProductDialog
          product={deactivateTarget}
          onClose={() => setDeactivateTarget(null)}
          onDeactivated={() => {
            setOverrides((prev) => ({ ...prev, [deactivateTarget.id]: { ...prev[deactivateTarget.id], active: false } }));
            setDeactivateTarget(null);
            router.refresh();
          }}
        />
      ) : null}

      {deleteTarget ? (
        <DeleteProductDialog
          product={deleteTarget}
          onClose={() => setDeleteTarget(null)}
          onDeleted={() => {
            setDeleteTarget(null);
            router.refresh();
          }}
          onOfferDeactivate={() => {
            setDeleteTarget(null);
            setDeactivateTarget(deleteTarget);
          }}
        />
      ) : null}
    </div>
  );
}

function DeactivateProductDialog({
  product,
  onClose,
  onDeactivated,
}: {
  product: Product;
  onClose: () => void;
  onDeactivated: () => void;
}) {
  const [saving, setSaving] = useState(false);

  async function handleConfirm() {
    setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("deactivate_product", { p_product_id: product.id });
    setSaving(false);

    if (error) {
      toast.error(error.message);
      return;
    }
    toast.success(`"${product.name}" fue desactivado.`);
    onDeactivated();
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>¿Desactivar este producto?</DialogTitle>
          <DialogDescription>{product.name}</DialogDescription>
        </DialogHeader>

        {product.activeKits.length > 0 ? (
          <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm">
            Este producto forma parte de {product.activeKits.length} kit
            {product.activeKits.length === 1 ? "" : "s"} activo{product.activeKits.length === 1 ? "" : "s"}:{" "}
            {product.activeKits.join(", ")}. Esos kits siguen activos — si te quedás sin stock de este
            componente, no vas a poder venderlos hasta reponerlo o cambiar su composición.
          </div>
        ) : null}

        <p className="text-sm text-muted-foreground">
          El producto dejará de estar disponible para nuevas ventas, promociones y consultas
          comerciales. Su historial se conservará.
        </p>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancelar
          </Button>
          <Button variant="destructive" onClick={handleConfirm} disabled={saving}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Desactivar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function DeleteProductDialog({
  product,
  onClose,
  onDeleted,
  onOfferDeactivate,
}: {
  product: Product;
  onClose: () => void;
  onDeleted: () => void;
  onOfferDeactivate: () => void;
}) {
  const [saving, setSaving] = useState(false);
  // Si el intento de borrar choca con historial (foreign_key_violation
  // traducido por delete_product()), se cambia el contenido del modal en
  // vez de solo mostrar un toast — sección 9 del pedido: ofrecer
  // "Desactivar producto", nunca una forma de forzar el borrado.
  const [blocked, setBlocked] = useState(false);

  async function handleConfirm() {
    setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("delete_product", { p_product_id: product.id });
    setSaving(false);

    if (error) {
      if (error.message.includes("tiene historial")) {
        setBlocked(true);
        return;
      }
      toast.error(error.message);
      return;
    }
    toast.success(`"${product.name}" fue eliminado definitivamente.`);
    onDeleted();
  }

  if (blocked) {
    return (
      <Dialog open onOpenChange={(o) => !o && onClose()}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Este producto tiene historial y no puede eliminarse definitivamente.</DialogTitle>
            <DialogDescription>{product.name}</DialogDescription>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            Tiene ventas, movimientos de stock u otras referencias que deben conservarse. Podés
            desactivarlo en su lugar — deja de estar disponible para nueva operatoria, sin perder
            nada de su historial.
          </p>
          <DialogFooter>
            <Button variant="ghost" onClick={onClose}>
              Cerrar
            </Button>
            <Button onClick={onOfferDeactivate}>Desactivar producto</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>¿Eliminar definitivamente este producto?</DialogTitle>
          <DialogDescription>{product.name}</DialogDescription>
        </DialogHeader>
        <p className="text-sm text-muted-foreground">
          Esta acción solo debe utilizarse para productos cargados por error y no se puede
          deshacer.
        </p>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancelar
          </Button>
          <Button variant="destructive" onClick={handleConfirm} disabled={saving}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Eliminar definitivamente
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
