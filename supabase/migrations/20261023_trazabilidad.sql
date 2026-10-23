-- =============================================================================
-- FENDY · Boletería — migración de trazabilidad
-- Fecha: 2026-10-23
-- Proyecto: duqrcrabazpixdkltpbd
--
-- PRECONDICIÓN: ya corriste backup_pre_trazabilidad.sql y verificaste las copias.
-- ESTE SCRIPT TOCA PRODUCCIÓN. Correrlo a mano en el SQL Editor, NO desde un
-- merge automático. Después se mergea el PR del frontend.
--
-- Qué hace:
--   1. Eventos persistentes (varios por fecha, estado open/closed, no overwrite)
--   2. Soft-delete (anulado + motivo) — nada se borra físicamente
--   3. Auditoría en cada fila + tabla audit_log
--   4. Campos extra de BARRA y BOLETERÍA
--   5. Rol auditor (grokbot@fendyfunclub.com) de solo lectura
--   6. Backfill del evento 2026-10-17 y de todas las noches históricas
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Helpers de rol
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.es_auditor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'auditor');
$$;

CREATE OR REPLACE FUNCTION public.es_admin_o_auditor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.es_admin() OR public.es_auditor();
$$;

-- -----------------------------------------------------------------------------
-- 1. EVENTOS: varias noches por fecha, estado open/closed, auditoría
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.eventos_fecha_key;
ALTER TABLE public.eventos DROP CONSTRAINT IF EXISTS eventos_fecha_key;

ALTER TABLE public.eventos
  ADD COLUMN IF NOT EXISTS creado_por text,
  ADD COLUMN IF NOT EXISTS creado_at timestamptz,
  ADD COLUMN IF NOT EXISTS modificado_por text,
  ADD COLUMN IF NOT EXISTS modificado_at timestamptz,
  ADD COLUMN IF NOT EXISTS anulado boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS anulado_por text,
  ADD COLUMN IF NOT EXISTS anulado_at timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

UPDATE public.eventos
   SET creado_at = COALESCE(creado_at, creado_en, now()),
       nombre    = COALESCE(NULLIF(nombre,''), 'Evento '||to_char(fecha,'YYYY-MM-DD'))
 WHERE creado_at IS NULL OR nombre IS NULL OR nombre = '';

ALTER TABLE public.eventos
  ALTER COLUMN creado_at SET DEFAULT now(),
  ALTER COLUMN creado_at SET NOT NULL,
  ALTER COLUMN nombre SET DEFAULT '';

-- estado derivado: 'open' / 'closed' (abierto sigue siendo la fuente de verdad)
ALTER TABLE public.eventos DROP COLUMN IF EXISTS estado;
ALTER TABLE public.eventos
  ADD COLUMN estado text GENERATED ALWAYS AS (CASE WHEN abierto THEN 'open' ELSE 'closed' END) STORED;

CREATE INDEX IF NOT EXISTS eventos_fecha_idx ON public.eventos (fecha DESC);
CREATE INDEX IF NOT EXISTS eventos_abierto_idx ON public.eventos (abierto) WHERE abierto AND NOT anulado;

-- El evento "primera noche con el modelo nuevo" ya existe: 2026-10-17 (abierto).
-- No se mueve nada de otras fechas: cada noche histórica se conserva.
UPDATE public.eventos
   SET nombre = 'Sábado 17/10'
 WHERE fecha = '2026-10-17'
   AND (nombre IS NULL OR nombre IN ('', 'Evento 2026-10-17'));

-- -----------------------------------------------------------------------------
-- 2. ANOTADOS (BOLETERÍA)
-- -----------------------------------------------------------------------------
ALTER TABLE public.anotados
  ADD COLUMN IF NOT EXISTS motivo text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS ingreso_at timestamptz,
  ADD COLUMN IF NOT EXISTS creado_por text,
  ADD COLUMN IF NOT EXISTS creado_at timestamptz,
  ADD COLUMN IF NOT EXISTS modificado_por text,
  ADD COLUMN IF NOT EXISTS modificado_at timestamptz,
  ADD COLUMN IF NOT EXISTS anulado boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS anulado_por text,
  ADD COLUMN IF NOT EXISTS anulado_at timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

UPDATE public.anotados
   SET creado_por = COALESCE(NULLIF(creado_por,''), autoriza, '—'),
       creado_at  = COALESCE(creado_at, creado_en, now()),
       motivo     = COALESCE(NULLIF(motivo,''), NULLIF(nota,''), '');

-- hora real de entrada = primer ingreso registrado
UPDATE public.anotados a
   SET ingreso_at = s.prim
  FROM (
    SELECT anotado_id, min(creado_en) AS prim
      FROM public.ingresos
     GROUP BY anotado_id
  ) s
 WHERE a.id = s.anotado_id
   AND a.ingreso_at IS NULL;

ALTER TABLE public.anotados
  ALTER COLUMN creado_at SET DEFAULT now(),
  ALTER COLUMN creado_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS anotados_anulado_idx ON public.anotados (evento_id, anulado);

-- -----------------------------------------------------------------------------
-- 3. CONSUMOS (BARRA)
-- -----------------------------------------------------------------------------
ALTER TABLE public.consumos
  ADD COLUMN IF NOT EXISTS producto text,
  ADD COLUMN IF NOT EXISTS cantidad integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS precio_lista integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS precio_cobrado integer,
  ADD COLUMN IF NOT EXISTS tipo_movimiento text NOT NULL DEFAULT 'VENTA',
  ADD COLUMN IF NOT EXISTS motivo text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS area text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS estado text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS botellas integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS creado_por text,
  ADD COLUMN IF NOT EXISTS creado_at timestamptz,
  ADD COLUMN IF NOT EXISTS modificado_por text,
  ADD COLUMN IF NOT EXISTS modificado_at timestamptz,
  ADD COLUMN IF NOT EXISTS anulado boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS anulado_por text,
  ADD COLUMN IF NOT EXISTS anulado_at timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

