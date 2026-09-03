// Donut de productos vendidos INDIVIDUALMENTE (unidades físicas netas) — los
// datos ya vienen resueltos por dashboard_products_breakdown (Bloque A):
// top 6 + "Otros", kits ya descompuestos en sus componentes históricos
// reales. Acá solo se dibuja: conic-gradient + leyenda, sin librería de
// gráficos (mismo criterio que revenue-by-day-chart.tsx/bar-list.tsx).
interface DonutItem {
  product_id: string;
  name: string;
  units: number;
}

// Colores diferenciados por índice vía rotación de matiz "golden angle" —
// nunca una paleta fija/hardcodeada, así que soporta cualquier cantidad de
// productos sin repetir tonos cercanos. "Otros" queda siempre gris neutro,
// para no competir visualmente con los productos reales.
function colorFor(index: number) {
  return `hsl(${Math.round((index * 137.508) % 360)} 65% 55%)`;
}
const OTHERS_COLOR = "hsl(0 0% 65%)";

export function ProductsDonutChart({ top, othersUnits }: { top: DonutItem[]; othersUnits: number }) {
  const items = [
    ...top.map((t) => ({ key: t.product_id, label: t.name, value: t.units })),
    ...(othersUnits > 0 ? [{ key: "__others__", label: "Otros", value: othersUnits }] : []),
  ];
  const total = items.reduce((sum, i) => sum + i.value, 0);

  if (total === 0) {
    return <p className="py-6 text-center text-sm text-muted-foreground">Sin ventas de productos individuales en este período.</p>;
  }

  let acc = 0;
  const stops = items.map((item, i) => {
    const from = (acc / total) * 100;
    acc += item.value;
    const to = (acc / total) * 100;
    return { ...item, from, to, color: item.key === "__others__" ? OTHERS_COLOR : colorFor(i) };
  });

  const gradient = `conic-gradient(${stops.map((s) => `${s.color} ${s.from}% ${s.to}%`).join(", ")})`;

  return (
    <div className="flex flex-col items-center gap-4 sm:flex-row">
      <div className="relative size-36 shrink-0 rounded-full" style={{ background: gradient }} role="img" aria-label="Distribución de productos vendidos individualmente">
        <div className="absolute inset-3 flex items-center justify-center rounded-full bg-background">
          <span className="text-xs font-medium text-muted-foreground">{total} u.</span>
        </div>
      </div>
      <ul className="flex w-full flex-1 flex-col gap-1.5 text-sm">
        {stops.map((s) => (
          <li key={s.key} className="flex items-center justify-between gap-2">
            <span className="flex min-w-0 items-center gap-2">
              <span className="size-2.5 shrink-0 rounded-full" style={{ backgroundColor: s.color }} />
              <span className="truncate">{s.label}</span>
            </span>
            <span className="shrink-0 tabular-nums text-muted-foreground">
              {s.value} u. · {Math.round((s.value / total) * 100)}%
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
