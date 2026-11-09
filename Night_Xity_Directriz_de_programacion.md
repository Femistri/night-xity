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

## Seguridad de nuevas operaciones

- No hacer una nueva auditoría general de permisos en cada paso. Al añadir o reemplazar RPC, comprobar los permisos que esa RPC necesita: sesión, asignación del personaje, rol DM cuando aplique, `SECURITY DEFINER` con `search_path` vacío o fijado, y `EXECUTE` limitado a los roles requeridos.
- Los clientes no escriben directamente suscripciones, obligaciones ni movimientos. Las operaciones económicas se realizan por RPC transaccionales.
- Antes de concluir la integración, revisar los flujos reales de alta, asignación y selección de personaje en la página publicada. La revisión inicial encontró que la página ofrece inicio de sesión y personajes ya asignados, pero no alta de cuenta ni selección de personajes sin asignación; la RPC `gestionar_mis_personajes` no está conectada desde ese flujo.

## Cambios y pruebas

- Toda migración se guarda como archivo versionado en `supabase/migrations` además de aplicarse a Supabase. No ejecutar SQL manual sin conservar su migración equivalente.
- Las migraciones `20261109013946_night_xity_mora_42_dias.sql` y `20261109023259_night_xity_reactivation_debt.sql` ya están aplicadas en la base de datos. La integración de GitHub rechazó la escritura (HTTP 403), y el editor web requiere una sesión iniciada; ambos archivos entregables todavía deben incorporarse a `supabase/migrations` del repositorio.
- No cobrar personajes reales en pruebas. Usar fixtures/personajes aislados o una rama/base de pruebas y cubrir reintentos, concurrencia, rollback, mora, reactivación y permisos de las rutas nuevas.
- No probar un bloque parcial: primero terminar la integración de facturación, mora, reactivación y flujos de la interfaz; después ejecutar la batería acordada.
