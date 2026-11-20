# Project context: ADO work item quality reviewer

This document is the project memory: why it exists, what was decided, and what was learned
building the first version. Read it before changing the pipeline, the agents or the scripts.

## Goal

When a User Story or Task is created (or materially changed) in Azure DevOps, the system:

1. Detects it.
2. Reads it completely (description, acceptance criteria, attachments, revisions, comments,
   parent/child hierarchy).
3. Evaluates it against an explicit rubric: vagueness, ambiguity, missing or unverifiable
   acceptance criteria, scope problems, size problems.
4. Writes a justified rewrite proposal that addresses every objection.
5. Validates the proposal with an independent judge.
6. Delivers it: today to a QA approver; later, after QA approval, by email to the work item
   creator plus a Teams notification.

The purpose is to reduce the cognitive load of whoever writes the work item, to reduce defects
caused by ambiguity for developers, and to give technical and functional QA clear acceptance
criteria to test against.

Owner: Keber Flores. The first target was one product of a single ADO organization; the design
must stay generalizable to other ADO projects/areas (one config per project under `projects/`;
real instances are gitignored, `projects/example/` is the public template).

## Decisions (and why)

| Decision | Rationale |
|---|---|
| Polling with WIQL, not ADO Service Hooks | No public endpoint/infrastructure needed for the prototype. Webhooks are a future option. |
| Runs locally (Windows Scheduled Task) for now | Prototype stage. Moving to a service (ADO pipeline or Azure Function) is required before emailing third parties on behalf of the team. |
| Semantic evaluation through Claude Code headless (`claude -p`) | Reuses the user's existing Claude Code auth; allows real judgment, not only regex. |
| Rubric lives in a plain text file (`rubric/rubric.md`) | QA can audit and edit criteria without touching code. |
| Rubric applied by detected content, not by declared work item type | In this team Tasks are often used as features (they carry "Como/Quiero/Para" and full scope). A Task that is really a feature gets a separate note, it does not block the evaluation. |
| QA approves every proposal before it reaches the creator | Protects credibility (generated proposals can contain errors), softens the human impact of automated criticism, and turns QA corrections into rubric tuning signal. Transitional: removing the approval step is a later decision. |
| Severity = cost of a wrong inference, not amount of missing text | The evaluator detects like a strict auditor (what is not stated does not exist), but rates each finding by inferibility (I1 source resolves it / I2 conventional default / I3 needs a decision) times the cost of a wrong guess (C1 presentation / C2 local rules / C3 destructive, money, external communication, documents, security, data used elsewhere). Hygiene findings (template text in a readiness field, root area) have fixed non-high severity. Rationale: developers fill gaps silently; the system exists to surface the risky silent decisions, not to punish brevity. |
| Evaluate by family (User Story + its Tasks), not item by item | The real context is spread across siblings and parents (designs attached to a sibling, revision history of another). Item-by-item evaluation produced contradictory proposals. |
| Proposals are written in neutral professional Spanish | Target context (ADO items, readers) is Spanish. Code, comments and agent prompts are English. |
| ADO PowerShell library vendored in `src/lib/ado-powershell` | The project must not depend on any particular QA repository to be generalizable. |
| Secrets only in `config.ps1` (gitignored) as environment variables | Org policy: never hardcode credentials. `config.example.ps1` documents the variables. |
| Project context through a manifest owned by the project repo | The context travels with the project and is maintained by the people who know it; the tool stays free of project-specific knowledge; the same tool can review one module today, the whole product tomorrow, or an unrelated product, by pointing at a different manifest. Contract: [context-manifest.md](context-manifest.md). |

## Pipeline

Project knowledge (specifications, business rules, glossary) enters only through the context
port defined in [context-manifest.md](context-manifest.md): the reader extracts excerpts into the
dossier and every dossier and evaluation declares its context state.

