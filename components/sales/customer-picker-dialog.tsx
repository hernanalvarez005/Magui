"use client";

import { useEffect, useState, useTransition } from "react";
import { CheckCircle2, Loader2, Search, UserPlus } from "lucide-react";
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
import { normalizeDni } from "@/lib/utils";

export interface CustomerOption {
  id: string;
  full_name: string;
  dni: string | null;
  whatsapp: string | null;
}

/**
 * Flujo de selección/alta de cliente (DNI -> autocompletar / crear, o
 * buscar por nombre) — sin ningún wrapper de modal. Se monta/desmonta desde
 * afuera (el padre decide cuándo mostrarlo); cada montaje arranca con
 * estado limpio, así que no hace falta un prop `open` acá adentro para
 * resetear campos.
 *
 * Dos consumidores: `CustomerPickerDialog` (abajo, lo envuelve en un Dialog
 * modal) y el bloque "Cliente" del carrito de Nueva Venta
 * (new-sale-cart.tsx), que lo muestra inline dentro de la misma sheet —
 * sección 5 del pedido de rediseño: "no sacar al usuario del carrito".
 */
export function CustomerPickerFields({
  onSelect,
  footer,
  autoFocus = true,
}: {
  onSelect: (customer: CustomerOption) => void;
  /** Acción secundaria opcional (ej. "Cancelar" inline, o "Venta sin identificar cliente" en el modal). */
  footer?: React.ReactNode;
  autoFocus?: boolean;
}) {
  // Flujo principal: DNI primero, con autobúsqueda debounced. Si aparece un
  // cliente, se ofrece autocompletar ("Cliente encontrado"). Si no, solo se
  // pide nombre y WhatsApp (el DNI ya quedó cargado) para no duplicar datos.
  const [dni, setDni] = useState("");
  const [dniStatus, setDniStatus] = useState<"idle" | "searching" | "found" | "not_found">("idle");
  const [found, setFound] = useState<CustomerOption | null>(null);
  const [nameSearchMode, setNameSearchMode] = useState(false);

  // Búsqueda alternativa por nombre/WhatsApp (para clientes sin DNI a mano).
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<CustomerOption[]>([]);
  const [searching, setSearching] = useState(false);

  const [form, setForm] = useState({ full_name: "", whatsapp: "" });
  const [isPending, startTransition] = useTransition();

  useEffect(() => {
    const normalized = normalizeDni(dni);
    if (normalized.length < 6) {
      void Promise.resolve().then(() => {
        setDniStatus("idle");
        setFound(null);
      });
      return;
    }
    let cancelled = false;
    void Promise.resolve().then(() => {
      if (!cancelled) setDniStatus("searching");
    });
    const timeout = setTimeout(async () => {
      const supabase = createClient();
      const { data } = await supabase
        .from("customers")
        .select("id, full_name, dni, whatsapp")
        .eq("active", true)
        .eq("dni", normalized)
        .maybeSingle();
      if (cancelled) return;
      if (data) {
        setFound(data);
        setDniStatus("found");
      } else {
        setFound(null);
        setDniStatus("not_found");
      }
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(timeout);
    };
  }, [dni]);

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
    if (isPending) return; // evita doble creación por doble click
    const parsed = newCustomerSchema.safeParse({
      full_name: form.full_name,
      dni: normalizeDni(dni),
      whatsapp: form.whatsapp,
    });
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
        })
        .select("id, full_name, dni, whatsapp")
        .single();

      if (error) {
        toast.error(
          error.message.includes("customers_dni_unique_idx")
            ? "Ya existe un cliente con este DNI."
            : "No pudimos crear el cliente."
        );
        return;
      }

      onSelect(data);
    });
  }

  const normalizedDni = normalizeDni(dni);
  const showCreateForm = dniStatus === "not_found" && normalizedDni.length >= 6;

  if (nameSearchMode) {
    return (
      <div className="flex flex-col gap-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            autoFocus={autoFocus}
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
            <p className="py-4 text-center text-sm text-muted-foreground">No encontramos clientes que coincidan.</p>
          ) : (
            results.map((c) => (
              <button
                key={c.id}
                type="button"
                className="flex flex-col rounded-md px-3 py-2 text-left text-sm hover:bg-accent"
                onClick={() => onSelect(c)}
              >
                <span className="font-medium">{c.full_name}</span>
                <span className="text-xs text-muted-foreground">
                  {[c.dni, c.whatsapp].filter(Boolean).join(" · ") || "Sin datos adicionales"}
                </span>
              </button>
            ))
          )}
        </div>

        <Button type="button" variant="outline" onClick={() => setNameSearchMode(false)}>
          Volver a buscar por DNI
        </Button>
        {footer}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="dni-search">DNI</Label>
        <div className="relative">
          <Input
            id="dni-search"
            autoFocus={autoFocus}
            inputMode="numeric"
            placeholder="Ej: 32123456"
            value={dni}
            // Sin onPaste ni onKeyDown restrictivos: escribir, pegar
            // (Ctrl+V/Cmd+V/"Pegar" en mobile) todo pasa por acá. Se
            // normaliza en el momento (saca puntos/espacios de
            // "32.123.456" o "32 123 456") para que quede "32123456" sin
            // que el usuario tenga que editarlo a mano.
            onChange={(e) => setDni(normalizeDni(e.target.value))}
          />
          {dniStatus === "searching" ? (
            <Loader2 className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 animate-spin text-muted-foreground" />
          ) : null}
        </div>
      </div>

      {dniStatus === "found" && found ? (
        <div className="flex flex-col gap-2 rounded-lg border border-emerald-600/30 bg-emerald-600/10 p-3">
          <div className="flex items-center gap-2 text-sm font-medium text-emerald-700 dark:text-emerald-400">
            <CheckCircle2 className="size-4" /> Cliente encontrado
          </div>
          <p className="text-sm">{found.full_name}</p>
          <p className="text-xs text-muted-foreground">
            {[found.dni ? `DNI ${found.dni}` : null, found.whatsapp].filter(Boolean).join(" · ")}
          </p>
          <Button type="button" onClick={() => onSelect(found)}>
            Usar este cliente
          </Button>
        </div>
      ) : null}

      {showCreateForm ? (
        <div className="flex flex-col gap-3 rounded-lg border border-border p-3">
          <p className="text-sm text-muted-foreground">
            No encontramos ningún cliente con ese DNI. Cargá los datos para crearlo.
          </p>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="full_name">Nombre y apellido</Label>
            <Input
              id="full_name"
              value={form.full_name}
              onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))}
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
          <Button type="button" onClick={handleCreate} disabled={isPending}>
            {isPending ? <Loader2 className="animate-spin" /> : <UserPlus />}
            Crear y seleccionar
          </Button>
        </div>
      ) : null}

      <Button type="button" variant="outline" onClick={() => setNameSearchMode(true)}>
        <Search /> Buscar por nombre en vez de DNI
      </Button>
      {footer}
    </div>
  );
}

/** Wrapper modal de CustomerPickerFields — se remonta (reset limpio) cada vez que se abre. */
export function CustomerPickerDialog({
  open,
  onOpenChange,
  onSelect,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (customer: CustomerOption | null) => void;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Cliente</DialogTitle>
          <DialogDescription>Escribí el DNI: si el cliente ya existe lo autocompletamos.</DialogDescription>
        </DialogHeader>

        {open ? (
          <CustomerPickerFields
            onSelect={(c) => {
              onSelect(c);
              onOpenChange(false);
            }}
            footer={
              <DialogFooter>
                <Button
                  variant="ghost"
                  onClick={() => {
                    onSelect(null);
                    onOpenChange(false);
                  }}
                >
                  Venta sin identificar cliente
                </Button>
              </DialogFooter>
            }
          />
        ) : null}
      </DialogContent>
    </Dialog>
  );
}
