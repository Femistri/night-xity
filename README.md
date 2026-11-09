# night-xity

Night Xity — Cyberpunk Old School RPG en Homie Ludens

## Alcance de cierre v1: plataforma web y economía

Esta fase cubre el portal público, el alta e inicio de sesión de jugadores, la elección de personajes, Citizen Net, la tienda y la economía persistente de Night Xity. Los suministros se consideran infinitos; no se gestionará inventario en esta fase.

### Incluye

- Páginas públicas para entrar al juego, comprar, consultar Citizen Net y recuperar el acceso.
- Hasta tres personajes asignados por cuenta de jugador.
- Compras con saldo validado en Supabase e historial económico; los suministros son infinitos.
- Vivienda y servicios periódicos; los ciclos mensuales equivalen a 42 días y los diarios a un día.
- Aprobación del DM para eventos y gastos variables; mora del 66% y reactivación según la directriz económica.

### Criterios de cierre

1. Registro, inicio de sesión, elección de personaje y acceso a Citizen Net funcionan en la web publicada.
2. Las compras validan la asignación y el saldo; la ficha y los movimientos se actualizan juntos.
3. El sistema no limita ni descuenta suministros en el alcance actual.
4. Los cargos recurrentes, la mora y la reactivación respetan los ciclos y reglas documentados.
5. Las migraciones y páginas publicadas están versionadas en este repositorio.
6. Las pruebas aisladas terminan sin datos o cargos de prueba persistentes.

### Pendientes conocidos

- Incorporar al repositorio la migración `20261109162100_integrar_existencias_productos.sql` y el `tienda.html` actualizado; la migración ya se aplicó en Supabase. La capacidad de inventario queda inactiva mientras los suministros sean infinitos.
- Mantener sin configurar cantidades finitas; no se requiere decidir productos ni cantidades para cerrar esta fase.
- Publicar y comprobar la tienda actualizada con suministros ilimitados.
- La prueba real de cobros simultáneos está aplazada por decisión del usuario.

### Fuera de este alcance

La gestión de inventario finito se aplaza. El ciclo completo de juego —misiones, sesiones, tiradas, habilidades, combate, daño, turnos y herramientas del DM— se definirá en una fase posterior.

Por tanto, el cierre v1 acredita la plataforma web y económica, no el juego de rol completo.

