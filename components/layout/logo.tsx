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
  variant?: "mark" | "full";
  className?: string;
}) {
  const [errored, setErrored] = useState(false);
  const { width, height } = SIZES[variant];

  if (errored) {
    // Antes de subir el archivo real, mismo monograma genérico "M" que ya
    // existía — en "full" además se acompaña con el texto, para no perder
    // el nombre de la marca mientras tanto (el isotipo real ya trae el
    // texto incorporado, este fallback no).
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
      src={variant === "full" ? "/brand/logo.png" : "/brand/mark.png"}
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
