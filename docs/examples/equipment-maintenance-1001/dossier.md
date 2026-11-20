# Dossier - fixture equipment-maintenance-1001 (parcial)
Proyecto: demo | Fecha de lectura: 2025-04-02 09:15 UTC | Items: 1001, 1002, 1003
Protocolo: dossier PARCIAL agregado al fixture de regresión. Contiene solo Jerarquía y Campos por tipo. Los pasos 3 a 10 del protocolo de lectura completa no están incluidos; los chequeos que dependen de ellos no son verificables con este dossier.

## Jerarquía

| id | tipo | título | estado/reason | padre | área | iteración |
|---|---|---|---|---|---|---|
| 1001 | User Story | Equipment maintenance requests | New / New | 1000 | contoso-platform\Team A | contoso-platform\Sprint 5 |
| 1002 | Task | Build the maintenance request form | Closed / Completed | 1001 | contoso-platform\Team A | contoso-platform\Sprint 5 |
| 1003 | Task | Build the technician work queue | Closed / Completed | 1001 | contoso-platform\Team A | contoso-platform\Sprint 5 |

[fuente: ADO workitemsbatch, 2025-04-02]

## Definiciones del proceso

### Campos por tipo

#### User Story (campo Acceptance Criteria: sí)

| Nombre | referenceName |
|---|---|
| Acceptance Criteria | Microsoft.VSTS.Common.AcceptanceCriteria |
| Description | System.Description |
| Equipment Code | Custom.EquipmentCode |
| State | System.State |
| Title | System.Title |

[fuente: proceso, tipo User Story, _apis/wit/workitemtypes/User Story/fields]

#### Task (campo Acceptance Criteria: no)

| Nombre | referenceName |
|---|---|
| Description | System.Description |
| Site Supervisor | Custom.SiteSupervisor |
| State | System.State |
| Title | System.Title |

[fuente: proceso, tipo Task, _apis/wit/workitemtypes/Task/fields]
