CREATE OR REPLACE FUNCTION public.realizar_compra_multiple(p_personaje_id uuid, p_productos text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_usuario uuid;
    v_personaje public.personajes%ROWTYPE;
    v_producto record;
    v_ficha jsonb;
    v_movimientos jsonb;
    v_saldo_inicial numeric;
    v_saldo_actual numeric;
    v_total numeric := 0;
    v_categoria text;
    v_nombre text;
    v_resultado jsonb := '[]'::jsonb;
BEGIN
    v_usuario := auth.uid();

    IF v_usuario IS NULL THEN
        RAISE EXCEPTION 'Debes iniciar sesión.';
    END IF;

    IF p_productos IS NULL
       OR cardinality(p_productos) = 0 THEN
        RAISE EXCEPTION 'No hay productos seleccionados.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(p_productos) AS x
        GROUP BY x
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Hay productos duplicados en la selección.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.asignaciones
        WHERE perfil_id = v_usuario
          AND personaje_id = p_personaje_id
    ) THEN
        RAISE EXCEPTION 'No tienes asignado este personaje.';
    END IF;

    SELECT *
    INTO v_personaje
    FROM public.personajes
    WHERE id = p_personaje_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Personaje no encontrado.';
    END IF;

    v_ficha := v_personaje.ficha;
    v_nombre := v_personaje.nombre_clave;

    v_movimientos :=
        COALESCE(v_ficha #> '{economia,movimientos}', '[]'::jsonb);

    IF jsonb_typeof(v_movimientos) <> 'array' THEN
        RAISE EXCEPTION 'El historial económico no es válido.';
    END IF;

    v_saldo_inicial :=
        COALESCE((v_ficha #>> '{economia,saldo_inicial}')::numeric, 0);

    SELECT
        v_saldo_inicial +
        COALESCE(SUM(
            CASE movimiento->>'tipo'
                WHEN 'ingreso' THEN
                    COALESCE((movimiento->>'monto')::numeric, 0)
                WHEN 'egreso' THEN
                    -COALESCE((movimiento->>'monto')::numeric, 0)
                ELSE 0
            END
        ), 0)
    INTO v_saldo_actual
    FROM jsonb_array_elements(v_movimientos) AS movimiento;

    -- Consultar y validar todos los productos antes de modificar la ficha.
    FOR v_producto IN
        SELECT id, nombre, categoria, costo, restantes
        FROM public.catalogo_productos
        WHERE id = ANY(p_productos)
          AND activo = true
        ORDER BY id
    LOOP
        IF v_producto.costo IS NULL OR v_producto.costo < 0 THEN
            RAISE EXCEPTION 'Precio inválido para %.', v_producto.nombre;
        END IF;

        IF v_producto.restantes IS NOT NULL THEN
            RAISE EXCEPTION
                'El producto % tiene control de existencias pendiente de integrar.',
                v_producto.nombre;
        END IF;

        v_total := v_total + v_producto.costo;
    END LOOP;

    IF (
        SELECT count(*)
        FROM public.catalogo_productos
        WHERE id = ANY(p_productos)
          AND activo = true
    ) <> cardinality(p_productos) THEN
        RAISE EXCEPTION 'Uno o más productos no existen o no están activos.';
    END IF;

    IF v_saldo_actual < v_total THEN
        RAISE EXCEPTION 'Saldo insuficiente. Disponible: % CORPOS.',
            v_saldo_actual;
    END IF;

    -- Aplicar inventario e historial dentro de la misma transacción.
    FOR v_producto IN
        SELECT id, nombre, categoria, costo
        FROM public.catalogo_productos
        WHERE id = ANY(p_productos)
          AND activo = true
        ORDER BY id
    LOOP
        v_categoria := CASE v_producto.categoria
            WHEN 'Implantes' THEN 'implantes'
            WHEN 'Programas' THEN 'programas'
            WHEN 'Armas' THEN 'armas'
            WHEN 'Accesorios' THEN 'accesorios'
            WHEN 'Blindajes' THEN 'blindajes'
            WHEN 'Terminales' THEN 'terminales'
            WHEN 'MediCare' THEN 'medicare'
            WHEN 'Drogas' THEN 'drogas'
            WHEN 'Vehiculos' THEN 'vehiculos'
            WHEN 'Varios' THEN 'varios'
            ELSE NULL
        END;

        IF v_categoria IS NULL THEN
            RAISE EXCEPTION 'Categoría no habilitada: %.',
                v_producto.categoria;
        END IF;

        v_ficha := jsonb_set(
            v_ficha,
            ARRAY['inventario', v_categoria],
            COALESCE(
                v_ficha #> ARRAY['inventario', v_categoria],
                '[]'::jsonb
            ) || jsonb_build_array(v_producto.id),
            true
        );

        v_ficha := jsonb_set(
            v_ficha,
            '{inventario_detallado}',
            COALESCE(
                NULLIF(v_ficha -> 'inventario_detallado', 'null'::jsonb),
                '[]'::jsonb
            ) || jsonb_build_array(
                jsonb_build_object(
                    'id_instancia', gen_random_uuid()::text,
                    'catalogo_id', v_producto.id,
                    'nombre', v_producto.nombre,
                    'categoria', v_producto.categoria,
                    'fecha_adquisicion', now(),
                    'precio_compra', v_producto.costo,
                    'estado', 'SERVIBLE'
                )
            ),
            true
        );

        v_movimientos := v_movimientos || jsonb_build_array(
            jsonb_build_object(
                'fecha', now(),
                'tipo', 'egreso',
                'subtipo', 'COMPRA',
                'monto', v_producto.costo,
                'concepto', v_producto.nombre,
                'catalogo_id', v_producto.id,
                'cantidad', 1,
                'precio_unitario', v_producto.costo,
                'quien_pago', v_nombre,
                'quien_cobro', 'TIENDA'
            )
        );

        v_resultado := v_resultado || jsonb_build_array(
            jsonb_build_object(
                'id', v_producto.id,
                'nombre', v_producto.nombre,
                'costo', v_producto.costo
            )
        );
    END LOOP;

    v_ficha := jsonb_set(
        v_ficha,
        '{economia,movimientos}',
        v_movimientos,
        true
    );

    UPDATE public.personajes
    SET ficha = v_ficha
    WHERE id = p_personaje_id;

    RETURN jsonb_build_object(
        'exito', true,
        'personaje', v_nombre,
        'productos', v_resultado,
        'total', v_total,
        'saldo_anterior', v_saldo_actual,
        'saldo_actual', v_saldo_actual - v_total
    );
END;
$function$
