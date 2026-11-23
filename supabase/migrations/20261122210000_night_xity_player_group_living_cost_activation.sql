-- Permite al jugador activar varios servicios periódicos de su propia ficha
-- en una sola operación atómica. La primera vivienda continúa como solicitud
-- al Arquitecto; la activación grupal de primera vivienda sigue siendo de DM.

CREATE OR REPLACE FUNCTION public.activar_costos_vida_grupo(
    p_personaje_id uuid,
    p_gasto_ids text[] DEFAULT ARRAY[]::text[],
    p_vivienda_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_gasto_id text;
    v_resultado jsonb;
    v_operaciones jsonb := '[]'::jsonb;
    v_total numeric := 0;
BEGIN
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Inicia sesión para activar servicios.';
    END IF;

    IF COALESCE(public.es_dm(), false) THEN
        RETURN public.activar_costos_vida_grupo_dm(
            p_personaje_id,
            p_gasto_ids,
            p_vivienda_id
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.asignaciones a
        WHERE a.perfil_id = v_usuario
          AND a.personaje_id = p_personaje_id
    ) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;

    IF NULLIF(btrim(COALESCE(p_vivienda_id, '')), '') IS NOT NULL THEN
        RAISE EXCEPTION 'La primera vivienda debe solicitarse al Arquitecto.';
    END IF;
    IF COALESCE(cardinality(p_gasto_ids), 0) = 0 THEN
        RAISE EXCEPTION 'Selecciona al menos un servicio periódico.';
    END IF;

    PERFORM 1
      FROM public.personajes p
     WHERE p.id = p_personaje_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Personaje no encontrado.';
    END IF;

    FOR v_gasto_id IN
        SELECT DISTINCT btrim(ids.gasto_id)
          FROM unnest(COALESCE(p_gasto_ids, ARRAY[]::text[])) AS ids(gasto_id)
         WHERE NULLIF(btrim(ids.gasto_id), '') IS NOT NULL
         ORDER BY btrim(ids.gasto_id)
    LOOP
        v_resultado := public.activar_servicio_gasto(p_personaje_id, v_gasto_id);
        v_operaciones := v_operaciones || jsonb_build_array(
            jsonb_build_object('tipo', 'servicio') || v_resultado
        );
        v_total := v_total + COALESCE((v_resultado->>'cargo_inicial')::numeric, 0);
    END LOOP;

    IF jsonb_array_length(v_operaciones) = 0 THEN
        RAISE EXCEPTION 'Selecciona al menos un servicio periódico.';
    END IF;

    RETURN jsonb_build_object(
        'exito', true,
        'cantidad', jsonb_array_length(v_operaciones),
        'cargo_total', v_total,
        'saldo_actual', public._saldo_personaje(p_personaje_id),
        'operaciones', v_operaciones
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.activar_costos_vida_grupo(uuid, text[], text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activar_costos_vida_grupo(uuid, text[], text)
    TO authenticated;
