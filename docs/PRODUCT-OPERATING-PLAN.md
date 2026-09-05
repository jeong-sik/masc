---
status: live
---

# Product Operating Plan

> Current package version: v0.31.0
> Latest changelog entry: v0.31.0 (2026-09-04)
> Latest published GitHub release: v0.31.0 (2026-09-04)
> Updated: 2026-09-04
> Release line: pre-1.0 (`0.y.z`)

## Product Scope

`masc` is a repo-local MCP server for coordinating long-running Keepers, MCP clients, and workspace state inside one repository.

Primary user:

- one engineer or a small trusted team running multiple coding agents against the same checkout or worktree

Scope stack:

1. Repo workspace collaboration
2. Keeper runtime and supervised delivery
3. Dashboard and operator visibility

The front-door promise is level 1. Levels 2-3 are supported surfaces.

## Capability Posture

| Capability | Current status | Promise level | Evidence | Main gap | Next action |
|-----------|----------------|---------------|----------|----------|-------------|
| Workspace and task hygiene | Done | Front door | `README.md`, `docs/spec/01-system-overview.md` | docs were too spread out | keep as default entry path |
| Worktree and collision control | Done | Front door | README, workspace/tool coverage, live usage | onboarding clarity | keep in front-door docs |
| Supervised execution + Supervisor | Working | Advanced | `docs/SUPERVISOR-MODE.md` | still not the safest starting path | present as advanced flow |
| Keeper continuity | Working | Advanced | `docs/KEEPER-STATE-OWNERSHIP.md`, `docs/KEEPER-CONTINUITY-VALIDATION.md` | live restore and independent-lane evidence must remain observable | validate typed checkpoint restore and domain receipts with the runbook |
| Dashboard core read models | Working | Supporting | — | transport truth and config visibility gaps | harden read truth and config introspection |
| Remote-safe operator | Working | Supporting | `docs/spec/09-server-transport.md`, `docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md` | auth and release posture still need tightening | keep surface reduced and explicit |
| Multi-transport matrix | Working but not front-door | Experimental | implementation status appendix, live transport issues | reachable state and reported state can diverge | fix health truth before promotion |
| Auth and API contract posture | Not done for product promise | Advanced / supporting | `docs/PRODUCT-REVIEW.md` | non-local default is still too weak, REST contract is not crisp | design + narrow hardening slices |
| Config introspection | Working but split | Supporting | `masc_config`, `/api/v1/dashboard/config`, open issues `#3364`, `#3365`, `#3363` | read contract is duplicated and not yet centralized enough to promise as SSOT | centralize config and expose one canonical read-only snapshot |
| Release evidence and local proof | Working | Front door | `docs/RELEASE-EVIDENCE.md`, `scripts/release-evidence.sh`, release workflow artifact | deployment-specific proof is still env-gated | keep release/main evidence bundle attached to artifacts |
| Release and doc truth | Working | Front door | doc truth lane + version truth + agent core pin doc sync | release/doc changes previously bypassed runtime gates | keep build/lint/health tied to release/doc/version changes |

Status legend:

- Done: code + tests + trustworthy product promise
- Working: code exists and is usable, but not yet the safest promise
- Not done for product promise: code may exist, but the user-facing promise is still too weak
- Deferred: visible but outside the current 6-8 week focus

## GitHub Operating Model

### Labels

Classification is declared in the issue body and projected onto labels. Nothing else sets them.

````text
```masc-triage
kind: defect
area: turn
impact: breaks-continuity
root: silent
must-do: true
```
````

The vocabulary SSOT is `.github/issue-taxonomy.json`. The `Issue Taxonomy` workflow reads the block,
validates every value against that file, and reconciles the labels. It never invents a label:
if the repository drifts from the SSOT the run fails and names the missing labels.
`APPLY=1 bash scripts/sync-issue-labels.sh` puts the repository back in line.

| Axis | Cardinality | Values |
|------|-------------|--------|
| `kind` | exactly one | `defect` `gap` `capability` `erosion` `inquiry` |
| `area` | exactly one | `turn` `continuity` `collab` `goal-task` `verification` `tools` `runtime` `transport` `dashboard` `connector` `observability` `persistence` `ci` |
| `impact` | exactly one | `breaks-continuity` `breaks-collab` `blinds-operator` `degrades` `internal` |
| `root` | zero or more | `ssot` `silent` `string` `variant` `boundary` `telemetry` `det` `ndt` |
| `must-do` | flag | `true` when the product promise is broken right now |

Two rules settle the overlaps the table cannot spell out:

- `area` is where the fix lands, not where the symptom shows. A panel rendering a stale metric is
  `dashboard` when the panel is wrong and `observability` when the metric is.
- `impact` takes the highest row that applies. The values are ordered, so an issue that both blinds the
  operator and stops turns is `breaks-continuity`.

