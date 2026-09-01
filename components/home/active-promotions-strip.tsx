import Link from "next/link";

import { Badge } from "@/components/ui/badge";
import type { PromotionParticipant } from "@/lib/promotions/active-promotions";
import type { PromotionType } from "@/types/database";

interface PromotionLite {
  id: string;
  name: string;
  type: PromotionType;
  discount_percent: string | null;
}

function pct(discount: string | null) {
  return discount ? `${Math.round(Number(discount) * 100)}%` : "";
}

/**
 * Compacto a propósito (sección 3 del pedido: "no convertir la Home en una
 * pantalla administrativa") — solo nombre + beneficio + participantes, en
 * una tira horizontal que scrollea en mobile (equivalente a un carrusel,
 * sin librería nueva). El detalle completo (precios, precio promocional)
 * vive en /precios — cada card linkea ahí (sección 5).
 */
export function ActivePromotionsStrip({
  promotions,
  participantsByPromotion,
}: {
  promotions: PromotionLite[];
  participantsByPromotion: Map<string, PromotionParticipant[]>;
}) {
  if (promotions.length === 0) {
    // Sección 7: nada de bloque grande vacío — un estado compacto de una
    // sola línea, o directamente se podría ocultar; se deja este mensaje
    // corto porque confirma que "no hay promos" es un estado leído, no un
    // bloque roto/cargando.
    return (
      <div className="rounded-xl border border-dashed border-border px-4 py-3 text-center text-sm text-muted-foreground">
        No hay promociones vigentes.
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-muted-foreground">Promociones vigentes</h2>
        <Link href="/precios" className="text-xs font-medium text-primary">
          Ver en Precios
        </Link>
      </div>
      <div className="-mx-4 flex gap-3 overflow-x-auto px-4 pb-1 md:mx-0 md:flex-wrap md:px-0">
        {promotions.map((promo) => {
          const participants = participantsByPromotion.get(promo.id) ?? [];
          const benefit = promo.type === "THREE_FOR_TWO" ? "3x2" : `${pct(promo.discount_percent)} OFF`;
          const names = participants.map((p) => p.name).join(", ") || "—";
          return (
            <Link
              key={promo.id}
              href="/precios"
              className="flex w-56 shrink-0 flex-col gap-1.5 rounded-xl border border-primary/30 bg-primary/5 p-3 transition-colors hover:bg-primary/10 md:w-64"
            >
              {/* Badge (solo el beneficio) y nombre en renglones separados —
                  nunca en la misma línea, para que un nombre largo nunca se
                  vea "pegado" al badge ni corra el riesgo de un truncado a
                  mitad de palabra que parezca repetir el beneficio. */}
              <Badge className="w-fit">{benefit}</Badge>
              <p className="line-clamp-2 text-sm font-medium leading-snug">{promo.name}</p>
              <p className="line-clamp-2 text-xs text-muted-foreground">{names}</p>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
