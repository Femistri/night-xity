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
    },

    registrarCompra(estado, objeto, cantidad = 1) {

        if (!estado || !objeto) {
            throw new Error("Faltan datos para registrar la compra.");
        }

        if (typeof objeto.costo !== "number") {
            throw new Error("El objeto no tiene un costo válido.");
        }

        if (!Number.isInteger(cantidad) || cantidad < 1) {
            throw new Error("La cantidad debe ser un número entero mayor que cero.");
        }

        const montoTotal = objeto.costo * cantidad;

        if (montoTotal > estado.saldo_actual) {
            throw new Error("Saldo insuficiente.");
        }

        estado.saldo_actual -= montoTotal;

        const movimiento = {
            fecha: new Date().toISOString(),
            tipo: "egreso",
            subtipo: "COMPRA",
            monto: montoTotal,
            concepto: objeto.nombre,
            catalogo_id: objeto.id,
            cantidad: cantidad,
            precio_unitario: objeto.costo,
            quien_pago: estado.ciudadano,
            quien_cobro: "TIENDA"
        };

        estado.movimientos.push(movimiento);

        const categoriaInventario = {
            "Programas": "programas",
            "Implantes": "implantes",
            "Armas": "armas",
            "Accesorios": "accesorios",
            "Blindajes": "blindajes",
            "Terminales": "terminales",
            "MediCare": "medicare",
            "Drogas": "drogas",
            "Vehiculos": "vehiculos",
            "Varios": "varios",
            "Cotidiano": "cotidiano"
        }[objeto.categoria];

        if (!categoriaInventario) {
            throw new Error("Categoría de inventario no reconocida.");
        }

        for (let i = 0; i < cantidad; i++) {
            estado.inventario[categoriaInventario].push(objeto.id);
        }

        return estado;
    }
};
