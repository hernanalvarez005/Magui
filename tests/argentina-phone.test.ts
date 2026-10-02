import { describe, expect, it } from "vitest";

import { resolveArgentinaNationalNumber, resolveArgentinaWhatsAppNumber } from "@/lib/argentina-phone";

// Bug real: "2215575069" (ya canónico, 10 dígitos: área 221 + abonado
// 5575069) perdía 2 dígitos porque el abonado empieza casualmente con "15"
// — la regex vieja no distinguía eso del "15" histórico real de celular.
// No es un problema de la característica 221: cualquier nacional de 10
// dígitos cuyo abonado empiece con "15" en la posición que el regex viejo
// mira sufre lo mismo (ver casos 9/10).
//
// La regla correcta no depende de ninguna característica: un nacional
// argentino SIEMPRE tiene 10 dígitos (nunca se le saca nada); el formato
// histórico (área + 15 + abonado) SIEMPRE tiene 12 (ahí, y solo ahí, se
// busca el "15" a sacar). Todas las variantes (con/sin código de país,
// con/sin 9, con/sin 0, históricas o no) convergen primero a ese "candidato
// nacional" antes de decidir nada sobre el "15" — ninguna rama corta antes
// de pasar por esa regla (ahí estaba la falla de una primera propuesta: la
// rama "54" hacía return antes de llegar a esa etapa).

describe("resolveArgentinaWhatsAppNumber", () => {
  it("1. bug original reportado: '2215575069' conserva sus 10 dígitos íntegros", () => {
    expect(resolveArgentinaWhatsAppNumber("2215575069")).toBe("5492215575069");
  });

  it("2. con 0 de larga distancia", () => {
    expect(resolveArgentinaWhatsAppNumber("02215575069")).toBe("5492215575069");
  });

  it("3. formato histórico real (área 221 + 15 + abonado, 3+2+7=12), con 0", () => {
    expect(resolveArgentinaWhatsAppNumber("0221155575069")).toBe("5492215575069");
  });

  it("4. ya completo, con código de país y 9", () => {
    expect(resolveArgentinaWhatsAppNumber("+5492215575069")).toBe("5492215575069");
  });

  it("5. con código de país y 9 explícito, con espacios", () => {
    expect(resolveArgentinaWhatsAppNumber("+54 9 221 5575069")).toBe("5492215575069");
  });

  it("6. con código de país, SIN el 9 — nunca tuvo 15, no debe confundirse con histórico", () => {
    expect(resolveArgentinaWhatsAppNumber("54 221 5575069")).toBe("5492215575069");
  });

  it("7. histórico CON código de país — la rama que antes nunca llegaba al strip del 15", () => {
    expect(resolveArgentinaWhatsAppNumber("+54 221 15 5575069")).toBe("5492215575069");
  });

  it("8. histórico con 0 y espacios, sin código de país", () => {
    expect(resolveArgentinaWhatsAppNumber("0 221 15 5575069")).toBe("5492215575069");
  });

  it("8b. histórico CON código de país y 9 explícito a la vez (+54 9 221 15 5575069)", () => {
    expect(resolveArgentinaWhatsAppNumber("+54 9 221 15 5575069")).toBe("5492215575069");
  });

  it("9. canónico de 10 dígitos con '15' en posición 3-4, área 11 — generaliza más allá de 221", () => {
    expect(resolveArgentinaWhatsAppNumber("1115756069")).toBe("5491115756069");
  });

  it("10. canónico de 10 dígitos con '15' en posición 3-4, área de 2 dígitos", () => {
    expect(resolveArgentinaWhatsAppNumber("2115575069")).toBe("5492115575069");
  });

  it("11. control: canónico sin ningún '15', con espacios y guion", () => {
    expect(resolveArgentinaWhatsAppNumber("11 2233-4455")).toBe("5491122334455");
  });

  it("12. vacío/null/undefined -> null", () => {
    expect(resolveArgentinaWhatsAppNumber("")).toBeNull();
    expect(resolveArgentinaWhatsAppNumber(null)).toBeNull();
    expect(resolveArgentinaWhatsAppNumber(undefined)).toBeNull();
  });

  it("13. sin dígitos -> null", () => {
    expect(resolveArgentinaWhatsAppNumber("abc")).toBeNull();
  });

  it("14. longitud inválida (3 dígitos, ni 10 ni 12) -> null, no fabrica un 549... falso", () => {
    expect(resolveArgentinaWhatsAppNumber("123")).toBeNull();
  });

  it("15. longitud inválida (8 dígitos, ni 10 ni 12) -> null", () => {
    expect(resolveArgentinaWhatsAppNumber("22334455")).toBeNull();
  });
});

describe("resolveArgentinaNationalNumber", () => {
  it("siempre devuelve el nacional de 10 dígitos sin el prefijo 549", () => {
    expect(resolveArgentinaNationalNumber("2215575069")).toBe("2215575069");
    expect(resolveArgentinaNationalNumber("+54 221 15 5575069")).toBe("2215575069");
  });

  it("null para una longitud que no resuelve a 10 dígitos", () => {
    expect(resolveArgentinaNationalNumber("123")).toBeNull();
  });
});
