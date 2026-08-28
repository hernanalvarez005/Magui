import { formatCurrency } from "@/lib/utils";

export function RevenueByDayChart({ data }: { data: { day: string; revenue: number }[] }) {
  if (data.length === 0) {
    return <p className="py-6 text-center text-sm text-muted-foreground">Sin ventas en este período.</p>;
  }

  const max = Math.max(...data.map((d) => d.revenue), 1);
  const width = 600;
  const height = 160;
  const barGap = 4;
  const barWidth = data.length > 0 ? width / data.length - barGap : 0;

  return (
    <div className="flex flex-col gap-2">
      <svg viewBox={`0 0 ${width} ${height}`} className="h-40 w-full" preserveAspectRatio="none" role="img" aria-label="Facturación por día">
        {data.map((d, i) => {
          const barHeight = (d.revenue / max) * (height - 20);
          const x = i * (barWidth + barGap);
          const y = height - barHeight;
          return (
            <g key={d.day}>
              <rect
                x={x}
                y={y}
                width={Math.max(barWidth, 1)}
                height={Math.max(barHeight, 1)}
                rx={3}
                className="fill-primary"
              >
                <title>
                  {d.day}: {formatCurrency(d.revenue)}
                </title>
              </rect>
            </g>
          );
        })}
      </svg>
      <div className="flex justify-between text-xs text-muted-foreground">
        <span>{data[0]?.day}</span>
        {data.length > 1 ? <span>{data[data.length - 1]?.day}</span> : null}
      </div>
    </div>
  );
}
