"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Check, Copy, KeyRound, Loader2, Plus, Settings2 } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
import { createUserAction, resetUserPasswordAction, updateUserAction } from "@/app/(app)/admin/usuarios/actions";
import type { AppRole } from "@/types/database";

interface UserRow {
  id: string;
  full_name: string;
  email: string;
  role: AppRole;
  active: boolean;
  can_view_financial_reports: boolean;
  can_adjust_stock: boolean;
  locationIds: string[];
}
interface LocationOption {
  id: string;
  code: string;
  name: string;
}

export function UsersTable({ users, locations }: { users: UserRow[]; locations: LocationOption[] }) {
  const router = useRouter();
  const [editing, setEditing] = useState<UserRow | null>(null);
  const [createOpen, setCreateOpen] = useState(false);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex justify-end">
        <Button onClick={() => setCreateOpen(true)}>
          <Plus /> Nuevo usuario
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Usuario</TableHead>
              <TableHead>Rol</TableHead>
              <TableHead>Sucursales</TableHead>
              <TableHead>Activo</TableHead>
              <TableHead />
            </TableRow>
          </TableHeader>
          <TableBody>
            {users.map((u) => (
              <TableRow key={u.id}>
                <TableCell>
                  <p className="font-medium">{u.full_name}</p>
                  {u.email ? <p className="text-xs text-muted-foreground">{u.email}</p> : null}
                </TableCell>
                <TableCell>
                  <Badge variant={u.role === "admin" ? "default" : "secondary"}>
                    {u.role === "admin" ? "Admin" : "Vendedora"}
                  </Badge>
                </TableCell>
                <TableCell className="text-xs text-muted-foreground">
                  {u.locationIds
                    .map((id) => locations.find((l) => l.id === id)?.code)
                    .filter(Boolean)
                    .join(", ") || "—"}
                </TableCell>
                <TableCell>
                  <Badge variant={u.active ? "success" : "outline"}>{u.active ? "Activo" : "Inactivo"}</Badge>
                </TableCell>
                <TableCell>
                  <Button variant="ghost" size="icon" onClick={() => setEditing(u)}>
                    <Settings2 className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {editing ? (
        <EditUserDialog
          user={editing}
          locations={locations}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            router.refresh();
          }}
        />
      ) : null}

      <CreateUserDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        locations={locations}
        onCreated={() => router.refresh()}
      />
    </div>
  );
}

