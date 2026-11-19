-- Permite que el Arquitecto active servicios periódicos para una ficha.
-- La operación cobra el primer ciclo y deja el siguiente cobro programado.

ALTER TABLE public.suscripciones_gastos_vida
    ADD COLUMN IF NOT EXISTS activado_por uuid
        REFERENCES public.perfiles(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.activar_servicio_gasto_dm(
    p_personaje_id uuid,
    p_gasto_id text
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
    v_proximo_cobro timestamptz;
    v_suscripcion_id uuid;
BEGIN
    IF v_usuario IS NULL OR NOT EXISTS (
        SELECT 1
          FROM public.perfiles p
         WHERE p.id = v_usuario
           AND p.rol = 'dm'
    ) THEN
        RAISE EXCEPTION 'Esta operación es exclusiva del Arquitecto.';
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
      INTO v_gasto
      FROM public.catalogo_gastos_vida
     WHERE id = p_gasto_id
       AND activo = true
       AND grupo IN ('obligatorio', 'opcional')
       AND frecuencia IN ('mensual', 'diaria');

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Solo se pueden activar costos periódicos obligatorios u opcionales.';
    END IF;

    v_intervalo := public._intervalo_gasto(v_gasto.id);
    IF v_intervalo IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar el periodo del servicio.';
    END IF;

    v_costo := v_gasto.costo;
    IF v_costo IS NULL OR v_costo <= 0 THEN
        RAISE EXCEPTION 'El servicio no tiene un costo válido.';
    END IF;

    SELECT *
      INTO v_existente
      FROM public.suscripciones_gastos_vida
     WHERE personaje_id = p_personaje_id
       AND gasto_id = p_gasto_id
     FOR UPDATE;

    IF FOUND THEN
        IF v_existente.estado = 'activa' THEN
            RAISE EXCEPTION 'Este servicio ya está activo.';
        ELSIF v_existente.estado = 'suspendida' THEN
            RAISE EXCEPTION 'Este servicio está suspendido. Usa el flujo de reactivación para liquidar deuda y reconexión.';
        ELSE
            RAISE EXCEPTION 'Este servicio ya tiene un registro. Revisa su estado antes de volver a activarlo.';
        END IF;
    END IF;

    v_saldo := public._saldo_personaje(p_personaje_id);
    IF v_saldo < v_costo THEN
        RAISE EXCEPTION 'Saldo insuficiente. Disponible: % CORPOS.', v_saldo;
    END IF;

    v_proximo_cobro := now() + v_intervalo;

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
    ) VALUES (
        p_personaje_id,
        p_gasto_id,
        v_costo,
        v_gasto.frecuencia,
        'activa',
        now(),
        now(),
        v_proximo_cobro,
        now(),
        v_usuario
    )
    RETURNING id INTO v_suscripcion_id;

    PERFORM public._registrar_movimiento_gasto(
        p_personaje_id,
        'egreso',
        'COSTO_DE_VIDA',
        v_costo,
        'Activación por Arquitecto: ' || v_gasto.nombre,
        p_gasto_id,
        NULL,
        NULL
    );

    RETURN jsonb_build_object(
        'exito', true,
        'suscripcion_id', v_suscripcion_id,
        'gasto', v_gasto.nombre,
        'cargo_inicial', v_costo,
        'saldo_actual', v_saldo - v_costo,
        'proximo_cobro', v_proximo_cobro
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.activar_servicio_gasto_dm(uuid, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activar_servicio_gasto_dm(uuid, text)
    TO authenticated;
