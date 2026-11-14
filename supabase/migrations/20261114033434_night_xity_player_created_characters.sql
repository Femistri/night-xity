-- Player-created characters use the established Citizen ficha structure.
-- nombre_clave remains an internal stable key; nombre_jugador is the visible name.
ALTER TABLE public.personajes
    ADD COLUMN nombre_jugador text;

ALTER TABLE public.personajes
    ADD CONSTRAINT personajes_nombre_jugador_length_check
    CHECK (
        nombre_jugador IS NULL
        OR (
            nombre_jugador = btrim(nombre_jugador)
            AND char_length(nombre_jugador) BETWEEN 1 AND 40
        )
    );

COMMENT ON COLUMN public.personajes.nombre_jugador IS
    'Nombre visible elegido por el jugador. nombre_clave permanece como identificador interno estable.';

CREATE OR REPLACE FUNCTION public.crear_personaje_jugador(
    p_nombre_jugador text,
    p_clase text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_rol text;
    v_nombre text := btrim(coalesce(p_nombre_jugador, ''));
    v_clase text := btrim(coalesce(p_clase, ''));
    v_asignados integer;
    v_personaje_id uuid := gen_random_uuid();
    v_clave text := 'NX-' || upper(substr(replace(v_personaje_id::text, '-', ''), 1, 12));
    v_ficha jsonb;
BEGIN
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.';
    END IF;

    SELECT p.rol
      INTO v_rol
      FROM public.perfiles p
     WHERE p.id = v_usuario;

    IF v_rol IS DISTINCT FROM 'jugador' THEN
        RAISE EXCEPTION 'Esta función es exclusiva para jugadores.';
    END IF;

    IF v_nombre = '' OR char_length(v_nombre) > 40 THEN
        RAISE EXCEPTION 'Escribe un nombre de personaje de 1 a 40 caracteres.';
    END IF;

    IF v_clase NOT IN ('Link', 'Data', 'Microchip', 'Backup') THEN
        RAISE EXCEPTION 'Elige una de las clases disponibles.';
    END IF;

    SELECT count(*)
      INTO v_asignados
      FROM public.asignaciones a
     WHERE a.perfil_id = v_usuario;

    IF v_asignados >= 3 THEN
        RAISE EXCEPTION 'Tu cuenta ya alcanzó el máximo de tres personajes.';
    END IF;

    v_ficha := jsonb_build_object(
        'identidad', jsonb_build_object(
            'nombre_clave', v_clave,
            'nombre_jugador', v_nombre,
            'clase', v_clase,
            'trasfondo', '',
            'tara_sintetica', '[]'::jsonb,
            'puntos_alma', 4,
            'talentos', '[]'::jsonb,
            'salud_mental', jsonb_build_object(
                'manias', '[]'::jsonb,
                'fobias', '[]'::jsonb,
                'adicciones', '[]'::jsonb
            )
        ),
        'economia', jsonb_build_object(
            'saldo_inicial', 4710,
            'movimientos', '[]'::jsonb
        ),
        'inventario', jsonb_build_object(
            'implantes', '[]'::jsonb,
            'programas', '[]'::jsonb,
            'armas', '[]'::jsonb,
            'accesorios', '[]'::jsonb,
            'blindajes', '[]'::jsonb,
            'terminales', '[]'::jsonb,
            'medicare', '[]'::jsonb,
            'drogas', '[]'::jsonb,
            'vehiculos', '[]'::jsonb,
            'varios', '[]'::jsonb,
            'cotidiano', '[]'::jsonb
        )
    );

    INSERT INTO public.personajes (id, nombre_clave, nombre_jugador, clase, ficha)
    VALUES (v_personaje_id, v_clave, v_nombre, v_clase, v_ficha);

    INSERT INTO public.asignaciones (perfil_id, personaje_id)
    VALUES (v_usuario, v_personaje_id);

    RETURN v_personaje_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.crear_personaje_jugador(text, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_personaje_jugador(text, text)
    TO authenticated;