UPDATE public.consumos SET producto = COALESCE(NULLIF(producto,''), tipo) WHERE producto IS NULL OR producto = '';
UPDATE public.consumos SET precio_cobrado = COALESCE(precio_cobrado, precio);
UPDATE public.consumos SET precio_lista = CASE WHEN precio_lista > 0 THEN precio_lista WHEN precio > 0 THEN precio ELSE precio_lista END;
UPDATE public.consumos SET estado = CASE WHEN entregado THEN 'delivered' ELSE 'pending' END;
UPDATE public.consumos SET area = COALESCE(NULLIF(area,''), NULLIF(zona,''), '') ;
UPDATE public.consumos SET creado_por = COALESCE(NULLIF(creado_por,''), autoriza, '—');
UPDATE public.consumos SET creado_at = COALESCE(creado_at, creado_en, now());

-- tipo de movimiento a partir de lo que ya había
UPDATE public.consumos SET tipo_movimiento = CASE
  WHEN upper(tipo) LIKE '%CUMPLEA%' OR upper(coalesce(cambio,'')) LIKE '%CUMPLEA%' THEN 'CUMPLEAÑOS'
  WHEN upper(tipo) LIKE '%RRPP%' THEN 'RRPP'
  WHEN upper(tipo) LIKE '%VIP%' OR upper(coalesce(zona,'')) LIKE '%VIP%' THEN 'MESA VIP'
  WHEN upper(tipo) LIKE '%STAFF%' THEN 'STAFF'
  WHEN extendido OR upper(tipo) LIKE '%INVIT%' THEN 'INVITACIÓN'
  WHEN coalesce(precio,0) = 0 THEN 'CORTESÍA'
  ELSE 'VENTA'
END
WHERE tipo_movimiento IS NULL OR tipo_movimiento = 'VENTA' AND (
  coalesce(precio,0)=0 OR extendido OR upper(tipo) LIKE '%CUMPLEA%' OR upper(tipo) LIKE '%RRPP%'
);

-- botellas enteras (Ciroc, Grey Goose, Pravda, Chandon, etc.)
UPDATE public.consumos
   SET botellas = GREATEST(botellas, cantidad, 1)
 WHERE botellas = 0
   AND upper(tipo) ~ '(CIROC|GREY GOOSE|PRAVDA|CHANDON|MOET|VEUVE|BAR[OÓ]N B|CHAMPAGNE)';

ALTER TABLE public.consumos
  ALTER COLUMN producto SET DEFAULT '',
  ALTER COLUMN precio_cobrado SET DEFAULT 0,
  ALTER COLUMN creado_at SET DEFAULT now(),
  ALTER COLUMN creado_at SET NOT NULL;

