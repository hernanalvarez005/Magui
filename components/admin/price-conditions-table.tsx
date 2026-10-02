"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Pencil, Plus, Table2 } from "lucide-react";
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
  PriceConditionFormDialog,
  type BranchLocationOption,
  type EditablePriceCondition,
} from "@/components/admin/price-condition-form-dialog";

export interface PriceConditionRow {
  id: string;
  code: string;
  name: string;
  is_base: boolean;
  active: boolean;
  visible_in_price_lookup: boolean;
  discount_percent: string | null;
  requires_billing: boolean;
  priority: number;
  location_codes: string[];
  location_names: string[];
  available_web: boolean;
}

export function PriceConditionsTable({
  conditions,
  branchLocations,
  listPriority,
}: {
  conditions: PriceConditionRow[];
  branchLocations: BranchLocationOption[];
  listPriority: number;
}) {
  const router = useRouter();
  const [overrides, setOverrides] = useState<Record<string, Partial<PriceConditionRow>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<PriceConditionRow | "new" | null>(null);
  const rows = conditions.map((c) => ({ ...c, ...overrides[c.id] }));

  // Toggle rápido de "Activa" sin abrir el formulario — pasa igual por la
  // RPC atómica (nunca un update directo a price_conditions/payment_methods
  // por separado, ver comentario de cabecera de update_price_condition en
  // 20260201000070_update_price_condition.sql: quedarían desincronizadas).
  async function toggleActive(row: PriceConditionRow, active: boolean) {
    if (!active && !window.confirm(`¿Desactivar "${row.name}"? Deja de ofrecerse en ventas nuevas (nunca se borra, ni afecta ventas ya hechas).`)) {
      return;
    }
    setSavingId(row.id);
    const supabase = createClient();
    const { error } = await supabase.rpc("update_price_condition", {
      p_price_condition_id: row.id,
      p_name: row.name,
      p_discount_percent: row.discount_percent ? Number(row.discount_percent) : 0,
      p_requires_billing: row.requires_billing,
      p_priority: row.priority,
      p_active: active,
      p_location_codes: row.location_codes,
      p_available_web: row.available_web,
    });
    setSavingId(null);
    if (error) {
      toast.error(error.message);
      return;
    }
    setOverrides((prev) => ({ ...prev, [row.id]: { ...prev[row.id], active } }));
    router.refresh();
  }

  // Toggle rápido de "Visible en Precios" — eje independiente de "Activa"
  // (migración 73): ocultarla de /precios nunca la desactiva para la venta.
  // p_visible_in_price_lookup es la única novedad acá; el resto de los
  // parámetros de la RPC siguen siendo reemplazo completo (igual que
  // toggleActive), así que se manda el valor actual de cada uno tal cual.
  async function toggleVisibility(row: PriceConditionRow, visible: boolean) {
    setSavingId(row.id);
    const supabase = createClient();
    const { error } = await supabase.rpc("update_price_condition", {
      p_price_condition_id: row.id,
      p_name: row.name,
      p_discount_percent: row.discount_percent ? Number(row.discount_percent) : 0,
      p_requires_billing: row.requires_billing,
      p_priority: row.priority,
      p_active: row.active,
      p_location_codes: row.location_codes,
      p_available_web: row.available_web,
      p_visible_in_price_lookup: visible,
    });
    setSavingId(null);
    if (error) {
      toast.error(error.message);
      return;
    }
    setOverrides((prev) => ({ ...prev, [row.id]: { ...prev[row.id], visible_in_price_lookup: visible } }));
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex justify-end gap-2">
        <Button size="sm" variant="outline" asChild>
          <Link href="/admin/precios">
            <Table2 /> Ver Matriz de precios
          </Link>
        </Button>
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> Nueva condición
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Condición</TableHead>
              <TableHead>Estado</TableHead>
              <TableHead>Visible en Precios</TableHead>
              <TableHead className="text-right">Ajuste</TableHead>
              <TableHead>Requiere facturación</TableHead>
              <TableHead>Disponibilidad</TableHead>
              <TableHead className="text-right">Prioridad</TableHead>
              <TableHead className="text-right">Acciones</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows
              .slice()
              .sort((a, b) => a.priority - b.priority)
              .map((c) => (
                <TableRow key={c.id}>
                  <TableCell>
                    <p className="font-medium">{c.name}</p>
                    {c.is_base ? <p className="text-xs text-muted-foreground">Precio de referencia — siempre disponible, no editable acá.</p> : null}
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <Switch
                        checked={c.active}
                        disabled={c.is_base || savingId === c.id}
                        onCheckedChange={(v) => toggleActive(c, v)}
                      />
                      <Badge variant={c.active ? "success" : "warning"}>{c.active ? "Activa" : "Desactivada"}</Badge>
                    </div>
                  </TableCell>
                  <TableCell>
                    {/* BASE (Lista) nunca ofrece el control — siempre visible
                        en /precios, sin importar la columna (ver migración
                        73 y app/(app)/precios/page.tsx). Para el resto, el
                        toggle es explícito acá — no solo escondido en el
                        formulario de edición — para que Administración vea
                        de un vistazo que "Activa" y "Visible en Precios" son
                        dos ejes independientes. */}
                    {c.is_base ? (
                      <Badge variant="secondary">Siempre</Badge>
                    ) : (
                      <div className="flex items-center gap-2">
                        <Switch
                          checked={c.visible_in_price_lookup}
                          disabled={savingId === c.id}
                          onCheckedChange={(v) => toggleVisibility(c, v)}
                        />
                        <Badge variant={c.visible_in_price_lookup ? "success" : "secondary"}>
                          {c.visible_in_price_lookup ? "Visible" : "Oculta"}
                        </Badge>
                      </div>
                    )}
                  </TableCell>
                  <TableCell className="text-right">
                    {c.discount_percent && Number(c.discount_percent) > 0 ? (
                      <Badge variant="secondary">{Math.round(Number(c.discount_percent) * 100)}%</Badge>
                    ) : (
                      "—"
                    )}
                  </TableCell>
                  <TableCell>
                    <Badge variant={c.requires_billing ? "outline" : "secondary"}>{c.requires_billing ? "Sí" : "No"}</Badge>
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-1">
                      {c.location_names.map((name) => (
                        <Badge key={name} variant="outline">
                          {name}
                        </Badge>
                      ))}
                      {c.available_web ? <Badge variant="outline">Web</Badge> : null}
                      {c.location_names.length === 0 && !c.available_web ? (
                        <Badge variant="warning">Sin sedes/Web — no se puede usar</Badge>
                      ) : null}
                    </div>
                  </TableCell>
                  <TableCell className="text-right">{c.priority}</TableCell>
                  <TableCell className="text-right">
                    {c.is_base ? (
                      <span className="text-xs text-muted-foreground">—</span>
                    ) : (
                      <Button variant="ghost" size="icon" onClick={() => setEditing(c)}>
                        <Pencil className="size-4" />
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={8} className="py-6 text-center text-sm text-muted-foreground">
                  Todavía no hay condiciones de precio cargadas.
                </TableCell>
              </TableRow>
            ) : null}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <PriceConditionFormDialog
          condition={
            editing === "new"
              ? null
              : ({
                  id: editing.id,
                  name: editing.name,
                  discount_percent: editing.discount_percent,
                  requires_billing: editing.requires_billing,
                  active: editing.active,
                  priority: editing.priority,
                  location_codes: editing.location_codes,
                  available_web: editing.available_web,
                  visible_in_price_lookup: editing.visible_in_price_lookup,
                } satisfies EditablePriceCondition)
          }
          branchLocations={branchLocations}
          listPriority={listPriority}
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
