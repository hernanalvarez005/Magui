// Ranking de kits más vendidos (Bloque B) — unidades COMERCIALES netas, tal
// como vienen de dashboard_products_breakdown.top_kits (nunca explotadas a
// componentes: acá "1 kit" siempre vale 1, sea cual sea su composición).
const MEDALS = ["🥇", "🥈", "🥉"];

export function TopKitsList({ items }: { items: { product_id: string; name: string; units: number }[] }) {
  if (items.length === 0) {
    return <p className="py-6 text-center text-sm text-muted-foreground">Sin kits vendidos en este período.</p>;
  }

  return (
    <ol className="flex flex-col gap-2.5">
      {items.map((item, i) => (
        <li key={item.product_id} className="flex items-center justify-between gap-2 text-sm">
          <span className="flex min-w-0 items-center gap-2">
            <span className="w-6 shrink-0 text-center">{MEDALS[i] ?? `${i + 1}º`}</span>
            <span className="truncate font-medium">{item.name}</span>
          </span>
          <span className="shrink-0 tabular-nums text-muted-foreground">{item.units} u.</span>
        </li>
      ))}
    </ol>
  );
}