UPDATE public.consumos SET precio_cobrado = COALESCE(precio_cobrado, 0);
ALTER TABLE public.consumos ALTER COLUMN precio_cobrado SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='consumos_tipo_movimiento_check') THEN
    ALTER TABLE public.consumos
      ADD CONSTRAINT consumos_tipo_movimiento_check
      CHECK (tipo_movimiento = ANY (ARRAY['VENTA','CORTESÍA','CUMPLEAÑOS','RRPP','MESA VIP','STAFF','INVITACIÓN']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='consumos_estado_check') THEN
    ALTER TABLE public.consumos
      ADD CONSTRAINT consumos_estado_check
      CHECK (estado = ANY (ARRAY['pending','delivered']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='consumos_cantidad_check') THEN
    ALTER TABLE public.consumos
      ADD CONSTRAINT consumos_cantidad_check CHECK (cantidad >= 1);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS consumos_anulado_idx ON public.consumos (evento_id, anulado);
CREATE INDEX IF NOT EXISTS consumos_area_idx ON public.consumos (evento_id, area);

-- -----------------------------------------------------------------------------
-- 4. INGRESOS (hora real de entrada) — también soft-delete
-- -----------------------------------------------------------------------------
ALTER TABLE public.ingresos
  ADD COLUMN IF NOT EXISTS creado_por text,
  ADD COLUMN IF NOT EXISTS creado_at timestamptz,
  ADD COLUMN IF NOT EXISTS modificado_por text,
  ADD COLUMN IF NOT EXISTS modificado_at timestamptz,
  ADD COLUMN IF NOT EXISTS anulado boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS anulado_por text,
  ADD COLUMN IF NOT EXISTS anulado_at timestamptz,
  ADD COLUMN IF NOT EXISTS motivo_anulacion text;

UPDATE public.ingresos
   SET creado_at = COALESCE(creado_at, creado_en, now());

ALTER TABLE public.ingresos
  ALTER COLUMN creado_at SET DEFAULT now(),
  ALTER COLUMN creado_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS ingresos_anulado_idx ON public.ingresos (anotado_id, anulado);

-- -----------------------------------------------------------------------------
-- 5. CATÁLOGO FIJO DE PRODUCTOS (barra)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.productos (
  id text PRIMARY KEY,
  nombre text NOT NULL,
  precio_lista integer NOT NULL DEFAULT 0,
  es_botella boolean NOT NULL DEFAULT false,
  activo boolean NOT NULL DEFAULT true
);

INSERT INTO public.productos (id, nombre, precio_lista, es_botella) VALUES
  ('COMBO SKYY SABOR',    'COMBO SKYY SABOR',    60000,  false),
  ('COMBO ABSOLUT SABOR', 'COMBO ABSOLUT SABOR', 85000,  false),
  ('GREY GOOSE',          'GREY GOOSE',          230000, true),
  ('CIROC',               'CIROC',               200000, true),
  ('CONSUMICIÓN',         'CONSUMICIÓN',         0,      false),
  ('SPEED',               'SPEED',               0,      false),
  ('CHANDON',             'CHANDON',             40000,  true),
  ('PRAVDA',              'PRAVDA',              160000, true),
  ('COMBO BRANCA',        'COMBO BRANCA',        80000,  false),
  ('COMBO HODLMOSSER',    'COMBO HODLMOSSER',    55000,  false),
  ('GIN BRIGHTON',        'GIN BRIGHTON',        35000,  false),
  ('SANTA JULIA CHENIN',  'SANTA JULIA CHENIN',  0,      false),
  ('CAFAYATE',            'CAFAYATE',            20000,  false),
  ('AGUA',                'AGUA',                0,      false),
  ('CHAMPAGNE',           'CHAMPAGNE',           0,      true),
  ('MOET',                'MOET',                0,      true),
  ('VEUVE',               'VEUVE',               0,      true),
  ('BARÓN B',             'BARÓN B',             30000,  true),
  ('COMBO RRPP',          'COMBO RRPP',          0,      false),
  ('COMBO CUMPLEAÑOS',    'COMBO CUMPLEAÑOS',    0,      false)
ON CONFLICT (id) DO UPDATE
  SET nombre = EXCLUDED.nombre,
      precio_lista = EXCLUDED.precio_lista,
      es_botella = EXCLUDED.es_botella,
      activo = true;

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "leer productos" ON public.productos;
CREATE POLICY "leer productos" ON public.productos FOR SELECT TO authenticated USING (true);

GRANT SELECT ON public.productos TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. AUDIT_LOG
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tabla text NOT NULL,
  registro_id uuid NOT NULL,
  accion text NOT NULL CHECK (accion = ANY (ARRAY['create','change','void'])),
  campo text,
  valor_anterior text,
  valor_nuevo text,
  quien text NOT NULL DEFAULT '—',
  quien_id uuid,
  cuando timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_registro_idx ON public.audit_log (tabla, registro_id, cuando DESC);
CREATE INDEX IF NOT EXISTS audit_log_cuando_idx ON public.audit_log (cuando DESC);

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "leer audit_log" ON public.audit_log;
CREATE POLICY "leer audit_log" ON public.audit_log
  FOR SELECT TO authenticated
  USING (public.es_admin_o_auditor());

GRANT SELECT ON public.audit_log TO authenticated;

CREATE OR REPLACE FUNCTION public.auditar_fila()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE
  col text;
  oldv text;
  newv text;
  v_quien text;
  v_accion text;
  rec_id uuid;
  src jsonb;
  oldj jsonb;
  newj jsonb;
BEGIN
  v_quien := coalesce(public.mi_nombre(), 'sistema');
  IF TG_OP = 'INSERT' THEN
    v_accion := 'create';
    rec_id := NEW.id;
    newj := to_jsonb(NEW);
    FOR col IN SELECT jsonb_object_keys(newj) LOOP
      IF col IN ('reporte') THEN CONTINUE; END IF;
      newv := newj->>col;
      IF newv IS NOT NULL THEN
        INSERT INTO public.audit_log(tabla, registro_id, accion, campo, valor_anterior, valor_nuevo, quien, quien_id, cuando)
        VALUES (TG_TABLE_NAME, rec_id, v_accion, col, NULL, left(newv, 2000), v_quien, auth.uid(), now());
      END IF;
    END LOOP;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    rec_id := NEW.id;
    oldj := to_jsonb(OLD);
    newj := to_jsonb(NEW);
    IF (newj->>'anulado') = 'true' AND coalesce(oldj->>'anulado','false') <> 'true' THEN
      v_accion := 'void';
    ELSE
      v_accion := 'change';
    END IF;
    FOR col IN SELECT jsonb_object_keys(newj) LOOP
      IF col IN ('reporte') THEN CONTINUE; END IF;
      oldv := oldj->>col;
      newv := newj->>col;
      IF oldv IS DISTINCT FROM newv THEN
        INSERT INTO public.audit_log(tabla, registro_id, accion, campo, valor_anterior, valor_nuevo, quien, quien_id, cuando)
        VALUES (TG_TABLE_NAME, rec_id, v_accion, col, left(oldv, 2000), left(newv, 2000), v_quien, auth.uid(), now());
      END IF;
    END LOOP;
    RETURN NEW;
  ELSE
    rec_id := OLD.id;
    INSERT INTO public.audit_log(tabla, registro_id, accion, campo, valor_anterior, valor_nuevo, quien, quien_id, cuando)
    VALUES (TG_TABLE_NAME, rec_id, 'void', '*', left(to_jsonb(OLD)::text, 2000), NULL, v_quien, auth.uid(), now());
    RETURN OLD;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS audit_eventos  ON public.eventos;
DROP TRIGGER IF EXISTS audit_anotados ON public.anotados;
DROP TRIGGER IF EXISTS audit_consumos ON public.consumos;
DROP TRIGGER IF EXISTS audit_ingresos ON public.ingresos;
CREATE TRIGGER audit_eventos  AFTER INSERT OR UPDATE OR DELETE ON public.eventos  FOR EACH ROW EXECUTE FUNCTION public.auditar_fila();
CREATE TRIGGER audit_anotados AFTER INSERT OR UPDATE OR DELETE ON public.anotados FOR EACH ROW EXECUTE FUNCTION public.auditar_fila();
CREATE TRIGGER audit_consumos AFTER INSERT OR UPDATE OR DELETE ON public.consumos FOR EACH ROW EXECUTE FUNCTION public.auditar_fila();
CREATE TRIGGER audit_ingresos AFTER INSERT OR UPDATE OR DELETE ON public.ingresos FOR EACH ROW EXECUTE FUNCTION public.auditar_fila();

-- snapshot de lo existente (una fila por registro, no por campo, para no inflar)
INSERT INTO public.audit_log (tabla, registro_id, accion, campo, valor_nuevo, quien, cuando)
SELECT 'eventos', id, 'create', '*', jsonb_build_object('fecha',fecha,'nombre',nombre,'abierto',abierto)::text,
       coalesce(creado_por,'migración'), coalesce(creado_at, creado_en, now())
  FROM public.eventos e
 WHERE NOT EXISTS (SELECT 1 FROM public.audit_log x WHERE x.tabla='eventos' AND x.registro_id=e.id);

INSERT INTO public.audit_log (tabla, registro_id, accion, campo, valor_nuevo, quien, cuando)
SELECT 'anotados', id, 'create', '*',
       jsonb_build_object('nombre',nombre,'autoriza',autoriza,'free',free,'sinrec',sinrec,'ext',ext,'pago',pago,'precio',precio)::text,
       coalesce(creado_por, autoriza, 'migración'), coalesce(creado_at, creado_en, now())
  FROM public.anotados a
 WHERE NOT EXISTS (SELECT 1 FROM public.audit_log x WHERE x.tabla='anotados' AND x.registro_id=a.id);

INSERT INTO public.audit_log (tabla, registro_id, accion, campo, valor_nuevo, quien, cuando)
SELECT 'consumos', id, 'create', '*',
       jsonb_build_object('nombre',nombre,'tipo',tipo,'precio',precio,'autoriza',autoriza)::text,
       coalesce(creado_por, autoriza, 'migración'), coalesce(creado_at, creado_en, now())
  FROM public.consumos c
 WHERE NOT EXISTS (SELECT 1 FROM public.audit_log x WHERE x.tabla='consumos' AND x.registro_id=c.id);

-- -----------------------------------------------------------------------------
-- 7. Sellar auditoría / no borrar
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sellar_auditoria()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE v_nombre text;
BEGIN
  SELECT nombre INTO v_nombre FROM public.perfiles WHERE id = auth.uid();
  IF TG_OP = 'INSERT' THEN
    NEW.creado_por := coalesce(NULLIF(NEW.creado_por,''), v_nombre, '—');
    NEW.creado_at  := coalesce(NEW.creado_at, now());
    NEW.modificado_por := NEW.creado_por;
    NEW.modificado_at  := NEW.creado_at;
    NEW.anulado := coalesce(NEW.anulado, false);
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.creado_por := OLD.creado_por;
    NEW.creado_at  := OLD.creado_at;
    NEW.modificado_por := coalesce(v_nombre, OLD.modificado_por, '—');
    NEW.modificado_at  := now();
    IF NEW.anulado AND NOT OLD.anulado THEN
      NEW.anulado_por := coalesce(NULLIF(NEW.anulado_por,''), v_nombre, '—');
      NEW.anulado_at  := coalesce(NEW.anulado_at, now());
      IF coalesce(trim(NEW.motivo_anulacion),'') = '' THEN
        RAISE EXCEPTION 'Para anular hay que escribir el motivo.';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sellar_auditoria_eventos  ON public.eventos;
DROP TRIGGER IF EXISTS sellar_auditoria_anotados ON public.anotados;
DROP TRIGGER IF EXISTS sellar_auditoria_consumos ON public.consumos;
DROP TRIGGER IF EXISTS sellar_auditoria_ingresos ON public.ingresos;
CREATE TRIGGER sellar_auditoria_eventos  BEFORE INSERT OR UPDATE ON public.eventos  FOR EACH ROW EXECUTE FUNCTION public.sellar_auditoria();
CREATE TRIGGER sellar_auditoria_anotados BEFORE INSERT OR UPDATE ON public.anotados FOR EACH ROW EXECUTE FUNCTION public.sellar_auditoria();
CREATE TRIGGER sellar_auditoria_consumos BEFORE INSERT OR UPDATE ON public.consumos FOR EACH ROW EXECUTE FUNCTION public.sellar_auditoria();
CREATE TRIGGER sellar_auditoria_ingresos BEFORE INSERT OR UPDATE ON public.ingresos FOR EACH ROW EXECUTE FUNCTION public.sellar_auditoria();

CREATE OR REPLACE FUNCTION public.prohibir_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Nada se borra: anulá el registro con un motivo.';
END;
$$;

DROP TRIGGER IF EXISTS no_delete_eventos  ON public.eventos;
DROP TRIGGER IF EXISTS no_delete_anotados ON public.anotados;
DROP TRIGGER IF EXISTS no_delete_consumos ON public.consumos;
DROP TRIGGER IF EXISTS no_delete_ingresos ON public.ingresos;
CREATE TRIGGER no_delete_eventos  BEFORE DELETE ON public.eventos  FOR EACH ROW EXECUTE FUNCTION public.prohibir_delete();
CREATE TRIGGER no_delete_anotados BEFORE DELETE ON public.anotados FOR EACH ROW EXECUTE FUNCTION public.prohibir_delete();
CREATE TRIGGER no_delete_consumos BEFORE DELETE ON public.consumos FOR EACH ROW EXECUTE FUNCTION public.prohibir_delete();
CREATE TRIGGER no_delete_ingresos BEFORE DELETE ON public.ingresos FOR EACH ROW EXECUTE FUNCTION public.prohibir_delete();

-- sellar autoriza: no pisa un autoriza distinto que mandó el cliente (barra)
CREATE OR REPLACE FUNCTION public.sellar_autoriza()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_nombre text;
BEGIN
  SELECT nombre INTO v_nombre FROM public.perfiles WHERE id = auth.uid();
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'No pudimos identificar tu cuenta.'; END IF;
  NEW.autoriza_id := coalesce(NEW.autoriza_id, auth.uid());
  IF NEW.autoriza IS NULL OR btrim(NEW.autoriza) = '' OR NEW.autoriza = '—' THEN
    NEW.autoriza := v_nombre;
    NEW.autoriza_id := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sellar_consumo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_nombre text;
BEGIN
  SELECT nombre INTO v_nombre FROM public.perfiles WHERE id=auth.uid();
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'No pudimos identificar tu cuenta.'; END IF;
  IF NEW.autoriza IS NULL OR btrim(NEW.autoriza) = '' OR NEW.autoriza = '—' THEN
    NEW.autoriza := v_nombre;
    NEW.autoriza_id := auth.uid();
  END IF;
  NEW.producto := coalesce(NULLIF(NEW.producto,''), NEW.tipo);
  NEW.precio_cobrado := coalesce(NEW.precio_cobrado, NEW.precio, 0);
  NEW.precio := NEW.precio_cobrado;
  NEW.estado := 'pending';
  NEW.entregado := false;
  NEW.entregado_por := NULL;
  NEW.entregado_at := NULL;
  NEW.entregado_usuario := NULL;
  NEW.area := coalesce(NULLIF(NEW.area,''), NULLIF(NEW.zona,''), '');
  NEW.zona := NEW.area;
  IF NEW.tipo_movimiento IS NULL OR NEW.tipo_movimiento = '' THEN
    NEW.tipo_movimiento := CASE WHEN coalesce(NEW.precio_cobrado,0)=0 THEN 'CORTESÍA' ELSE 'VENTA' END;
  END IF;
  -- motivo obligatorio si es gratis o con descuento
  IF (NEW.precio_cobrado = 0 OR NEW.tipo_movimiento <> 'VENTA' OR (NEW.precio_lista > 0 AND NEW.precio_cobrado < NEW.precio_lista))
     AND coalesce(btrim(NEW.motivo),'') = '' THEN
    RAISE EXCEPTION 'Falta el motivo: es obligatorio cuando es sin cargo o con descuento.';
  END IF;
  RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. RPCs: anular, abrir evento, marcar, entregar, reportes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_anotado(p_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE r public.anotados;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede anular.'; END IF;
  IF NOT public.es_admin() THEN RAISE EXCEPTION 'Solo un admin puede anular.'; END IF;
  IF coalesce(btrim(p_motivo),'') = '' THEN RAISE EXCEPTION 'El motivo de anulación es obligatorio.'; END IF;
  UPDATE public.anotados
     SET anulado=true, anulado_por=public.mi_nombre(), anulado_at=now(), motivo_anulacion=btrim(p_motivo)
   WHERE id=p_id AND NOT anulado
  RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'No se pudo anular (ya estaba anulado o no existe).'; END IF;
  RETURN to_jsonb(r);
END;
$$;

CREATE OR REPLACE FUNCTION public.anular_consumos(p_ids uuid[], p_motivo text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE n int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede anular.'; END IF;
  IF NOT public.es_admin() THEN RAISE EXCEPTION 'Solo un admin puede anular.'; END IF;
  IF coalesce(btrim(p_motivo),'') = '' THEN RAISE EXCEPTION 'El motivo de anulación es obligatorio.'; END IF;
  UPDATE public.consumos
     SET anulado=true, anulado_por=public.mi_nombre(), anulado_at=now(), motivo_anulacion=btrim(p_motivo)
   WHERE id = ANY(p_ids) AND NOT anulado;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION public.abrir_evento(p_fecha date, p_nombre text, p_cerrar_anterior boolean DEFAULT true)
RETURNS public.eventos
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE r public.eventos;
BEGIN
  IF NOT public.es_admin() THEN RAISE EXCEPTION 'Solo un admin puede abrir una noche.'; END IF;
  IF p_fecha IS NULL THEN RAISE EXCEPTION 'Falta la fecha.'; END IF;
  IF p_cerrar_anterior THEN
    UPDATE public.eventos
       SET abierto=false, cerrada_en=coalesce(cerrada_en, now())
     WHERE abierto AND NOT anulado;
  END IF;
  INSERT INTO public.eventos(fecha, nombre, abierto)
  VALUES (p_fecha, coalesce(NULLIF(btrim(p_nombre),''), 'Evento '||to_char(p_fecha,'YYYY-MM-DD')), true)
  RETURNING * INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.marcar_ingreso(p_anotado uuid, p_campo text, p_delta integer, p_estacion text DEFAULT '—'::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE
  r public.anotados; tope int; actual int; quitado boolean := false;
  est text := coalesce(nullif(trim(p_estacion),''), '—');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede marcar ingresos.'; END IF;
  IF p_campo NOT IN ('free','sinrec','ext','pago') THEN RAISE EXCEPTION 'Condición inválida.'; END IF;
  SELECT * INTO r FROM public.anotados WHERE id = p_anotado;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe esa ficha.'; END IF;
  IF r.anulado THEN RAISE EXCEPTION 'Esa ficha está anulada.'; END IF;
  IF NOT public.es_admin() AND EXISTS (SELECT 1 FROM public.eventos e WHERE e.id=r.evento_id AND NOT e.abierto) THEN
    RAISE EXCEPTION 'Esa noche está cerrada.';
  END IF;
  tope := CASE p_campo WHEN 'free' THEN r.free WHEN 'sinrec' THEN r.sinrec WHEN 'ext' THEN r.ext ELSE r.pago END;
  SELECT count(*) INTO actual FROM public.ingresos WHERE anotado_id=p_anotado AND condicion=p_campo AND NOT anulado;

  IF p_delta = 1 THEN
    IF actual < tope THEN
      INSERT INTO public.ingresos(anotado_id,condicion,estacion,usuario_id,creado_por)
      VALUES (p_anotado,p_campo,est,auth.uid(),public.mi_nombre());
    END IF;
  ELSIF p_delta = -1 THEN
    UPDATE public.ingresos
       SET anulado=true, anulado_por=public.mi_nombre(), anulado_at=now(),
           motivo_anulacion='Deshacer ingreso'
     WHERE id = (
       SELECT id FROM public.ingresos
        WHERE anotado_id=p_anotado AND condicion=p_campo AND NOT anulado
          AND (public.es_admin() OR estacion=est)
        ORDER BY creado_en DESC LIMIT 1)
    RETURNING true INTO quitado;
  ELSE
    RAISE EXCEPTION 'Solo se puede sumar o restar de a uno.';
  END IF;

  UPDATE public.anotados SET
    i_free   = (SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='free'   AND NOT anulado),
    i_sinrec = (SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='sinrec' AND NOT anulado),
    i_ext    = (SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='ext'    AND NOT anulado),
    i_pago   = (SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='pago'   AND NOT anulado),
    ingreso_at = (SELECT min(creado_en) FROM public.ingresos WHERE anotado_id=p_anotado AND NOT anulado)
  WHERE id=p_anotado RETURNING * INTO r;

  RETURN jsonb_build_object(
    'ficha', to_jsonb(r),
    'no_era_tuyo', (p_delta=-1 AND NOT coalesce(quitado,false)),
    'por_estacion', coalesce((SELECT jsonb_object_agg(estacion,c) FROM (
        SELECT estacion, count(*) c FROM public.ingresos WHERE anotado_id=p_anotado AND NOT anulado GROUP BY estacion) s), '{}'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION public.marcar_todos(p_anotado uuid, p_estacion text DEFAULT '—'::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r public.anotados; est text := coalesce(nullif(trim(p_estacion),''), '—');
  campos text[] := ARRAY['free','sinrec','ext','pago']; cmp text; tope int; actual int; faltan int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede marcar ingresos.'; END IF;
  SELECT * INTO r FROM public.anotados WHERE id=p_anotado;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe esa ficha.'; END IF;
  IF r.anulado THEN RAISE EXCEPTION 'Esa ficha está anulada.'; END IF;
  IF NOT public.es_admin() AND EXISTS (SELECT 1 FROM public.eventos e WHERE e.id=r.evento_id AND NOT e.abierto) THEN
    RAISE EXCEPTION 'Esa noche está cerrada.';
  END IF;
  FOREACH cmp IN ARRAY campos LOOP
    tope := CASE cmp WHEN 'free' THEN r.free WHEN 'sinrec' THEN r.sinrec WHEN 'ext' THEN r.ext ELSE r.pago END;
    SELECT count(*) INTO actual FROM public.ingresos WHERE anotado_id=p_anotado AND condicion=cmp AND NOT anulado;
    faltan := greatest(0, tope-actual);
    IF faltan > 0 THEN
      INSERT INTO public.ingresos(anotado_id,condicion,estacion,usuario_id,creado_por)
      SELECT p_anotado, cmp, est, auth.uid(), public.mi_nombre() FROM generate_series(1, faltan);
    END IF;
  END LOOP;
  UPDATE public.anotados SET
    i_free=(SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='free' AND NOT anulado),
    i_sinrec=(SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='sinrec' AND NOT anulado),
    i_ext=(SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='ext' AND NOT anulado),
    i_pago=(SELECT count(*) FROM public.ingresos WHERE anotado_id=p_anotado AND condicion='pago' AND NOT anulado),
    ingreso_at=(SELECT min(creado_en) FROM public.ingresos WHERE anotado_id=p_anotado AND NOT anulado)
  WHERE id=p_anotado RETURNING * INTO r;
  RETURN jsonb_build_object('ficha', to_jsonb(r));
END;
$$;

CREATE OR REPLACE FUNCTION public.entregar_consumos(p_ids uuid[], p_barra text DEFAULT NULL::text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET timezone TO 'America/Argentina/Buenos_Aires'
AS $$
DECLARE n int; v_por text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede entregar.'; END IF;
  IF NOT (public.es_admin() OR public.mi_rol()='barra') THEN RAISE EXCEPTION 'No autorizado.'; END IF;
  IF public.es_multibarra() AND p_barra IS NOT NULL AND p_barra <> '' THEN
    IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE rol='barra' AND nombre=p_barra)
       AND p_barra NOT IN ('VIP','Principal','Terraza','Zebra','Entre Piso') THEN
      RAISE EXCEPTION 'Barra inválida.'; END IF;
    v_por := p_barra;
  ELSE
    v_por := public.mi_nombre();
  END IF;
  UPDATE public.consumos
     SET entregado=true, estado='delivered', entregado_por=v_por, entregado_at=now(), entregado_usuario=auth.uid(),
         area = CASE WHEN coalesce(area,'')='' THEN v_por ELSE area END
   WHERE id = ANY(p_ids) AND NOT entregado AND NOT anulado;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION public.desentregar_consumo(p_id uuid, p_barra text DEFAULT NULL::text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE ok boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Tenés que iniciar sesión.'; END IF;
  IF public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede deshacer entregas.'; END IF;
  IF NOT (public.es_admin() OR public.mi_rol()='barra') THEN RAISE EXCEPTION 'No autorizado.'; END IF;
  UPDATE public.consumos
     SET entregado=false, estado='pending', entregado_por=null, entregado_at=null, entregado_usuario=null
   WHERE id=p_id AND entregado AND NOT anulado
     AND ( public.es_admin()
        OR (public.es_multibarra() AND entregado_por = p_barra)
        OR (NOT public.es_multibarra() AND entregado_por = public.mi_nombre()) )
  RETURNING true INTO ok;
  RETURN coalesce(ok,false);
END;
$$;

DROP FUNCTION IF EXISTS public.historico_noches();
CREATE OR REPLACE FUNCTION public.historico_noches()
RETURNS TABLE(id uuid, fecha date, nombre text, abierto boolean, estado text, cerrada_en timestamptz, personas integer, ingresaron integer, recaudado integer, tiene_reporte boolean)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT e.id, e.fecha, e.nombre, e.abierto, e.estado, e.cerrada_en,
         coalesce(sum(a.free+a.sinrec+a.ext+a.pago) FILTER (WHERE NOT a.anulado),0)::int,
         coalesce(sum(a.i_free+a.i_sinrec+a.i_ext+a.i_pago) FILTER (WHERE NOT a.anulado),0)::int,
         coalesce(sum(a.i_pago*a.precio) FILTER (WHERE NOT a.anulado),0)::int,
         (e.reporte IS NOT NULL)
    FROM public.eventos e
    LEFT JOIN public.anotados a ON a.evento_id = e.id
   WHERE public.es_admin_o_auditor()
     AND NOT e.anulado
   GROUP BY e.id, e.fecha, e.nombre, e.abierto, e.estado, e.cerrada_en, e.reporte
   ORDER BY e.fecha DESC, e.creado_en DESC;
$$;

CREATE OR REPLACE FUNCTION public.reporte_noche(p_evento uuid, p_cerrar boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v jsonb; v_confiable boolean; v_barra jsonb;
BEGIN
  IF NOT public.es_admin_o_auditor() THEN RAISE EXCEPTION 'Solo admin o auditor pueden generar el reporte.'; END IF;
  IF p_cerrar AND NOT public.es_admin() THEN RAISE EXCEPTION 'El auditor no puede cerrar la noche.'; END IF;
  IF p_cerrar AND public.es_auditor() THEN RAISE EXCEPTION 'El auditor no puede cerrar la noche.'; END IF;

  SELECT count(*) FILTER (WHERE autoriza_id IS NULL AND NOT anulado) = 0 INTO v_confiable
    FROM public.anotados WHERE evento_id = p_evento;

  WITH ci AS (SELECT * FROM public.consumos WHERE evento_id = p_evento AND NOT anulado),
  bt AS (SELECT count(*)::int AS items,
             coalesce(sum(cantidad),0)::int AS unidades,
             count(*) FILTER (WHERE entregado)::int AS entregados,
             count(*) FILTER (WHERE NOT entregado)::int AS sin_retirar,
             coalesce(sum(precio_cobrado * cantidad),0) AS facturado,
             count(*) FILTER (WHERE precio_cobrado=0 AND coalesce(cambio,'')='' AND NOT extendido)::int AS regalados,
             count(*) FILTER (WHERE extendido)::int AS extendidos,
             count(*) FILTER (WHERE coalesce(cambio,'')<>'')::int AS upgrades,
             coalesce(sum(botellas),0)::int AS botellas
         FROM ci),
  ba AS (SELECT coalesce(producto,tipo) AS tipo, count(*)::int AS cant,
             coalesce(sum(cantidad),0)::int AS unidades,
             count(*) FILTER (WHERE entregado)::int AS entregados,
             count(*) FILTER (WHERE precio_cobrado=0 AND coalesce(cambio,'')='' AND NOT extendido)::int AS regalados,
             count(*) FILTER (WHERE extendido)::int AS extendidos,
             count(*) FILTER (WHERE coalesce(cambio,'')<>'')::int AS upgrades,
             coalesce(sum(precio_cobrado * cantidad),0) AS facturado,
             coalesce(sum(botellas),0)::int AS botellas
         FROM ci GROUP BY coalesce(producto,tipo)),
  bm AS (SELECT tipo_movimiento, count(*)::int AS items,
             coalesce(sum(cantidad),0)::int AS unidades,
             coalesce(sum(precio_cobrado * cantidad),0) AS facturado
         FROM ci GROUP BY tipo_movimiento),
  bb AS (SELECT entregado_por AS barra, count(*)::int AS entregas, coalesce(sum(precio_cobrado * cantidad),0) AS valor,
             EXISTS(SELECT 1 FROM public.perfiles pf WHERE pf.rol='barra' AND pf.nombre = ci.entregado_por) AS es_barra
         FROM ci WHERE entregado AND entregado_por IS NOT NULL GROUP BY entregado_por),
  ar AS (SELECT coalesce(NULLIF(area,''),'—') AS area, count(*)::int AS items,
             coalesce(sum(precio_cobrado * cantidad),0) AS facturado
         FROM ci GROUP BY 1),
  bc AS (SELECT autoriza AS socio, count(*)::int AS items, coalesce(sum(precio_cobrado * cantidad),0) AS facturado,
             count(*) FILTER (WHERE entregado)::int AS entregados,
             count(*) FILTER (WHERE precio_cobrado=0 AND coalesce(cambio,'')='' AND NOT extendido)::int AS regalados,
             count(*) FILTER (WHERE coalesce(cambio,'')<>'')::int AS upgrades,
             count(*) FILTER (WHERE extendido)::int AS extendidos
         FROM ci GROUP BY autoriza),
  bp AS (SELECT nombre, coalesce(producto,tipo) AS tipo, precio_cobrado AS precio, coalesce(cambio,'') AS cambio FROM ci WHERE NOT entregado ORDER BY nombre),
  fv AS (SELECT
            coalesce(sum(precio_cobrado * cantidad) FILTER (WHERE precio_cobrado>0),0) AS cobrado,
            coalesce(sum(cantidad) FILTER (WHERE precio_cobrado>0),0)::int AS unid_cobradas,
            coalesce(sum(cantidad) FILTER (WHERE precio_cobrado=0),0)::int AS unid_gratis
         FROM ci)
  SELECT jsonb_build_object(
    'totales', (SELECT to_jsonb(t) FROM bt t),
    'por_articulo', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.cant DESC, x.facturado DESC) FROM ba x),'[]'::jsonb),
    'por_tipo_movimiento', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.items DESC) FROM bm x),'[]'::jsonb),
    'por_area', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.items DESC) FROM ar x),'[]'::jsonb),
    'por_barra', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.entregas DESC) FROM bb x),'[]'::jsonb),
    'quien_cargo', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.items DESC) FROM bc x),'[]'::jsonb),
    'sin_retirar', coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM bp x),'[]'::jsonb),
    'gratis_vs_cobrado', (SELECT to_jsonb(x) FROM fv x)
  ) INTO v_barra;

  WITH a AS (SELECT * FROM public.anotados WHERE evento_id = p_evento AND NOT anulado),
  tot AS (SELECT coalesce(sum(free+sinrec+ext+pago),0) AS personas,
                 coalesce(sum(i_free+i_sinrec+i_ext+i_pago),0) AS ingresaron,
                 count(*) AS fichas, coalesce(sum(i_pago*precio),0) AS recaudado FROM a),
  socios AS (SELECT autoriza AS socio, count(*)::int AS fichas,
                 sum(free+sinrec+ext+pago)::int AS personas, sum(i_free+i_sinrec+i_ext+i_pago)::int AS entraron,
                 sum(free)::int AS free, sum(sinrec)::int AS sinrec, sum(ext)::int AS ext, sum(pago)::int AS pagan,
                 sum(i_pago*precio)::int AS recaudado FROM a GROUP BY autoriza),
  noshow AS (SELECT nombre, autoriza,
                 ((free+sinrec+ext+pago)-(i_free+i_sinrec+i_ext+i_pago))::int AS faltan,
                 (free+sinrec+ext+pago)::int AS total FROM a
             WHERE (free+sinrec+ext+pago)>(i_free+i_sinrec+i_ext+i_pago) ORDER BY nombre),
  boles AS (SELECT i.estacion, count(*)::int AS ingresos
              FROM public.ingresos i JOIN public.anotados a2 ON a2.id=i.anotado_id
             WHERE a2.evento_id=p_evento AND NOT i.anulado AND NOT a2.anulado GROUP BY i.estacion)
  SELECT jsonb_build_object(
    'totales', (SELECT jsonb_build_object('personas',personas,'ingresaron',ingresaron,
        'no_vinieron',personas-ingresaron,
        'asistencia_pct',CASE WHEN personas>0 THEN round(100.0*ingresaron/personas) ELSE 0 END,
        'fichas',fichas,'recaudado',recaudado) FROM tot),
    'por_condicion', (SELECT jsonb_build_object(
        'free',jsonb_build_object('anotados',coalesce(sum(free),0),'entraron',coalesce(sum(i_free),0)),
        'sinrec',jsonb_build_object('anotados',coalesce(sum(sinrec),0),'entraron',coalesce(sum(i_sinrec),0)),
        'ext',jsonb_build_object('anotados',coalesce(sum(ext),0),'entraron',coalesce(sum(i_ext),0)),
        'pago',jsonb_build_object('anotados',coalesce(sum(pago),0),'entraron',coalesce(sum(i_pago),0))) FROM a),
    'por_socio', coalesce((SELECT jsonb_agg(to_jsonb(socios) ORDER BY socios.recaudado DESC, socios.personas DESC) FROM socios),'[]'::jsonb),
    'por_boleteria', coalesce((SELECT jsonb_agg(to_jsonb(boles) ORDER BY boles.ingresos DESC) FROM boles),'[]'::jsonb),
    'ranking', jsonb_build_object(
        'mas_invitados',(SELECT jsonb_build_object('socio',socio,'valor',personas) FROM socios WHERE personas>0 ORDER BY personas DESC LIMIT 1),
        'mas_free',(SELECT jsonb_build_object('socio',socio,'valor',free) FROM socios WHERE free>0 ORDER BY free DESC LIMIT 1),
        'mas_descuento',(SELECT jsonb_build_object('socio',socio,'valor',sinrec) FROM socios WHERE sinrec>0 ORDER BY sinrec DESC LIMIT 1),
        'mas_recaudado',(SELECT jsonb_build_object('socio',socio,'valor',recaudado) FROM socios WHERE recaudado>0 ORDER BY recaudado DESC LIMIT 1)),
    'no_shows', coalesce((SELECT jsonb_agg(to_jsonb(noshow)) FROM noshow),'[]'::jsonb),
    'atribucion_confiable', v_confiable
  ) INTO v;

  v := v || jsonb_build_object('barra', v_barra);

  IF p_cerrar THEN
    UPDATE public.eventos SET abierto=false, cerrada_en=now(), reporte=v WHERE id=p_evento;
  END IF;
  v := v || jsonb_build_object(
    'fecha',(SELECT fecha FROM public.eventos WHERE id=p_evento),
    'nombre',(SELECT nombre FROM public.eventos WHERE id=p_evento),
    'cerrada',p_cerrar);
  RETURN v;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. ROL AUDITOR (grokbot) — solo lectura
