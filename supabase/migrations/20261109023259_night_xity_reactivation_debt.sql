-- Reactivation fees become first-class obligations. If a player cannot pay the
-- all-or-nothing reactivation invoice, each fee enters mora once and is not
-- recreated or penalized again on retries.

CREATE TABLE public.cargos_reactivacion (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    obligacion_id uuid NOT NULL REFERENCES public.obligaciones_gastos_vida(id),
    tipo text NOT NULL CHECK (tipo IN ('reconexion', 'nueva_cuota')),
    monto numeric(12,2) NOT NULL CHECK (monto >= 0),
    multa_mora numeric(12,2) NOT NULL DEFAULT 0 CHECK (multa_mora >= 0),
    estado text NOT NULL CHECK (estado IN ('mora', 'liquidada')),
    vence_en timestamptz NOT NULL DEFAULT now(),
    creada_en timestamptz NOT NULL DEFAULT now(),
    liquidada_en timestamptz,
    CONSTRAINT cargos_reactivacion_obligacion_tipo_unico
        UNIQUE (obligacion_id, tipo),
    CONSTRAINT cargos_reactivacion_liquidacion_consistente
        CHECK ((estado = 'liquidada') = (liquidada_en IS NOT NULL))
);

CREATE INDEX cargos_reactivacion_estado_idx
    ON public.cargos_reactivacion (obligacion_id, estado);

ALTER TABLE public.cargos_reactivacion ENABLE ROW LEVEL SECURITY;

CREATE POLICY cargos_reactivacion_lectura_propias_o_dm
    ON public.cargos_reactivacion
    FOR SELECT TO authenticated
    USING (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.obligaciones_gastos_vida o
            JOIN public.asignaciones a ON a.personaje_id = o.personaje_id
            WHERE o.id = cargos_reactivacion.obligacion_id
              AND a.perfil_id = (SELECT auth.uid())
        )
    );

GRANT SELECT ON public.cargos_reactivacion TO authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON public.cargos_reactivacion FROM anon, authenticated;

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
    v_cargos integer;
    v_reconexion numeric;
    v_nueva numeric;
    v_cargos_base numeric;
    v_cargos_mora numeric;
    v_total numeric;
    v_saldo numeric;
    v_intervalo interval;
