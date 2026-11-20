# Expected validator result for the equipment-maintenance-1001 fixture

Answer key for the regression test of `wi-validator`. **The validator must never read this
file**: the orchestrator runs the validator blind, then compares its `validation.md` against this
list. All content of this fixture is fictional.

Run: `wi-validator` with `target` = `docs/examples/equipment-maintenance-1001/`, `output` =
`reviews/_fixtures/equipment-maintenance-1001/validation.md`, `round` = 1.

Fixture inputs: the 3 proposals (`WI-*.md`) and a PARTIAL `dossier.md` (hierarchy and fields per
type only). There is no `evaluation.md`.

## Pass criteria

- Verdict: **REJECTED**.
- Every **required** defect below is reported (any VAL ID, under the listed check or an
  equivalent one).

## Required defects

| # | Check | File | Defect |
|---|---|---|---|
| R1 | C3 | WI-1002 criterion 4 | Cites "criterio 3 de #1001" for empty selection; it is criterion 4 |
| R2 | C9 | WI-1001 | Alcance lists "equipos arrendados y equipos dados de baja" as undefined; criterion 2 covers only leased equipment |
| R3 | C5 | several | Justification prose inside criteria (mockup references, "producto debe", parentheticals) |
| R4 | C6 | WI-1003 | Task with 12 criteria and no conversion/split recommendation |
| R5 | C11 | WI-1002 | "Nota para la actualización en ADO" asks to fill the Acceptance Criteria field, which the Task type does not have (dossier, "Campos por tipo") |
| R6 | C1 / C10 | all | No `evaluation.md`; no "Hallazgos atendidos" in the headers |

## Not required

Other real defects the validator may report (for example the bare "El producto debe confirmar el
orden secundario" inside a criterion of WI-1002, or the "New / New" header of Tasks that the
dossier records as "Closed / Completed") are a good sign; missing them is not a regression
failure.

Finding counts vary between runs. Compare by defect presence, never by count.
