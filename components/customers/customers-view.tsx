"use client";

import { useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Loader2, Plus, Search, Trash2 } from "lucide-react";
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
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { createClient } from "@/lib/supabase/client";
import { newCustomerSchema } from "@/lib/validation/sale";
import { formatDate } from "@/lib/utils";

interface Customer {
  id: string;
  full_name: string;
  dni: string | null;
  whatsapp: string | null;
  email: string | null;
  active: boolean;
  notes: string | null;
  created_at: string;
}

export function CustomersView({
  initialCustomers,
  initialQuery,
  showInactive,
  isAdmin,
}: {
  initialCustomers: Customer[];
  initialQuery: string;
  showInactive: boolean;
  isAdmin: boolean;
}) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [editing, setEditing] = useState<Customer | "new" | null>(null);

  function search(value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value) params.set("q", value);
    else params.delete("q");
    router.push(`/clientes?${params.toString()}`);
  }

  function toggleInactive() {
    const params = new URLSearchParams(searchParams.toString());
    if (showInactive) params.delete("inactive");
    else params.set("inactive", "1");
    router.push(`/clientes?${params.toString()}`);
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap gap-2">
        <div className="relative flex-1 min-w-48">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Nombre, DNI o WhatsApp…"
            className="pl-9"
            defaultValue={initialQuery}
            onChange={(e) => search(e.target.value)}
          />
        </div>
        <Button onClick={() => setEditing("new")}>
          <Plus /> Cliente
        </Button>
      </div>

      {isAdmin ? (
        <label className="flex w-fit items-center gap-2 text-sm text-muted-foreground">
          <input type="checkbox" checked={showInactive} onChange={toggleInactive} />
          Mostrar clientes inactivos
        </label>
      ) : null}

      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {initialCustomers.map((c) => (
          <button
            key={c.id}
            onClick={() => setEditing(c)}
            className="flex flex-col gap-1 rounded-xl border border-border bg-card p-3.5 text-left transition-colors hover:bg-accent"
          >
            <div className="flex items-center justify-between">
              <p className="font-medium">{c.full_name}</p>
              {!c.active ? <Badge variant="outline">Inactivo</Badge> : null}
            </div>
            <p className="text-xs text-muted-foreground">
              {[c.dni ? `DNI ${c.dni}` : null, c.whatsapp].filter(Boolean).join(" · ") || "Sin datos adicionales"}
            </p>
            <p className="text-xs text-muted-foreground">Cliente desde {formatDate(c.created_at)}</p>
          </button>
        ))}
      </div>

      {editing ? (
        <CustomerDialog
          customer={editing === "new" ? null : editing}
          isAdmin={isAdmin}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            router.refresh();
          }}
        />
      ) : null}
    </div>
  );
}

function CustomerDialog({
  customer,
  isAdmin,
  onClose,
  onSaved,
}: {
  customer: Customer | null;
  isAdmin: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [form, setForm] = useState({
    full_name: customer?.full_name ?? "",
    dni: customer?.dni ?? "",
    whatsapp: customer?.whatsapp ?? "",
    email: customer?.email ?? "",
    notes: customer?.notes ?? "",
  });
  const [active, setActive] = useState(customer?.active ?? true);
  const [saving, setSaving] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);

  async function handleSave() {
    const parsed = newCustomerSchema.safeParse(form);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Revisá los datos.");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const payload = {
      full_name: parsed.data.full_name,
      dni: parsed.data.dni || null,
      whatsapp: parsed.data.whatsapp || null,
      email: parsed.data.email || null,
      notes: parsed.data.notes || null,
    };

    const { error } = customer
      ? await supabase.from("customers").update({ ...payload, active }).eq("id", customer.id)
      : await supabase.from("customers").insert(payload);

    setSaving(false);

    if (error) {
      toast.error(
        error.message.includes("customers_dni_unique_idx") ? "Ya existe un cliente con ese DNI." : error.message
      );
      return;
    }

    toast.success(customer ? "Cliente actualizado." : "Cliente creado.");
    onSaved();
  }

  async function handleDelete() {
    if (!customer) return;
    setDeleting(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("deactivate_customer", { p_customer_id: customer.id });
    setDeleting(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Cliente eliminado. Sus ventas históricas se conservan.");
    onSaved();
  }

  if (confirmingDelete && customer) {
    return (
      <Dialog open onOpenChange={(o) => !o && setConfirmingDelete(false)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Eliminar {customer.full_name}</DialogTitle>
            <DialogDescription>
              El cliente pasa a inactivo y deja de aparecer en las búsquedas. No se borra ni afecta sus ventas
              históricas — un administrador puede reactivarlo más adelante. No se puede deshacer desde acá.
            </DialogDescription>
          </DialogHeader>

          <DialogFooter>
            <Button variant="ghost" onClick={() => setConfirmingDelete(false)}>
              Volver
            </Button>
            <Button variant="destructive" onClick={handleDelete} disabled={deleting}>
              {deleting ? <Loader2 className="animate-spin" /> : null}
              Confirmar eliminación
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{customer ? "Editar cliente" : "Nuevo cliente"}</DialogTitle>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Nombre y apellido</Label>
            <Input value={form.full_name} onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label>DNI</Label>
              <Input value={form.dni} onChange={(e) => setForm((f) => ({ ...f, dni: e.target.value }))} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>WhatsApp</Label>
              <Input value={form.whatsapp} onChange={(e) => setForm((f) => ({ ...f, whatsapp: e.target.value }))} />
            </div>
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>Email</Label>
            <Input value={form.email} onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>Notas</Label>
            <Textarea
              rows={2}
              value={form.notes}
              onChange={(e) => setForm((f) => ({ ...f, notes: e.target.value }))}
            />
          </div>
          {customer ? (
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
              Cliente activo
            </label>
          ) : null}
        </div>

        <DialogFooter className="sm:justify-between">
          {isAdmin && customer ? (
            <Button
              variant="outline"
              className="text-destructive hover:text-destructive"
              onClick={() => setConfirmingDelete(true)}
            >
              <Trash2 /> Eliminar cliente
            </Button>
          ) : null}
          <div className="flex gap-2">
            <Button variant="ghost" onClick={onClose}>
              Cancelar
            </Button>
            <Button onClick={handleSave} disabled={saving}>
              {saving ? <Loader2 className="animate-spin" /> : null}
              Guardar
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
