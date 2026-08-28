"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { cn } from "@/lib/utils";

const TABS = [
  { href: "/admin/productos", label: "Productos" },
  { href: "/admin/precios", label: "Precios" },
  { href: "/admin/promociones", label: "Promociones" },
  { href: "/admin/doctores", label: "Doctoras" },
  { href: "/admin/usuarios", label: "Usuarios" },
];

export function AdminTabs() {
  const pathname = usePathname();

  return (
    <div className="flex gap-1 overflow-x-auto rounded-lg bg-muted p-1">
      {TABS.map((tab) => {
        const active = pathname.startsWith(tab.href);
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={cn(
              "shrink-0 rounded-md px-3.5 py-1.5 text-sm font-medium transition-colors",
              active ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
            )}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
