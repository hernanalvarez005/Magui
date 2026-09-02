"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Pencil, Plus } from "lucide-react";
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

interface Account {
  id: string;
  code: string;
  name: string;
  alias: string | null;
  active: boolean;
  sort_order: number;
}

export function AccountsTable({ accounts }: { accounts: Account[] }) {
  const router = useRouter();
  const [overrides, setOverrides] = useState<Record<string, Partial<Account>>>({});
  const [savingId, setSavingId] = useState<string | null>(null);
  const [editing, setEditing] = useState<Account | "new" | null>(null);

  const rows = accounts.map((a) => ({ ...a, ...overrides[a.id] }));

  async function toggleActive(account: Account, active: boolean) {
    setSavingId(account.id);
    const supabase = createClient();
    const { error } = await supabase.from("payment_accounts").update({ active }).eq("id", account.id);
    setSavingId(null);
    if (error) {
      toast.error("No pudimos guardar el cambio.");
      return;
    }
    setOverrides((prev) => ({ ...prev, [account.id]: { ...prev[account.id], active } }));
    toast.success(active ? `"${account.name}" está activa de nuevo.` : `"${account.name}" fue desactivada.`);
    router.refresh();
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex justify-end">
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> Nueva cuenta
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Cuenta</TableHead>
              <TableHead>Alias</TableHead>
              <TableHead>Estado</TableHead>
              <TableHead className="text-right">Acciones</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((a) => (
              <TableRow key={a.id}>
                <TableCell>
                  <p className="font-medium">{a.name}</p>
                  <p className="text-xs text-muted-foreground">{a.code}</p>
                </TableCell>
                <TableCell className="font-mono text-sm">{a.alias ?? <span className="text-muted-foreground">Sin alias</span>}</TableCell>
                <TableCell>
                  <div className="flex items-center gap-2">
                    <Switch
                      checked={a.active}
                      disabled={savingId === a.id}
                      onCheckedChange={(v) => toggleActive(a, v)}
                    />
                    <Badge variant={a.active ? "success" : "secondary"}>{a.active ? "Activa" : "Inactiva"}</Badge>
                  </div>
                </TableCell>
                <TableCell className="text-right">
                  <Button variant="ghost" size="icon" onClick={() => setEditing(a)}>
                    <Pencil className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={4} className="py-6 text-center text-sm text-muted-foreground">
                  Todavía no hay cuentas cargadas.
                </TableCell>
              </TableRow>
            ) : null}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <AccountFormDialog
          account={editing === "new" ? null : editing}
          nextSortOrder={accounts.length ? Math.max(...accounts.map((a) => a.sort_order)) + 1 : 0}
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

function AccountFormDialog({
  account,
  nextSortOrder,
  onOpenChange,
  onSaved,
}: {
  /** null = alta de una cuenta nueva */
  account: Account | null;
  nextSortOrder: number;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [code, setCode] = useState(account?.code ?? "");
  const [name, setName] = useState(account?.name ?? "");
  const [alias, setAlias] = useState(account?.alias ?? "");
  const [active, setActive] = useState(account?.active ?? true);
  const [saving, setSaving] = useState(false);

  async function handleSave() {
    if (!name.trim()) {
      toast.error("Ingresá un nombre para la cuenta.");
      return;
    }
    if (!account && !code.trim()) {
      toast.error("Ingresá un código interno para la cuenta.");
      return;
    }

    setSaving(true);
    const supabase = createClient();

    if (account) {
      // Editar: sección 10 del pedido — solo nombre/alias/estado, el código
      // no se toca acá (queda como identificador interno estable).
      const { error } = await supabase
        .from("payment_accounts")
        .update({ name: name.trim(), alias: alias.trim() || null, active })
        .eq("id", account.id);
      setSaving(false);
      if (error) {
        toast.error(error.message.includes("payment_accounts_code_key") ? "Ya existe una cuenta con ese código." : error.message);
        return;
      }
    } else {
      const { error } = await supabase.from("payment_accounts").insert({
        code: code.trim(),
        name: name.trim(),
        alias: alias.trim() || null,
        active,
        sort_order: nextSortOrder,
      });
      setSaving(false);
      if (error) {
        toast.error(error.message.includes("payment_accounts_code_key") ? "Ya existe una cuenta con ese código." : "No pudimos crear la cuenta.");
        return;
      }
    }

    toast.success(account ? "Cuenta actualizada." : "Cuenta creada.");
    onSaved();
  }

  return (
    <Dialog open onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{account ? "Editar cuenta" : "Nueva cuenta"}</DialogTitle>
          <DialogDescription>
            Cuenta donde ingresa el dinero de una venta (Mercado Pago, Banco Galicia, etc.).
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          {!account ? (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="account-code">Código interno</Label>
              <Input
                id="account-code"
                placeholder="BANCO_NACION"
                value={code}
                onChange={(e) => setCode(e.target.value)}
              />
            </div>
          ) : null}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="account-name">Nombre</Label>
            <Input id="account-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="account-alias">Alias (opcional)</Label>
            <Input
              id="account-alias"
              placeholder="maguirejuve.mp"
              value={alias}
              onChange={(e) => setAlias(e.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              Se muestra automáticamente en Nueva Venta cuando el medio de pago es Transferencia y se
              elige esta cuenta. Vacío = no se muestra ningún bloque de alias.
            </p>
          </div>

          <label className="flex items-center gap-2 text-sm">
            <Switch checked={active} onCheckedChange={setActive} />
            Activa (disponible para elegir en Nueva Venta)
          </label>
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
