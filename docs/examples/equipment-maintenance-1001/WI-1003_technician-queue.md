# Propuesta de redacción - Task #1003 "Build the technician work queue"

| Campo | Valor |
|---|---|
| Work item | [#1003](https://dev.azure.com/contoso-dev/contoso-platform/_workitems/edit/1003) |
| Tipo | Task |
| Estado / Reason | New / New |
| Padre | User Story #1001 "Equipment maintenance requests" |
| Iteración | contoso-platform\Sprint 5 |
| Fecha de propuesta | 2025-03-18 |
| Estado de la propuesta | Borrador para revisión de producto |

## Redacción propuesta

**Título sugerido:** Desarrollar la cola de trabajo del técnico

### Objetivo

Permitir al supervisor asignar solicitudes y al técnico atenderlas y cerrarlas desde su cola.

### Alcance

- **Incluye:** asignación, cola del técnico, registro del trabajo, cierre y notificación.
- **No incluye:** el formulario y la lista de solicitudes (#1002).

### Criterios de aceptación

1. **Asignar.** Dada una solicitud "Abierta", cuando el supervisor elige un técnico, entonces
   puede confirmar la asignación.
2. **Técnico no disponible.** Dado un técnico marcado como ausente, entonces no aparece entre
   los técnicos asignables.
3. **Cola.** Dado un técnico con solicitudes asignadas, entonces ve su cola ordenada por
   prioridad.
4. **Filtro por equipo.** Dada la cola, entonces se puede filtrar por tipo de equipo.
5. **Filtro por prioridad.** Dada la cola, entonces se puede filtrar por prioridad.
6. **Búsqueda.** Dada la cola, entonces se puede buscar por número de solicitud.
7. **Abrir detalle.** Dada una solicitud de la cola, cuando el técnico la abre, entonces ve la
   descripción de la falla y el historial.
8. **Registrar trabajo.** Dada una solicitud abierta en detalle, cuando el técnico escribe el
   trabajo realizado, entonces puede guardarlo.
9. **Repuestos.** Dado el detalle, entonces el técnico puede marcar un repuesto como pendiente.
10. **Cerrar.** Dada una solicitud con trabajo registrado, cuando el técnico pulsa "Cerrar",
    entonces pasa a "Cerrada".
11. **Notificación.** Dada una solicitud cerrada, entonces se envía un correo al operario que la
    creó.
12. **Reapertura.** Dada una solicitud "Cerrada", cuando el supervisor pulsa "Reabrir", entonces
    vuelve a "Asignada".

**Usuario validador:** **[POR CONFIRMAR]**

---

## Nota para la actualización en ADO

- Pegar Objetivo y Alcance en la Description y los criterios en la Description, bajo el título
  "Criterios de aceptación".

## Evaluación de origen

La Description original describe la cola en una frase y no enumera criterios. Los 12 criterios
salen del mockup adjunto a #1002.
