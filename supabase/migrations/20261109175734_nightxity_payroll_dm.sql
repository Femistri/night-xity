-- Night Xity: salarios periódicos y pagos puntuales emitidos por el DM.
-- El historial JSONB existente sigue siendo la fuente del saldo. Cada abono
-- también queda en pagos_dm con clave de idempotencia y autoría verificable.

CREATE TABLE public.nominas_jugadores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    personaje_id uuid NOT NULL REFERENCES public.personajes(id) ON DELETE RESTRICT,
    puesto text NOT NULL CHECK (length(btrim(puesto)) BETWEEN 2 AND 120),
    monto numeric(14,2) NOT NULL CHECK (monto > 0),
    ciclo_dias integer NOT NULL DEFAULT 42 CHECK (ciclo_dias = 42),
    proximo_pago timestamptz NOT NULL,
    estado text NOT NULL DEFAULT 'activa'
        CHECK (estado IN ('activa', 'cancelada')),
    creado_por uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    creado_en timestamptz NOT NULL DEFAULT now(),
    cancelado_por uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
    cancelado_en timestamptz,
    CONSTRAINT nominas_cancelacion_consistente CHECK (
        (estado = 'activa' AND cancelado_por IS NULL AND cancelado_en IS NULL)
        OR (estado = 'cancelada' AND cancelado_por IS NOT NULL AND cancelado_en IS NOT NULL)
    )
);

CREATE UNIQUE INDEX nominas_jugadores_puesto_activo_uq
    ON public.nominas_jugadores (personaje_id, lower(puesto))
    WHERE estado = 'activa';

CREATE INDEX nominas_jugadores_vencimiento_idx
    ON public.nominas_jugadores (proximo_pago, id)
    WHERE estado = 'activa';

CREATE TABLE public.pagos_dm (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    personaje_id uuid NOT NULL REFERENCES public.personajes(id) ON DELETE RESTRICT,
    nomina_id uuid REFERENCES public.nominas_jugadores(id) ON DELETE RESTRICT,
    tipo text NOT NULL CHECK (tipo IN ('salario', 'salario_manual', 'trabajo')),
    origen text NOT NULL CHECK (origen IN ('nomina_automatica', 'dm_manual')),
    monto numeric(14,2) NOT NULL CHECK (monto > 0),
    concepto text NOT NULL CHECK (length(btrim(concepto)) BETWEEN 2 AND 200),
    ciclo_vencimiento timestamptz,
    clave_idempotencia uuid NOT NULL UNIQUE,
    pagado_por uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    pagado_en timestamptz NOT NULL DEFAULT now(),
    saldo_resultante numeric(14,2),
    CONSTRAINT pagos_dm_origen_consistente CHECK (
        (origen = 'nomina_automatica' AND tipo = 'salario'
            AND nomina_id IS NOT NULL AND ciclo_vencimiento IS NOT NULL)
        OR (origen = 'dm_manual' AND tipo IN ('salario_manual', 'trabajo')
            AND nomina_id IS NULL AND ciclo_vencimiento IS NULL)
    ),
    CONSTRAINT pagos_dm_nomina_ciclo_uq UNIQUE (nomina_id, ciclo_vencimiento)
);

CREATE INDEX pagos_dm_personaje_fecha_idx
    ON public.pagos_dm (personaje_id, pagado_en DESC);

ALTER TABLE public.nominas_jugadores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos_dm ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.nominas_jugadores FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.pagos_dm FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.nominas_jugadores TO authenticated;
GRANT SELECT ON TABLE public.pagos_dm TO authenticated;

CREATE POLICY nominas_jugadores_solo_dm_lectura
    ON public.nominas_jugadores
    FOR SELECT TO authenticated
    USING ((SELECT public.es_dm()));

CREATE POLICY pagos_dm_solo_dm_lectura
    ON public.pagos_dm
    FOR SELECT TO authenticated
    USING ((SELECT public.es_dm()));

