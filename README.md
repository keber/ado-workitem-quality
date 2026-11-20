# ado-workitem-quality

Quality reviewer for Azure DevOps User Stories and Tasks. It reads a work item family (User
Story plus its Tasks) completely, evaluates it against an explicit rubric and deterministic
checks, writes a justified rewrite proposal per item in Spanish, and validates the proposals
with an independent judge. Proposals are drafts for QA approval: nothing is written back to ADO.

Project memory (decisions, gotchas, content rules, reference case): [docs/context.md](docs/context.md).
Long-term plan: [docs/roadmap.md](docs/roadmap.md).
Orchestrator instructions for Claude Code: [CLAUDE.md](CLAUDE.md).

## Status

The family review pipeline is complete. Nothing is automated yet: reviews are requested by hand
in a Claude Code session, and nothing is delivered to ADO, Teams or email. The poller in
`src/monitor/` is a legacy-derived prototype (see the roadmap).

## Layout

| Path | Content |
|---|---|
| `CLAUDE.md` | Orchestrator instructions for Claude Code |
| `.claude/agents/` | Subagents: `wi-reader`, `wi-evaluator`, `wi-proposer`, `wi-validator` |
| `rubric/rubric.md` | Semantic rubric (Spanish, editable by QA) |
| `projects/example/` | Public template of a project instance: `config.json`, `local.example.json` |
| `projects/<name>/` | Your own instances (gitignored, see "Instance configuration") |
| `src/lib/ado-powershell/` | Vendored ADO REST library (PowerShell) |
| `src/monitor/` | Poller, setup, Scheduled Task registration, Teams webhook test |
| `src/review/check-xrefs.ps1` | Deterministic cross-reference gate run after every proposer pass |
| `docs/examples/equipment-maintenance-1001/` | Fictional cycle with known defects, used as validator fixture |
| `reviews/<project>/<us-id>/` | Review output (dossier, evaluation, proposals, validation); gitignored |
| `config.example.ps1` | Template for the gitignored `config.ps1` |

## Prerequisites

- Windows with Windows PowerShell 5.1 (`powershell.exe`; `pwsh` is not used).
- Claude Code CLI (`claude`) with an authenticated session.
- ADO access: Git Credential Manager signed in to `dev.azure.com` (preferred: an Entra ID token
  that passes the organization's conditional access policy), and/or a Personal Access Token with
  Work Items (Read) scope as fallback.
- Teams Workflows webhook URL (only for the monitor).

## Instance configuration (gitignored)

Everything that identifies a real organization lives outside version control. The repository
ignores `projects/*` except `projects/example/`, plus `reviews/`, `config.ps1`, `state/`,
`*.local.*` and the session handoff file `AGENT-NEXT-STEPS.md`. To set up your own instance:

1. Copy `config.example.ps1` to `config.ps1` at the repo root and fill in `ADO_ORG`,
   `ADO_PROJECT`, `ADO_PAT` (and `TEAMS_WEBHOOK_URL` for the monitor). Never commit it.
2. Copy the template folder: `projects/example/` to `projects/<name>/` (`<name>`: lowercase
   letters, digits, dashes) and edit `projects/<name>/config.json`:

   ```json
   {
     "areaPath": "<project>\\<area>",
     "workItemTypes": ["User Story", "Task"],
     "initialLookbackDays": 7
   }
   ```

   `src/monitor/setup.ps1 -Project <name>` can write it interactively, but it also offers to
   run the poller and register a Scheduled Task: answer "n" to both unless you want that.
3. Optional, project context: copy `projects/<name>/local.example.json` to
   `projects/<name>/local.json` and set `contextManifest` to the absolute path of
   `<project repo>/.ado-quality/context.json`. The manifest format and its safety rules are in
   [docs/context-manifest.md](docs/context-manifest.md). Without it, reviews run and declare
   `Contexto: no provisto`.
4. Optional, private notes for Claude Code: a `CLAUDE.local.md` at the repo root is loaded in
   addition to `CLAUDE.md` and is gitignored.

## Reviewing a family

Open Claude Code at the repo root and ask, for example:

> Review the family of work item 1001 in project demo.

The orchestrator (`CLAUDE.md`) runs reader, evaluator, proposer and validator, with at most one
correction round, and leaves the output in `reviews/demo/<us-id>/`. Passing a Task ID reviews the
whole family of its parent User Story.

## Monitor warning

The monitor scripts post real cards to Teams and register a Scheduled Task. If an older monitor
(`ADO-Monitor-*` Scheduled Task) already covers the same scope, do not run this one against it:
both would post duplicate cards. `register-scheduled-task.ps1` refuses to run while an
`ADO-Monitor-*` task exists unless `-AllowAlongsideLegacy` is passed.

## License

MIT, see [LICENSE](LICENSE).
