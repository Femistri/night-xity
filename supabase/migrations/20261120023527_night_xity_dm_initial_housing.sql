-- Asignación inicial de vivienda por el Arquitecto cuando el jugador no la solicitó.
-- Solo se permite si el personaje no tiene vivienda activa, suspendida ni una solicitud pendiente.
-- Cobra el primer ciclo y programa el siguiente con el mismo calendario de 42 días.

CREATE OR REPLACE FUNCTION public.activar_vivienda_inicial_dm(
    p_personaje_id uuid,
    p_vivienda_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_personaje public.personajes%ROWTYPE;
    v_vivienda public.catalogo_gastos_vida%ROWTYPE;
    v_costo numeric;
    v_saldo numeric;
    v_suscripcion_id uuid;
    v_proximo_cobro timestamptz;
BEGIN
    IF v_usuario IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el Arquitecto puede asignar una vivienda inicial.';
    END IF;

    SELECT *
    INTO v_personaje
    FROM public.personajes
    WHERE id = p_personaje_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Personaje no encontrado.';
    END IF;

    SELECT *
    INTO v_vivienda
    FROM public.catalogo_gastos_vida
    WHERE id = p_vivienda_id
      AND grupo = 'vivienda'
      AND activo = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La vivienda seleccionada no está disponible.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.suscripciones_gastos_vida
        WHERE personaje_id = p_personaje_id
          AND gasto_id LIKE 'VIV-%'
          AND estado = 'activa'
    ) THEN
        RAISE EXCEPTION 'Este personaje ya tiene una vivienda activa. Para mudarse, resuelve una solicitud de cambio de vivienda.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.suscripciones_gastos_vida
        WHERE personaje_id = p_personaje_id
          AND gasto_id LIKE 'VIV-%'
          AND estado = 'suspendida'
    ) THEN
        RAISE EXCEPTION 'Hay una vivienda suspendida. Resuelve primero el saldo pendiente.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.solicitudes_gastos_vida
        WHERE personaje_id = p_personaje_id
          AND tipo_solicitud = 'cambio_vivienda'
          AND estado = 'pendiente'
    ) THEN
        RAISE EXCEPTION 'Este personaje ya tiene una solicitud de vivienda pendiente. Resuélvela primero.';
    END IF;

    v_costo := COALESCE(
        NULLIF(v_vivienda.datos_originales ->> 'costo_por_persona', '')::numeric,
        v_vivienda.costo
    );

    IF v_costo IS NULL OR v_costo <= 0 THEN
        RAISE EXCEPTION 'El costo de la vivienda no es válido.';
    END IF;

    v_saldo := public._saldo_personaje(p_personaje_id);
    IF v_saldo < v_costo THEN
        RAISE EXCEPTION 'Saldo insuficiente. Disponible: % CORPOS.', v_saldo;
    END IF;

    v_proximo_cobro := public.proximo_cobro_vivienda(now());

    INSERT INTO public.suscripciones_gastos_vida (
        personaje_id,
        gasto_id,
        costo,
        frecuencia,
        estado,
        fecha_solicitud,
        fecha_activacion,
        proximo_cobro,
        actualizado_en,
        activado_por
    )
    VALUES (
        p_personaje_id,
        p_vivienda_id,
        v_costo,
        'cada_6_miercoles',
        'activa',
        now(),
        now(),
        v_proximo_cobro,
        now(),
        v_usuario
    )
    ON CONFLICT (personaje_id, gasto_id)
    DO UPDATE SET
        costo = EXCLUDED.costo,
        frecuencia = EXCLUDED.frecuencia,
        estado = 'activa',
        fecha_solicitud = now(),
        fecha_activacion = now(),
        proximo_cobro = EXCLUDED.proximo_cobro,
        actualizado_en = now(),
        activado_por = EXCLUDED.activado_por
    RETURNING id INTO v_suscripcion_id;

    PERFORM public._registrar_movimiento_gasto(
        p_personaje_id,
        'egreso',
        'COSTO_DE_VIDA',
        v_costo,
        'Asignación inicial por Arquitecto: ' || v_vivienda.nombre,
        p_vivienda_id,
        NULL,
        NULL
    );

    RETURN jsonb_build_object(
        'exito', true,
        'suscripcion_id', v_suscripcion_id,
        'vivienda', v_vivienda.nombre,
        'cargo_inicial', v_costo,
        'saldo_actual', v_saldo - v_costo,
        'proximo_cobro', v_proximo_cobro
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.activar_vivienda_inicial_dm(uuid, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activar_vivienda_inicial_dm(uuid, text)
    TO authenticated;
