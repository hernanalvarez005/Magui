import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

// MAGUI REJUVE — BLOQUE FINAL, sección 1 (Logo/PWA). Verifica que la
// identidad quede consistente entre metadata de Next.js, el manifest y los
// archivos de ícono reales — sin re-parsear app/layout.tsx (es un Server
// Component con JSX, no un módulo importable en un test de Node), se lee
// su fuente como texto para confirmar los valores de metadata.
const root = resolve(__dirname, "..");

describe("Branding Magui Rejuve — metadata (sección 1.3 del pedido)", () => {
  it("app/layout.tsx define el título por defecto y el template como 'Magui Rejuve'", () => {
    const layoutSrc = readFileSync(resolve(root, "app/layout.tsx"), "utf-8");
    expect(layoutSrc).toMatch(/default:\s*"Magui Rejuve"/);
    expect(layoutSrc).toMatch(/template:\s*"%s · Magui Rejuve"/);
    expect(layoutSrc).toMatch(/appleWebApp:[\s\S]*title:\s*"Magui Rejuve"/);
    expect(layoutSrc).toContain('manifest: "/manifest.webmanifest"');
  });
});

describe("Branding Magui Rejuve — manifest (sección 1.3 del pedido)", () => {
  const manifest = JSON.parse(readFileSync(resolve(root, "public/manifest.webmanifest"), "utf-8"));

  it("name y short_name son exactamente 'Magui Rejuve'", () => {
    expect(manifest.name).toBe("Magui Rejuve");
    expect(manifest.short_name).toBe("Magui Rejuve");
  });

  it("declara al menos un ícono de 192x192 y uno de 512x512 (mínimo PWA instalable)", () => {
    const sizes = manifest.icons.map((i: { sizes: string }) => i.sizes);
    expect(sizes).toContain("192x192");
    expect(sizes).toContain("512x512");
  });

  it("todos los íconos declarados en el manifest existen físicamente en public/", () => {
    for (const icon of manifest.icons as { src: string }[]) {
      const path = resolve(root, "public", icon.src.replace(/^\//, ""));
      expect(existsSync(path), `falta el archivo ${icon.src}`).toBe(true);
    }
  });
});

describe("Branding Magui Rejuve — íconos de app (favicon / Apple touch icon)", () => {
  it("app/icon.png (favicon) existe — reemplaza al monograma genérico anterior", () => {
    expect(existsSync(resolve(root, "app/icon.png"))).toBe(true);
  });

  it("app/apple-icon.png (apple-touch-icon, acceso directo desde celular) existe", () => {
    expect(existsSync(resolve(root, "app/apple-icon.png"))).toBe(true);
  });

  it("no quedó el ícono genérico anterior (app/icon.svg) duplicando la configuración", () => {
    expect(existsSync(resolve(root, "app/icon.svg"))).toBe(false);
    expect(existsSync(resolve(root, "public/icon.svg"))).toBe(false);
  });

  it("el isotipo real (public/brand/mark.png y logo.png) está presente — Logo() ya no cae al fallback genérico", () => {
    expect(existsSync(resolve(root, "public/brand/mark.png"))).toBe(true);
    expect(existsSync(resolve(root, "public/brand/logo.png"))).toBe(true);
  });
});
