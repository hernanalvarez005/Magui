import type { Metadata, Viewport } from "next";
import { Fraunces, Geist, Geist_Mono } from "next/font/google";

import { Toaster } from "@/components/ui/sonner";

import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

// Exploración "V1 Elegante" (rama claude/magui-v1-elegante-ui): serif
// editorial solo para hero/títulos de marca puntuales — ver --font-serif en
// globals.css. La interfaz operativa (tablas, formularios, datos) sigue
// siendo Geist Sans en toda la app, sin excepciones.
const fraunces = Fraunces({
  variable: "--font-fraunces",
  subsets: ["latin"],
  style: ["normal", "italic"],
});

export const metadata: Metadata = {
  title: {
    default: "Magui Rejuve",
    template: "%s · Magui Rejuve",
  },
  description: "Sistema de ventas, precios y stock de Magui Rejuve.",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, statusBarStyle: "default", title: "Magui Rejuve" },
};

export const viewport: Viewport = {
  themeColor: "#faf8f6",
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="es-AR" className={`${geistSans.variable} ${geistMono.variable} ${fraunces.variable} h-full antialiased`}>
      <body className="flex min-h-full flex-col bg-background text-foreground">
        {children}
        <Toaster />
      </body>
    </html>
  );
}
