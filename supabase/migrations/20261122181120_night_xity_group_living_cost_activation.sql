-- Activa varios servicios y, opcionalmente, la primera vivienda del personaje
-- en una sola transacción. Si una validación o cobro falla, se revierte todo.

CREATE OR REPLACE FUNCTION public.activar_costos_vida_grupo_dm(
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
    v_vivienda_id text := NULLIF(btrim(p_vivienda_id), '');
BEGIN
    IF v_usuario IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Esta operación es exclusiva del Arquitecto.';
    END IF;

    IF COALESCE(cardinality(p_gasto_ids), 0) = 0 AND v_vivienda_id IS NULL THEN
        RAISE EXCEPTION 'Selecciona al menos un servicio o una vivienda.';
    END IF;

    PERFORM 1
      FROM public.personajes
     WHERE id = p_personaje_id
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
        v_resultado := public.activar_servicio_gasto_dm(p_personaje_id, v_gasto_id);
        v_operaciones := v_operaciones ||
            jsonb_build_array(jsonb_build_object('tipo', 'servicio') || v_resultado);
        v_total := v_total + COALESCE((v_resultado ->> 'cargo_inicial')::numeric, 0);
    END LOOP;

    IF v_vivienda_id IS NOT NULL THEN
        v_resultado := public.activar_vivienda_inicial_dm(p_personaje_id, v_vivienda_id);
        v_operaciones := v_operaciones ||
            jsonb_build_array(jsonb_build_object('tipo', 'vivienda') || v_resultado);
        v_total := v_total + COALESCE((v_resultado ->> 'cargo_inicial')::numeric, 0);
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

REVOKE ALL ON FUNCTION public.activar_costos_vida_grupo_dm(uuid, text[], text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.activar_costos_vida_grupo_dm(uuid, text[], text)
    TO authenticated;
