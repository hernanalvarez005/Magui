"use client";

import { useState, useTransition } from "react";
import { Loader2, Search, UserPlus } from "lucide-react";
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
import { createClient } from "@/lib/supabase/client";
import { newCustomerSchema } from "@/lib/validation/sale";

export interface CustomerOption {
  id: string;
  full_name: string;
  dni: string | null;
  whatsapp: string | null;
}

export function CustomerPickerDialog({
  open,
  onOpenChange,
  onSelect,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (customer: CustomerOption | null) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<CustomerOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [creating, setCreating] = useState(false);
  const [form, setForm] = useState({ full_name: "", dni: "", whatsapp: "" });
  const [isPending, startTransition] = useTransition();

  async function handleSearch(value: string) {
    setQuery(value);
    if (value.trim().length < 2) {
      setResults([]);
      return;
    }
    setSearching(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("customers")
      .select("id, full_name, dni, whatsapp")
      .eq("active", true)
      .or(`full_name.ilike.%${value}%,dni.ilike.%${value}%,whatsapp.ilike.%${value}%`)
      .limit(10);
    setResults(data ?? []);
    setSearching(false);
  }

  function handleCreate() {
    const parsed = newCustomerSchema.safeParse(form);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? "Datos inválidos.");
      return;
    }
    startTransition(async () => {
      const supabase = createClient();
      const { data, error } = await supabase
        .from("customers")
        .insert({
          full_name: parsed.data.full_name,
          dni: parsed.data.dni || null,
          whatsapp: parsed.data.whatsapp || null,
          email: parsed.data.email || null,
          notes: parsed.data.notes || null,
        })
        .select("id, full_name, dni, whatsapp")
        .single();

      if (error) {
        toast.error(
          error.message.includes("customers_dni_unique_idx")
            ? "Ya existe un cliente con ese DNI."
            : "No pudimos crear el cliente."
        );
        return;
      }

      onSelect(data);
      onOpenChange(false);
      setCreating(false);
      setForm({ full_name: "", dni: "", whatsapp: "" });
    });
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{creating ? "Nuevo cliente" : "Buscar cliente"}</DialogTitle>
          <DialogDescription>
            {creating
              ? "La venta puede quedar sin cliente si preferís no cargarlo."
              : "Buscá por nombre, DNI o WhatsApp."}
          </DialogDescription>
        </DialogHeader>

        {creating ? (
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="full_name">Nombre y apellido</Label>
              <Input
                id="full_name"
                value={form.full_name}
                onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))}
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="dni">DNI (opcional)</Label>
                <Input
                  id="dni"
                  inputMode="numeric"
                  value={form.dni}
                  onChange={(e) => setForm((f) => ({ ...f, dni: e.target.value }))}
                />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="whatsapp">WhatsApp (opcional)</Label>
                <Input
                  id="whatsapp"
                  value={form.whatsapp}
                  onChange={(e) => setForm((f) => ({ ...f, whatsapp: e.target.value }))}
                />
              </div>
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                autoFocus
                placeholder="Nombre, DNI o WhatsApp…"
                className="pl-9"
                value={query}
                onChange={(e) => handleSearch(e.target.value)}
              />
            </div>

            <div className="flex max-h-64 flex-col gap-1 overflow-y-auto">
              {searching ? (
                <p className="py-4 text-center text-sm text-muted-foreground">Buscando…</p>
              ) : results.length === 0 && query.length >= 2 ? (
                <p className="py-4 text-center text-sm text-muted-foreground">
                  No encontramos clientes que coincidan.
                </p>
              ) : (
                results.map((c) => (
                  <button
                    key={c.id}
                    type="button"
                    className="flex flex-col rounded-md px-3 py-2 text-left text-sm hover:bg-accent"
                    onClick={() => {
                      onSelect(c);
                      onOpenChange(false);
                    }}
                  >
                    <span className="font-medium">{c.full_name}</span>
                    <span className="text-xs text-muted-foreground">
                      {[c.dni, c.whatsapp].filter(Boolean).join(" · ") || "Sin datos adicionales"}
                    </span>
                  </button>
                ))
              )}
            </div>

            <Button type="button" variant="outline" onClick={() => setCreating(true)}>
              <UserPlus /> Crear cliente nuevo
            </Button>
          </div>
        )}

        <DialogFooter>
          {creating ? (
            <>
              <Button variant="ghost" onClick={() => setCreating(false)}>
                Volver
              </Button>
              <Button onClick={handleCreate} disabled={isPending}>
                {isPending ? <Loader2 className="animate-spin" /> : null}
                Crear y seleccionar
              </Button>
            </>
          ) : (
            <Button
              variant="ghost"
              onClick={() => {
                onSelect(null);
                onOpenChange(false);
              }}
            >
              Venta sin identificar cliente
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