function EditUserDialog({
  user,
  locations,
  onClose,
  onSaved,
}: {
  user: UserRow;
  locations: LocationOption[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [fullName, setFullName] = useState(user.full_name);
  const [email, setEmail] = useState(user.email);
  const [role, setRole] = useState<AppRole>(user.role);
  const [active, setActive] = useState(user.active);
  const [canViewFinancial, setCanViewFinancial] = useState(user.can_view_financial_reports);
  const [canAdjustStock, setCanAdjustStock] = useState(user.can_adjust_stock);
  const [locationIds, setLocationIds] = useState<string[]>(user.locationIds);
  const [saving, setSaving] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [confirmingReset, setConfirmingReset] = useState(false);
  const [tempPassword, setTempPassword] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function handleSave() {
    setSaving(true);

    if (fullName !== user.full_name || email !== user.email) {
      const result = await updateUserAction({ userId: user.id, fullName, email });
      if (result.error) {
        setSaving(false);
        toast.error(result.error);
        return;
      }
    }

    const supabase = createClient();
    const { error: profileError } = await supabase
      .from("profiles")
      .update({
        role,
        active,
        can_view_financial_reports: canViewFinancial,
        can_adjust_stock: canAdjustStock,
      })
      .eq("id", user.id);

    if (profileError) {
      setSaving(false);
      toast.error("No pudimos guardar los cambios del usuario.");
      return;
    }

    const toRemove = user.locationIds.filter((id) => !locationIds.includes(id));
    const toAdd = locationIds.filter((id) => !user.locationIds.includes(id));

    if (toRemove.length > 0) {
      await supabase.from("profile_locations").delete().eq("profile_id", user.id).in("location_id", toRemove);
    }
    if (toAdd.length > 0) {
      await supabase
        .from("profile_locations")
        .insert(toAdd.map((locationId) => ({ profile_id: user.id, location_id: locationId })));
    }

    setSaving(false);
    toast.success("Usuario actualizado.");
    onSaved();
  }

  async function handleResetPassword() {
    setResetting(true);
    const result = await resetUserPasswordAction(user.id);
    setResetting(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    setTempPassword(result.tempPassword ?? null);
  }

  async function copyTempPassword() {
    if (!tempPassword) return;
    try {
      await navigator.clipboard.writeText(tempPassword);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error("No pudimos copiar. Copiala manualmente.");
    }
  }

  if (confirmingReset) {
    return (
      <Dialog open onOpenChange={(o) => !o && setConfirmingReset(false)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Restablecer contraseña de {user.full_name}</DialogTitle>
            <DialogDescription>
              {tempPassword
                ? "Se generó una contraseña provisoria. Copiala y compartísela por un canal seguro — no queda guardada en ningún lado, esta es la única vez que se muestra."
                : "Se genera una contraseña provisoria aleatoria y reemplaza la actual. La persona podrá cambiarla después de iniciar sesión."}
            </DialogDescription>
          </DialogHeader>

          {tempPassword ? (
            <div className="flex items-center gap-2 rounded-lg border border-border bg-muted p-3">
              <code className="flex-1 text-sm font-medium tracking-wide">{tempPassword}</code>
              <Button type="button" variant="outline" size="icon" onClick={copyTempPassword}>
                {copied ? <Check className="size-4" /> : <Copy className="size-4" />}
              </Button>
            </div>
          ) : null}

          <DialogFooter>
            {tempPassword ? (
              <Button
                onClick={() => {
                  setConfirmingReset(false);
                  setTempPassword(null);
                }}
              >
                Listo
              </Button>
            ) : (
              <>
                <Button variant="ghost" onClick={() => setConfirmingReset(false)}>
                  Volver
                </Button>
                <Button variant="destructive" onClick={handleResetPassword} disabled={resetting}>
                  {resetting ? <Loader2 className="animate-spin" /> : null}
                  Generar contraseña nueva
                </Button>
              </>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{user.full_name}</DialogTitle>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="user-name">Nombre completo</Label>
              <Input id="user-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="user-email">Email</Label>
              <Input id="user-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
          </div>

          <Button type="button" variant="outline" size="sm" onClick={() => setConfirmingReset(true)}>
            <KeyRound className="size-3.5" /> Restablecer contraseña
          </Button>

          <div className="flex items-center justify-between">
            <Label>Rol</Label>
            <Select value={role} onValueChange={(v) => setRole(v as AppRole)}>
              <SelectTrigger className="w-40">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="seller">Vendedora</SelectItem>
                <SelectItem value="admin">Admin</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="flex items-center justify-between">
            <Label>Usuario activo</Label>
            <Switch checked={active} onCheckedChange={setActive} />
          </div>

          <div className="flex items-center justify-between">
            <Label>Ve reportes financieros</Label>
            <Switch checked={canViewFinancial} onCheckedChange={setCanViewFinancial} />
          </div>

          <div className="flex items-center justify-between">
            <Label>Puede ajustar stock</Label>
            <Switch checked={canAdjustStock} onCheckedChange={setCanAdjustStock} />
          </div>

          <div className="flex flex-col gap-2">
            <Label>Sucursales con acceso</Label>
            {locations.map((l) => (
              <label key={l.id} className="flex items-center gap-2 text-sm">
                <Checkbox
                  checked={locationIds.includes(l.id)}
                  onCheckedChange={(checked) =>
                    setLocationIds((prev) => (checked ? [...prev, l.id] : prev.filter((id) => id !== l.id)))
                  }
                />
                {l.name}
              </label>
            ))}
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
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

function CreateUserDialog({
  open,
  onOpenChange,
  locations,
  onCreated,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  locations: LocationOption[];
  onCreated: () => void;
}) {
  const [form, setForm] = useState({ email: "", password: "", fullName: "", role: "seller" as AppRole });
  const [locationIds, setLocationIds] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);

  async function handleCreate() {
    setLoading(true);
    const result = await createUserAction({ ...form, locationIds });
    setLoading(false);

    if (result.error) {
      toast.error(result.error);
      return;
    }

    toast.success("Usuario creado.");
    onOpenChange(false);
    setForm({ email: "", password: "", fullName: "", role: "seller" });
    setLocationIds([]);
    onCreated();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nuevo usuario</DialogTitle>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label>Nombre completo</Label>
            <Input value={form.fullName} onChange={(e) => setForm((f) => ({ ...f, fullName: e.target.value }))} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>Email</Label>
            <Input
              type="email"
              value={form.email}
              onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))}
            />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>Contraseña provisoria</Label>
            <Input
              type="text"
              value={form.password}
              onChange={(e) => setForm((f) => ({ ...f, password: e.target.value }))}
            />
          </div>
          <div className="flex items-center justify-between">
            <Label>Rol</Label>
            <Select value={form.role} onValueChange={(v) => setForm((f) => ({ ...f, role: v as AppRole }))}>
              <SelectTrigger className="w-40">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="seller">Vendedora</SelectItem>
                <SelectItem value="admin">Admin</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="flex flex-col gap-2">
            <Label>Sucursales con acceso</Label>
            {locations.map((l) => (
              <label key={l.id} className="flex items-center gap-2 text-sm">
                <Checkbox
                  checked={locationIds.includes(l.id)}
                  onCheckedChange={(checked) =>
                    setLocationIds((prev) => (checked ? [...prev, l.id] : prev.filter((id) => id !== l.id)))
                  }
                />
                {l.name}
              </label>
            ))}
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={handleCreate} disabled={loading}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Crear usuario
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
