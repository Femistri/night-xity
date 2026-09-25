/*
 * NIGHT XITY
 * Motor Económico v1
 *
 * Responsabilidad:
 * - Construir el estado económico inicial de un ciudadano.
 * - Mantener separado el estado base de las operaciones realizadas.
 * - Servir posteriormente a TIENDA y CITIZEN NET.
 *
 * No modifica directamente los archivos JSON.
 */

const MotorEconomico = {

    crearEstadoInicial(ciudadano) {

        if (!ciudadano) {
            throw new Error("No se recibió un ciudadano válido.");
        }

        const inventarioBase = ciudadano.inventario || {};

        return {
            ciudadano: ciudadano.identidad?.nombre_clave || null,

            saldo_inicial: ciudadano.economia?.saldo_inicial ?? 0,

            saldo_actual: ciudadano.economia?.saldo_inicial ?? 0,

            movimientos: [
                ...(ciudadano.economia?.movimientos || [])
            ],

            inventario: {
                implantes: [...(inventarioBase.implantes || [])],
                programas: [...(inventarioBase.programas || [])],
                armas: [...(inventarioBase.armas || [])],
                accesorios: [...(inventarioBase.accesorios || [])],
                blindajes: [...(inventarioBase.blindajes || [])],
                terminales: [...(inventarioBase.terminales || [])],
                medicare: [...(inventarioBase.medicare || [])],
                drogas: [...(inventarioBase.drogas || [])],
                vehiculos: [...(inventarioBase.vehiculos || [])],
                varios: [...(inventarioBase.varios || [])],
                cotidiano: [...(inventarioBase.cotidiano || [])]
            }
        };
    }
};
