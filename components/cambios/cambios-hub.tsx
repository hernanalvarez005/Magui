"use client";

import { useState } from "react";
import { ArrowLeft, ArrowRightLeft, Repeat, Undo2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { CambiosClient } from "@/components/cambios/cambios-client";
import { DevolucionClient } from "@/components/cambios/devolucion-client";
import { cn } from "@/lib/utils";

interface ProductOption {
  id: string;
  sku: string;
  name: string;
  product_type: string;
  category: string | null;
  track_stock: boolean;
  image_url: string | null;
  kitContents: string[] | null;
}

type Mode = "select" | "exchange" | "return";

// Sección 39 del pedido: la pantalla /cambios tiene que presentar las dos
// opciones con claridad. Este componente ES esa elección (tarjetas) y
// simplemente MONTA uno de los dos flujos existentes según lo elegido —
// nunca los mezcla ni comparte estado entre ellos. CambiosClient (Cambio de
// producto) no se toca para nada: se importa y se renderiza tal cual.
export function CambiosHub({ products }: { products: ProductOption[] }) {
  const [mode, setMode] = useState<Mode>("select");

  if (mode === "select") {
    return (
      <div className="mx-auto flex max-w-2xl flex-col gap-5 p-4 md:p-6">
        <div>
          <h1 className="flex items-center gap-2 text-xl font-semibold">
            <ArrowRightLeft className="size-5" /> Cambios / Devoluciones
          </h1>
          <p className="text-sm text-muted-foreground">¿Qué querés hacer con esta venta?</p>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <ModeCard
            icon={Repeat}
            title="Cambio de producto"
            description="El cliente devuelve un producto y se lleva otro distinto. Puede haber diferencia a favor o en contra."
            onClick={() => setMode("exchange")}
          />
          <ModeCard
            icon={Undo2}
            title="Devolución de producto"
            description="El cliente devuelve uno o más productos y recupera el dinero — no se lleva nada a cambio."
            onClick={() => setMode("return")}
          />
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-1">
      <div className="mx-auto flex w-full max-w-2xl items-center px-4 pt-4 md:px-6">
        <Button variant="ghost" size="sm" onClick={() => setMode("select")}>
          <ArrowLeft className="size-4" /> Elegir otra opción
        </Button>
      </div>
      {mode === "exchange" ? <CambiosClient products={products} /> : <DevolucionClient />}
    </div>
  );
}

function ModeCard({
  icon: Icon,
  title,
  description,
  onClick,
}: {
  icon: React.ElementType;
  title: string;
  description: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex flex-col items-start gap-2 rounded-xl border border-border bg-card p-5 text-left shadow-sm transition-colors hover:border-primary"
      )}
    >
      <div className="flex size-10 items-center justify-center rounded-full bg-primary/10 text-primary">
        <Icon className="size-5" />
      </div>
      <p className="font-semibold">{title}</p>
      <p className="text-sm text-muted-foreground">{description}</p>
    </button>
  );
}
