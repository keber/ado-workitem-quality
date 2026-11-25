# Propuesta de redacción - User Story #3001 "Spare parts stock"

| Campo | Valor |
|---|---|
| Work item | #3001 |
| Tipo | User Story |
| Padre | Feature #1000 "Maintenance" |
| Hijos / Hermanas | Hijos: Task #3002 "Stock mínimo" |

## Redacción propuesta

### Historia

Como encargado de bodega, quiero conocer el stock de repuestos, para no detener una reparación.

## Preguntas abiertas para producto

1. ¿Qué proveedor entrega los repuestos importados y con qué plazo?
2. ¿El stock mínimo de un repuesto se define por bodega o para toda la empresa?
3. ¿A qué correo se notifica al supervisor cuando el stock de un repuesto baja del mínimo?

## Supuestos propuestos

| N | Comportamiento propuesto | Por qué es la convención | Hallazgo (I, C) |
|---|---|---|---|
| 1 | Un repuesto pendiente deja la solicitud en espera hasta su entrega | Convención de flujos con dependencia externa | EV-3001-04 (I2, C2) |
