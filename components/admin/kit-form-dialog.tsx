"use client";

import { useState } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";

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
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { createClient } from "@/lib/supabase/client";
import { kitSchema } from "@/lib/validation/kit";

export interface ComponentCandidate {
  id: string;
  sku: string;
  name: string;
  unit: string;
}

export interface EditableKit {
  id: string;
  sku: string;
  name: string;
  category: string | null;
  commissionable: boolean;
  promo_eligible: boolean;
  notes: string | null;
  components: { id: string; component_product_id: string; quantity: string }[];
}

interface Row {
  key: string;
  /** presente solo si ya existe en kit_components */
  id?: string;
  component_product_id: string;
  quantity: string;
}

function newRow(): Row {
  return { key: crypto.randomUUID(), component_product_id: "", quantity: "1" };
}

export function KitFormDialog({
  kit,
  candidates,
  open,
  onOpenChange,
  onSaved,
}: {
  /** null = alta de un kit nuevo */
  kit: EditableKit | null;
  candidates: ComponentCandidate[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [form, setForm] = useState({
    sku: kit?.sku ?? "",
    name: kit?.name ?? "",
    category: kit?.category ?? "",
    commissionable: kit?.commissionable ?? true,
    promo_eligible: kit?.promo_eligible ?? true,
    notes: kit?.notes ?? "",
  });
  const [rows, setRows] = useState<Row[]>(
    kit && kit.components.length > 0
      ? kit.components.map((c) => ({ key: c.id, id: c.id, component_product_id: c.component_product_id, quantity: c.quantity }))
      : [newRow()]
  );
  const [saving, setSaving] = useState(false);

  function updateRow(key: string, values: Partial<Row>) {
    setRows((prev) => prev.map((r) => (r.key === key ? { ...r, ...values } : r)));
  }

  function removeRow(key: string) {
    setRows((prev) => prev.filter((r) => r.key !== key));
  }

  async function handleSave() {
    const nonEmptyRows = rows.filter((r) => r.component_product_id);
    const parsed = kitSchema.safeParse({
      ...form,
      components: nonEmptyRows.map((r) => ({ component_product_id: r.component_product_id, quantity: Number(r.quantity) })),
    });
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos del kit.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const productPayload = {
      sku: parsed.data.sku,
      name: parsed.data.name,
      category: parsed.data.category || null,
      commissionable: parsed.data.commissionable,
      promo_eligible: parsed.data.promo_eligible,
      notes: parsed.data.notes || null,
    };

    let kitId = kit?.id ?? null;

    if (kitId) {
      const { error } = await supabase.from("products").update(productPayload).eq("id", kitId);
      if (error) {
        setSaving(false);
        toast.error(
          error.message.includes("products_sku_key") ? "Ya existe un producto con ese SKU." : error.message
        );
        return;
      }
    } else {
      const { data, error } = await supabase
        .from("products")
        .insert({ ...productPayload, product_type: "kit", track_stock: false, unit: "kit" })
        .select("id")
        .single();
      if (error || !data) {
        setSaving(false);
        toast.error(
          error?.message.includes("products_sku_key") ? "Ya existe un producto con ese SKU." : "No pudimos crear el kit."
        );
        return;
      }
      kitId = data.id;
    }

    // Composición: diff contra lo que ya existía en kit_components.
    const originalById = new Map((kit?.components ?? []).map((c) => [c.id, c]));
    const keptIds = new Set(rows.filter((r) => r.id).map((r) => r.id!));
    const toDelete = [...originalById.keys()].filter((id) => !keptIds.has(id));
    const toUpdate = rows.filter((r) => {
      if (!r.id) return false;
      const original = originalById.get(r.id);
      return original && (original.component_product_id !== r.component_product_id || original.quantity !== r.quantity);
    });
    const toInsert = parsed.data.components.filter((_, i) => !nonEmptyRows[i]?.id);

    if (toDelete.length > 0) {
      const { error } = await supabase.from("kit_components").delete().in("id", toDelete);
      if (error) {
        setSaving(false);
        toast.error("El kit se guardó, pero no pudimos quitar algún componente. Volvé a revisar la composición.");
        onSaved();
        return;
      }
    }

    for (const r of toUpdate) {
      const { error } = await supabase
        .from("kit_components")
        .update({ component_product_id: r.component_product_id, quantity: r.quantity })
        .eq("id", r.id!);
      if (error) {
        setSaving(false);
        toast.error(
          error.message.includes("kit_components_unique")
            ? "Ese producto ya está cargado como componente de este kit."
            : "El kit se guardó, pero no pudimos actualizar algún componente."
        );
        onSaved();
        return;
      }
    }

    if (toInsert.length > 0) {
      const { error } = await supabase.from("kit_components").insert(
        toInsert.map((c) => ({
          kit_product_id: kitId,
          component_product_id: c.component_product_id,
          quantity: String(c.quantity),
        }))
      );
      if (error) {
        setSaving(false);
        toast.error(
          error.message.includes("kit_components_unique")
            ? "Ese producto ya está cargado como componente de este kit."
            : "El kit se guardó, pero no pudimos agregar algún componente nuevo."
        );
        onSaved();
        return;
      }
    }

    setSaving(false);
    toast.success(kit ? "Kit actualizado." : "Kit creado.");
    onSaved();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{kit ? "Editar kit" : "Nuevo kit"}</DialogTitle>
          <DialogDescription>
            El stock del kit se calcula solo, a partir del stock de sus componentes — nunca es un
            número propio. Editar la composición no cambia ventas ya confirmadas.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="kit-sku">SKU</Label>
              <Input id="kit-sku" value={form.sku} onChange={(e) => setForm((f) => ({ ...f, sku: e.target.value }))} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="kit-category">Categoría</Label>
              <Input
                id="kit-category"
                value={form.category}
                onChange={(e) => setForm((f) => ({ ...f, category: e.target.value }))}
              />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="kit-name">Nombre</Label>
            <Input id="kit-name" value={form.name} onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))} />
          </div>

          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between">
              <Label>Componentes</Label>
              <Button type="button" variant="outline" size="sm" onClick={() => setRows((prev) => [...prev, newRow()])}>
                <Plus className="size-3.5" /> Agregar
              </Button>
            </div>

            {rows.map((r) => (
              <div key={r.key} className="flex items-center gap-2">
                <Select
                  value={r.component_product_id}
                  onValueChange={(v) => updateRow(r.key, { component_product_id: v })}
                >
                  <SelectTrigger className="flex-1">
                    <SelectValue placeholder="Elegí un producto…" />
                  </SelectTrigger>
                  <SelectContent>
                    {candidates.map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.name} ({c.sku})
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Input
                  type="number"
                  min={0.01}
                  step="0.01"
                  className="w-20"
                  value={r.quantity}
                  onChange={(e) => updateRow(r.key, { quantity: e.target.value })}
                />
                <Button type="button" variant="ghost" size="icon" onClick={() => removeRow(r.key)}>
                  <Trash2 className="size-4 text-destructive" />
                </Button>
              </div>
            ))}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="kit-notes">Notas</Label>
            <Textarea
              id="kit-notes"
              rows={2}
              value={form.notes}
              onChange={(e) => setForm((f) => ({ ...f, notes: e.target.value }))}
            />
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Guardar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
