"use client";

import { useState } from "react";
import Image from "next/image";

import { cn } from "@/lib/utils";

const SIZES = {
  // Mark: el ícono cuadrado solo (sidebar, header mobile, favicon).
  mark: { width: 40, height: 40 },
  // Full: isotipo + wordmark completo (pantalla de login).
  full: { width: 220, height: 220 },
} as const;

const SOURCES = {
  mark: "/brand/mark.png",
  full: "/brand/logo.png",
  // V1 Elegante (rama claude/magui-v1-elegante-ui): variantes blancas,
  // derivadas de mark.png/logo.png preservando su canal alfa original
  // (mismo trazo, sin invert) — para el sidebar oscuro y el hero.
  "mark-white": "/brand/mark-white.png",
} as const;

/**
 * Logo de Magui Rejuve. Busca los archivos reales en public/brand/ (mark.png
 * para el ícono cuadrado, logo.png para el isotipo completo con texto) — si
 * todavía no se subieron, cae automáticamente al monograma genérico anterior
 * en vez de romper el layout. En cuanto se agreguen esos dos archivos al
 * repo, el logo real aparece solo, sin tocar código.
 */
export function Logo({
  variant = "mark",
  className,
}: {
  variant?: "mark" | "full" | "mark-white";
  className?: string;
}) {
  const [errored, setErrored] = useState(false);
  const { width, height } = SIZES[variant === "mark-white" ? "mark" : variant];

  if (errored) {
    // Antes de subir el archivo real, mismo monograma genérico "M" que ya
    // existía — en "full" además se acompaña con el texto, para no perder
    // el nombre de la marca mientras tanto (el isotipo real ya trae el
    // texto incorporado, este fallback no). "mark-white" cae al mismo
    // fallback en blanco sobre el carbón del sidebar, nunca al monograma
    // con fondo --primary (ilegible sobre un fondo ya oscuro).
    if (variant === "mark-white") {
      return (
        <div
          className={cn(
            "flex items-center justify-center rounded-xl border border-white/30 font-serif text-white",
            className
          )}
        >
          M
        </div>
      );
    }
    return variant === "full" ? (
      <div className={cn("flex flex-col items-center gap-2", className)}>
        <div className="flex size-14 items-center justify-center rounded-2xl bg-primary text-2xl font-serif text-primary-foreground">
          M
        </div>
        <p className="text-xl font-semibold">Magui Rejuve</p>
      </div>
    ) : (
      <div
        className={cn(
          "flex items-center justify-center rounded-xl bg-primary font-serif text-primary-foreground",
          className
        )}
      >
        M
      </div>
    );
  }

  return (
    <Image
      src={SOURCES[variant]}
      alt="Magui Rejuve"
      width={width}
      height={height}
      className={cn("object-contain", className)}
      onError={() => setErrored(true)}
      priority={variant === "full"}
      unoptimized
    />
  );
}
