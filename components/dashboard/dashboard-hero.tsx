import { Logo } from "@/components/layout/logo";
import { formatDate } from "@/lib/utils";

// Exploración "V1 Elegante" (rama claude/magui-v1-elegante-ui) — banner
// horizontal puramente visual para el Inicio/Dashboard. Recibe todo por
// props (fullName: mismo profile.fullName que ya usa AppShell; from/to: los
// mismos que ya resuelve la página para las RPC) — no hace ninguna consulta
// propia, no toca KPIs/filtros/lógica del Dashboard. El período de la
// derecha es de SOLO LECTURA (mismos valores ya resueltos server-side): el
// control interactivo real sigue siendo DashboardFilters, sin tocar.
const longDateFormatter = new Intl.DateTimeFormat("es-AR", {
  timeZone: "America/Argentina/Buenos_Aires",
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
});

/** "María Martínez" -> "María" — saludo más cálido, mismo dato, sin tocar el perfil real. */
function firstName(fullName: string): string {
  return fullName.trim().split(/\s+/)[0] ?? fullName;
}

function capitalize(text: string): string {
  return text.length > 0 ? text[0].toUpperCase() + text.slice(1) : text;
}

export function DashboardHero({ fullName, from, to }: { fullName: string; from: string; to: string }) {
  const today = capitalize(longDateFormatter.format(new Date()));

  return (
    <section
      className="relative flex flex-col gap-3 overflow-hidden rounded-xl px-5 py-4 md:h-[200px] md:flex-row md:items-center md:justify-between md:gap-6 md:px-10 md:py-6"
      style={{
        // Sin foto de marca disponible todavía (auditado en /public/brand) —
        // textura sobria vía gradiente: carbón profundo hacia beige/taupe en
        // el extremo derecho. Reemplazar por background-image el día que
        // exista una fotografía oficial apropiada, misma estructura.
        background: "linear-gradient(115deg, oklch(0.19 0.015 40) 0%, oklch(0.19 0.015 40) 45%, oklch(0.32 0.03 45) 100%)",
      }}
    >
      {/* Fila 1 en mobile (logo + saludo compacto) / columna izquierda en desktop (logo + separador). */}
      <div className="flex items-center gap-3 md:shrink-0 md:gap-5">
        <Logo variant="mark-white" className="size-8 shrink-0 md:size-11" />
        <div className="hidden h-10 w-px bg-white/20 md:block" />
        <h1 className="font-serif text-xl italic text-white md:hidden">Hola, {firstName(fullName)}</h1>
      </div>

      {/* Centro (solo desktop): saludo grande + fecha completa. */}
      <div className="hidden flex-col gap-1.5 md:flex">
        <h1 className="font-serif text-4xl italic text-white">Hola, {firstName(fullName)}</h1>
        <p className="text-base text-white/70">{today}</p>
      </div>

      {/* Fila 2 en mobile (fecha + período compactos) / columna derecha en desktop (período,
          solo lectura — el control real es DashboardFilters, debajo, sin tocar). */}
      <div className="flex items-center justify-between gap-3 md:flex-col md:items-end md:justify-center md:gap-1">
        <p className="text-xs text-white/70 md:hidden">{today}</p>
        <div className="flex flex-col items-end gap-0.5">
          <p className="text-[10px] font-medium uppercase tracking-wide text-white/50 md:text-[11px]">Período</p>
          <p className="text-xs font-medium text-white/85 md:text-sm">
            {formatDate(from)} — {formatDate(to)}
          </p>
        </div>
      </div>
    </section>
  );
}
