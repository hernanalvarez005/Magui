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

interface Condition {
  id: string;
  code: string;
  name: string;
  rule_type: "BASE" | "PAYMENT_METHOD" | "QUANTITY";
  min_units: string | null;
  discount_percent: string | null;
  priority: number;
  combinable: boolean;
  active: boolean;
  paymentMethodName?: string;
}

function triggerLabel(c: Condition) {
  if (c.rule_type === "BASE") return "Siempre (fallback)";
  if (c.rule_type === "PAYMENT_METHOD") return `Medio de pago: ${c.paymentMethodName ?? "—"}`;
  return `${c.min_units}+ productos`;
}

export function PromotionsTable({ conditions }: { conditions: Condition[] }) {
  const router = useRouter();
  const [rows, setRows] = useState(conditions);
  const [savingId, setSavingId] = useState<string | null>(null);

  async function update(id: string, patch: Partial<Pick<Condition, "active" | "priority">>) {
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("price_conditions").update(patch).eq("id", id);
    setSavingId(null);

    if (error) {
      toast.error("No pudimos guardar el cambio.");
      return;
    }
    setRows((prev) => prev.map((r) => (r.id === id ? { ...r, ...patch } : r)));
    router.refresh();
  }

  return (
    <div className="overflow-x-auto rounded-xl border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Nombre</TableHead>
            <TableHead>Trigger</TableHead>
            <TableHead className="text-right">% informativo</TableHead>
            <TableHead className="text-right">Prioridad</TableHead>
            <TableHead>Combinable</TableHead>
            <TableHead>Activa</TableHead>
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
                  <p className="text-xs text-muted-foreground">{c.code}</p>
                </TableCell>
                <TableCell className="text-sm text-muted-foreground">{triggerLabel(c)}</TableCell>
                <TableCell className="text-right">
                  {c.discount_percent ? (
                    <Badge variant="secondary">{Math.round(Number(c.discount_percent) * 100)}%</Badge>
                  ) : (
                    "—"
                  )}
                </TableCell>
                <TableCell className="text-right">
                  <Input
                    type="number"
                    className="ml-auto h-8 w-20 text-right"
                    defaultValue={c.priority}
                    disabled={savingId === c.id}
                    onBlur={(e) => {
                      const value = Number(e.target.value);
                      if (!Number.isNaN(value) && value !== c.priority) update(c.id, { priority: value });
                    }}
                  />
                </TableCell>
                <TableCell>
                  <Badge variant="outline">{c.combinable ? "Sí" : "No"}</Badge>
                </TableCell>
                <TableCell>
                  <Switch
                    checked={c.active}
                    disabled={savingId === c.id}
                    onCheckedChange={(checked) => update(c.id, { active: checked })}
                  />
                </TableCell>
              </TableRow>
            ))}
        </TableBody>
      </Table>
    </div>
  );
}
