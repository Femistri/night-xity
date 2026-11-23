-- Herramientas del Arquitecto para crear y mantener personajes y PNJ.
-- Las fichas se archivan en lugar de borrarse para conservar historial y referencias.

ALTER TABLE public.personajes
    ADD COLUMN IF NOT EXISTS es_pnj boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS archivado_en timestamptz;

COMMENT ON COLUMN public.personajes.es_pnj IS
    'Indica que la ficha fue creada como PNJ por el Arquitecto y no debe ofrecerse para asignación de jugadores.';
COMMENT ON COLUMN public.personajes.archivado_en IS
    'Fecha en que la ficha se archivó; se conserva para mantener historial y referencias.';

CREATE OR REPLACE FUNCTION public.listar_personajes_dm_gestion()
RETURNS TABLE (
    id uuid,
    nombre_clave text,
    nombre_jugador text,
    clase text,
    es_pnj boolean,
    archivado_en timestamptz,
    asignado boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
BEGIN
    IF v_usuario IS NULL OR NOT COALESCE(public.es_dm(), false) THEN
        RAISE EXCEPTION 'Esta herramienta es exclusiva del Arquitecto.';
    END IF;

    RETURN QUERY
    SELECT p.id, p.nombre_clave, p.nombre_jugador, p.clase,
           p.es_pnj, p.archivado_en,
           EXISTS (
               SELECT 1 FROM public.asignaciones a
               WHERE a.personaje_id = p.id
           )
      FROM public.personajes p
     ORDER BY (p.archivado_en IS NOT NULL), p.nombre_clave;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crear_pnj_dm(
    p_nombre text,
    p_clase text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_nombre text := btrim(coalesce(p_nombre, ''));
    v_clase text := btrim(coalesce(p_clase, ''));
    v_id uuid := gen_random_uuid();
    v_clave text := 'PNJ-' || upper(substr(replace(v_id::text, '-', ''), 1, 10));
    v_ficha jsonb;
BEGIN
    IF v_usuario IS NULL OR NOT COALESCE(public.es_dm(), false) THEN
        RAISE EXCEPTION 'Esta herramienta es exclusiva del Arquitecto.';
    END IF;

    IF v_nombre = '' OR char_length(v_nombre) > 40 THEN
        RAISE EXCEPTION 'El nombre debe tener entre 1 y 40 caracteres.';
    END IF;
    IF v_clase NOT IN ('Backup', 'Data', 'Link', 'Microchip') THEN
        RAISE EXCEPTION 'Elige una clase válida.';
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
            'saldo_inicial', 0,
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

    INSERT INTO public.personajes (id, nombre_clave, nombre_jugador, clase, ficha, es_pnj)
    VALUES (v_id, v_clave, v_nombre, v_clase, v_ficha, true);

    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.renombrar_personaje_no_asignado_dm(
    p_personaje_id uuid,
    p_nombre text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_nombre text := btrim(coalesce(p_nombre, ''));
    v_ficha jsonb;
BEGIN
    IF v_usuario IS NULL OR NOT COALESCE(public.es_dm(), false) THEN
        RAISE EXCEPTION 'Esta herramienta es exclusiva del Arquitecto.';
    END IF;
    IF v_nombre = '' OR char_length(v_nombre) > 40 THEN
        RAISE EXCEPTION 'El nombre debe tener entre 1 y 40 caracteres.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.asignaciones a
        WHERE a.personaje_id = p_personaje_id
    ) THEN
        RAISE EXCEPTION 'No se puede cambiar el nombre visible de un personaje asignado.';
    END IF;

    SELECT p.ficha INTO v_ficha
      FROM public.personajes p
     WHERE p.id = p_personaje_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró el personaje.';
    END IF;

    UPDATE public.personajes p
       SET nombre_jugador = v_nombre,
           ficha = jsonb_set(
               coalesce(v_ficha, '{}'::jsonb),
               '{identidad}',
               coalesce(v_ficha->'identidad', '{}'::jsonb)
                   || jsonb_build_object('nombre_jugador', v_nombre),
               true
           )
     WHERE p.id = p_personaje_id;

    RETURN jsonb_build_object('exito', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.archivar_personaje_dm(
    p_personaje_id uuid,
    p_archivar boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
BEGIN
    IF v_usuario IS NULL OR NOT COALESCE(public.es_dm(), false) THEN
        RAISE EXCEPTION 'Esta herramienta es exclusiva del Arquitecto.';
    END IF;
    IF p_archivar IS NULL THEN
        RAISE EXCEPTION 'Indica si deseas archivar o reactivar la ficha.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.personajes p WHERE p.id = p_personaje_id) THEN
        RAISE EXCEPTION 'No se encontró el personaje.';
    END IF;
    IF p_archivar THEN
        IF EXISTS (
            SELECT 1 FROM public.asignaciones a
            WHERE a.personaje_id = p_personaje_id
        ) THEN
            RAISE EXCEPTION 'Desasigna el personaje antes de archivarlo.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.suscripciones_gastos_vida s
            WHERE s.personaje_id = p_personaje_id AND s.estado = 'activa'
        ) THEN
            RAISE EXCEPTION 'Cancela primero los servicios periódicos activos.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.nominas_jugadores n
            WHERE n.personaje_id = p_personaje_id AND n.estado = 'activa'
        ) THEN
            RAISE EXCEPTION 'Cancela primero los salarios periódicos activos.';
        END IF;
    END IF;

    UPDATE public.personajes p
       SET archivado_en = CASE WHEN p_archivar THEN now() ELSE NULL END
     WHERE p.id = p_personaje_id;

    RETURN jsonb_build_object('exito', true, 'archivado', p_archivar);
END;
$function$;

-- Los personajes nuevos para jugadores excluyen PNJ y fichas archivadas.
CREATE OR REPLACE FUNCTION public.listar_personajes_disponibles()
RETURNS TABLE(id uuid, nombre_clave text, clase text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_rol text;
    v_asignados integer;
BEGIN
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.';
    END IF;

    SELECT p.rol INTO v_rol
      FROM public.perfiles p
     WHERE p.id = v_usuario;
    IF v_rol IS DISTINCT FROM 'jugador' THEN
        RAISE EXCEPTION 'Esta función es exclusiva para jugadores.';
    END IF;

    SELECT count(*) INTO v_asignados
      FROM public.asignaciones a
     WHERE a.perfil_id = v_usuario;
    IF v_asignados >= 3 THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT p.id, p.nombre_clave, p.clase
      FROM public.personajes p
     WHERE p.es_pnj = false
       AND p.archivado_en IS NULL
       AND NOT EXISTS (
           SELECT 1 FROM public.asignaciones a
           WHERE a.personaje_id = p.id
       )
     ORDER BY p.nombre_clave;
END;
$function$;

-- Refuerza la asignación del lado del servidor: un PNJ o una ficha archivada
-- nunca puede ser tomada por un jugador aunque alguien intente saltarse la lista.
CREATE OR REPLACE FUNCTION public.gestionar_mis_personajes(
    p_accion text,
    p_personaje_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_rol text;
    v_es_pnj boolean;
    v_archivado_en timestamptz;
BEGIN
    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.';
    END IF;
    SELECT p.rol INTO v_rol
      FROM public.perfiles p
     WHERE p.id = v_usuario;
    IF v_rol IS DISTINCT FROM 'jugador' THEN
        RAISE EXCEPTION 'Esta función es exclusiva para jugadores.';
    END IF;
    IF p_personaje_id IS NULL THEN
        RAISE EXCEPTION 'Debes indicar un personaje.';
    END IF;

    IF p_accion = 'elegir' THEN
        SELECT p.es_pnj, p.archivado_en
          INTO v_es_pnj, v_archivado_en
          FROM public.personajes p
         WHERE p.id = p_personaje_id
         FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El personaje no existe.';
        END IF;
        IF v_es_pnj OR v_archivado_en IS NOT NULL THEN
            RAISE EXCEPTION 'Este personaje no está disponible para jugadores.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM public.asignaciones a
            WHERE a.personaje_id = p_personaje_id
        ) THEN
            RAISE EXCEPTION 'Este personaje ya está asignado.';
        END IF;
        INSERT INTO public.asignaciones (perfil_id, personaje_id)
        VALUES (v_usuario, p_personaje_id);
        RETURN 'Personaje elegido correctamente.';

    ELSIF p_accion = 'liberar' THEN
        DELETE FROM public.asignaciones a
         WHERE a.perfil_id = v_usuario
           AND a.personaje_id = p_personaje_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese personaje no está asignado a tu cuenta.';
        END IF;
        RETURN 'Personaje liberado correctamente.';
    ELSE
        RAISE EXCEPTION 'Acción no válida.';
    END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.listar_personajes_dm_gestion() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_pnj_dm(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.renombrar_personaje_no_asignado_dm(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archivar_personaje_dm(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_personajes_disponibles() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gestionar_mis_personajes(text, uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.listar_personajes_dm_gestion() TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_pnj_dm(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.renombrar_personaje_no_asignado_dm(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.archivar_personaje_dm(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_personajes_disponibles() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gestionar_mis_personajes(text, uuid) TO authenticated;
