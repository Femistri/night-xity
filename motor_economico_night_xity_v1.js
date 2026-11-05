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
        const saldoInicial = ciudadano.economia?.saldo_inicial ?? 0;
        const movimientos = [
            ...(ciudadano.economia?.movimientos || [])
        ];

        if (
            typeof saldoInicial !== "number" ||
            !Number.isFinite(saldoInicial)
        ) {
            throw new Error("El saldo inicial no es válido.");
        }

        if (!Array.isArray(movimientos)) {
            throw new Error("El historial de movimientos no es válido.");
        }

        let saldoActual = saldoInicial;

        for (const movimiento of movimientos) {

            if (!movimiento || typeof movimiento !== "object") {
                throw new Error("Se encontró un movimiento inválido.");
            }

            if (
                typeof movimiento.monto !== "number" ||
                !Number.isFinite(movimiento.monto) ||
                movimiento.monto < 0
            ) {
                throw new Error("El monto de un movimiento no es válido.");
            }

            if (movimiento.tipo === "ingreso") {
                saldoActual += movimiento.monto;
            } else if (movimiento.tipo === "egreso") {
                saldoActual -= movimiento.monto;
            } else {
                throw new Error(
                    `Tipo de movimiento no reconocido: ${movimiento.tipo}`
                );
            }
        }

        return {
            ciudadano: ciudadano.identidad?.nombre_clave || null,
            saldo_inicial: saldoInicial,
            saldo_actual: saldoActual,
            movimientos,

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

        const montoTotal = objeto.costo * cantidad;

        if (montoTotal > estado.saldo_actual) {
            throw new Error("Saldo insuficiente.");
        }

        if (!Array.isArray(estado.inventario[categoriaInventario])) {
            estado.inventario[categoriaInventario] = [];
        }

        if (!Array.isArray(estado.inventario_detallado)) {
            estado.inventario_detallado = [];
        }

        const fechaCompra = new Date().toISOString();

        estado.saldo_actual -= montoTotal;

        estado.movimientos.push({
            fecha: fechaCompra,
            tipo: "egreso",
            subtipo: "COMPRA",
            monto: montoTotal,
            concepto: objeto.nombre,
            catalogo_id: objeto.id,
            cantidad: cantidad,
            precio_unitario: objeto.costo,
            quien_pago: estado.ciudadano,
            quien_cobro: "TIENDA"
        });

        for (let i = 0; i < cantidad; i++) {

            const identificadorUnico =
                window.crypto &&
                typeof window.crypto.randomUUID === "function"
                    ? window.crypto.randomUUID()
                    : `NX-${Date.now()}-${Math.random().toString(36).slice(2)}`;

            // Conserva el inventario anterior para compatibilidad.
            estado.inventario[categoriaInventario].push(objeto.id);

            // Registra la unidad individual.
            estado.inventario_detallado.push({
                id_instancia: identificadorUnico,
                catalogo_id: objeto.id,
                nombre: objeto.nombre,
                categoria: objeto.categoria,
                fecha_adquisicion: fechaCompra,
                precio_compra: objeto.costo,
                estado: "SERVIBLE"
            });
        }

        return estado;
    },

    registrarGastoVida(estado, gasto) {

        if (!estado || !gasto) {
            throw new Error("Faltan datos para registrar el gasto.");
        }

        if (typeof gasto.costo !== "number" || gasto.costo < 0) {
            throw new Error("El gasto no tiene un costo válido.");
        }

        if (gasto.costo > estado.saldo_actual) {
            throw new Error("Saldo insuficiente.");
        }

        estado.saldo_actual -= gasto.costo;

        estado.movimientos.push({
            fecha: new Date().toISOString(),
            tipo: "egreso",
            subtipo: "COSTO_DE_VIDA",
            monto: gasto.costo,
            concepto: gasto.nombre,
            catalogo_id: gasto.id,
            cantidad: 1,
            precio_unitario: gasto.costo,
            quien_pago: estado.ciudadano,
            quien_cobro: "TIENDA"
        });

        return estado;
    }
};
