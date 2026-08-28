import { formatCurrency } from "@/lib/utils";

interface BarListItem {
  label: string;
  value: number;
  sublabel?: string;
}

export function BarList({
  items,
  valueFormat = "currency",
  emptyLabel = "Sin datos en este período.",
}: {
  items: BarListItem[];
  valueFormat?: "currency" | "number";
  emptyLabel?: string;
}) {
  if (items.length === 0) {
    return <p className="py-6 text-center text-sm text-muted-foreground">{emptyLabel}</p>;
  }

  const max = Math.max(...items.map((i) => i.value), 1);

  return (
    <div className="flex flex-col gap-3">
      {items.map((item) => (
        <div key={item.label} className="flex flex-col gap-1">
          <div className="flex items-baseline justify-between gap-2 text-sm">
            <span className="truncate font-medium">{item.label}</span>
            <span className="shrink-0 tabular-nums text-muted-foreground">
              {valueFormat === "currency" ? formatCurrency(item.value) : item.value}
              {item.sublabel ? <span className="ml-1">· {item.sublabel}</span> : null}
            </span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
            <div
              className="h-full rounded-full bg-primary"
              style={{ width: `${Math.max((item.value / max) * 100, 3)}%` }}
            />
          </div>
        </div>
      ))}
    </div>
  );
}