| Stage | Responsibility | Lesson behind it |
|---|---|---|
| 1. Detect | New OR modified items in scope | See "Detection gaps" below |
| 2. Read | Full content per the full-read protocol | A proposal written from description/AC/hierarchy alone can contradict the real sources (attachments, comments, revisions) |
| 3. Evaluate | Deterministic checks first (template placeholder, empty AC, size), then rubric judgment | "Task with 12 acceptance criteria" is detectable by counting, no LLM needed |
| 4. Propose | Justified rewrite, per family, consistent across items | Separately written proposals referenced each other with stale numbers |
| 5. Validate | Independent judge: consistency, invented rules, references, clean AC | Without it, errors reach the approver unchecked |
| 6. Deliver | QA approval, then email to creator + Teams | Notification channel still pending |

## Detection gaps found in the legacy monitor (must be fixed in this project)

Observed with a bulk-loaded sprint:

1. **Exact AreaPath match.** The legacy WIQL uses `[System.AreaPath] = '<area>'`. Items created
   at the project root area (`contoso-platform`) with root iteration were silently excluded. Use `UNDER` and decide explicitly how to treat items sitting at the
   project root (likely misclassified, probably in scope).
2. **Cursor by CreatedDate.** Items moved INTO the area after creation are never seen (their
   CreatedDate is already behind the cursor). Content edits are never seen either: a Task
   whose description is cut drastically in a later revision is evaluated only in its degraded
   form. Trigger on `System.ChangedDate` and keep, per
   work item, the last evaluated revision or a content hash; re-evaluate only when the evaluated
   content (title, description, acceptance criteria) changed.
3. **Bulk loads.** Bulk-loaded items share the same CreatedDate to the millisecond (bulk
   import). One card per item would flood the channel; group by parent User Story.

## Technical gotchas (all confirmed with evidence; do not reintroduce)

Environment: Windows, Windows PowerShell 5.1 only (no `pwsh`), console codepage CP850.

1. `config.ps1`, the ADO library loader and the ADO queries must run in the SAME PowerShell
   invocation (`powershell -NoProfile -ExecutionPolicy Bypass -File <script>`). Calling a library
   function from a separate child script breaks `$script:AdoSession` in its default parameter
   values. Always pass `-Org/-Project/-ApiV/-Headers` explicitly.
2. WIQL date literals only accept day granularity. A literal with a non-midnight time
   (`'2025-01-24T13:04:31Z'`) returns 400 Bad Request. Filter by date in WIQL and apply the exact
   cutoff in PowerShell.
3. ADO omits unset fields from the payload. Under `Set-StrictMode`, read optional fields through
   `$fields.PSObject.Properties['Name']`.
4. A function returning `@()` yields `$null` to a caller that assigns it to a variable. Wrap
   calls in `@(...)` before reading `.Count`.
5. `Microsoft.VSTS.Common.AcceptanceCriteria` exists only on User Story in this process, not on
   Task. Its process `defaultValue` is the template example text; the ADO web UI renders that
   default when the field is empty, but the API omits the field. Compare against the default
   fetched dynamically from `_apis/wit/workitemtypes/{type}/fields`, never hardcoded. Note that
   some items have the template text actually SAVED in Description/AC (e.g. User Story 1001).
6. Encoding with native executables (`claude`) under PS 5.1: stdout is decoded with
   `[Console]::OutputEncoding` (CP850 by default) and piped input is encoded with
   `$OutputEncoding` (ASCII by default). Set both to UTF-8 without BOM at the top of any script
   that calls `claude`. Symptoms if missing: "est├í" in output, "env?o" in the prompt.
7. HTTP bodies: `Invoke-RestMethod` with a `[string]` body uses the system codepage. Send
   `[System.Text.Encoding]::UTF8.GetBytes($json)` with `application/json; charset=utf-8`.
8. `Get-Content` without `-Encoding UTF8` reads BOM-less files as Windows-1252. Keep `.ps1` files
   pure ASCII (PS 5.1 parses BOM-less scripts as Windows-1252).
9. `powershell -File script.ps1 -Param 1,2,3` passes "1,2,3" as ONE string. Declare list
   parameters as `[string[]]`, split on commas, validate, convert into a separate typed variable.
10. Task Scheduler `-RepetitionDuration ([TimeSpan]::MaxValue)` produces invalid task XML. Use a
    long finite duration (10 years).
