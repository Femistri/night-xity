-- Guarda los campos de identidad que se editan en Citizen.
-- El jugador solo puede editar personajes asignados y el Arquitecto puede
-- corregir cualquier ficha. Los cambios siguen almacenados en personajes.ficha.

CREATE OR REPLACE FUNCTION public.guardar_identidad_ciudadano(
    p_personaje_id uuid,
    p_identidad jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_usuario uuid := auth.uid();
    v_ficha jsonb;
    v_clase text;
    v_identidad jsonb;
BEGIN
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Inicia sesión para guardar la ficha.';
    END IF;

    IF p_identidad IS NULL OR jsonb_typeof(p_identidad) <> 'object' THEN
        RAISE EXCEPTION 'Los datos de identidad no tienen un formato válido.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_object_keys(p_identidad) AS campo(nombre)
        WHERE campo.nombre <> ALL (ARRAY[
            'clase', 'puntos_alma', 'trasfondo', 'tara_sintetica',
            'talentos', 'salud_mental'
        ])
    ) THEN
        RAISE EXCEPTION 'La ficha contiene campos que no se pueden editar desde Citizen.';
    END IF;

    IF p_identidad ? 'clase'
       AND p_identidad->>'clase' NOT IN ('Link', 'Data', 'Microchip', 'Backup') THEN
        RAISE EXCEPTION 'La clase no es válida.';
    END IF;

    IF p_identidad ? 'puntos_alma' THEN
        IF jsonb_typeof(p_identidad->'puntos_alma') <> 'number' THEN
            RAISE EXCEPTION 'Los puntos de Alma deben ser un número entero de 0 a 4.';
        END IF;
        IF (p_identidad->>'puntos_alma')::numeric NOT BETWEEN 0 AND 4
           OR trunc((p_identidad->>'puntos_alma')::numeric) <> (p_identidad->>'puntos_alma')::numeric THEN
            RAISE EXCEPTION 'Los puntos de Alma deben ser un número entero de 0 a 4.';
        END IF;
    END IF;

    IF p_identidad ? 'trasfondo'
       AND jsonb_typeof(p_identidad->'trasfondo') NOT IN ('string', 'null') THEN
        RAISE EXCEPTION 'El trasfondo debe ser texto.';
    END IF;

    IF p_identidad ? 'tara_sintetica'
       AND jsonb_typeof(p_identidad->'tara_sintetica') <> 'array' THEN
        RAISE EXCEPTION 'Las taras deben enviarse como una lista.';
    END IF;

    IF p_identidad ? 'talentos'
       AND jsonb_typeof(p_identidad->'talentos') <> 'array' THEN
        RAISE EXCEPTION 'Los talentos deben enviarse como una lista.';
    END IF;

    IF p_identidad ? 'salud_mental' THEN
        IF jsonb_typeof(p_identidad->'salud_mental') <> 'object' THEN
            RAISE EXCEPTION 'Los datos de salud mental no tienen un formato válido.';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_object_keys(p_identidad->'salud_mental') AS campo(nombre)
            WHERE campo.nombre <> ALL (ARRAY['manias', 'fobias', 'adicciones'])
        ) THEN
            RAISE EXCEPTION 'La ficha contiene campos de salud mental no editables.';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_each(p_identidad->'salud_mental') AS dato(nombre, valor)
            WHERE jsonb_typeof(dato.valor) <> 'array'
        ) THEN
            RAISE EXCEPTION 'Manías, fobias y adicciones deben enviarse como listas.';
        END IF;
    END IF;

    IF NOT COALESCE(public.es_dm(), false)
       AND NOT EXISTS (
           SELECT 1
           FROM public.asignaciones AS a
           WHERE a.perfil_id = v_usuario
             AND a.personaje_id = p_personaje_id
       ) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;

    SELECT p.ficha, p.clase
      INTO v_ficha, v_clase
      FROM public.personajes AS p
     WHERE p.id = p_personaje_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el personaje.';
    END IF;

    v_identidad := COALESCE(v_ficha->'identidad', '{}'::jsonb) || p_identidad;
    v_clase := COALESCE(p_identidad->>'clase', v_clase);

    UPDATE public.personajes AS p
       SET ficha = jsonb_set(COALESCE(v_ficha, '{}'::jsonb), '{identidad}', v_identidad, true),
           clase = v_clase
     WHERE p.id = p_personaje_id;

    RETURN jsonb_build_object('exito', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.guardar_identidad_ciudadano(uuid, jsonb)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_identidad_ciudadano(uuid, jsonb)
    TO authenticated;

COMMENT ON FUNCTION public.guardar_identidad_ciudadano(uuid, jsonb) IS
    'Guarda identidad, clase, Alma, trasfondo, taras, talentos y salud mental del personaje asignado o seleccionado por el Arquitecto.';
