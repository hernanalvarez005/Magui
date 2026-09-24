# Logo de Magui Rejuve

Esta carpeta está lista para recibir el isotipo real de la marca. En cuanto
se agreguen estos dos archivos, el logo aparece solo en el login, la barra
lateral y el header — sin tocar código (ver `components/layout/logo.tsx`).

- **`logo.png`** — isotipo completo (el monograma "MR" + el texto "MAGUI
  REJUVE" debajo), usado en la pantalla de login. Recomendado: cuadrado o
  casi cuadrado, fondo transparente, al menos 400×400px.
- **`mark.png`** — solo el monograma "MR", sin texto, usado en la barra
  lateral, el header mobile y (a futuro) el favicon. Recomendado: cuadrado,
  fondo transparente, al menos 200×200px.

Mientras no estén estos archivos, la app sigue funcionando con el
monograma genérico anterior (una "M" en un cuadrado de color) — no hay
ningún error ni pantalla rota por su ausencia.

## `wordmark-hero.png` (exploración "V1 Elegante", rama claude/magui-v1-elegante-ui)

Lockup horizontal (MR + "MAGUI REJUVE", 594×424, fondo transparente) usado
en `components/dashboard/dashboard-hero.tsx`. Recortado y con el blanco de
fondo convertido a transparencia a partir del isotipo oficial cuadrado que
compartió el usuario — mismo trazo/color, sin el espacio en blanco
sobrante. Si se reemplaza `logo.png`/`mark.png` por una versión más
reciente de la marca, conviene regenerar también este archivo con el mismo
criterio (recorte ajustado al contenido + fondo transparente) en vez de
dejarlo desactualizado.