-- -----------------------------------------------------------------------------
ALTER TABLE public.perfiles DROP CONSTRAINT IF EXISTS perfiles_rol_check;
ALTER TABLE public.perfiles
  ADD CONSTRAINT perfiles_rol_check
  CHECK (rol = ANY (ARRAY['admin'::text, 'boleteria'::text, 'barra'::text, 'auditor'::text]));

UPDATE public.perfiles
   SET rol = 'auditor'
 WHERE id = (SELECT id FROM auth.users WHERE lower(email) = 'grokbot@fendyfunclub.com');

CREATE OR REPLACE FUNCTION public.nuevo_usuario()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE v_nombre text; v_rol text; v_mb boolean := false; v_mp boolean := false;
BEGIN
  SELECT x.nombre, x.rol INTO v_nombre, v_rol FROM (VALUES
    ('pablosg85@gmail.com',            'Pablo',       'admin'),
    ('lautaroaste@gmail.com',          'Lautaro',     'admin'),
    ('francodelsol2@gmail.com',        'Chino',       'admin'),
    ('grokbot@fendyfunclub.com',       'GrokBot',     'auditor'),
    ('boleteria1@fendyfunclub.com',    'Boletería 1', 'boleteria'),
    ('boleteria2@fendyfunclub.com',    'Boletería 2', 'boleteria'),
    ('barravip@fendyfunclub.com',        'VIP',        'barra'),
    ('barraprincipal@fendyfunclub.com',  'Principal',  'barra'),
    ('barraterraza@fendyfunclub.com',    'Terraza',    'barra'),
    ('barraentrepiso@fendyfunclub.com',  'Entre Piso', 'barra'),
    ('barrazebra@fendyfunclub.com',      'Zebra',      'barra'),
    ('multipuesto@fendyfunclub.com',     'Multipuesto','barra')
  ) AS x(email, nombre, rol) WHERE x.email = lower(new.email);
  IF v_nombre IS NULL THEN RAISE EXCEPTION 'Ese correo no está habilitado para esta app.'; END IF;
  IF lower(new.email) = 'multipuesto@fendyfunclub.com' THEN v_mb := true; v_mp := true; END IF;
  INSERT INTO public.perfiles (id, nombre, rol, multibarra, multipuesto)
    VALUES (new.id, v_nombre, v_rol, v_mb, v_mp);
  RETURN new;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. RLS: auditor lee todo; nadie borra
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "admin borra" ON public.anotados;
DROP POLICY IF EXISTS "admin borra consumos" ON public.consumos;

