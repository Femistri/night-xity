-- Permite cargar, consultar y reemplazar retratos privados solo al Arquitecto
-- o a la persona asignada al personaje correspondiente.

DROP POLICY IF EXISTS "Retratos privados: lectura asignada o dm" ON storage.objects;
CREATE POLICY "Retratos privados: lectura asignada o dm"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'retratos-personajes'
  AND (
    public.es_dm()
    OR EXISTS (
      SELECT 1
      FROM public.asignaciones AS asignacion
      WHERE asignacion.perfil_id = (SELECT auth.uid())
        AND asignacion.personaje_id::text = (storage.foldername(name))[1]
    )
  )
);

DROP POLICY IF EXISTS "Retratos privados: carga asignada o dm" ON storage.objects;
CREATE POLICY "Retratos privados: carga asignada o dm"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'retratos-personajes'
  AND (
    public.es_dm()
    OR EXISTS (
      SELECT 1
      FROM public.asignaciones AS asignacion
      WHERE asignacion.perfil_id = (SELECT auth.uid())
        AND asignacion.personaje_id::text = (storage.foldername(name))[1]
    )
  )
);

DROP POLICY IF EXISTS "Retratos privados: reemplazo asignado o dm" ON storage.objects;
CREATE POLICY "Retratos privados: reemplazo asignado o dm"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'retratos-personajes'
  AND (
    public.es_dm()
    OR EXISTS (
      SELECT 1
      FROM public.asignaciones AS asignacion
      WHERE asignacion.perfil_id = (SELECT auth.uid())
        AND asignacion.personaje_id::text = (storage.foldername(name))[1]
    )
  )
)
WITH CHECK (
  bucket_id = 'retratos-personajes'
  AND (
    public.es_dm()
    OR EXISTS (
      SELECT 1
      FROM public.asignaciones AS asignacion
      WHERE asignacion.perfil_id = (SELECT auth.uid())
        AND asignacion.personaje_id::text = (storage.foldername(name))[1]
    )
  )
);

COMMENT ON COLUMN public.ficha_datos_manuales.retrato_path IS
  'Ruta privada del retrato en Supabase Storage; acceso limitado al jugador asignado y al Arquitecto.';
