# Propuesta de redacción - Task #1002 "Build the maintenance request form"

| Campo | Valor |
|---|---|
| Work item | [#1002](https://dev.azure.com/contoso-dev/contoso-platform/_workitems/edit/1002) |
| Tipo | Task |
| Estado / Reason | New / New |
| Padre | User Story #1001 "Equipment maintenance requests" |
| Iteración | contoso-platform\Sprint 5 |
| Fecha de propuesta | 2025-03-18 |
| Estado de la propuesta | Borrador para revisión de producto |

## Redacción propuesta

**Título sugerido:** Desarrollar el formulario y la lista de solicitudes de mantenimiento

### Objetivo

Permitir registrar una solicitud con su formulario y consultarlas en una lista con estado.

### Alcance

- **Incluye:** el formulario de registro y la lista de solicitudes.
- **No incluye:** la asignación de técnicos (implementada en criterio 3 de #1001).

### Criterios de aceptación

1. **Campos del formulario.** Dado el formulario, entonces pide código de equipo, descripción de
   la falla y prioridad (Baja, Media, Alta).
2. **Campos obligatorios.** Dado un formulario con algún campo vacío, cuando el usuario guarda,
   entonces se marca el campo faltante y no se crea la solicitud.
3. **Lista.** Dada la lista de solicitudes, entonces muestra número, equipo, prioridad y estado
   (el mockup agrega una columna de antigüedad porque el supervisor la usa).
4. **Selección vacía.** Dado que no hay solicitudes seleccionadas, entonces el botón "Exportar"
   está deshabilitado, según el criterio 3 de #1001.
5. **Orden.** Dada la lista, entonces se ordena por prioridad. El producto debe confirmar si el
   orden secundario es por fecha.

**Usuario validador:** **[POR CONFIRMAR]**

---

## Nota para la actualización en ADO

- Copiar los criterios de aceptación al campo Acceptance Criteria del work item.
- Copiar Objetivo y Alcance a la Description.

## Evaluación de origen

La Description original tiene una sola línea y ningún criterio verificable. El formulario y la
lista provienen del mockup adjunto (`wireframes_v2.png`).
