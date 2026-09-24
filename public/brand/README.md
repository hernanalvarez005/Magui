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

## `mark-white.png` (exploración "V1 Elegante", rama claude/magui-v1-elegante-ui)

Variante 100% blanca de `mark.png` (604×604, fondo transparente), usada por
`<Logo variant="mark-white">` en el sidebar oscuro y en el hero del
Dashboard (`components/dashboard/dashboard-hero.tsx`) — ambas superficies
oscuras donde el monograma navy original no tendría contraste. Generada a
partir del canal alfa real de `mark.png` (mismo trazo exacto, RGB
reemplazado por blanco puro) — deliberadamente NO es un `filter: invert()`
en CSS, que hubiera invertido el navy hacia un tono amarillento en vez de
blanco. `mark.png` nunca se modificó. Si se reemplaza `mark.png` por una
versión más reciente de la marca, regenerar `mark-white.png` con el mismo
criterio en vez de dejarlo desactualizado.
