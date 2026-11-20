-- Registra bajas, ventas y transferencias de implantes y armas desde la vista DM.
CREATE TABLE IF NOT EXISTS public.movimientos_equipo (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fecha timestamptz NOT NULL DEFAULT now(),
    actor_id uuid NOT NULL REFERENCES public.perfiles(id),
    tipo text NOT NULL CHECK (tipo IN ('baja', 'venta', 'transferencia')),
    origen_personaje_id uuid NOT NULL REFERENCES public.personajes(id),
    destino_tipo text NOT NULL CHECK (destino_tipo IN ('pj', 'npc', 'baja')),
    destino_personaje_id uuid REFERENCES public.personajes(id),
    id_instancia text NOT NULL,
    catalogo_id text NOT NULL,
    objeto jsonb NOT NULL,
    monto numeric NOT NULL DEFAULT 0 CHECK (monto >= 0),
    motivo text,
    CONSTRAINT movimientos_equipo_destino_valido CHECK (
        (destino_tipo = 'pj' AND destino_personaje_id IS NOT NULL)
        OR (destino_tipo IN ('npc', 'baja') AND destino_personaje_id IS NULL)
    ),
    CONSTRAINT movimientos_equipo_operacion_valida CHECK (
        (tipo = 'baja' AND destino_tipo = 'baja' AND monto = 0
            AND motivo IN ('perdida', 'descompostura'))
        OR (tipo = 'venta' AND destino_tipo IN ('pj', 'npc') AND monto > 0
            AND motivo IS NULL)
        OR (tipo = 'transferencia' AND destino_tipo IN ('pj', 'npc') AND monto = 0
            AND motivo IS NULL)
    )
);

ALTER TABLE public.movimientos_equipo ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Lectura de movimientos de equipo propios o DM"
    ON public.movimientos_equipo;
CREATE POLICY "Lectura de movimientos de equipo propios o DM"
    ON public.movimientos_equipo
    FOR SELECT
    TO authenticated
    USING (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.asignaciones a
            WHERE a.perfil_id = (SELECT auth.uid())
              AND a.personaje_id IN (
                  movimientos_equipo.origen_personaje_id,
                  movimientos_equipo.destino_personaje_id
              )
        )
    );
REVOKE ALL ON TABLE public.movimientos_equipo FROM anon, authenticated;
GRANT SELECT ON TABLE public.movimientos_equipo TO authenticated;

CREATE INDEX IF NOT EXISTS movimientos_equipo_origen_fecha_idx
    ON public.movimientos_equipo (origen_personaje_id, fecha DESC);
CREATE INDEX IF NOT EXISTS movimientos_equipo_destino_fecha_idx
    ON public.movimientos_equipo (destino_personaje_id, fecha DESC);

