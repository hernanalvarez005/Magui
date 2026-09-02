import type { LucideIcon } from "lucide-react";
import {
  BarChart3,
  History,
  LayoutDashboard,
  Package,
  Repeat,
  Settings,
  ShoppingBag,
  Tag,
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
  // Nueva venta es la única acción de escritura en la barra de navegación —
  // el rol viewer (modo observador, solo lectura) nunca la ve.
  { href: "/ventas/nueva", label: "Nueva venta", icon: ShoppingBag, mobile: true, roles: ["admin", "seller"] },
  // Igual que Nueva venta: es una acción de escritura, el rol viewer (solo
  // lectura) nunca la ve. No es "mobile: true" — la barra inferior mobile ya
  // tiene su máximo de 5 ítems; se llega igual desde el menú del header.
  { href: "/cambios", label: "Cambios / Devoluciones", icon: Repeat, roles: ["admin", "seller"] },
  { href: "/ventas", label: "Ventas", icon: BarChart3, mobile: true },
  { href: "/stock", label: "Stock", icon: Package, mobile: true },
  { href: "/stock/movimientos", label: "Movimientos", icon: History },
  { href: "/clientes", label: "Clientes", icon: Users, mobile: true },
  // Solo consulta (productos/kits, precios vigentes, promociones vigentes) —
  // visible para los 3 roles. No es "mobile: true": la barra inferior mobile
  // ya tiene 5 ítems (el máximo recomendado); en mobile se llega igual desde
  // el menú del header (ver app-shell.tsx), que está siempre visible.
  { href: "/precios", label: "Precios", icon: Tag },
  { href: "/admin/precios", label: "Administración", icon: Settings, roles: ["admin"] },
];
