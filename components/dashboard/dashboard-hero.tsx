import Image from "next/image";

// Exploración "V1 Elegante" (rama claude/magui-v1-elegante-ui) — banner
// horizontal puramente visual para el Inicio/Dashboard. Recibe el nombre
// ya resuelto por props (mismo profile.fullName que ya usa AppShell) — no
// hace ninguna consulta propia, no toca KPIs/filtros/lógica del Dashboard.
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

export function DashboardHero({ fullName }: { fullName: string }) {
  const today = capitalize(longDateFormatter.format(new Date()));

  return (
    <section className="relative flex items-center justify-between gap-4 overflow-hidden rounded-xl bg-gradient-to-br from-secondary via-secondary to-accent px-5 py-6 md:h-[200px] md:px-10">
      <div className="flex flex-col gap-1.5">
        <h1 className="font-serif text-2xl italic text-accent-foreground md:text-4xl">
          Hola, {firstName(fullName)}
        </h1>
        <p className="text-sm text-accent-foreground/70 md:text-base">{today}</p>
      </div>

      <Image
        src="/brand/wordmark-hero.png"
        alt="Magui Rejuve"
        width={594}
        height={424}
        className="h-16 w-auto shrink-0 opacity-90 md:h-28"
        priority
        unoptimized
      />
    </section>
  );
}
