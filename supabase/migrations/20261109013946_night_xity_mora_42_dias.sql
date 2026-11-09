-- Night Xity: ciclos de gastos de vida, mora y reactivacion.
-- Politica: compras instantaneas no financiadas quedan fuera de esta deuda.
-- Esta migracion no crea cargos retroactivos ni inscribe personajes nuevos.

ALTER TABLE public.suscripciones_gastos_vida
    DROP CONSTRAINT IF EXISTS suscripciones_gastos_vida_frecuencia_check;

ALTER TABLE public.suscripciones_gastos_vida
    ADD CONSTRAINT suscripciones_gastos_vida_frecuencia_check
    CHECK (
        frecuencia IS NULL OR frecuencia IN (
            'mensual', 'por evento', 'variable',
            'cada_6_miercoles', 'diaria'
        )
    );

CREATE TABLE public.obligaciones_gastos_vida (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    personaje_id uuid NOT NULL REFERENCES public.personajes(id),
    gasto_id text NOT NULL REFERENCES public.catalogo_gastos_vida(id),
    suscripcion_id uuid REFERENCES public.suscripciones_gastos_vida(id),
    solicitud_id uuid REFERENCES public.solicitudes_gastos_vida(id),
    origen text NOT NULL CHECK (origen IN ('periodico', 'aprobado')),
    ciclo_vencimiento timestamptz,
    vence_en timestamptz NOT NULL,
    monto_base numeric(12,2) NOT NULL CHECK (monto_base >= 0),
    multa_mora numeric(12,2) NOT NULL DEFAULT 0 CHECK (multa_mora >= 0),
    cargo_reconexion numeric(12,2) NOT NULL DEFAULT 0 CHECK (cargo_reconexion >= 0),
    nueva_cuota numeric(12,2) NOT NULL DEFAULT 0 CHECK (nueva_cuota >= 0),
    estado text NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente', 'mora', 'liquidada', 'cancelada')),
    creada_en timestamptz NOT NULL DEFAULT now(),
    liquidada_en timestamptz,
    CONSTRAINT obligaciones_periodicas_requieren_suscripcion
        CHECK (origen <> 'periodico' OR suscripcion_id IS NOT NULL),
    CONSTRAINT obligaciones_aprobadas_requieren_solicitud
        CHECK (origen <> 'aprobado' OR solicitud_id IS NOT NULL)
);

CREATE UNIQUE INDEX obligaciones_ciclo_unico
    ON public.obligaciones_gastos_vida (suscripcion_id, ciclo_vencimiento)
    WHERE origen = 'periodico';

CREATE UNIQUE INDEX obligaciones_solicitud_unica
    ON public.obligaciones_gastos_vida (solicitud_id)
    WHERE solicitud_id IS NOT NULL;

CREATE INDEX obligaciones_personaje_estado_idx
    ON public.obligaciones_gastos_vida (personaje_id, estado, vence_en);

ALTER TABLE public.obligaciones_gastos_vida ENABLE ROW LEVEL SECURITY;

CREATE POLICY obligaciones_lectura_propias_o_dm
    ON public.obligaciones_gastos_vida
    FOR SELECT TO authenticated
    USING (
        public.es_dm()
        OR EXISTS (
            SELECT 1 FROM public.asignaciones a
            WHERE a.personaje_id = obligaciones_gastos_vida.personaje_id
              AND a.perfil_id = (SELECT auth.uid())
        )
    );