CREATE OR REPLACE FUNCTION public._emitir_pago_dm(
    p_personaje_id uuid,
    p_tipo text,
    p_origen text,
    p_monto numeric,
    p_concepto text,
    p_clave_idempotencia uuid,
    p_nomina_id uuid,
    p_ciclo_vencimiento timestamptz,
    p_pagado_por uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_existente public.pagos_dm%ROWTYPE;
    v_personaje public.personajes%ROWTYPE;
    v_ficha jsonb;
    v_economia jsonb;
    v_movimientos jsonb;
    v_monto numeric(14,2);
    v_concepto text;
    v_pago_id uuid;
    v_fecha timestamptz;
    v_saldo numeric(14,2);
BEGIN
    IF p_clave_idempotencia IS NULL OR p_pagado_por IS NULL THEN
        RAISE EXCEPTION 'Faltan datos de control del pago.';
    END IF;

    v_monto := round(p_monto, 2);
    v_concepto := btrim(p_concepto);
    IF v_monto IS NULL OR v_monto <= 0 THEN
        RAISE EXCEPTION 'El monto debe ser mayor que cero.';
    END IF;
    IF v_concepto IS NULL OR length(v_concepto) NOT BETWEEN 2 AND 200 THEN
        RAISE EXCEPTION 'El concepto debe tener entre 2 y 200 caracteres.';
    END IF;
    IF NOT (
        (p_origen = 'nomina_automatica' AND p_tipo = 'salario'
            AND p_nomina_id IS NOT NULL AND p_ciclo_vencimiento IS NOT NULL)
        OR (p_origen = 'dm_manual' AND p_tipo IN ('salario_manual', 'trabajo')
            AND p_nomina_id IS NULL AND p_ciclo_vencimiento IS NULL)
    ) THEN
        RAISE EXCEPTION 'Tipo u origen de pago no válido.';
    END IF;

    SELECT * INTO v_existente
    FROM public.pagos_dm
    WHERE clave_idempotencia = p_clave_idempotencia
       OR (p_nomina_id IS NOT NULL
           AND nomina_id = p_nomina_id
           AND ciclo_vencimiento = p_ciclo_vencimiento)
    FOR UPDATE;

    IF FOUND THEN
        IF v_existente.personaje_id <> p_personaje_id
           OR v_existente.tipo <> p_tipo
           OR v_existente.origen <> p_origen
           OR v_existente.monto <> v_monto
           OR v_existente.concepto <> v_concepto
           OR v_existente.nomina_id IS DISTINCT FROM p_nomina_id
           OR v_existente.ciclo_vencimiento IS DISTINCT FROM p_ciclo_vencimiento THEN
            RAISE EXCEPTION 'La clave de idempotencia ya pertenece a otro pago.';
        END IF;
        RETURN jsonb_build_object(
            'exito', true,
            'duplicado', true,
            'pago_id', v_existente.id,
            'tipo', v_existente.tipo,
            'monto', v_existente.monto,
            'saldo_actual', v_existente.saldo_resultante,
            'pagado_en', v_existente.pagado_en
        );
    END IF;

    SELECT * INTO v_personaje
    FROM public.personajes
    WHERE id = p_personaje_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Personaje no encontrado.'; END IF;

    -- Revisa de nuevo tras tomar el bloqueo de personaje para serializar
    -- reintentos simultáneos sobre la misma ficha.
    SELECT * INTO v_existente
    FROM public.pagos_dm
    WHERE clave_idempotencia = p_clave_idempotencia
       OR (p_nomina_id IS NOT NULL
           AND nomina_id = p_nomina_id
           AND ciclo_vencimiento = p_ciclo_vencimiento)
    FOR UPDATE;
    IF FOUND THEN
        IF v_existente.personaje_id <> p_personaje_id
           OR v_existente.tipo <> p_tipo
           OR v_existente.origen <> p_origen
           OR v_existente.monto <> v_monto
           OR v_existente.concepto <> v_concepto
           OR v_existente.nomina_id IS DISTINCT FROM p_nomina_id
           OR v_existente.ciclo_vencimiento IS DISTINCT FROM p_ciclo_vencimiento THEN
            RAISE EXCEPTION 'La clave de idempotencia ya pertenece a otro pago.';
        END IF;
        RETURN jsonb_build_object(
            'exito', true,
            'duplicado', true,
            'pago_id', v_existente.id,
            'tipo', v_existente.tipo,
            'monto', v_existente.monto,
            'saldo_actual', v_existente.saldo_resultante,
            'pagado_en', v_existente.pagado_en
        );
    END IF;

    INSERT INTO public.pagos_dm (
        personaje_id, nomina_id, tipo, origen, monto, concepto,
        ciclo_vencimiento, clave_idempotencia, pagado_por
    ) VALUES (
        p_personaje_id, p_nomina_id, p_tipo, p_origen, v_monto, v_concepto,
        p_ciclo_vencimiento, p_clave_idempotencia, p_pagado_por
    )
    ON CONFLICT DO NOTHING
    RETURNING id, pagado_en INTO v_pago_id, v_fecha;

    IF v_pago_id IS NULL THEN
        SELECT * INTO v_existente
        FROM public.pagos_dm
        WHERE clave_idempotencia = p_clave_idempotencia
           OR (p_nomina_id IS NOT NULL
               AND nomina_id = p_nomina_id
               AND ciclo_vencimiento = p_ciclo_vencimiento)
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo registrar el pago.'; END IF;
        IF v_existente.personaje_id <> p_personaje_id
           OR v_existente.tipo <> p_tipo
           OR v_existente.origen <> p_origen
           OR v_existente.monto <> v_monto
           OR v_existente.concepto <> v_concepto
           OR v_existente.nomina_id IS DISTINCT FROM p_nomina_id
           OR v_existente.ciclo_vencimiento IS DISTINCT FROM p_ciclo_vencimiento THEN
            RAISE EXCEPTION 'La clave de idempotencia ya pertenece a otro pago.';
        END IF;
        RETURN jsonb_build_object(
            'exito', true,
            'duplicado', true,
            'pago_id', v_existente.id,
            'tipo', v_existente.tipo,
            'monto', v_existente.monto,
            'saldo_actual', v_existente.saldo_resultante,
            'pagado_en', v_existente.pagado_en
        );
    END IF;

    v_ficha := COALESCE(v_personaje.ficha, '{}'::jsonb);
    v_economia := COALESCE(v_ficha -> 'economia', '{}'::jsonb);
    IF jsonb_typeof(v_economia) <> 'object' THEN
        v_economia := '{}'::jsonb;
    END IF;
    v_movimientos := COALESCE(v_economia -> 'movimientos', '[]'::jsonb);
    IF jsonb_typeof(v_movimientos) <> 'array' THEN
        RAISE EXCEPTION 'El historial económico del personaje no es válido.';
    END IF;

    v_movimientos := v_movimientos || jsonb_build_array(jsonb_strip_nulls(
        jsonb_build_object(
            'fecha', v_fecha,
            'tipo', 'ingreso',
            'subtipo', upper(p_tipo),
            'monto', v_monto,
            'concepto', v_concepto,
            'quien_pago', 'DM',
            'quien_cobro', v_personaje.nombre_clave,
            'pago_dm_id', v_pago_id,
            'nomina_id', p_nomina_id,
            'ciclo_vencimiento', p_ciclo_vencimiento,
            'origen', p_origen
        )
    ));
    v_economia := jsonb_set(v_economia, '{movimientos}', v_movimientos, true);
    v_ficha := jsonb_set(v_ficha, '{economia}', v_economia, true);
    UPDATE public.personajes SET ficha = v_ficha WHERE id = p_personaje_id;

    v_saldo := public._saldo_personaje(p_personaje_id);
    UPDATE public.pagos_dm SET saldo_resultante = v_saldo WHERE id = v_pago_id;

    RETURN jsonb_build_object(
        'exito', true,
        'duplicado', false,
        'pago_id', v_pago_id,
        'personaje', v_personaje.nombre_clave,
        'tipo', p_tipo,
        'monto', v_monto,
        'saldo_actual', v_saldo,
        'pagado_en', v_fecha
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._emitir_pago_dm(uuid, text, text, numeric, text, uuid, uuid, timestamptz, uuid)
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.pagar_ingreso_dm(
    p_personaje_id uuid,
    p_tipo text,
    p_monto numeric,
    p_concepto text,
    p_clave_idempotencia uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF (SELECT auth.uid()) IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el DM puede emitir pagos.';
    END IF;
    IF p_tipo NOT IN ('salario_manual', 'trabajo') THEN
        RAISE EXCEPTION 'El pago debe ser salario manual o trabajo puntual.';
    END IF;

    RETURN public._emitir_pago_dm(
        p_personaje_id, p_tipo, 'dm_manual', p_monto, p_concepto,
        p_clave_idempotencia, NULL, NULL, (SELECT auth.uid())
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.pagar_ingreso_dm(uuid, text, numeric, text, uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pagar_ingreso_dm(uuid, text, numeric, text, uuid)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.crear_nomina_jugador_dm(
    p_personaje_id uuid,
    p_puesto text,
    p_monto numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_nomina public.nominas_jugadores%ROWTYPE;
    v_puesto text := btrim(p_puesto);
    v_monto numeric(14,2) := round(p_monto, 2);
BEGIN
    IF (SELECT auth.uid()) IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el DM puede crear salarios periódicos.';
    END IF;
    IF v_puesto IS NULL OR length(v_puesto) NOT BETWEEN 2 AND 120 THEN
        RAISE EXCEPTION 'El puesto debe tener entre 2 y 120 caracteres.';
    END IF;
    IF v_monto IS NULL OR v_monto <= 0 THEN
        RAISE EXCEPTION 'El salario debe ser mayor que cero.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.personajes WHERE id = p_personaje_id) THEN
        RAISE EXCEPTION 'Personaje no encontrado.';
    END IF;

    INSERT INTO public.nominas_jugadores (
        personaje_id, puesto, monto, proximo_pago, creado_por
    ) VALUES (
        p_personaje_id, v_puesto, v_monto, now() + interval '42 days',
        (SELECT auth.uid())
    )
    RETURNING * INTO v_nomina;

    RETURN jsonb_build_object(
        'exito', true,
        'nomina_id', v_nomina.id,
        'personaje_id', v_nomina.personaje_id,
        'puesto', v_nomina.puesto,
        'monto', v_nomina.monto,
        'ciclo_dias', v_nomina.ciclo_dias,
        'proximo_pago', v_nomina.proximo_pago,
        'estado', v_nomina.estado
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.crear_nomina_jugador_dm(uuid, text, numeric)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_nomina_jugador_dm(uuid, text, numeric)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.cancelar_nomina_jugador_dm(p_nomina_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_nomina public.nominas_jugadores%ROWTYPE;
BEGIN
    IF (SELECT auth.uid()) IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el DM puede cancelar salarios periódicos.';
    END IF;

    SELECT * INTO v_nomina
    FROM public.nominas_jugadores
    WHERE id = p_nomina_id
    FOR UPDATE;
    IF NOT FOUND OR v_nomina.estado <> 'activa' THEN
        RAISE EXCEPTION 'El salario no existe o ya está cancelado.';
    END IF;

    UPDATE public.nominas_jugadores
    SET estado = 'cancelada',
        cancelado_por = (SELECT auth.uid()),
        cancelado_en = now()
    WHERE id = p_nomina_id;

    RETURN jsonb_build_object('exito', true, 'nomina_id', p_nomina_id, 'estado', 'cancelada');
END;
$function$;

REVOKE ALL ON FUNCTION public.cancelar_nomina_jugador_dm(uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_nomina_jugador_dm(uuid)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.procesar_nominas_dm()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_nomina record;
    v_ciclo timestamptz;
    v_resultado jsonb;
    v_pagados integer := 0;
    v_fallidos integer := 0;
BEGIN
    FOR v_nomina IN
        SELECT id, personaje_id, puesto, monto, proximo_pago, creado_por, ciclo_dias
        FROM public.nominas_jugadores
        WHERE estado = 'activa' AND proximo_pago <= now()
        ORDER BY proximo_pago, id
        FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_ciclo := v_nomina.proximo_pago;
            WHILE v_ciclo <= now() LOOP
                v_resultado := public._emitir_pago_dm(
                    v_nomina.personaje_id,
                    'salario',
                    'nomina_automatica',
                    v_nomina.monto,
                    'Salario por ' || v_nomina.puesto,
                    gen_random_uuid(),
                    v_nomina.id,
                    v_ciclo,
                    v_nomina.creado_por
                );
                v_pagados := v_pagados + 1;
                v_ciclo := v_ciclo + make_interval(days => v_nomina.ciclo_dias);
            END LOOP;

            UPDATE public.nominas_jugadores
            SET proximo_pago = v_ciclo
            WHERE id = v_nomina.id;
        EXCEPTION WHEN OTHERS THEN
            v_fallidos := v_fallidos + 1;
            RAISE WARNING 'No se pudo procesar la nómina %: %', v_nomina.id, SQLERRM;
        END;
    END LOOP;

    RETURN jsonb_build_object('pagos_emitidos', v_pagados, 'nominas_fallidas', v_fallidos);
END;
$function$;

REVOKE ALL ON FUNCTION public.procesar_nominas_dm() FROM PUBLIC, anon, authenticated;

-- La nómina se procesa cinco minutos después del cobro periódico diario.
-- El nombre estable evita crear duplicados al volver a aplicar la definición.
SELECT cron.schedule(
    'nightxity-procesar-nominas-dm',
    '5 14 * * *',
    'SELECT public.procesar_nominas_dm();'
);
