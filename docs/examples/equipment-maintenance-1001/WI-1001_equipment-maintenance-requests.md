# Propuesta de redacción - User Story #1001 "Equipment maintenance requests"

| Campo | Valor |
|---|---|
| Work item | [#1001](https://dev.azure.com/contoso-dev/contoso-platform/_workitems/edit/1001) |
| Tipo | User Story |
| Estado / Reason | New / New |
| Padre | Feature #1000 "Maintenance" (sin descripción) |
| Hijos | Task #1002 (formulario y lista), Task #1003 (cola de trabajo) |
| Iteración | contoso-platform\Sprint 5 |
| Fecha de propuesta | 2025-03-18 |
| Estado de la propuesta | Borrador para revisión de producto |

## Redacción propuesta

**Título sugerido:** Solicitudes de mantenimiento de equipos de bodega

### Historia

Como **[POR CONFIRMAR: rol, p. ej. operario/a de bodega]**,
quiero registrar una falla de un equipo y seguir su atención hasta el cierre,
para no avisar por teléfono y saber en qué estado está cada solicitud.

### Contexto

Cada equipo de la bodega (montacargas, transpaletas eléctricas, cintas) tiene un código. Una
falla se registra como solicitud, la asigna un supervisor a un técnico y el técnico la cierra
cuando termina el trabajo.

### Alcance

- **Incluye:**
  - Registro de la solicitud y lista de solicitudes (#1002).
  - Asignación, cola de trabajo del técnico y cierre (#1003).
- **Por definir:** el tratamiento de equipos arrendados y de equipos dados de baja. El mockup
  permite crear la solicitud sin restricción para ambos (ver criterio 2). **[POR CONFIRMAR]**

### Criterios de aceptación

1. **Creación de solicitud.** Dado un operario autenticado, cuando completa código de equipo,
   descripción de la falla y prioridad y guarda, entonces se crea una solicitud en estado
   "Abierta" con número REQ-n.
2. **Equipo arrendado.** Dado un equipo arrendado, cuando se intenta crear una solicitud,
   entonces **[POR CONFIRMAR]**. El mockup permite crearla sin restricción. Producto debe decidir
   si la solicitud se deriva al proveedor del arriendo o se atiende igual.
3. **Asignación.** Dada una solicitud "Abierta", cuando el supervisor elige un técnico y
   confirma, entonces la solicitud pasa a "Asignada" y aparece en la cola de ese técnico.
4. **Selección vacía.** Si no hay ninguna solicitud seleccionada en la lista, entonces las
   acciones de asignación y cierre masivo no están disponibles.
5. **Cierre.** Dada una solicitud "Asignada", cuando el técnico registra el trabajo realizado,
   entonces pasa a "Cerrada" y se notifica al operario que la creó.
6. **Cierre con repuesto pendiente.** Dada una solicitud con un repuesto pendiente de entrega,
   cuando el técnico la cierra, entonces queda en "En espera" y no en "Cerrada" (comportamiento
   del mockup, **[POR CONFIRMAR]**).

**Usuario validador:** **[POR CONFIRMAR]**

---

## Preguntas abiertas para producto

1. ¿Cómo se atienden las solicitudes de equipos arrendados y de equipos dados de baja?
2. ¿Una solicitud con repuesto pendiente debe quedar "En espera" o "Cerrada"?
3. ¿Qué roles pueden asignar y cuáles solo consultar?

---

## Evaluación de origen

Problemas detectados por el monitor de calidad en el work item original:

- La Description contiene solo el texto de ejemplo de la plantilla, guardado como contenido.
- El Acceptance Criteria contiene solo el texto de ejemplo de la plantilla.
- No hay formato Como/Quiero/Para, ni alcance, ni criterios verificables.

### Fuentes usadas

El contenido de esta propuesta proviene de las Descriptions de las Tasks hijas (#1002, #1003) y
del mockup adjunto a #1002 (`wireframes_v2.png`).
