# Propuesta de redacción - User Story #1001 "Equipment maintenance requests"

| Campo | Valor |
|---|---|
| Work item | #1001 |
| Tipo | User Story |
| Padre | Feature #1000 "Maintenance" |
| Hijos / Hermanas | Hijos: Task #1002 "Formulario de solicitud" |

## Redacción propuesta

### Historia

Como operario de bodega [POR CONFIRMAR: ver pregunta 3], quiero registrar una falla de un equipo y seguir su atención hasta el cierre.

### Criterios de aceptación

1. **Creación de solicitud.**
   Dado un operario autenticado,
   cuando completa código de equipo, descripción de la falla y prioridad y guarda,
   entonces se crea una solicitud en estado "Abierta".

2. **Cierre con repuesto pendiente.**
   Dada una solicitud con un repuesto pendiente de entrega,
   cuando el técnico la cierra,
   entonces queda en [POR CONFIRMAR: ver pregunta 2].

3. **Orden de la lista.**
   Dada la lista de solicitudes,
   cuando el operario la abre,
   entonces las solicitudes se ordenan por fecha de creación [PROPUESTO: ver supuesto 1].

**Usuario validador:** [POR CONFIRMAR: ver pregunta 4]

## Preguntas abiertas para producto

1. ¿Cómo se atienden las solicitudes de equipos arrendados y de equipos dados de baja?
2. ¿Una solicitud con repuesto pendiente debe quedar "En espera" o "Cerrada"?
3. ¿Qué roles pueden asignar solicitudes y cuáles solo consultar la lista?
4. ¿Quién es el usuario validador de esta funcionalidad (rol o persona)?

## Supuestos propuestos

| N | Comportamiento propuesto | Por qué es la convención | Hallazgo (I, C) |
|---|---|---|---|
| 1 | La lista de solicitudes se ordena por fecha de creación, de la más reciente a la más antigua | Convención de listas de trabajo | EV-1001-03 (I2, C1) |

QA acepta o reemplaza cada supuesto al aprobar.

## Evaluación de origen

### Hallazgos atendidos

| ID | Hallazgo (resumen) | Cómo se atiende |
|---|---|---|
| EV-1001-01 | Rol no definido | Pregunta 3 |
