# Propuesta de redacción - User Story #2001 "Technician work queue"

| Campo | Valor |
|---|---|
| Work item | #2001 |
| Tipo | User Story |
| Padre | Feature #1000 "Maintenance" |
| Hijos / Hermanas | Hijos: Task #2002 "Alertas de plazo" |

## Redacción propuesta

### Historia

Como técnico, quiero ver mi cola de trabajo ordenada, para atender primero lo urgente.

### Criterios de aceptación

1. **Cola del técnico.**
   Dado un técnico con solicitudes asignadas,
   cuando abre su cola,
   entonces ve las solicitudes ordenadas [PROPUESTO: ver supuesto 1].

## Preguntas abiertas para producto

1. ¿Qué roles pueden asignar solicitudes a un técnico y cuáles solo consultar la cola?
2. ¿Qué significa que una solicitud quede "En espera" y quién la
   reactiva cuando llega el repuesto?
3. ¿A qué correo se notifica al supervisor cuando una solicitud supera el plazo de atención? Hoy no existe una lista de destinatarios [fuente: contexto specs "Notificaciones" 02-workflows.md:10-12].
4. ¿Quién es el usuario validador de esta funcionalidad (rol o persona)?

## Supuestos propuestos

| N | Comportamiento propuesto | Por qué es la convención | Hallazgo (I, C) |
|---|---|---|---|
| 1 | La cola del técnico se ordena por prioridad y luego por fecha de asignación | Convención de colas de trabajo | EV-2001-02 (I2, C1) |

## Evaluación de origen

### Fuentes usadas

- Cola: [fuente: WI-2001 System.Description rev 1]
