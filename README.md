# FENDY · Boletería

App de boletería y barra de FENDY. Reemplaza el grupo de WhatsApp para anotar
FREE, descuento, extensión de QR y precios especiales, cargar consumos de barra
y marcar ingresos y entregas en tiempo real.

**App en vivo:** https://pablossg85.github.io/fendy-boleteria/

Es un solo archivo (`index.html`, sin build). Los datos y el login viven en
Supabase (proyecto `duqrcrabazpixdkltpbd`, región `sa-east-1`).
El contexto y las notas internas están en el repo privado `fendy-boleteria-docs`.
Las contraseñas NO van en el código: se piden por privado.

## ¿Querés proponer un cambio?

Leé **[CONTRIBUTING.md](CONTRIBUTING.md)**: los cambios NO se pushean a `main` —
se hacen en una rama, se abre un Pull Request y un administrador lo aprueba.
La rama `main` está protegida y publica directo a producción.

Los cambios de backend (SQL) **tampoco se aplican solos**: van en
`supabase/` y los corre un admin a mano, **después de un backup**.

---

## Esquema (trazabilidad)

Zona horaria de auditoría: **`America/Argentina/Buenos_Aires`**. En la base los
timestamps se guardan en `timestamptz` (UTC); la app y los triggers los muestran
y sellan en hora argentina.

Nada se borra físicamente. Anular = `anulado=true` + `anulado_por` +
`anulado_at` + `motivo_anulacion` (obligatorio).

### `eventos`

Una noche = un evento. Crear uno nuevo **no pisa** el anterior (se sacó el
`UNIQUE` de `fecha`).

| Columna | Tipo | Notas |
|---|---|---|
| `id` | uuid | PK |
| `fecha` | date | YYYY-MM-DD de la noche (aunque sea madrugada del día siguiente) |
| `nombre` | text | Ej. `Sábado 17/10` |
| `abierto` | bool | fuente de verdad del estado |
| `estado` | text generado | `open` / `closed` según `abierto` |
| `creado_por`, `creado_at`, `modificado_por`, `modificado_at` | auditoría | |
| `anulado`, `anulado_por`, `anulado_at`, `motivo_anulacion` | soft-delete | |
| `cerrada_en`, `reporte` | cierre | el reporte JSON se guarda al cerrar |

RPC `abrir_evento(fecha, nombre, cerrar_anterior)` inserta un evento nuevo.
Si `cerrar_anterior=true` pasa los abiertos a `closed` **sin borrar filas**.

### `anotados` (BOLETERÍA)

Tipo de entrada (una ficha puede combinar cantidades):

- `free` → **FREE**
- `sinrec` → **DESCUENTO**
- `ext` → **EXTENDER QR**
- `pago` → **PAGA** (`precio` por persona)

| Extra | Notas |
|---|---|
| `autoriza` / `autoriza_id` | quién autorizó |
| `motivo` | obligatorio si es FREE, DESCUENTO o EXTENDER QR |
| `nota` | libre |
| `ingreso_at` | hora real de la primera entrada (desde `ingresos`) |
| `i_free` / `i_sinrec` / `i_ext` / `i_pago` | cuántos ya ingresaron |
| auditoría + anulación | igual que el resto |

### `ingresos`

Una fila por persona que pasó. `condicion` = `free` \| `sinrec` \| `ext` \|
`pago`. Deshacer **anula** la fila; no la borra. `creado_en` / `creado_at` es
la hora de entrada.

### `consumos` (BARRA)

| Columna | Notas |
|---|---|
| `producto` / `tipo` | del catálogo (`productos`) |
| `cantidad` | unidades de esa línea |
| `botellas` | >0 si es botella entera (Ciroc, Grey Goose, Pravda, Chandon, etc.) |
| `precio_lista` | lista |
| `precio_cobrado` (`precio`) | lo que se cobró |
| `tipo_movimiento` | `VENTA`, `CORTESÍA`, `CUMPLEAÑOS`, `RRPP`, `MESA VIP`, `STAFF`, `INVITACIÓN` |
| `motivo` | obligatorio si es gratis o con descuento |
| `autoriza` | quién autorizó (puede ser distinto de quien cargó) |
| `area` | Principal, VIP, Zebra, Terraza |
| `estado` | `pending` / `delivered` (espejo de `entregado`) |
| `entregado_por`, `entregado_at` | quién y cuándo entregó |
| `creado_por`, `creado_at` | quién cargó y cuándo |
| anulación | igual que el resto |

### `productos`

Catálogo fijo (lista + flag `es_botella`). La app también lo tiene en JS para
no depender de un fetch extra.

### `audit_log`

Una fila por **alta**, **cambio de campo** y **anulación**: `tabla`,
`registro_id`, `accion` (`create` / `change` / `void`), `campo`,
`valor_anterior`, `valor_nuevo`, `quien`, `quien_id`, `cuando`.

Lo leen admin y auditor. Lo escribe un trigger; el cliente no inserta ahí.

### `perfiles.rol`

`admin` | `boleteria` | `barra` | **`auditor`**.

`grokbot@fendyfunclub.com` es **auditor**: ve y exporta todo, no crea ni
modifica. Eso lo cubren RLS + las RPC (`marcar_ingreso`, `entregar_consumos`,
`anular_*`, `abrir_evento`, `reporte_noche` con `p_cerrar`).

---

## Backup y migración (a mano, en este orden)

**No mergear este cambio a `main` ni aplicarlo a producción sin aprobación.**
`main` publica solo a GitHub Pages; el SQL hay que pegarlo en el SQL Editor.

### 1. Backup (obligatorio, antes de tocar nada)

Opción A — SQL de copia (recomendado, queda en el mismo proyecto):

1. Dashboard → SQL Editor.
2. Pegar **`supabase/backup_pre_trazabilidad.sql`** → Run.
3. Verificar que origen y copia tengan las mismas cantidades.

Opción B — dump / PITR:

- Dashboard → Database → Backups.
- O `pg_dump` con la connection string (Settings → Database). **Nunca**
  commitear el dump al repo: hay datos de personas.

### 2. Migración

Pegar **`supabase/migrations/20261023_trazabilidad.sql`** en el SQL Editor →
Run. Después, en Dashboard → Settings → API → **Reload schema cache**
(PostgREST), si no las columnas nuevas no aparecen. El `SELECT` final tiene
que mostrar:

- las mismas cantidades de `eventos` / `anotados` / `consumos` que el backup
- `evento_2026-10-17` = 1 (noche abierta actual, datos intactos)
- `grokbot@fendyfunclub.com` con rol `auditor`

Los 13 eventos históricos (18/07, 25/07, …, 17/10) **se conservan**. No se
mueve nada de una noche a otra. El evento del 17/10/2026 se nombra
`Sábado 17/10` y sigue abierto.

### 3. Frontend

Recién después de (1) y (2), mergear el PR. GitHub Pages publica en 1–3 min.

### Rollback (si hace falta)

Los datos siguen en `public.*` (soft-delete, no se perdió nada) y la copia
está en schema `backup_pre_trazabilidad`. Restaurar es un
`INSERT … SELECT` desde ese schema; pedíselo a un admin, no lo corras a ciegas.
El frontend anterior **no** habla con las columnas nuevas: si hay que volver
atrás la UI, revertí el merge **después** de decidir qué hacer con el SQL.
