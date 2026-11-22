-- Guarda los atributos, nivel y puntos de vida que se completan manualmente
-- en la ficha visual. El jugador edita sus personajes asignados y el DM puede
-- corregir cualquier ficha.

CREATE TABLE IF NOT EXISTS public.ficha_datos_manuales (
    personaje_id uuid PRIMARY KEY
        REFERENCES public.personajes(id) ON DELETE CASCADE,
    nivel smallint NOT NULL DEFAULT 1
        CHECK (nivel BETWEEN 1 AND 10),
    fue smallint,
    des smallint,
    con smallint,
    int smallint,
    sab smallint,
    car smallint,
    puntos_vida_manual integer,
    CONSTRAINT ficha_datos_manuales_fue_check CHECK (fue IS NULL OR fue BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_des_check CHECK (des IS NULL OR des BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_con_check CHECK (con IS NULL OR con BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_int_check CHECK (int IS NULL OR int BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_sab_check CHECK (sab IS NULL OR sab BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_car_check CHECK (car IS NULL OR car BETWEEN 3 AND 18),
    CONSTRAINT ficha_datos_manuales_pv_check CHECK (puntos_vida_manual IS NULL OR puntos_vida_manual >= 0)
);

ALTER TABLE public.ficha_datos_manuales ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.ficha_datos_manuales FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.ficha_datos_manuales TO authenticated;

DROP POLICY IF EXISTS "Lectura de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales;
CREATE POLICY "Lectura de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales
    FOR SELECT TO authenticated
    USING (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.asignaciones a
            WHERE a.perfil_id = (SELECT auth.uid())
              AND a.personaje_id = ficha_datos_manuales.personaje_id
        )
    );

DROP POLICY IF EXISTS "Alta de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales;
CREATE POLICY "Alta de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales
    FOR INSERT TO authenticated
    WITH CHECK (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.asignaciones a
            WHERE a.perfil_id = (SELECT auth.uid())
              AND a.personaje_id = ficha_datos_manuales.personaje_id
        )
    );

DROP POLICY IF EXISTS "Edición de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales;
CREATE POLICY "Edición de datos manuales del personaje o DM"
    ON public.ficha_datos_manuales
    FOR UPDATE TO authenticated
    USING (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.asignaciones a
            WHERE a.perfil_id = (SELECT auth.uid())
              AND a.personaje_id = ficha_datos_manuales.personaje_id
        )
    )
    WITH CHECK (
        public.es_dm()
        OR EXISTS (
            SELECT 1
            FROM public.asignaciones a
            WHERE a.perfil_id = (SELECT auth.uid())
              AND a.personaje_id = ficha_datos_manuales.personaje_id
        )
    );

COMMENT ON TABLE public.ficha_datos_manuales IS
    'Atributos, nivel y PV manual de la ficha visual; editable por el jugador asignado o el DM.';
