"use client";

import { useState } from "react";
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
import {
  PromotionFormDialog,
  type EditablePromotion,
  type ProductCandidate,
} from "@/components/admin/promotion-form-dialog";
import { formatDate } from "@/lib/utils";
import type { PromotionType } from "@/types/database";

interface Promotion {
  id: string;
  code: string;
  name: string;
  type: PromotionType;
  discount_percent: string | null;
  group_size: number;
  priority: number;
  stackable: boolean;
  active: boolean;
  valid_from: string;
  valid_until: string | null;
  notes: string | null;
  productIds: string[];
}

const TYPE_BADGE: Record<PromotionType, string> = {
  THREE_FOR_TWO: "3x2",
  DUO_PERCENT: "Duo %",
  KIT_PERCENT: "Kit %",
};

export function PromotionsTable({
  promotions,
  products,
}: {
  promotions: Promotion[];
  products: ProductCandidate[];
}) {
  const router = useRouter();
  const [overrides, setOverrides] = useState<Record<string, Partial<Promotion>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Promotion | "new" | null>(null);
  const rows = promotions.map((p) => ({ ...p, ...overrides[p.id] }));
  const nameById = new Map(products.map((p) => [p.id, p]));

  async function toggleActive(id: string, active: boolean) {
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("promotions").update({ active }).eq("id", id);
    setSavingId(null);
    if (error) {
      toast.error(
        active
          ? "No pudimos activarla: algún producto ya está en otra promoción activa."
          : "No pudimos guardar el cambio."
      );
      return;
    }
    setOverrides((prev) => ({ ...prev, [id]: { ...prev[id], active } }));
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex justify-end">
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> Nueva promoción
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Promoción</TableHead>
              <TableHead>Productos</TableHead>
              <TableHead className="text-right">Prioridad</TableHead>
              <TableHead>Combinable</TableHead>
              <TableHead>Vigencia</TableHead>
              <TableHead>Activa</TableHead>
              <TableHead className="text-right">Editar</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows
              .slice()
              .sort((a, b) => a.priority - b.priority)
              .map((p) => (
                <TableRow key={p.id}>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <Badge variant="secondary">{TYPE_BADGE[p.type]}</Badge>
                      <p className="font-medium">{p.name}</p>
                    </div>
                    <p className="text-xs text-muted-foreground">
                      {p.code}
                      {p.discount_percent ? ` · ${Math.round(Number(p.discount_percent) * 100)}% OFF` : ""}
                      {p.type === "THREE_FOR_TWO" ? ` · cada ${p.group_size}, 1 gratis` : ""}
                    </p>
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">
                    {p.productIds.map((id) => nameById.get(id)?.sku ?? "?").join(", ") || "—"}
                  </TableCell>
                  <TableCell className="text-right">{p.priority}</TableCell>
                  <TableCell>
                    <Badge variant="outline">{p.stackable ? "Sí" : "No"}</Badge>
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">
                    {formatDate(p.valid_from)} — {p.valid_until ? formatDate(p.valid_until) : "sin fin"}
                  </TableCell>
                  <TableCell>
                    <Switch
                      checked={p.active}
                      disabled={savingId === p.id}
                      onCheckedChange={(v) => toggleActive(p.id, v)}
                    />
                  </TableCell>
                  <TableCell className="text-right">
                    <Button variant="ghost" size="icon" onClick={() => setEditing(p)}>
                      <Pencil className="size-4" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} className="py-6 text-center text-sm text-muted-foreground">
                  Todavía no hay promociones cargadas.
                </TableCell>
              </TableRow>
            ) : null}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <PromotionFormDialog
          promotion={(editing === "new" ? null : editing) as EditablePromotion | null}
          products={products}
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
