# Night Xity — Directriz de programación económica

Esta directriz conserva los acuerdos del sistema económico y rige los cambios siguientes.

## Reglas de cobro

- Las obligaciones marcadas como mensuales se renuevan cada 42 días. Vivienda mantiene el ciclo de seis semanas acordado. Los servicios diarios se renuevan cada día. El cron revisa vencimientos diariamente a las 9:00, hora de Cancún.
- La primera cuota recurrente se cobra al activar la suscripción. El siguiente vencimiento se calcula desde su fecha de vencimiento anterior; el proceso diario no debe desplazar el ancla del ciclo.
- CV-001 a CV-018 son recurrentes cada 42 días. CV-019 y CV-020 son diarios. CV-021 es una compra instantánea y no crea deuda. CV-022 a CV-027 y EV-001/EV-002 son obligaciones por solicitud/evento y requieren aprobación del DM.
- El alcance de mora es ALL para vivienda, servicios obligatorios u opcionales y obligaciones variables/eventuales aprobadas. Las compras instantáneas pagadas al momento quedan fuera.
- Hay una sola multa del 66% del importe ordinario por obligación vencida. No se acumulan multas por día ni por reintento del cron.
- La reactivación recurrente cobra deuda original + multa + reconexión (66% del costo ordinario) + nueva cuota del ciclo. Una obligación aprobada no recurrente liquida deuda original + multa + reconexión (66%) + nuevo cargo de activación equivalente al importe aprobado.
- La falta de saldo no genera saldo negativo: persiste la obligación, suspende el servicio aplicable y permite regularizar mediante una operación atómica.

## Contabilidad e idempotencia

- `personajes.ficha.economia.movimientos` sigue siendo la fuente del saldo porque las compras y otras operaciones existentes ya lo usan. No crear un segundo saldo paralelo.
- `obligaciones_gastos_vida` conserva deuda original, episodio, ciclo, multa y liquidación. `cargos_reactivacion` conserva por separado cada cargo de reconexión y nueva cuota, incluida su multa si queda impagado. Cada cargo tiene unicidad por obligación y tipo, de modo que los reintentos no duplican ni el cargo ni su multa.
- Los cargos de reactivación se preparan en una sola factura indivisible: si el saldo alcanza, se liquida la deuda, su multa, reconexión y nuevo ciclo; si no alcanza, la deuda persiste y la reconexión/nueva cuota entran en mora con multa única del 66% cada una. El siguiente intento cobra los mismos importes ya asentados, sin volver a generarlos.
- Cada ciclo recurrente se identifica por suscripción y vencimiento. Cada obligación aprobada se identifica por solicitud. Las restricciones únicas y el bloqueo de la fila de personaje evitan duplicados y cargos concurrentes.
- Cobros, movimientos, estado de obligación y estado de suscripción deben confirmarse o revertirse dentro de la misma transacción.
- No crear deuda retroactiva a partir de periodos históricos para los que el sistema no guardó un importe vencido.

## Inventario y compras

- catalogo_productos.restantes es el dato único de existencias: SQL NULL o JSON null significa inventario sin límite; un entero JSON no negativo representa existencias finitas.
- La tienda compra una unidad por producto y rechaza identificadores duplicados. realizar_compra_multiple bloquea las filas de productos en orden estable, valida y descuenta el inventario dentro de la misma transacción que actualiza la ficha, el saldo y el historial.
- Una existencia de cero impide la compra. Si el saldo no alcanza, el inventario no se descuenta. Cada movimiento registra las existencias que quedan cuando el producto tiene control finito.
- No se crea otra tabla de inventario porque el catálogo ya contiene restantes. Al 9 de noviembre de 2026, los 158 productos activos tienen restantes = NULL. El usuario decidió tratar los suministros como infinitos y no gestionar inventario en el alcance v1; no se deben configurar cantidades finitas hasta que reabra esa decisión.
- La migración 20261109162100_integrar_existencias_productos.sql ya se aplicó a Supabase. Su archivo y el HTML de tienda actualizado siguen pendientes de incorporarse al repositorio, porque GitHub rechazó la escritura de esta sesión con HTTP 403.
## Seguridad de nuevas operaciones

- No hacer una nueva auditoría general de permisos en cada paso. Al añadir o reemplazar RPC, comprobar los permisos que esa RPC necesita: sesión, asignación del personaje, rol DM cuando aplique, `SECURITY DEFINER` con `search_path` vacío o fijado, y `EXECUTE` limitado a los roles requeridos.
- Los clientes no escriben directamente suscripciones, obligaciones ni movimientos. Las operaciones económicas se realizan por RPC transaccionales.
- El flujo de alta y acceso de jugadores ya está publicado. La prueba del usuario confirmó que Citizen Net carga al iniciar sesión después del alta. La página limita la cuenta a tres personajes; la cuenta probada tiene tres asignaciones reales.

## Cambios y pruebas

- Toda migración se guarda como archivo versionado en `supabase/migrations` además de aplicarse a Supabase. No ejecutar SQL manual sin conservar su migración equivalente.
- Las migraciones de facturación y reactivación están aplicadas y guardadas en `supabase/migrations` del repositorio. La migración de inventario ya está aplicada; su archivo y la tienda actualizada están en los entregables locales porque la conexión de GitHub rechazó esta escritura con HTTP 403.
- Las pruebas económicas aisladas y las pruebas de inventario con fixtures se ejecutaron sin dejar cargos ni datos de prueba persistentes. No se usaron personajes de jugadores.
- La prueba de dos cobros simultáneos queda aplazada por decisión del usuario. La función de compra bloquea filas de productos para evitar sobreventa; la carrera real entre dos sesiones no se verificó.
- El README y esta directriz delimitan el cierre v1 a la plataforma web y económica. Las mecánicas de partida quedan para una fase posterior.

