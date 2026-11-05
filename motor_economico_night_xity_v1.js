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
