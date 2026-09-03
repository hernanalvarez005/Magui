"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { KeyRound, Loader2, Plus, Settings2 } from "lucide-react";
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
                  <Badge variant={u.role === "admin" ? "default" : u.role === "viewer" ? "outline" : "secondary"}>
                    {u.role === "admin" ? "Admin" : u.role === "viewer" ? "Observador" : "Vendedora"}
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
  const isViewer = role === "viewer";

  // Observador (solo lectura): siempre ve reportes, nunca ajusta stock — no
  // son "permisos configurables" para este rol, van implícitos. Se fuerzan
  // acá (además de en el backend, cinturón y tirantes) para que no quede una
  // combinación contradictoria guardada por accidente.
  function handleRoleChange(next: AppRole) {
    setRole(next);
    if (next === "viewer") {
      setCanViewFinancial(true);
      setCanAdjustStock(false);
    }
  }
  const [locationIds, setLocationIds] = useState<string[]>(user.locationIds);
  const [saving, setSaving] = useState(false);
  const [changingPassword, setChangingPassword] = useState(false);

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

  if (changingPassword) {
    return (
      <ChangePasswordDialog
        userId={user.id}
        userName={user.full_name}
        onClose={() => setChangingPassword(false)}
      />
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

          <Button type="button" variant="outline" size="sm" onClick={() => setChangingPassword(true)}>
            <KeyRound className="size-3.5" /> Cambiar contraseña
          </Button>

          <div className="flex items-center justify-between">
            <Label>Rol</Label>
            <Select value={role} onValueChange={(v) => handleRoleChange(v as AppRole)}>
              <SelectTrigger className="w-44">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="seller">Vendedora</SelectItem>
                <SelectItem value="admin">Admin</SelectItem>
                <SelectItem value="viewer">Observador (solo lectura)</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {isViewer ? (
            <p className="-mt-2 text-xs text-muted-foreground">
              Ve dashboard, reportes, ventas, stock y clientes en las sedes que le asignes abajo. Nunca puede
              cargar ni anular ventas, ajustar stock, ni editar precios o promociones — ni desde acá ni desde
              la app.
            </p>
          ) : null}

          <div className="flex items-center justify-between">
            <Label>Usuario activo</Label>
            <Switch
              checked={active}
              onCheckedChange={(v) => {
                if (!v && !window.confirm(`¿Desactivar a ${user.full_name}? No va a poder iniciar sesión.`)) return;
                setActive(v);
              }}
            />
          </div>

          <div className="flex items-center justify-between">
            <Label>Ve reportes financieros</Label>
            <Switch checked={canViewFinancial} disabled={isViewer} onCheckedChange={setCanViewFinancial} />
          </div>

          <div className="flex items-center justify-between">
            <Label>Puede ajustar stock</Label>
            <Switch checked={canAdjustStock} disabled={isViewer} onCheckedChange={setCanAdjustStock} />
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

// Acción puramente administrativa: el admin ELIGE la contraseña nueva (dos
// campos, para detectar un typo antes de guardar) — nunca se pide ni se
// muestra la actual, porque Supabase Auth nunca la expone. Después de
// guardar, solo se confirma el éxito — la contraseña nunca vuelve del
// servidor ni se muestra en pantalla.
function ChangePasswordDialog({
  userId,
  userName,
  onClose,
}: {
  userId: string;
  userName: string;
  onClose: () => void;
}) {
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [saving, setSaving] = useState(false);

  const mismatch = confirmPassword.length > 0 && newPassword !== confirmPassword;
  const canSave = newPassword.length >= 8 && newPassword === confirmPassword;

  async function handleSave() {
    if (!canSave) return;
    setSaving(true);
    const result = await resetUserPasswordAction({ userId, newPassword });
    setSaving(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success("Contraseña actualizada correctamente.");
    onClose();
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Cambiar contraseña de {userName}</DialogTitle>
          <DialogDescription>
            No hace falta la contraseña anterior — es una acción administrativa. La persona va a poder
            iniciar sesión con la contraseña nueva de inmediato.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="new-password">Nueva contraseña</Label>
            <Input
              id="new-password"
              type="password"
              autoComplete="new-password"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
            />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="confirm-password">Repetir contraseña</Label>
            <Input
              id="confirm-password"
              type="password"
              autoComplete="new-password"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
            />
            {mismatch ? <p className="text-xs text-destructive">Las contraseñas no coinciden.</p> : null}
            {!mismatch && newPassword.length > 0 && newPassword.length < 8 ? (
              <p className="text-xs text-destructive">Tiene que tener al menos 8 caracteres.</p>
            ) : null}
          </div>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>
            Cancelar
          </Button>
          <Button onClick={handleSave} disabled={saving || !canSave}>
            {saving ? <Loader2 className="animate-spin" /> : null}
            Guardar nueva contraseña
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
  const [confirmPassword, setConfirmPassword] = useState("");
  const [locationIds, setLocationIds] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);

  const mismatch = confirmPassword.length > 0 && form.password !== confirmPassword;
  const canCreate = form.password.length >= 8 && form.password === confirmPassword;

  async function handleCreate() {
    if (!canCreate) return;
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
    setConfirmPassword("");
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
            <Label>Contraseña</Label>
            <Input
              type="password"
              autoComplete="new-password"
              value={form.password}
              onChange={(e) => setForm((f) => ({ ...f, password: e.target.value }))}
            />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>Repetir contraseña</Label>
            <Input
              type="password"
              autoComplete="new-password"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
            />
            {mismatch ? <p className="text-xs text-destructive">Las contraseñas no coinciden.</p> : null}
            {!mismatch && form.password.length > 0 && form.password.length < 8 ? (
              <p className="text-xs text-destructive">Tiene que tener al menos 8 caracteres.</p>
            ) : null}
          </div>
          <div className="flex items-center justify-between">
            <Label>Rol</Label>
            <Select value={form.role} onValueChange={(v) => setForm((f) => ({ ...f, role: v as AppRole }))}>
              <SelectTrigger className="w-44">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="seller">Vendedora</SelectItem>
                <SelectItem value="admin">Admin</SelectItem>
                <SelectItem value="viewer">Observador (solo lectura)</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {form.role === "viewer" ? (
            <p className="-mt-1 text-xs text-muted-foreground">
              Ve dashboard, reportes, ventas, stock y clientes en las sedes que le asignes abajo. Nunca puede
              cargar ventas ni escribir nada.
            </p>
          ) : null}
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
          <Button onClick={handleCreate} disabled={loading || !canCreate}>
            {loading ? <Loader2 className="animate-spin" /> : null}
            Crear usuario
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
