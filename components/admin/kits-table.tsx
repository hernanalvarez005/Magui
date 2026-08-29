"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Pencil, Plus } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import { KitFormDialog, type ComponentCandidate, type EditableKit } from "@/components/admin/kit-form-dialog";

interface Kit {
  id: string;
  sku: string;
  name: string;
  category: string | null;
  commissionable: boolean;
  promo_eligible: boolean;
  active: boolean;
  notes: string | null;
  image_url: string | null;
  components: { id: string; component_product_id: string; quantity: string }[];
}

export function KitsTable({ kits, candidates }: { kits: Kit[]; candidates: ComponentCandidate[] }) {
  const router = useRouter();
  const [overrides, setOverrides] = useState<Record<string, Partial<Kit>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Kit | "new" | null>(null);
  const rows = kits.map((k) => ({ ...k, ...overrides[k.id] }));
  const nameById = useMemo(() => new Map(candidates.map((c) => [c.id, c])), [candidates]);

  async function toggleActive(id: string, active: boolean) {
    if (!active) {
      const name = kits.find((k) => k.id === id)?.name ?? "este kit";
      if (!window.confirm(`¿Desactivar "${name}"? Deja de aparecer en Nueva Venta.`)) return;
    }
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("products").update({ active }).eq("id", id);
    setSavingId(null);
    if (error) {
      toast.error("No pudimos guardar el cambio.");
      return;
    }
    setOverrides((prev) => ({ ...prev, [id]: { ...prev[id], active } }));
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex justify-end">
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> Nuevo kit
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Kit</TableHead>
              <TableHead>Componentes</TableHead>
              <TableHead>Activo</TableHead>
              <TableHead className="text-right">Editar</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((k) => (
              <TableRow key={k.id}>
                <TableCell>
                  <div className="flex items-center gap-2.5">
                    <div className="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded-md border border-border bg-muted">
                      {k.image_url ? (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img src={k.image_url} alt="" className="size-full object-cover" />
                      ) : (
                        <span className="text-xs text-muted-foreground">{k.sku.slice(0, 2)}</span>
                      )}
                    </div>
                    <div>
                      <p className="font-medium">{k.name}</p>
                      <p className="text-xs text-muted-foreground">{k.sku}</p>
                    </div>
                  </div>
                </TableCell>
                <TableCell>
                  {k.components.length === 0 ? (
                    <Badge variant="destructive">Sin componentes</Badge>
                  ) : (
                    <span className="text-xs text-muted-foreground">
                      {k.components
                        .map((c) => `${c.quantity}× ${nameById.get(c.component_product_id)?.name ?? "?"}`)
                        .join(", ")}
                    </span>
                  )}
                </TableCell>
                <TableCell>
                  <Switch
                    checked={k.active}
                    disabled={savingId === k.id}
                    onCheckedChange={(v) => toggleActive(k.id, v)}
                  />
                </TableCell>
                <TableCell className="text-right">
                  <Button variant="ghost" size="icon" onClick={() => setEditing(k)}>
                    <Pencil className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={4} className="py-6 text-center text-sm text-muted-foreground">
                  Todavía no hay kits cargados.
                </TableCell>
              </TableRow>
            ) : null}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <KitFormDialog
          kit={(editing === "new" ? null : editing) as EditableKit | null}
          candidates={candidates}
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