CREATE OR REPLACE FUNCTION public.gestionar_equipo_dm(
    p_origen_personaje_id uuid,
    p_id_instancia text,
    p_tipo text,
    p_destino_tipo text,
    p_destino_personaje_id uuid DEFAULT NULL,
    p_precio numeric DEFAULT 0,
    p_motivo text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_usuario uuid := (SELECT auth.uid());
    v_origen public.personajes%ROWTYPE;
    v_destino public.personajes%ROWTYPE;
    v_objeto jsonb;
    v_detalle jsonb;
    v_lista_ids jsonb;
    v_lista_ids_actualizada jsonb;
    v_detalles jsonb;
    v_detalles_actualizados jsonb;
    v_categoria text;
    v_categoria_inventario text;
    v_catalogo_id text;
    v_indice_id bigint;
    v_numero_instancias integer;
    v_precio numeric := COALESCE(p_precio, 0);
    v_saldo_origen numeric;
    v_saldo_destino numeric;
    v_destino_nombre text;
BEGIN
    IF v_usuario IS NULL OR NOT public.es_dm() THEN
        RAISE EXCEPTION 'Solo el Arquitecto puede gestionar equipo.';
    END IF;

    IF p_tipo NOT IN ('baja', 'venta', 'transferencia') THEN
        RAISE EXCEPTION 'Selecciona baja, venta o transferencia sin costo.';
    END IF;

    IF p_tipo = 'baja' THEN
        IF p_destino_tipo IS DISTINCT FROM 'baja'
           OR p_destino_personaje_id IS NOT NULL
           OR v_precio <> 0
           OR p_motivo IS NULL
           OR p_motivo NOT IN ('perdida', 'descompostura') THEN
            RAISE EXCEPTION 'Para dar de baja, elige pérdida o descompostura.';
        END IF;
    ELSE
        IF p_destino_tipo NOT IN ('pj', 'npc') THEN
            RAISE EXCEPTION 'Elige otro personaje o un PNJ como destinatario.';
        END IF;
        IF p_tipo = 'venta' AND v_precio <= 0 THEN
            RAISE EXCEPTION 'La venta requiere un importe mayor que cero.';
        END IF;
        IF p_tipo = 'transferencia' AND v_precio <> 0 THEN
            RAISE EXCEPTION 'La transferencia sin costo no puede incluir un importe.';
        END IF;
        IF NULLIF(p_motivo, '') IS NOT NULL THEN
            RAISE EXCEPTION 'Las transferencias y ventas no requieren motivo.';
        END IF;
        IF p_destino_tipo = 'pj'
           AND (p_destino_personaje_id IS NULL
                OR p_destino_personaje_id = p_origen_personaje_id) THEN
            RAISE EXCEPTION 'Elige otro personaje como destinatario.';
        END IF;
        IF p_destino_tipo = 'npc' AND p_destino_personaje_id IS NOT NULL THEN
            RAISE EXCEPTION 'Un PNJ no requiere seleccionar personaje.';
        END IF;
    END IF;

    -- Bloqueo ordenado: evita que operaciones cruzadas bloqueen fichas en distinto orden.
    PERFORM p.id
    FROM public.personajes p
    WHERE p.id = p_origen_personaje_id
       OR (p_destino_tipo = 'pj' AND p.id = p_destino_personaje_id)
    ORDER BY p.id
    FOR UPDATE;

    SELECT * INTO v_origen
    FROM public.personajes
    WHERE id = p_origen_personaje_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Personaje de origen no encontrado.';
    END IF;

    IF p_destino_tipo = 'pj' THEN
        SELECT * INTO v_destino
        FROM public.personajes
        WHERE id = p_destino_personaje_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Personaje destinatario no encontrado.';
        END IF;
        v_destino_nombre := COALESCE(v_destino.nombre_jugador, v_destino.nombre_clave);
    ELSE
        v_destino_nombre := 'PNJ / COMERCIO';
    END IF;

    v_detalles := COALESCE(
        NULLIF(v_origen.ficha -> 'inventario_detallado', 'null'::jsonb),
        '[]'::jsonb
    );
    IF jsonb_typeof(v_detalles) <> 'array' THEN
        RAISE EXCEPTION 'El inventario detallado del personaje no es válido.';
    END IF;

    SELECT COUNT(*)::integer
    INTO v_numero_instancias
    FROM jsonb_array_elements(v_detalles) AS e(objeto)
    WHERE e.objeto ->> 'id_instancia' = p_id_instancia;

    IF v_numero_instancias <> 1 THEN
        RAISE EXCEPTION 'El objeto ya no está disponible o su identificador está duplicado.';
    END IF;

    SELECT e.objeto
    INTO v_objeto
    FROM jsonb_array_elements(v_detalles) AS e(objeto)
    WHERE e.objeto ->> 'id_instancia' = p_id_instancia;

    v_categoria := v_objeto ->> 'categoria';
    v_categoria_inventario := CASE v_categoria
        WHEN 'Implantes' THEN 'implantes'
        WHEN 'Armas' THEN 'armas'
        ELSE NULL
    END;
    v_catalogo_id := v_objeto ->> 'catalogo_id';

    IF v_categoria_inventario IS NULL OR v_catalogo_id IS NULL THEN
        RAISE EXCEPTION 'Solo se pueden gestionar implantes y armas del inventario detallado.';
    END IF;

    v_lista_ids := COALESCE(
        NULLIF(v_origen.ficha #> ARRAY['inventario', v_categoria_inventario], 'null'::jsonb),
        '[]'::jsonb
    );
    IF jsonb_typeof(v_lista_ids) <> 'array' THEN
        RAISE EXCEPTION 'La lista de inventario del objeto no es válida.';
    END IF;

    SELECT e.ord
    INTO v_indice_id
    FROM jsonb_array_elements(v_lista_ids) WITH ORDINALITY AS e(valor, ord)
    WHERE e.valor = to_jsonb(v_catalogo_id)
    ORDER BY e.ord
    LIMIT 1;

    IF v_indice_id IS NULL THEN
        RAISE EXCEPTION 'La ficha no contiene el objeto en su inventario activo.';
    END IF;

    SELECT COALESCE(jsonb_agg(e.valor ORDER BY e.ord), '[]'::jsonb)
    INTO v_lista_ids_actualizada
    FROM jsonb_array_elements(v_lista_ids) WITH ORDINALITY AS e(valor, ord)
    WHERE e.ord <> v_indice_id;

    SELECT COALESCE(jsonb_agg(e.objeto ORDER BY e.ord), '[]'::jsonb)
    INTO v_detalles_actualizados
    FROM jsonb_array_elements(v_detalles) WITH ORDINALITY AS e(objeto, ord)
    WHERE e.objeto ->> 'id_instancia' IS DISTINCT FROM p_id_instancia;

    v_origen.ficha := jsonb_set(
        v_origen.ficha,
        ARRAY['inventario', v_categoria_inventario],
        v_lista_ids_actualizada,
        true
    );
    v_origen.ficha := jsonb_set(
        v_origen.ficha,
        '{inventario_detallado}',
        v_detalles_actualizados,
        true
    );

    IF p_destino_tipo = 'pj' THEN
        IF jsonb_typeof(v_destino.ficha -> 'inventario') IS DISTINCT FROM 'object' THEN
            v_destino.ficha := jsonb_set(v_destino.ficha, '{inventario}', '{}'::jsonb, true);
        END IF;
        v_lista_ids := COALESCE(
            NULLIF(v_destino.ficha #> ARRAY['inventario', v_categoria_inventario], 'null'::jsonb),
            '[]'::jsonb
        );
        v_detalles := COALESCE(
            NULLIF(v_destino.ficha -> 'inventario_detallado', 'null'::jsonb),
            '[]'::jsonb
        );
        IF jsonb_typeof(v_lista_ids) <> 'array'
           OR jsonb_typeof(v_detalles) <> 'array' THEN
            RAISE EXCEPTION 'El inventario del personaje destinatario no es válido.';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_detalles) AS e(objeto)
            WHERE e.objeto ->> 'id_instancia' = p_id_instancia
        ) THEN
            RAISE EXCEPTION 'El identificador de instancia ya existe en el inventario destinatario.';
        END IF;
        v_destino.ficha := jsonb_set(
            v_destino.ficha,
            ARRAY['inventario', v_categoria_inventario],
            v_lista_ids || jsonb_build_array(v_catalogo_id),
            true
        );
        v_destino.ficha := jsonb_set(
            v_destino.ficha,
            '{inventario_detallado}',
            v_detalles || jsonb_build_array(v_objeto),
            true
        );
    END IF;

    IF p_tipo = 'venta' THEN
        v_saldo_origen := public._saldo_personaje(p_origen_personaje_id);
        IF p_destino_tipo = 'pj' THEN
            v_saldo_destino := public._saldo_personaje(p_destino_personaje_id);
            IF v_saldo_destino < v_precio THEN
                RAISE EXCEPTION 'Saldo insuficiente del comprador. Disponible: % CORPOS.', v_saldo_destino;
            END IF;
        END IF;
    END IF;

    INSERT INTO public.movimientos_equipo (
        actor_id, tipo, origen_personaje_id, destino_tipo,
        destino_personaje_id, id_instancia, catalogo_id, objeto,
        monto, motivo
    )
    VALUES (
        v_usuario, p_tipo, p_origen_personaje_id, p_destino_tipo,
        p_destino_personaje_id, p_id_instancia, v_catalogo_id, v_objeto,
        v_precio, NULLIF(p_motivo, '')
    );

    UPDATE public.personajes SET ficha = v_origen.ficha
    WHERE id = p_origen_personaje_id;
    IF p_destino_tipo = 'pj' THEN
        UPDATE public.personajes SET ficha = v_destino.ficha
        WHERE id = p_destino_personaje_id;
    END IF;

    IF p_tipo = 'venta' THEN
        PERFORM public._registrar_movimiento_gasto(
            p_origen_personaje_id, 'ingreso', 'VENTA_EQUIPO', v_precio,
            'Venta de equipo: ' || COALESCE(v_objeto ->> 'nombre', v_catalogo_id),
            v_catalogo_id, NULL, NULL
        );
        IF p_destino_tipo = 'pj' THEN
            PERFORM public._registrar_movimiento_gasto(
                p_destino_personaje_id, 'egreso', 'COMPRA_EQUIPO', v_precio,
                'Compra de equipo: ' || COALESCE(v_objeto ->> 'nombre', v_catalogo_id),
                v_catalogo_id, NULL, NULL
            );
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'exito', true,
        'tipo', p_tipo,
        'objeto', COALESCE(v_objeto ->> 'nombre', v_catalogo_id),
        'destino', v_destino_nombre,
        'monto', v_precio,
        'saldo_vendedor_anterior', v_saldo_origen,
        'saldo_comprador_anterior', v_saldo_destino
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.gestionar_equipo_dm(uuid, text, text, text, uuid, numeric, text)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gestionar_equipo_dm(uuid, text, text, text, uuid, numeric, text)
    TO authenticated;