BEGIN
    SELECT personaje_id INTO v_personaje_id
    FROM public.suscripciones_gastos_vida WHERE id = p_suscripcion_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Suscripción no encontrada.'; END IF;
    IF v_usuario IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.asignaciones
        WHERE perfil_id = v_usuario AND personaje_id = v_personaje_id
    ) THEN RAISE EXCEPTION 'No tienes asignado este personaje.'; END IF;

    PERFORM 1 FROM public.personajes WHERE id = v_personaje_id FOR UPDATE;
    SELECT * INTO v_suscripcion FROM public.suscripciones_gastos_vida
    WHERE id = p_suscripcion_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Suscripción no encontrada.'; END IF;
    IF v_suscripcion.estado <> 'suspendida' THEN
        RAISE EXCEPTION 'Solo se puede reactivar un servicio suspendido.';
    END IF;

    SELECT * INTO v_obligacion
    FROM public.obligaciones_gastos_vida
    WHERE suscripcion_id = p_suscripcion_id AND estado = 'mora'
    ORDER BY vence_en LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No hay una obligación en mora asociada a este servicio.';
    END IF;

    SELECT count(*), COALESCE(sum(monto), 0), COALESCE(sum(multa_mora), 0)
      INTO v_cargos, v_cargos_base, v_cargos_mora
    FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id;

    IF v_cargos = 0 THEN
        v_reconexion := round(v_suscripcion.costo * 0.66, 2);
        v_nueva := v_suscripcion.costo;
        v_saldo := public._saldo_personaje(v_personaje_id);
        v_total := v_obligacion.monto_base + v_obligacion.multa_mora
                 + v_reconexion + v_nueva;

        IF v_saldo < v_total THEN
            INSERT INTO public.cargos_reactivacion
                (obligacion_id, tipo, monto, multa_mora, estado)
            VALUES
                (v_obligacion.id, 'reconexion', v_reconexion,
                 round(v_reconexion * 0.66, 2), 'mora'),
                (v_obligacion.id, 'nueva_cuota', v_nueva,
                 round(v_nueva * 0.66, 2), 'mora');
            SELECT COALESCE(sum(multa_mora), 0)
              INTO v_cargos_mora
            FROM public.cargos_reactivacion
            WHERE obligacion_id = v_obligacion.id;
            v_total := v_total + v_cargos_mora;
            RETURN jsonb_build_object(
                'exito', false, 'estado', 'mora', 'deuda', v_obligacion.monto_base,
                'multa_mora', v_obligacion.multa_mora, 'reconexion', v_reconexion,
                'nueva_cuota', v_nueva, 'multa_cargos_reactivacion', v_cargos_mora,
                'total', v_total, 'saldo_actual', v_saldo,
                'mensaje', 'Saldo insuficiente; la reconexión y la nueva cuota quedaron como obligaciones en mora.'
            );
        END IF;

        INSERT INTO public.cargos_reactivacion
            (obligacion_id, tipo, monto, multa_mora, estado, liquidada_en)
        VALUES
            (v_obligacion.id, 'reconexion', v_reconexion, 0, 'liquidada', now()),
            (v_obligacion.id, 'nueva_cuota', v_nueva, 0, 'liquidada', now());
        v_cargos_base := v_reconexion + v_nueva;
        v_cargos_mora := 0;
    ELSIF v_cargos <> 2 THEN
        RAISE EXCEPTION 'Integridad inválida en los cargos de reactivación.';
    END IF;

    SELECT COALESCE(sum(monto), 0), COALESCE(sum(multa_mora), 0)
      INTO v_cargos_base, v_cargos_mora
    FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id;
    SELECT monto INTO v_reconexion FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id AND tipo = 'reconexion';
    SELECT monto INTO v_nueva FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id AND tipo = 'nueva_cuota';

    v_total := v_obligacion.monto_base + v_obligacion.multa_mora
             + v_cargos_base + v_cargos_mora;
    v_saldo := public._saldo_personaje(v_personaje_id);
    IF v_saldo < v_total THEN
        RETURN jsonb_build_object(
            'exito', false, 'estado', 'mora', 'deuda', v_obligacion.monto_base,
            'multa_mora', v_obligacion.multa_mora, 'reconexion', v_reconexion,
            'multa_reconexion', (SELECT multa_mora FROM public.cargos_reactivacion
                WHERE obligacion_id = v_obligacion.id AND tipo = 'reconexion'),
            'nueva_cuota', v_nueva,
            'multa_nueva_cuota', (SELECT multa_mora FROM public.cargos_reactivacion
                WHERE obligacion_id = v_obligacion.id AND tipo = 'nueva_cuota'),
            'total', v_total, 'saldo_actual', v_saldo,
            'mensaje', 'Saldo insuficiente para liquidar la deuda y reactivar el servicio.'
        );
    END IF;

    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'DEUDA_ORIGINAL',
        v_obligacion.monto_base, 'Liquidación de deuda: ' || v_suscripcion.gasto_id,
        v_suscripcion.gasto_id, v_obligacion.id, NULL);
    IF v_obligacion.multa_mora > 0 THEN
        PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'MULTA_MORA',
            v_obligacion.multa_mora, 'Multa por mora (66%): ' || v_suscripcion.gasto_id,
            v_suscripcion.gasto_id, v_obligacion.id, NULL);
    END IF;
    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'CARGO_RECONEXION',
        v_reconexion, 'Cargo de reconexión (66%): ' || v_suscripcion.gasto_id,
        v_suscripcion.gasto_id, v_obligacion.id, NULL);
    IF v_cargos_mora > 0 THEN
        PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'MULTA_MORA_REACTIVACION',
            v_cargos_mora, 'Multa por mora de reconexión y nueva cuota: ' || v_suscripcion.gasto_id,
            v_suscripcion.gasto_id, v_obligacion.id, NULL);
    END IF;
    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'COSTO_DE_VIDA',
        v_nueva, 'Nueva cuota al reactivar: ' || v_suscripcion.gasto_id,
        v_suscripcion.gasto_id, v_obligacion.id, NULL);

    UPDATE public.cargos_reactivacion SET estado = 'liquidada', liquidada_en = now()
    WHERE obligacion_id = v_obligacion.id AND estado = 'mora';
    UPDATE public.obligaciones_gastos_vida SET estado = 'liquidada',
        cargo_reconexion = v_reconexion, nueva_cuota = v_nueva, liquidada_en = now()
    WHERE id = v_obligacion.id;

    v_intervalo := public._intervalo_gasto(v_suscripcion.gasto_id);
    UPDATE public.suscripciones_gastos_vida SET estado = 'activa',
        fecha_activacion = now(), proximo_cobro = now() + v_intervalo,
        actualizado_en = now() WHERE id = p_suscripcion_id;
    RETURN jsonb_build_object('exito', true, 'estado', 'activa',
        'deuda', v_obligacion.monto_base, 'multa_mora', v_obligacion.multa_mora,
        'reconexion', v_reconexion, 'nueva_cuota', v_nueva,
        'multa_cargos_reactivacion', v_cargos_mora, 'total', v_total,
        'saldo_actual', v_saldo - v_total);
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
    v_suscripcion_id uuid;
    v_cargos integer;
    v_reconexion numeric;
    v_nueva numeric;
    v_cargos_base numeric;
    v_cargos_mora numeric;
    v_total numeric;
    v_saldo numeric;