11. To reproduce Scheduled Task conditions from a UTF-8 terminal:
    `cmd //c "chcp 850 >nul && powershell -NoProfile -ExecutionPolicy Bypass -File <absolute path>"`.
12. Rubric wording matters: a rule saying "use only ASCII" (meant for dashes/quotes) made the model
    drop every Spanish accent. Restrictions copied from a convention must carry their exceptions.
13. A 403 from ADO is not necessarily the PAT. An organization conditional-access policy
    (device, network or sign-in session) can reject a valid PAT: the error carries a service
    error code in the `X-TFS-ServiceError` response header, and renewing the PAT does not help.
    `ado-base.ps1` surfaces that header with a hint; always read it before concluding anything
    about credentials. A PAT bound to such a policy makes unattended monitoring fragile (see
    roadmap step 5).
    Mitigation: `New-AdoHeaders` asks Git Credential Manager first
    (`credential.azreposCredentialType=oauth` gives an Entra ID token from the user's sign-in,
    sent as Bearer) and falls back to the PAT. GCM runs with `GCM_INTERACTIVE=never` and a
    timeout unless `-AllowInteractive`, so unattended runs never hang on a sign-in window. Such
    tokens expire in about an hour: rebuild the session if a 401 appears in a long run.
    `$AdoSession.AuthSource` says which source was used.

## Content rules for generated artifacts

- Never invent business rules. Every concrete rule must trace to a source (work item text,
  attachment, revision, comment, sibling/parent). Undefined points become `[POR CONFIRMAR: ...]`
  plus an open question for the product owner.
- Rules found only in a prototype or design attachment are cited and still marked
  `[POR CONFIRMAR]` (prototypes declare their own assumptions).
- Proposed defaults: when the evaluator classified a gap as I2 (a named conventional default)
  with cost C1 or C2, the proposer writes the default in the criterion as
  `[PROPUESTO: ver supuesto N]` and lists it in "Supuestos propuestos" instead of asking. Never
  for I3 or C3, never by reclassifying the finding. QA accepts or replaces each supuesto when
  approving. Decided after an early review produced 13 questions for one User Story,
  many of them with an obvious answer: questions are reserved for real decisions, to keep the
  creator's cognitive load low.
- Acceptance criteria text must be clean enough to paste into ADO: keep justification out of the
  criterion, reference the open question instead (lesson from the first family review).
- Character rule: no em-dash, en-dash, single-character ellipsis, curly quotes or arrow
  characters (U+2013, U+2014, U+2026, U+2018, U+2019, U+201C, U+201D, U+2190-U+21FF). Use ASCII
  equivalents. Spanish accented letters and enie are allowed and expected. UTF-8 without BOM.

## Reference case

`docs/examples/equipment-maintenance-1001/` is a small fictional cycle (US 1001 "Equipment
maintenance requests" and Tasks 1002-1003). The validator's answer key is
`docs/examples/equipment-maintenance-1001/EXPECTED.md`; the validator itself must never read it
(nor this section). Known defects, kept on purpose as a regression reference for the validator:

- Stale cross-reference: Task 1002 cites "criterion 3 of #1001" for empty selection (it is
  criterion 4).
- US 1001 Scope lists "leased and decommissioned equipment" as undefined while its criterion 2
  only covers leased equipment.
- Several criteria embed justification text, which is not paste-ready for ADO.
- Task 1003 has 12 criteria: it is a User Story in practice and should have been flagged by a
  size check.
- The Task 1002 "Nota para la actualizacion en ADO" asks to fill the Acceptance Criteria field,
  but that field does not exist on the Task type in this process (gotcha 5). Impossible
  instruction; the validator must flag type-inapplicable field requests.

## Legacy monitor (if one is running, do not disturb)

This project started as a copy of a single-project monitor that may still run on the same
machine as a Scheduled Task named `ADO-Monitor-<repo>-<area>` (every 30 minutes, posting to a
Teams channel). While such a task is active, do NOT register a second Scheduled Task and do NOT
run this project's monitor in polling mode against the same scope: both would post duplicate
cards. `register-scheduled-task.ps1` refuses to run while an `ADO-Monitor-*` task exists unless
`-AllowAlongsideLegacy` is passed.
