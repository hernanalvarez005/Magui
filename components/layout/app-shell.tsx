"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { LogOut, Settings, User as UserIcon } from "lucide-react";

import { navItems } from "@/components/layout/nav-items";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { createClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";
import type { AppRole } from "@/types/database";

function isActive(pathname: string, href: string) {
  if (href === "/") return pathname === "/";
  return pathname === href || pathname.startsWith(href + "/");
}

export function AppShell({
  fullName,
  role,
  locationLabel,
  children,
}: {
  fullName: string;
  role: AppRole;
  locationLabel: string;
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();

  const visibleItems = navItems.filter((item) => !item.roles || item.roles.includes(role));
  const mobileItems = visibleItems.filter((item) => item.mobile).slice(0, 5);

  async function handleSignOut() {
    const supabase = createClient();
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <div className="flex min-h-screen w-full">
      {/* Sidebar desktop */}
      <aside className="hidden w-64 shrink-0 flex-col border-r border-border bg-card md:flex">
        <div className="flex items-center gap-2.5 px-5 py-5">
          <div className="flex size-9 items-center justify-center rounded-xl bg-primary font-serif text-primary-foreground">
            M
          </div>
          <div>
            <p className="text-sm font-semibold leading-tight">Maguirejuve</p>
            <p className="text-xs text-muted-foreground">{locationLabel}</p>
          </div>
        </div>
        <nav className="flex flex-1 flex-col gap-1 px-3">
          {visibleItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
                isActive(pathname, item.href)
                  ? "bg-primary/10 text-primary"
                  : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
              )}
            >
              <item.icon className="size-4.5 shrink-0" />
              {item.label}
            </Link>
          ))}
        </nav>
        <div className="border-t border-border p-3">
          <button
            onClick={handleSignOut}
            className="flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground"
          >
            <LogOut className="size-4.5" />
            Cerrar sesión
          </button>
        </div>
      </aside>

      <div className="flex min-h-screen flex-1 flex-col">
        {/* Header mobile + desktop */}
        <header className="sticky top-0 z-30 flex h-14 shrink-0 items-center justify-between border-b border-border bg-card/95 px-4 backdrop-blur supports-[backdrop-filter]:bg-card/80 md:h-16 md:px-6">
          <div className="flex items-center gap-2 md:hidden">
            <div className="flex size-8 items-center justify-center rounded-lg bg-primary font-serif text-sm text-primary-foreground">
              M
            </div>
            <span className="text-sm font-semibold">Maguirejuve</span>
          </div>
          <div className="hidden text-sm text-muted-foreground md:block">{locationLabel}</div>

          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" className="rounded-full">
                <UserIcon className="size-5" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuLabel>
                <p className="font-medium">{fullName}</p>
                <p className="text-xs font-normal text-muted-foreground">
                  {role === "admin" ? "Administrador/a" : "Vendedora"}
                </p>
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              {role === "admin" ? (
                <DropdownMenuItem asChild>
                  <Link href="/admin/precios">
                    <Settings className="mr-2 size-4" /> Administración
                  </Link>
                </DropdownMenuItem>
              ) : null}
              <DropdownMenuItem onClick={handleSignOut}>
                <LogOut className="mr-2 size-4" /> Cerrar sesión
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </header>

        <main className="flex-1 pb-20 md:pb-6">{children}</main>

        {/* Bottom tab bar mobile */}
        <nav className="safe-bottom fixed inset-x-0 bottom-0 z-30 grid border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80 md:hidden"
          style={{ gridTemplateColumns: `repeat(${mobileItems.length}, minmax(0, 1fr))` }}
        >
          {mobileItems.map((item) => {
            const active = isActive(pathname, item.href);
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex flex-col items-center gap-1 py-2.5 text-[11px] font-medium",
                  active ? "text-primary" : "text-muted-foreground"
                )}
              >
                <item.icon className={cn("size-5", active && "fill-primary/15")} />
                {item.label}
              </Link>
            );
          })}
        </nav>
      </div>
    </div>
  );
}