BEGIN
    SELECT personaje_id INTO v_personaje_id
    FROM public.obligaciones_gastos_vida WHERE id = p_obligacion_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'La obligación no existe.'; END IF;
    IF v_usuario IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.asignaciones
        WHERE perfil_id = v_usuario AND personaje_id = v_personaje_id
    ) THEN RAISE EXCEPTION 'No tienes asignado este personaje.'; END IF;

    PERFORM 1 FROM public.personajes WHERE id = v_personaje_id FOR UPDATE;
    SELECT * INTO v_obligacion FROM public.obligaciones_gastos_vida
    WHERE id = p_obligacion_id FOR UPDATE;
    IF NOT FOUND OR v_obligacion.origen <> 'aprobado' OR v_obligacion.estado <> 'mora' THEN
        RAISE EXCEPTION 'La obligación no está disponible para reactivación.';
    END IF;

    SELECT id INTO v_suscripcion_id FROM public.suscripciones_gastos_vida
    WHERE personaje_id = v_personaje_id AND gasto_id = v_obligacion.gasto_id
    ORDER BY creado_en DESC LIMIT 1;
    SELECT count(*), COALESCE(sum(monto), 0), COALESCE(sum(multa_mora), 0)
      INTO v_cargos, v_cargos_base, v_cargos_mora
    FROM public.cargos_reactivacion WHERE obligacion_id = v_obligacion.id;

    IF v_cargos = 0 THEN
        v_reconexion := round(v_obligacion.monto_base * 0.66, 2);
        v_nueva := v_obligacion.monto_base;
        v_saldo := public._saldo_personaje(v_personaje_id);
        v_total := v_obligacion.monto_base + v_obligacion.multa_mora
                 + v_reconexion + v_nueva;
        IF v_saldo < v_total THEN
            INSERT INTO public.cargos_reactivacion
                (obligacion_id, tipo, monto, multa_mora, estado)
            VALUES
                (v_obligacion.id, 'reconexion', v_reconexion,
                 round(v_reconexion * 0.66, 2), 'mora'),
                (v_obligacion.id, 'nueva_cuota', v_nueva,
                 round(v_nueva * 0.66, 2), 'mora');
            SELECT COALESCE(sum(multa_mora), 0) INTO v_cargos_mora
            FROM public.cargos_reactivacion WHERE obligacion_id = v_obligacion.id;
            v_total := v_total + v_cargos_mora;
            RETURN jsonb_build_object('exito', false, 'estado', 'mora',
                'deuda', v_obligacion.monto_base, 'multa_mora', v_obligacion.multa_mora,
                'reconexion', v_reconexion, 'nueva_activacion', v_nueva,
                'multa_cargos_reactivacion', v_cargos_mora, 'total', v_total,
                'saldo_actual', v_saldo,
                'mensaje', 'La reconexión y la nueva activación quedaron como obligaciones en mora.');
        END IF;
        INSERT INTO public.cargos_reactivacion
            (obligacion_id, tipo, monto, multa_mora, estado, liquidada_en)
        VALUES
            (v_obligacion.id, 'reconexion', v_reconexion, 0, 'liquidada', now()),
            (v_obligacion.id, 'nueva_cuota', v_nueva, 0, 'liquidada', now());
    ELSIF v_cargos <> 2 THEN
        RAISE EXCEPTION 'Integridad inválida en los cargos de reactivación.';
    END IF;

    SELECT COALESCE(sum(monto), 0), COALESCE(sum(multa_mora), 0)
      INTO v_cargos_base, v_cargos_mora
    FROM public.cargos_reactivacion WHERE obligacion_id = v_obligacion.id;
    SELECT monto INTO v_reconexion FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id AND tipo = 'reconexion';
    SELECT monto INTO v_nueva FROM public.cargos_reactivacion
    WHERE obligacion_id = v_obligacion.id AND tipo = 'nueva_cuota';
    v_total := v_obligacion.monto_base + v_obligacion.multa_mora
             + v_cargos_base + v_cargos_mora;
    v_saldo := public._saldo_personaje(v_personaje_id);
    IF v_saldo < v_total THEN
        RETURN jsonb_build_object('exito', false, 'estado', 'mora',
            'deuda', v_obligacion.monto_base, 'multa_mora', v_obligacion.multa_mora,
            'reconexion', v_reconexion, 'nueva_activacion', v_nueva,
            'multa_cargos_reactivacion', v_cargos_mora, 'total', v_total,
            'saldo_actual', v_saldo,
            'mensaje', 'Saldo insuficiente para liquidar la deuda y completar la reactivación.');
    END IF;

    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'DEUDA_ORIGINAL',
        v_obligacion.monto_base, 'Liquidación de obligación aprobada: ' || v_obligacion.gasto_id,
        v_obligacion.gasto_id, v_obligacion.id, v_obligacion.solicitud_id);
    IF v_obligacion.multa_mora > 0 THEN
        PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'MULTA_MORA',
            v_obligacion.multa_mora, 'Multa por mora (66%): ' || v_obligacion.gasto_id,
            v_obligacion.gasto_id, v_obligacion.id, v_obligacion.solicitud_id);
    END IF;
    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'CARGO_RECONEXION',
        v_reconexion, 'Cargo de reconexión (66%): ' || v_obligacion.gasto_id,
        v_obligacion.gasto_id, v_obligacion.id, v_obligacion.solicitud_id);
    IF v_cargos_mora > 0 THEN
        PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'MULTA_MORA_REACTIVACION',
            v_cargos_mora, 'Multa por mora de reconexión y nueva activación: ' || v_obligacion.gasto_id,
            v_obligacion.gasto_id, v_obligacion.id, v_obligacion.solicitud_id);
    END IF;
    PERFORM public._registrar_movimiento_gasto(v_personaje_id, 'egreso', 'COSTO_REACTIVACION',
        v_nueva, 'Nueva activación tras mora: ' || v_obligacion.gasto_id,
        v_obligacion.gasto_id, v_obligacion.id, v_obligacion.solicitud_id);
    UPDATE public.cargos_reactivacion SET estado = 'liquidada', liquidada_en = now()
    WHERE obligacion_id = v_obligacion.id AND estado = 'mora';
    UPDATE public.obligaciones_gastos_vida SET estado = 'liquidada',
        cargo_reconexion = v_reconexion, nueva_cuota = v_nueva, liquidada_en = now()
    WHERE id = v_obligacion.id;
    RETURN jsonb_build_object('exito', true, 'estado', 'liquidada',
        'deuda', v_obligacion.monto_base, 'multa_mora', v_obligacion.multa_mora,
        'reconexion', v_reconexion, 'nueva_activacion', v_nueva,
        'multa_cargos_reactivacion', v_cargos_mora, 'total', v_total,
        'saldo_actual', v_saldo - v_total, 'suscripcion_id', v_suscripcion_id);
END;
$function$;
