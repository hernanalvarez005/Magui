"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Plus } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
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

interface Doctor {
  id: string;
  code: string;
  full_name: string;
  commission_percent: string;
  active: boolean;
}

export function DoctorsTable({ doctors }: { doctors: Doctor[] }) {
  const router = useRouter();
  const [rows, setRows] = useState(doctors);
  const [savingId, setSavingId] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ code: "", full_name: "", commission_percent: "20" });
  const [creating, setCreating] = useState(false);

  async function updateCommission(id: string, percent: number) {
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase
      .from("doctors")
      .update({ commission_percent: String(percent / 100) })
      .eq("id", id);
    setSavingId(null);
    if (error) {
      toast.error("No pudimos actualizar la comisión.");
      return;
    }
    setRows((prev) => prev.map((d) => (d.id === id ? { ...d, commission_percent: String(percent / 100) } : d)));
    router.refresh();
  }

  async function toggleActive(id: string, active: boolean) {
    setSavingId(id);
    const supabase = createClient();
    const { error } = await supabase.from("doctors").update({ active }).eq("id", id);
    setSavingId(null);
    if (error) {
      toast.error("No pudimos actualizar el estado.");
      return;
    }
    setRows((prev) => prev.map((d) => (d.id === id ? { ...d, active } : d)));
    router.refresh();
  }

  async function handleCreate() {
    if (!form.code.trim() || !form.full_name.trim()) {
      toast.error("Completá código y nombre.");
      return;
    }
    setCreating(true);
    const supabase = createClient();
    const { data, error } = await supabase
      .from("doctors")
      .insert({
        code: form.code.trim().toUpperCase(),
        full_name: form.full_name.trim(),
        commission_percent: String(Number(form.commission_percent) / 100),
      })
      .select("id, code, full_name, commission_percent, active")
      .single();
    setCreating(false);
    if (error) {
      toast.error(error.message.includes("doctors_code_key") ? "Ya existe una doctora con ese código." : error.message);
      return;
    }
    setRows((prev) => [...prev, data].sort((a, b) => a.full_name.localeCompare(b.full_name)));
    setOpen(false);
    setForm({ code: "", full_name: "", commission_percent: "20" });
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex justify-end">
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button>
              <Plus /> Nueva doctora
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Nueva doctora</DialogTitle>
            </DialogHeader>
            <div className="flex flex-col gap-3">
              <div className="flex flex-col gap-1.5">
                <Label>Código</Label>
                <Input value={form.code} onChange={(e) => setForm((f) => ({ ...f, code: e.target.value }))} />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>Nombre completo</Label>
                <Input
                  value={form.full_name}
                  onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))}
                />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>Comisión (%)</Label>
                <Input
                  type="number"
                  value={form.commission_percent}
                  onChange={(e) => setForm((f) => ({ ...f, commission_percent: e.target.value }))}
                />
              </div>
            </div>
            <DialogFooter>
              <Button variant="ghost" onClick={() => setOpen(false)}>
                Cancelar
              </Button>
              <Button onClick={handleCreate} disabled={creating}>
                {creating ? <Loader2 className="animate-spin" /> : null}
                Crear
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Doctora</TableHead>
              <TableHead className="text-right">Comisión (%)</TableHead>
              <TableHead>Activa</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((d) => (
              <TableRow key={d.id}>
                <TableCell>
                  <p className="font-medium">{d.full_name}</p>
                  <p className="text-xs text-muted-foreground">{d.code}</p>
                </TableCell>
                <TableCell className="text-right">
                  <Input
                    type="number"
                    className="ml-auto h-8 w-20 text-right"
                    defaultValue={Math.round(Number(d.commission_percent) * 100)}
                    disabled={savingId === d.id}
                    onBlur={(e) => {
                      const value = Number(e.target.value);
                      if (!Number.isNaN(value)) updateCommission(d.id, value);
                    }}
                  />
                </TableCell>
                <TableCell>
                  <Switch
                    checked={d.active}
                    disabled={savingId === d.id}
                    onCheckedChange={(checked) => toggleActive(d.id, checked)}
                  />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