DROP POLICY IF EXISTS "leer consumos" ON public.consumos;
CREATE POLICY "leer consumos" ON public.consumos
  FOR SELECT TO authenticated
  USING (
    public.es_admin_o_auditor()
    OR (
      public.mi_rol() = 'barra'
      AND (NOT entregado OR public.es_multibarra() OR entregado_por = public.mi_nombre())
    )
  );

DROP POLICY IF EXISTS "admin carga consumos" ON public.consumos;
CREATE POLICY "admin carga consumos" ON public.consumos
  FOR INSERT TO authenticated
  WITH CHECK (public.es_admin() AND NOT public.es_auditor());

DROP POLICY IF EXISTS "admin anota" ON public.anotados;
CREATE POLICY "admin anota" ON public.anotados
  FOR INSERT TO authenticated
  WITH CHECK (public.es_admin() AND NOT public.es_auditor());

DROP POLICY IF EXISTS "admin edita todo" ON public.anotados;
CREATE POLICY "admin edita todo" ON public.anotados
  FOR UPDATE TO authenticated
  USING (public.es_admin() AND NOT public.es_auditor())
  WITH CHECK (public.es_admin() AND NOT public.es_auditor());

DROP POLICY IF EXISTS "admin crea eventos" ON public.eventos;
CREATE POLICY "admin crea eventos" ON public.eventos
  FOR INSERT TO authenticated
  WITH CHECK (public.es_admin() AND NOT public.es_auditor());