GRANT SELECT ON public.obligaciones_gastos_vida TO authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON public.obligaciones_gastos_vida FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._saldo_personaje(p_personaje_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_ficha jsonb;
    v_movimientos jsonb;
    v_saldo numeric;
BEGIN
    SELECT ficha INTO v_ficha
    FROM public.personajes WHERE id = p_personaje_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;
    v_movimientos := COALESCE(v_ficha #> '{economia,movimientos}', '[]'::jsonb);
    IF jsonb_typeof(v_movimientos) <> 'array' THEN
        RAISE EXCEPTION 'El historial económico no es válido.';
    END IF;
    SELECT COALESCE(NULLIF(v_ficha #>> '{economia,saldo_inicial}', '')::numeric, 0)
        + COALESCE(SUM(CASE movimiento->>'tipo'
            WHEN 'ingreso' THEN COALESCE((movimiento->>'monto')::numeric, 0)
            WHEN 'egreso' THEN -COALESCE((movimiento->>'monto')::numeric, 0)
            ELSE 0 END), 0)
    INTO v_saldo
    FROM jsonb_array_elements(v_movimientos) AS x(movimiento);
    RETURN v_saldo;
END;
$function$;

CREATE OR REPLACE FUNCTION public._registrar_movimiento_gasto(
    p_personaje_id uuid,
    p_tipo text,
    p_subtipo text,
    p_monto numeric,
    p_concepto text,
    p_gasto_id text,
    p_obligacion_id uuid,
    p_solicitud_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_ficha jsonb;
    v_economia jsonb;
    v_movimientos jsonb;
    v_nombre text;
BEGIN
    SELECT ficha, nombre_clave INTO v_ficha, v_nombre
    FROM public.personajes WHERE id = p_personaje_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;
    v_economia := COALESCE(v_ficha->'economia', '{}'::jsonb);
    IF jsonb_typeof(v_economia) <> 'object' THEN v_economia := '{}'::jsonb; END IF;
    v_movimientos := COALESCE(v_economia->'movimientos', '[]'::jsonb);
    IF jsonb_typeof(v_movimientos) <> 'array' THEN
        RAISE EXCEPTION 'El historial económico no es válido.';
    END IF;
    v_movimientos := v_movimientos || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'fecha', now(), 'tipo', p_tipo, 'subtipo', p_subtipo,
        'monto', p_monto, 'concepto', p_concepto, 'catalogo_id', p_gasto_id,
        'obligacion_id', p_obligacion_id, 'solicitud_id', p_solicitud_id,
        'quien_pago', v_nombre, 'quien_cobro', 'GASTOS DE VIDA'
    )));
    v_economia := jsonb_set(v_economia, '{movimientos}', v_movimientos, true);
    v_ficha := jsonb_set(COALESCE(v_ficha, '{}'::jsonb), '{economia}', v_economia, true);
    UPDATE public.personajes SET ficha = v_ficha WHERE id = p_personaje_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public._intervalo_gasto(p_gasto_id text)
RETURNS interval
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT CASE
        WHEN c.grupo = 'vivienda'
          OR c.frecuencia IN ('mensual', 'cada_6_miercoles') THEN interval '42 days'
        WHEN c.frecuencia = 'diaria' THEN interval '1 day'
        ELSE NULL
    END
    FROM public.catalogo_gastos_vida c
    WHERE c.id = p_gasto_id AND c.activo = true
$function$;

CREATE OR REPLACE FUNCTION public.procesar_cobros_periodicos()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_candidato record;
    v_personaje public.personajes%ROWTYPE;
    v_suscripcion public.suscripciones_gastos_vida%ROWTYPE;
    v_base numeric;
    v_saldo numeric;
    v_intervalo interval;
    v_obligacion_id uuid;
    v_cobrados integer := 0;
    v_suspendidos integer := 0;
BEGIN
    FOR v_candidato IN
        SELECT s.id, s.personaje_id
        FROM public.suscripciones_gastos_vida s
        JOIN public.catalogo_gastos_vida c ON c.id = s.gasto_id
        WHERE s.estado = 'activa' AND s.proximo_cobro <= now()
          AND (c.grupo = 'vivienda' OR c.frecuencia IN ('mensual','diaria','cada_6_miercoles'))
        ORDER BY s.proximo_cobro, s.id
    LOOP
        SELECT * INTO v_personaje FROM public.personajes
        WHERE id = v_candidato.personaje_id FOR UPDATE SKIP LOCKED;
        IF NOT FOUND THEN CONTINUE; END IF;
        SELECT * INTO v_suscripcion FROM public.suscripciones_gastos_vida
        WHERE id = v_candidato.id FOR UPDATE SKIP LOCKED;
        IF NOT FOUND OR v_suscripcion.estado <> 'activa'
           OR v_suscripcion.proximo_cobro > now() THEN CONTINUE; END IF;

        v_intervalo := public._intervalo_gasto(v_suscripcion.gasto_id);
        IF v_intervalo IS NULL THEN CONTINUE; END IF;
        v_base := v_suscripcion.costo;
        IF v_base IS NULL OR v_base < 0 THEN
            RAISE EXCEPTION 'Costo inválido en suscripción %.', v_suscripcion.id;
        END IF;

        INSERT INTO public.obligaciones_gastos_vida
            (personaje_id, gasto_id, suscripcion_id, origen, ciclo_vencimiento,
             vence_en, monto_base, estado)
        VALUES (v_suscripcion.personaje_id, v_suscripcion.gasto_id,
                v_suscripcion.id, 'periodico', v_suscripcion.proximo_cobro,
                v_suscripcion.proximo_cobro, v_base, 'pendiente')
        ON CONFLICT (suscripcion_id, ciclo_vencimiento) WHERE origen = 'periodico'
        DO NOTHING
        RETURNING id INTO v_obligacion_id;
        IF v_obligacion_id IS NULL THEN CONTINUE; END IF;

        v_saldo := public._saldo_personaje(v_suscripcion.personaje_id);
        IF v_saldo >= v_base THEN
            PERFORM public._registrar_movimiento_gasto(
                v_suscripcion.personaje_id, 'egreso', 'COSTO_DE_VIDA', v_base,
                'Cuota periódica: ' || v_suscripcion.gasto_id,
                v_suscripcion.gasto_id, v_obligacion_id, NULL);
            UPDATE public.obligaciones_gastos_vida
                SET estado = 'liquidada', liquidada_en = now()
                WHERE id = v_obligacion_id;
            UPDATE public.suscripciones_gastos_vida
                SET proximo_cobro = v_suscripcion.proximo_cobro + v_intervalo,
                    actualizado_en = now()
                WHERE id = v_suscripcion.id;
            v_cobrados := v_cobrados + 1;
        ELSE
            UPDATE public.obligaciones_gastos_vida
                SET multa_mora = round(v_base * 0.66, 2), estado = 'mora'
                WHERE id = v_obligacion_id;
            UPDATE public.suscripciones_gastos_vida
                SET estado = 'suspendida', actualizado_en = now()
                WHERE id = v_suscripcion.id;
            v_suspendidos := v_suspendidos + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('cobrados', v_cobrados, 'suspendidos_por_saldo', v_suspendidos);
END;
$function$;

CREATE OR REPLACE FUNCTION public.procesar_cobros_vivienda()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT public.procesar_cobros_periodicos();
$function$;

CREATE OR REPLACE FUNCTION public.activar_servicio_gasto(
    p_personaje_id uuid, p_gasto_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_personaje public.personajes%ROWTYPE;
    v_gasto public.catalogo_gastos_vida%ROWTYPE;
    v_existente public.suscripciones_gastos_vida%ROWTYPE;
    v_intervalo interval;
    v_costo numeric;
    v_saldo numeric;
    v_id uuid;
BEGIN
    IF v_usuario IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.asignaciones
        WHERE perfil_id = v_usuario AND personaje_id = p_personaje_id
    ) THEN RAISE EXCEPTION 'No tienes asignado este personaje.'; END IF;
    SELECT * INTO v_personaje FROM public.personajes
    WHERE id = p_personaje_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;
    SELECT * INTO v_gasto FROM public.catalogo_gastos_vida
    WHERE id = p_gasto_id AND activo = true
      AND (grupo IN ('obligatorio','opcional') OR id = 'VIV-003');
    IF NOT FOUND THEN RAISE EXCEPTION 'Servicio no disponible para activación directa.'; END IF;
    v_intervalo := public._intervalo_gasto(v_gasto.id);
    IF v_intervalo IS NULL THEN RAISE EXCEPTION 'El gasto no es periódico.'; END IF;
    v_costo := CASE WHEN v_gasto.grupo = 'vivienda'
        THEN COALESCE(NULLIF(v_gasto.datos_originales->>'costo_por_persona','')::numeric, v_gasto.costo)
        ELSE v_gasto.costo END;
    IF v_costo IS NULL OR v_costo < 0 THEN RAISE EXCEPTION 'Costo inválido.'; END IF;

    SELECT * INTO v_existente FROM public.suscripciones_gastos_vida
    WHERE personaje_id = p_personaje_id AND gasto_id = p_gasto_id FOR UPDATE;
    IF FOUND AND v_existente.estado = 'activa' THEN
        RAISE EXCEPTION 'El servicio ya está activo.';
    ELSIF FOUND AND v_existente.estado = 'suspendida' THEN
        RETURN public.reactivar_servicio_gasto(v_existente.id);
    END IF;
    IF v_gasto.grupo = 'vivienda' AND EXISTS (
        SELECT 1 FROM public.suscripciones_gastos_vida
        WHERE personaje_id = p_personaje_id AND gasto_id LIKE 'VIV-%' AND estado = 'activa'
    ) THEN RAISE EXCEPTION 'Ya existe una vivienda activa.'; END IF;

    v_saldo := public._saldo_personaje(p_personaje_id);
    IF v_saldo < v_costo THEN RAISE EXCEPTION 'Saldo insuficiente: % CORPOS.', v_saldo; END IF;
    INSERT INTO public.suscripciones_gastos_vida
        (personaje_id,gasto_id,costo,frecuencia,estado,fecha_solicitud,fecha_activacion,proximo_cobro,actualizado_en)
    VALUES (p_personaje_id,p_gasto_id,v_costo,
        CASE WHEN v_gasto.grupo='vivienda' THEN 'cada_6_miercoles' ELSE v_gasto.frecuencia END,
        'activa',now(),now(),now()+v_intervalo,now())
    ON CONFLICT (personaje_id,gasto_id) DO UPDATE SET
        costo=EXCLUDED.costo, frecuencia=EXCLUDED.frecuencia, estado='activa',
        fecha_solicitud=now(),fecha_activacion=now(),proximo_cobro=EXCLUDED.proximo_cobro,actualizado_en=now()
    RETURNING id INTO v_id;
    PERFORM public._registrar_movimiento_gasto(p_personaje_id,'egreso','COSTO_DE_VIDA',v_costo,
        'Activación: '||v_gasto.nombre,p_gasto_id,NULL,NULL);
    RETURN jsonb_build_object('exito',true,'suscripcion_id',v_id,'gasto',v_gasto.nombre,
        'cargo_inicial',v_costo,'saldo_actual',v_saldo-v_costo,'proximo_cobro',now()+v_intervalo);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reactivar_servicio_gasto(p_suscripcion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_personaje_id uuid;
    v_suscripcion public.suscripciones_gastos_vida%ROWTYPE;
    v_obligacion public.obligaciones_gastos_vida%ROWTYPE;
    v_base numeric;
    v_mora numeric := 0;
    v_reconexion numeric;
    v_nueva numeric;
    v_total numeric;
    v_saldo numeric;
    v_intervalo interval;
    v_obligacion_id uuid;
BEGIN
    SELECT personaje_id INTO v_personaje_id FROM public.suscripciones_gastos_vida
    WHERE id=p_suscripcion_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Suscripción no encontrada.'; END IF;
    IF v_usuario IS NULL OR NOT EXISTS (SELECT 1 FROM public.asignaciones
        WHERE perfil_id=v_usuario AND personaje_id=v_personaje_id) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;
    PERFORM 1 FROM public.personajes WHERE id=v_personaje_id FOR UPDATE;
    SELECT * INTO v_suscripcion FROM public.suscripciones_gastos_vida
    WHERE id=p_suscripcion_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Suscripción no encontrada.'; END IF;
    IF v_suscripcion.estado='activa' THEN RAISE EXCEPTION 'El servicio ya está activo.'; END IF;
    IF v_suscripcion.estado<>'suspendida' THEN
        RAISE EXCEPTION 'Solo se puede reactivar un servicio suspendido.';
    END IF;
    SELECT * INTO v_obligacion FROM public.obligaciones_gastos_vida
    WHERE suscripcion_id=p_suscripcion_id AND estado='mora'
    ORDER BY vence_en LIMIT 1 FOR UPDATE;
    IF FOUND THEN
        v_obligacion_id := v_obligacion.id;
        v_base := v_obligacion.monto_base;
        v_mora := v_obligacion.multa_mora;
    ELSE
        v_base := 0;
    END IF;
    v_reconexion := round(v_suscripcion.costo * 0.66,2);
    v_nueva := v_suscripcion.costo;
    v_total := v_base+v_mora+v_reconexion+v_nueva;
    v_saldo := public._saldo_personaje(v_suscripcion.personaje_id);
    IF v_saldo < v_total THEN RAISE EXCEPTION 'Saldo insuficiente. Liquidación: % CORPOS.',v_total; END IF;
    IF v_base>0 THEN PERFORM public._registrar_movimiento_gasto(v_suscripcion.personaje_id,'egreso','DEUDA_ORIGINAL',v_base,
        'Liquidación de deuda: '||v_suscripcion.gasto_id,v_suscripcion.gasto_id,v_obligacion_id,NULL); END IF;
    IF v_mora>0 THEN PERFORM public._registrar_movimiento_gasto(v_suscripcion.personaje_id,'egreso','MULTA_MORA',v_mora,
        'Multa por mora (66%): '||v_suscripcion.gasto_id,v_suscripcion.gasto_id,v_obligacion_id,NULL); END IF;
    PERFORM public._registrar_movimiento_gasto(v_suscripcion.personaje_id,'egreso','CARGO_RECONEXION',v_reconexion,
        'Cargo de reconexión (66%): '||v_suscripcion.gasto_id,v_suscripcion.gasto_id,v_obligacion_id,NULL);
    PERFORM public._registrar_movimiento_gasto(v_suscripcion.personaje_id,'egreso','COSTO_DE_VIDA',v_nueva,
        'Nueva cuota al reactivar: '||v_suscripcion.gasto_id,v_suscripcion.gasto_id,v_obligacion_id,NULL);
    IF v_obligacion_id IS NOT NULL THEN
        UPDATE public.obligaciones_gastos_vida SET estado='liquidada',
            cargo_reconexion=v_reconexion,nueva_cuota=v_nueva,liquidada_en=now()
        WHERE id=v_obligacion_id;
    END IF;
    v_intervalo := public._intervalo_gasto(v_suscripcion.gasto_id);
    UPDATE public.suscripciones_gastos_vida SET estado='activa',fecha_activacion=now(),
        proximo_cobro=now()+v_intervalo,actualizado_en=now() WHERE id=p_suscripcion_id;
    RETURN jsonb_build_object('exito',true,'deuda',v_base,'multa_mora',v_mora,
        'reconexion',v_reconexion,'nueva_cuota',v_nueva,'total',v_total,'saldo_actual',v_saldo-v_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reactivar_obligacion_aprobada(p_obligacion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_personaje_id uuid;
    v_obligacion public.obligaciones_gastos_vida%ROWTYPE;
    v_saldo numeric;
    v_reconexion numeric;
    v_nueva numeric;
    v_total numeric;
BEGIN
    SELECT personaje_id INTO v_personaje_id FROM public.obligaciones_gastos_vida
    WHERE id=p_obligacion_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'La obligación no existe.'; END IF;
    IF v_usuario IS NULL OR NOT EXISTS (SELECT 1 FROM public.asignaciones
        WHERE perfil_id=v_usuario AND personaje_id=v_personaje_id) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;
    PERFORM 1 FROM public.personajes WHERE id=v_personaje_id FOR UPDATE;
    SELECT * INTO v_obligacion FROM public.obligaciones_gastos_vida
    WHERE id=p_obligacion_id FOR UPDATE;
    IF NOT FOUND OR v_obligacion.origen<>'aprobado' OR v_obligacion.estado<>'mora' THEN
        RAISE EXCEPTION 'La obligación no está disponible para reactivación.';
    END IF;
    v_reconexion:=round(v_obligacion.monto_base*0.66,2);
    v_nueva:=v_obligacion.monto_base;
    v_total:=v_obligacion.monto_base+v_obligacion.multa_mora+v_reconexion+v_nueva;
    v_saldo:=public._saldo_personaje(v_obligacion.personaje_id);
    IF v_saldo<v_total THEN RAISE EXCEPTION 'Saldo insuficiente. Liquidación: % CORPOS.',v_total; END IF;
    PERFORM public._registrar_movimiento_gasto(v_obligacion.personaje_id,'egreso','DEUDA_ORIGINAL',v_obligacion.monto_base,
        'Liquidación de obligación aprobada: '||v_obligacion.gasto_id,v_obligacion.gasto_id,v_obligacion.id,v_obligacion.solicitud_id);
    PERFORM public._registrar_movimiento_gasto(v_obligacion.personaje_id,'egreso','MULTA_MORA',v_obligacion.multa_mora,
        'Multa por mora (66%): '||v_obligacion.gasto_id,v_obligacion.gasto_id,v_obligacion.id,v_obligacion.solicitud_id);
    PERFORM public._registrar_movimiento_gasto(v_obligacion.personaje_id,'egreso','CARGO_RECONEXION',v_reconexion,
        'Cargo de reconexión (66%): '||v_obligacion.gasto_id,v_obligacion.gasto_id,v_obligacion.id,v_obligacion.solicitud_id);
    PERFORM public._registrar_movimiento_gasto(v_obligacion.personaje_id,'egreso','COSTO_REACTIVACION',v_nueva,
        'Nueva activación tras mora: '||v_obligacion.gasto_id,v_obligacion.gasto_id,v_obligacion.id,v_obligacion.solicitud_id);
    UPDATE public.obligaciones_gastos_vida SET estado='liquidada',cargo_reconexion=v_reconexion,
        nueva_cuota=v_nueva,liquidada_en=now() WHERE id=v_obligacion.id;
    RETURN jsonb_build_object('exito',true,'deuda',v_obligacion.monto_base,
        'multa_mora',v_obligacion.multa_mora,'reconexion',v_reconexion,
        'nueva_activacion',v_nueva,'total',v_total,'saldo_actual',v_saldo-v_total);
END;
$function$;

CREATE OR REPLACE FUNCTION public.activar_vivienda_predeterminada(p_personaje_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT public.activar_servicio_gasto(p_personaje_id, 'VIV-003');
$function$;

CREATE OR REPLACE FUNCTION public._proteger_vivienda_con_mora()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF TG_OP='UPDATE' AND OLD.estado='activa' AND NEW.estado='cancelada'
       AND OLD.gasto_id LIKE 'VIV-%'
       AND EXISTS (SELECT 1 FROM public.obligaciones_gastos_vida o
           WHERE o.suscripcion_id=OLD.id AND o.estado='mora') THEN
        RAISE EXCEPTION 'Liquida la mora de vivienda antes de cambiarla.';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER proteger_vivienda_con_mora
    BEFORE UPDATE OF estado ON public.suscripciones_gastos_vida
    FOR EACH ROW EXECUTE FUNCTION public._proteger_vivienda_con_mora();

CREATE OR REPLACE FUNCTION public._resolver_solicitud_gasto(
    p_solicitud_id uuid, p_tipo text, p_aprobar boolean, p_costo numeric, p_mensaje text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_solicitud public.solicitudes_gastos_vida%ROWTYPE;
    v_personaje public.personajes%ROWTYPE;
    v_gasto public.catalogo_gastos_vida%ROWTYPE;
    v_saldo numeric;
    v_obligacion uuid;
    v_mora numeric := 0;
BEGIN
    IF (SELECT auth.uid()) IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el DM puede resolver solicitudes.';
    END IF;
    SELECT * INTO v_solicitud FROM public.solicitudes_gastos_vida
    WHERE id=p_solicitud_id FOR UPDATE;
    IF NOT FOUND OR v_solicitud.tipo_solicitud<>p_tipo OR v_solicitud.estado<>'pendiente' THEN
        RAISE EXCEPTION 'La solicitud no existe o ya fue resuelta.';
    END IF;
    IF NOT p_aprobar THEN
        UPDATE public.solicitudes_gastos_vida SET estado='rechazada',
            mensaje=COALESCE(NULLIF(p_mensaje,''),'Solicitud rechazada por el DM.'),
            fecha_revision=now(),revisado_por=(SELECT auth.uid()) WHERE id=p_solicitud_id;
        RETURN jsonb_build_object('exito',true,'estado','rechazada');
    END IF;
    SELECT * INTO v_gasto FROM public.catalogo_gastos_vida
    WHERE id=v_solicitud.gasto_id AND grupo=p_tipo AND (activo OR p_tipo='variable');
    IF NOT FOUND THEN RAISE EXCEPTION 'El gasto no está disponible.'; END IF;
    IF p_costo IS NULL OR p_costo<0 THEN RAISE EXCEPTION 'El costo aprobado no es válido.'; END IF;
    SELECT * INTO v_personaje FROM public.personajes
    WHERE id=v_solicitud.personaje_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;
    v_saldo:=public._saldo_personaje(v_personaje.id);
    IF v_saldo<p_costo THEN v_mora:=round(p_costo*0.66,2); END IF;
    INSERT INTO public.obligaciones_gastos_vida
        (personaje_id,gasto_id,solicitud_id,origen,vence_en,monto_base,multa_mora,estado)
    VALUES (v_personaje.id,v_gasto.id,v_solicitud.id,'aprobado',now(),p_costo,v_mora,
        CASE WHEN v_saldo<p_costo THEN 'mora' ELSE 'pendiente' END)
    RETURNING id INTO v_obligacion;
    IF v_saldo>=p_costo THEN
        PERFORM public._registrar_movimiento_gasto(v_personaje.id,'egreso',
            CASE WHEN p_tipo='evento' THEN 'EVENTO' ELSE 'GASTO_VARIABLE' END,
            p_costo,v_gasto.nombre,v_gasto.id,v_obligacion,v_solicitud.id);
        UPDATE public.obligaciones_gastos_vida SET estado='liquidada',liquidada_en=now()
            WHERE id=v_obligacion;
    END IF;
    UPDATE public.solicitudes_gastos_vida SET estado='aprobada',importe_solicitado=p_costo,
        mensaje=COALESCE(NULLIF(p_mensaje,''),'Solicitud aprobada por el DM.'),
        fecha_revision=now(),revisado_por=(SELECT auth.uid()) WHERE id=p_solicitud_id;
    RETURN jsonb_build_object('exito',true,'estado',CASE WHEN v_saldo<p_costo THEN 'mora' ELSE 'aprobada' END,
        'obligacion_id',v_obligacion,'cargo',p_costo,'multa_mora',v_mora,'saldo_actual',v_saldo);
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_solicitud_evento(
    p_solicitud_id uuid,p_aprobar boolean,p_mensaje text DEFAULT NULL
)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
    SELECT public._resolver_solicitud_gasto(p_solicitud_id,'evento',p_aprobar,
        (SELECT s.importe_solicitado FROM public.solicitudes_gastos_vida s WHERE s.id=p_solicitud_id),p_mensaje);
$function$;

CREATE OR REPLACE FUNCTION public.solicitar_gasto_variable(
    p_personaje_id uuid,p_gasto_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_gasto public.catalogo_gastos_vida%ROWTYPE;
    v_solicitud uuid;
BEGIN
    IF v_usuario IS NULL OR NOT EXISTS (SELECT 1 FROM public.asignaciones
        WHERE perfil_id=v_usuario AND personaje_id=p_personaje_id) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;
    PERFORM 1 FROM public.personajes WHERE id=p_personaje_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;
    SELECT * INTO v_gasto FROM public.catalogo_gastos_vida
    WHERE id=p_gasto_id AND grupo='variable' AND activo=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'El gasto variable no está disponible.'; END IF;
    INSERT INTO public.solicitudes_gastos_vida
        (personaje_id,gasto_id,tipo_solicitud,importe_solicitado,mensaje)
    VALUES (p_personaje_id,p_gasto_id,'variable',NULL,'Solicitud pendiente de revisión del DM.')
    RETURNING id INTO v_solicitud;
    RETURN jsonb_build_object('exito',true,'solicitud_id',v_solicitud,'estado','pendiente','gasto',v_gasto.nombre);
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_solicitud_variable(
    p_solicitud_id uuid,p_aprobar boolean,p_importe numeric,p_mensaje text DEFAULT NULL
)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
    SELECT public._resolver_solicitud_gasto(p_solicitud_id,'variable',p_aprobar,p_importe,p_mensaje);
$function$;

REVOKE ALL ON FUNCTION public._saldo_personaje(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._registrar_movimiento_gasto(uuid,text,text,numeric,text,text,uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._intervalo_gasto(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._proteger_vivienda_con_mora() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.procesar_cobros_periodicos() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.procesar_cobros_periodicos() TO postgres;
REVOKE ALL ON FUNCTION public._resolver_solicitud_gasto(uuid,text,boolean,numeric,text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.activar_servicio_gasto(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activar_servicio_gasto(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.reactivar_servicio_gasto(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reactivar_servicio_gasto(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.reactivar_obligacion_aprobada(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reactivar_obligacion_aprobada(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.activar_vivienda_predeterminada(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activar_vivienda_predeterminada(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.resolver_solicitud_evento(uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_evento(uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.solicitar_gasto_variable(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.solicitar_gasto_variable(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.resolver_solicitud_variable(uuid,boolean,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolver_solicitud_variable(uuid,boolean,numeric,text) TO authenticated;

