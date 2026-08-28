import type { LucideIcon } from "lucide-react";
import {
  BarChart3,
  History,
  LayoutDashboard,
  Package,
  Settings,
  ShoppingBag,
  Users,
} from "lucide-react";

import type { AppRole } from "@/types/database";

export interface NavItem {
  href: string;
  label: string;
  icon: LucideIcon;
  roles?: AppRole[];
  /** Se muestra en la barra inferior mobile (máximo 5 ítems recomendado). */
  mobile?: boolean;
}

export const navItems: NavItem[] = [
  { href: "/", label: "Inicio", icon: LayoutDashboard, mobile: true },
  { href: "/ventas/nueva", label: "Nueva venta", icon: ShoppingBag, mobile: true },
  { href: "/ventas", label: "Ventas", icon: BarChart3, mobile: true },
  { href: "/stock", label: "Stock", icon: Package, mobile: true },
  { href: "/stock/movimientos", label: "Movimientos", icon: History },
  { href: "/clientes", label: "Clientes", icon: Users, mobile: true },
  { href: "/admin/precios", label: "Administración", icon: Settings, roles: ["admin"] },
];
