-- Clasifica la aportación a servicios de emergencia como gasto obligatorio.
-- No crea ni modifica suscripciones, saldos o cobros.
UPDATE public.catalogo_gastos_vida
SET grupo = 'obligatorio', actualizado_en = now()
WHERE id = 'CV-018' AND grupo = 'opcional';
