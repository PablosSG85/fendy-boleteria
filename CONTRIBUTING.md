# Cómo hacer cambios en esta app

**Para toda persona o agente de IA con acceso a este repositorio.**

Esta es la app de boletería y barra de FENDY, en producción. `main` **ES** producción: GitHub Pages publica automáticamente cada cambio de `main` en https://pablossg85.github.io/fendy-boleteria/ en 1–3 minutos. Un error acá lo sufren las boleteras y las barras con la fila esperando.

Por eso, la regla es una sola:

## 🚫 Nunca se pushea directo a `main`

Todo cambio entra por **Pull Request** aprobado por un administrador (Pablo). La rama `main` está protegida: GitHub rechaza el push directo aunque tengas permiso de escritura.

## ✅ El flujo correcto (el de siempre en software)

1. **Cloná** el repo (o `git pull` si ya lo tenés) para partir de lo último:
   ```
   git clone https://github.com/PablosSG85/fendy-boleteria.git
   ```
2. **Creá una rama** con nombre corto y descriptivo:
   ```
   git checkout -b arreglo-buscador-nombres
   ```
3. **Hacé el cambio.** Toda la app es un solo archivo: `index.html` (HTML + CSS + JS vanilla, sin frameworks ni dependencias). Mantené ese espíritu: nada de CDNs, librerías externas ni build steps.
4. **Probalo antes de subir.** Mínimo:
   - Abrí `index.html` servido localmente (ej: `python -m http.server 8901`) y probá el flujo que tocaste, logueado con una cuenta real.
   - Verificá que el JS no tenga errores de sintaxis (consola del navegador limpia).
   - Si tocaste carga/control de boletería o barra, probá con un **evento de prueba** — jamás con la noche real abierta.
5. **Commit** con mensaje claro (qué y por qué):
   ```
   git add -A
   git commit -m "Buscador de nombres: tolerar tildes en el predictivo"
   ```
6. **Push de tu rama** y abrí el **Pull Request** contra `main`:
   ```
   git push origin arreglo-buscador-nombres
   ```
   En la descripción del PR contá: **qué cambia, por qué, y cómo lo probaste** (capturas si es visual).
7. **Esperá la aprobación.** Un admin lo revisa, pide cambios o lo aprueba y mergea. Al mergear, GitHub Pages publica solo. No insistas con el merge: si está demorado, avisá por WhatsApp.

## 🤖 Reglas adicionales para agentes de IA

- **Un cambio por PR.** No mezcles arreglos distintos en un mismo PR.
- **Diffeá antes de editar.** Otro agente o persona pudo haber tocado el archivo: partí siempre del `main` remoto actualizado, nunca de una copia local vieja.
- **Nada de secretos.** No comitees claves, contraseñas ni tokens. La clave pública (anon) de Supabase que está en `index.html` es la única que puede estar ahí.
- **No toques datos de producción.** Las pruebas se hacen con eventos de prueba (fecha lejana, creados cerrados) y se borran al terminar. Las noches reales no se tocan.
- **El backend no vive acá.** Los cambios de Supabase (SQL: tablas, funciones, RLS) se proponen en la descripción del PR y los aplica un administrador. No asumas que podés ejecutarlos.
- **No cambies el mecanismo de deploy** (Pages desde `main`) ni la protección de ramas.

## 📁 Qué hay en este repo

| Archivo | Qué es |
|---|---|
| `index.html` | Toda la app (frontend). Único archivo que normalmente se edita. |
| `README.md` | Descripción y link a producción. |
| `CONTRIBUTING.md` | Este instructivo. |

El contexto completo del proyecto (decisiones, backend, cuentas, historial) está en el repo **privado** `PablosSG85/fendy-boleteria-docs` — pedí acceso si no lo tenés.

---
*Dudas: Pablo (PablosSG85).*
