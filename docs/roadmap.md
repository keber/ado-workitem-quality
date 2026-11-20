# Roadmap

Ordered next steps, derived from [context.md](context.md). Each step lists what it covers and
when it is done.

Status 2026-11-03: steps 1 to 6 are all still open. The work done so far is on the review
pipeline itself (severity model, proposed defaults, context port, cross-reference gate, GCM
authentication). A Feature-level analysis step (cross-family dependencies, overlaps,
contradictions and consolidated questions) was designed but not built.

## 1. Detection fixes in the monitor

- Use `[System.AreaPath] UNDER '<area>'` and an explicit, configurable policy for items sitting
  at the project root area or root iteration (likely misclassified, probably in scope).
- Trigger on `System.ChangedDate` instead of `System.CreatedDate`; keep per work item the last
  evaluated revision or a hash of title + description + acceptance criteria, and re-evaluate
  only when that content changed (catches items moved into the area and content edits such as
  description shrinkage, see context.md).
- Group bulk loads by parent User Story (one notification per family, not per item).

**Done when:** replaying a bulk load of items and a description-shrinking edit in a
non-posting dry-run mode detects all of them, once each, grouped into one entry per family.

## 2. Monitor triggers the family review pipeline

Replace the single-call `claude -p` rubric evaluation with a headless run of the family review
(reader, evaluator, proposer, validator) per detected family, writing to
`reviews/<project>/<us-id>/`.

**Done when:** a detected family produces a complete review folder with a `validation.md`
verdict, and the notification links to it instead of carrying a free-text critique.

## 3. QA approval flow

Define how the QA approver marks a proposal approved, approved with edits, or rejected (e.g. a
status field in the proposal header or a sidecar file), where corrections are captured, and how
rejections and edits feed rubric tuning.

**Done when:** an approval state is recorded per proposal, only approved proposals can move to
delivery, and QA corrections are logged in a place the rubric owner reviews.

## 4. Notification channel to work item creators

Send approved proposals to the work item creator through a notification channel (for example
e-mail or chat), with credentials held in a vault.

**Done when:** an approved proposal reaches its creator through the channel, and nothing is sent
for unapproved proposals.

## 5. From local Scheduled Task to a service

Move detection and review from the local Scheduled Task to a service (ADO pipeline or Azure
Function), with secrets in a vault and retirement of the legacy monitor.

**Done when:** the service runs on schedule without a logged-on user, the legacy Scheduled Task
is unregistered, and no duplicate notifications are produced during the switch.

## 6. Generalization to other ADO projects

Support several ADO organizations/projects/areas with one `projects/<name>/config.json` each
(including org/project, not only the area), per-project rubric overrides, and per-project
delivery channels.

**Done when:** a second ADO project is onboarded by adding a config folder only, with no code
changes, and its reviews run side by side with the first one.