DROP POLICY IF EXISTS "admin edita eventos" ON public.eventos;
CREATE POLICY "admin edita eventos" ON public.eventos
  FOR UPDATE TO authenticated
  USING (public.es_admin() AND NOT public.es_auditor());

GRANT EXECUTE ON FUNCTION public.es_auditor() TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin_o_auditor() TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_anotado(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_consumos(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_evento(date, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.historico_noches() TO authenticated;
GRANT EXECUTE ON FUNCTION public.reporte_noche(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_ingreso(uuid, text, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marcar_todos(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.entregar_consumos(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.desentregar_consumo(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 11. Verificación
-- -----------------------------------------------------------------------------
SELECT 'eventos' AS tabla, count(*) AS filas FROM public.eventos
UNION ALL SELECT 'anotados', count(*) FROM public.anotados
UNION ALL SELECT 'consumos', count(*) FROM public.consumos
UNION ALL SELECT 'audit_log', count(*) FROM public.audit_log
UNION ALL SELECT 'evento_2026-10-17', count(*) FROM public.eventos WHERE fecha='2026-10-17';

SELECT email, p.nombre, p.rol
  FROM auth.users u JOIN public.perfiles p ON p.id=u.id
 WHERE lower(u.email)='grokbot@fendyfunclub.com';
