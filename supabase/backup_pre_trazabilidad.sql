-- =============================================================================
-- FENDY · Boletería — BACKUP MANUAL (correr ANTES de la migración)
-- Proyecto: duqrcrabazpixdkltpbd  (https://supabase.com/dashboard/project/duqrcrabazpixdkltpbd)
--
-- Qué hace: copia las tablas de producción a un schema aparte. NO cambia datos
-- de la app. Es el paso 1; el paso 2 es migrations/20261023_trazabilidad.sql.
--
-- Cómo correrlo:
--   1. Supabase Dashboard → SQL Editor → New query
--   2. Pegá este archivo completo → Run
--   3. Verificá que las filas copiadas coincidan (el SELECT final)
--
-- También conviene: Dashboard → Database → Backups (PITR / backup diario)
-- o `pg_dump` con la connection string de la DB (Settings → Database).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS backup_pre_trazabilidad;

DROP TABLE IF EXISTS backup_pre_trazabilidad.eventos CASCADE;
DROP TABLE IF EXISTS backup_pre_trazabilidad.anotados CASCADE;
DROP TABLE IF EXISTS backup_pre_trazabilidad.consumos CASCADE;
DROP TABLE IF EXISTS backup_pre_trazabilidad.ingresos CASCADE;
DROP TABLE IF EXISTS backup_pre_trazabilidad.perfiles CASCADE;
DROP TABLE IF EXISTS backup_pre_trazabilidad.clientes CASCADE;

CREATE TABLE backup_pre_trazabilidad.eventos  AS TABLE public.eventos;
CREATE TABLE backup_pre_trazabilidad.anotados AS TABLE public.anotados;
CREATE TABLE backup_pre_trazabilidad.consumos AS TABLE public.consumos;
CREATE TABLE backup_pre_trazabilidad.ingresos AS TABLE public.ingresos;
CREATE TABLE backup_pre_trazabilidad.perfiles AS TABLE public.perfiles;
CREATE TABLE backup_pre_trazabilidad.clientes AS TABLE public.clientes;

COMMENT ON SCHEMA backup_pre_trazabilidad IS
  'Copia previa a la migración de trazabilidad (eventos persistentes, soft-delete, audit_log). No borrar hasta confirmar la app en producción.';

-- Verificación: estas cantidades tienen que coincidir con public.*
SELECT 'eventos'  AS tabla, (SELECT count(*) FROM public.eventos)  AS origen, (SELECT count(*) FROM backup_pre_trazabilidad.eventos)  AS copia
UNION ALL
SELECT 'anotados',          (SELECT count(*) FROM public.anotados),           (SELECT count(*) FROM backup_pre_trazabilidad.anotados)
UNION ALL
SELECT 'consumos',          (SELECT count(*) FROM public.consumos),           (SELECT count(*) FROM backup_pre_trazabilidad.consumos)
UNION ALL
SELECT 'ingresos',          (SELECT count(*) FROM public.ingresos),           (SELECT count(*) FROM backup_pre_trazabilidad.ingresos)
UNION ALL
SELECT 'perfiles',          (SELECT count(*) FROM public.perfiles),           (SELECT count(*) FROM backup_pre_trazabilidad.perfiles)
UNION ALL
SELECT 'clientes',          (SELECT count(*) FROM public.clientes),           (SELECT count(*) FROM backup_pre_trazabilidad.clientes);
