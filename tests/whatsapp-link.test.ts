import { describe, expect, it } from "vitest";

import { whatsAppLink } from "@/lib/utils";

// Integración liviana: confirma que whatsAppLink() arma la URL sobre el
// número que resuelve resolveArgentinaWhatsAppNumber() (lib/argentina-phone.ts)
// — la normalización en sí ya está cubierta a fondo en
// tests/argentina-phone.test.ts, acá solo se verifica que whatsAppLink no
// mantenga un segundo algoritmo propio y arme bien la URL final.

describe("whatsAppLink", () => {
  it("'2215575069' produce el link con el destino correcto (bug original)", () => {
    expect(whatsAppLink("2215575069")).toBe("https://wa.me/5492215575069");
  });

  it("formato histórico produce el mismo destino que el canónico equivalente", () => {
    expect(whatsAppLink("0221155575069")).toBe("https://wa.me/5492215575069");
  });

  it("input inválido devuelve null, no un link roto", () => {
    expect(whatsAppLink("123")).toBeNull();
    expect(whatsAppLink(null)).toBeNull();
    expect(whatsAppLink("")).toBeNull();
  });
});