### Priority comes from impact, not from an assertion

`impact` is ordered, and that order is the priority order:

1. `breaks-continuity` - turns stop, or a keeper cannot recall its own last ten turns
2. `breaks-collab` - keepers stop reaching each other, or output lands where nobody reads it
3. `blinds-operator` - it runs, but nobody can see it
4. `degrades` - friction, performance, or accuracy
5. `internal` - development flow only

There is no separate priority or scheduling label. Severity is derived from which product failure the issue
causes, so it can be argued about with evidence instead of asserted. A roadmap decides *when* work happens;
a label decides *what is at stake*.

`root` is optional and follows `docs/spec/16-root-cause-rubric.md`. A missing `root` is not a triage
violation; the rubric only applies when a structural marker actually matches. Multiple values are allowed,
and overlap is real - a boundary violation that also swallows errors takes both - but it is rare in the
intake we actually have: on 2026-08-22, 48 of the 820 open issues that declare `root` name two or more,
and 401 declare none. This paragraph used to quote 60% from the 2026-04-19 sweep; that number stopped
describing the repository.

### Issue intake

Humans file through the issue form; keepers file with `gh issue create`. Both produce the same fenced
`masc-triage` block, so there is one format and one parser. An issue filed without the block gets a comment
naming the expected shape, and no labels. Do not pass `--label` to `gh issue create`: labels set that way
have no declaration behind them, and the sweep takes them off again.

The workflow also sweeps every open issue once an hour, because the `issues` events do not all arrive - 62
issues were filed on 2026-08-21 against 16 workflow runs. The sweep, not the event, is what keeps labels
and bodies in agreement. It touches only the issues where the two disagree, so a quiet repository produces
no comments and no notifications.

### PR status labels

The `Issue Taxonomy` workflow skips pull requests outright: `kind`/`area`/`impact` describe a problem and a
PR is an answer. Practice disagrees - on 2026-08-22, 15 of 29 open PRs and 13 of the last 30 merged ones
carried taxonomy labels, applied by hand at `gh pr create --label` time. Nothing declares those and nothing
reconciles them, so they are the one place in this model where a label asserts a classification with no
source behind it. Either the hand-labelling stops or PRs get a declaration of their own; today it is
neither.

The former `pr/*` status-label projection was retired with automatic PR
workflows. GitHub's native mergeability, review decision, and unresolved-thread
views are the source of truth instead of a second state machine maintained by
scheduled reconciliation.

### PR rules

Every PR should include:

- `## Summary`
- `## Product impact`
- `## Evidence`
- `## Review evidence`
- `## Linked issue`

Each PR should link at least one issue and state which promise it affects:

- `repo workspace collaboration`
- `supervised delivery`
- `ops visibility`
- `none/internal`

### Release rules

- while pre-1.0, `0.y.0` carries one promise train
- `0.y.z` releases stabilize the current promise only
- `1.0.0` stays reserved until the front-door promise is trustworthy without release-truth caveats
- do not tag with open `must-do` issues
- do not tag if version truth is broken across `dune-project`, `masc.opam`, `ROADMAP.md`, and `CHANGELOG.md`

## 6-8 Week Tracks

### Track A. Product truth and onboarding

- rewrite the README around repo workspace collaboration first
- keep advanced delivery paths visible but clearly secondary
- align roadmap, changelog, and product review
- replace stale or ambiguous “what is this product?” prose with one consistent promise

### Track B. GitHub planning hygiene

- enforce issue taxonomy with forms and a lightweight workflow
- enforce PR section discipline with a sticky hygiene comment
- keep release blockers meaningful
- make release truth check automatic instead of remembered

### Track C. Promise hardening

- restore truthful CI gates
- fix transport / health read-model drift
- add config visibility foundation
- keep auth/API contract hardening visible, but treat it as the next advanced slice after front-door truth

## Current Research and Implementation Queue

Implement now:

- CI truth and quick-suite recovery
- release evidence bundle + front-door proof contract
- transport health truth
- config centralization groundwork
- product/docs/release truth automation

Research next:

- non-local auth defaults and REST contract versioning
- supervised-delivery readiness and verifier budget reliability
- bounded keeper continuity contract beyond same-trace proof
- read-only diagnosis bundles for operator workflows

Keep visible, but defer:

- package extraction and large library breakup
- broad Eio architecture cleanup
- cluster mode and other speculative scaling stories

## GLM Role

GLM is part of the operating model, not the core product promise.

Use direct `sb glm-text` for:

- cross-model PR review
- skeptical review of product docs and roadmap text
- release-note and spec ambiguity checks

Do not describe `sb glm-cascade --simple` results as proof that direct GLM itself worked. That path is a multi-model chain, not a pure GLM call.
