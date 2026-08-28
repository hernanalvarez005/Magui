import { expect, test } from "@playwright/test";

// Smoke E2E: no requiere una base Supabase real (proxy.ts fallа "cerrado" —
// trata cualquier error de red hacia Auth como "sin sesión" en vez de romper).
// El flujo completo de venta se prueba localmente contra `supabase start`.

test("la pantalla de login carga y pide email/contraseña", async ({ page }) => {
  await page.goto("/login");
  await expect(page.getByRole("heading", { name: "Maguirejuve" })).toBeVisible();
  await expect(page.getByLabel("Email")).toBeVisible();
  await expect(page.getByLabel("Contraseña")).toBeVisible();
  await expect(page.getByRole("button", { name: "Ingresar" })).toBeVisible();
});

test("una ruta protegida sin sesión redirige a /login", async ({ page }) => {
  await page.goto("/ventas/nueva");
  await expect(page).toHaveURL(/\/login/);
});

test("login con credenciales inválidas muestra un error legible", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("Email").fill("nadie@maguirejuve.com");
  await page.getByLabel("Contraseña").fill("contraseña-incorrecta");
  await page.getByRole("button", { name: "Ingresar" }).click();
  await expect(page.getByRole("alert")).toBeVisible({ timeout: 15_000 });
});
