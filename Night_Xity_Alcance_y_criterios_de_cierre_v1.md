# Night Xity — alcance de cierre v1

**Decisión acordada el 9 de noviembre de 2026:** esta fase cierra la plataforma web y económica. Las mecánicas de partida quedan para una fase posterior.

## Incluido en esta fase

- Portada y páginas públicas de tienda, Citizen Net y recuperación de acceso.
- Alta e inicio de sesión de jugadores, asignación y elección de hasta tres personajes por cuenta.
- Ficha ciudadana conectada con los datos persistentes del personaje.
- Tienda con compras instantáneas, validación del saldo e historial económico.
- Suministros infinitos; la gestión de inventario finito no forma parte de esta fase.
- Vivienda, servicios, facturación periódica, solicitudes aprobadas por el DM, mora del 66% y reactivación.
- Supabase como persistencia para cuentas, personajes, operaciones y obligaciones.

## Criterios para declarar cerrada esta fase

1. Un jugador puede registrarse, iniciar sesión, elegir un personaje asignado y abrir Citizen Net.
2. Una compra solo se confirma para un personaje asignado y con saldo suficiente; el saldo, la ficha y el historial coinciden.
3. Las compras validan personaje y saldo, pero no limitan ni descuentan suministros en esta fase.
4. Las cuotas mensuales usan ciclos de 42 días, las diarias de un día, y la mora y reactivación respetan la directriz económica.
5. Las solicitudes de eventos y gastos variables requieren aprobación del DM antes del cobro.
6. Las pruebas aisladas no dejan personajes, compras, cargos ni existencias de prueba persistentes.
7. Las páginas y sus migraciones están versionadas en GitHub, y GitHub Pages muestra la versión publicada.

## Pendientes conocidos para completar el cierre

- Guardar en `supabase/migrations` la migración `20261109162100_integrar_existencias_productos.sql`, ya aplicada en Supabase, y publicar el `tienda.html` actualizado. La conexión de GitHub de esta sesión rechazó la escritura con HTTP 403; los archivos están preparados como entregables locales.
- Mantener sin cantidades finitas los 158 productos activos; no configurar inventario mientras los suministros sean infinitos.
- Hacer una comprobación final de la tienda publicada con el comportamiento de suministros ilimitados.
- La prueba real de dos cobros simultáneos queda aplazada por decisión del usuario. El soporte futuro para inventario no se activa en esta fase.

## Fuera de esta fase

Misiones, conducción de sesiones, tiradas, habilidades, combate, daño, turnos y herramientas de dirección de partida no son requisitos de este cierre. Se podrán definir como una fase posterior.

El cierre descrito aquí significa que queda operativa la **plataforma web y económica**; no declara terminado el ciclo completo de juego de rol.

