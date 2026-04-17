---
status: live
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - lib/mcp_server.ml
  - lib/keeper/keeper_supervisor.ml
---

# Product Operating Plan

> Current package version: v0.9.10
> Latest release: v0.9.10 (2026-04-17)
> Updated: 2026-04-17
> Release line: pre-1.0 (`0.y.z`); legacy `v2.*` tags are frozen history

Execution companion for capsule-only coordination hardening:
[design/masc-capsule-execution-plan.md](design/masc-capsule-execution-plan.md)

## Product Promise

`masc-mcp` is a repo-local MCP server for coordinating multiple coding agents inside one repository.

Primary user:

- one engineer or a small trusted team running multiple coding agents against the same checkout or worktree

Promise stack:

1. Repo coordination
2. Keeper runtime and supervised delivery
3. Dashboard and operator visibility

The front-door promise is level 1. Levels 2-3 are supported surfaces. Retired compatibility lanes and research material remain in-tree for history, not as product promise.

## Capability Posture

| Capability | Current status | Promise level | Evidence | Main gap | Next action |
|-----------|----------------|---------------|----------|----------|-------------|
| Room and task hygiene | Done | Front door | `docs/spec/C-implementation-status.md`, `README.md` | docs were too spread out | keep as default entry path |
| Worktree and collision control | Done | Front door | README, room/tool coverage, live usage | onboarding clarity | keep in front-door docs |
| Supervised execution + Supervisor | Working | Advanced | `docs/SWARM-DELIVERY-RUNBOOK.md`, `docs/SUPERVISOR-MODE.md` | still not the safest starting path | present as advanced flow |
| Keeper continuity | Not done for product promise | Advanced | `docs/design/keeper-continuity-product-rfc.md`, `docs/KEEPER-CONTINUITY-VALIDATION.md` | checkpoint truth and bounded contract are not productized yet | ship as bounded same-trace continuity with explicit runbook |
| Dashboard core read models | Working | Supporting | — | transport truth and config visibility gaps | harden read truth and config introspection |
| Remote-safe operator | Working | Supporting | `docs/spec/09-server-transport.md`, `docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md` | auth and release posture still need tightening | keep surface reduced and explicit |
| Multi-transport matrix | Working but not front-door | Experimental | implementation status appendix, live transport issues | reachable state and reported state can diverge | fix health truth before promotion |
| Auth and API contract posture | Not done for product promise | Advanced / supporting | `docs/PRODUCT-REVIEW.md` | non-local default is still too weak, REST contract is not crisp | design + narrow hardening slices |
| Config introspection | Working but split | Supporting | `masc_config`, `/api/v1/dashboard/config`, open issues `#3364`, `#3365`, `#3363` | read contract is duplicated and not yet centralized enough to promise as SSOT | centralize config and expose one canonical read-only snapshot |
| Release evidence and local proof | Working | Front door | `docs/RELEASE-EVIDENCE.md`, `scripts/release-evidence.sh`, release workflow artifact | deployment-specific proof is still env-gated | keep release/main evidence bundle attached to artifacts |
| Release and doc truth | Working | Front door | doc truth lane + version truth + OAS pin doc sync | release/doc changes previously bypassed runtime gates | keep build/lint/health tied to release/doc/version changes |
| Research and legacy surfaces | Historical only | Not part of product promise | archived docs, implementation appendix | merged surface area is wider than product promise | keep out of front-door docs and remove unused residue when references disappear |

Status legend:

- Done: code + tests + trustworthy product promise
- Working: code exists and is usable, but not yet the safest promise
- Not done for product promise: code may exist, but the user-facing promise is still too weak
- Deferred: visible but outside the current 6-8 week focus

## GitHub Operating Model

### Labels

Each new issue should end with:

- exactly one `type:*`
- exactly one `area:*`
- exactly one `target:*`
- optional `release-blocker`
- optional `product-gap`
- temporary `triage-required` while the issue is missing one of the required planning labels

Canonical label set:

| Group | Labels |
|------|--------|
| Type | `type:bug`, `type:friction`, `type:feature`, `type:architecture`, `type:docs` |
| Area | `area:coordination`, `area:swarm-execution`, `area:dashboard`, `area:operator`, `area:transport`, `area:config`, `area:ci`, `area:docs`, `area:experimental` |
| Target | `target:now`, `target:next`, `target:later` |
| Gates | `release-blocker`, `product-gap` |

Triage defaults:

- `target:now`
  - current product promise is broken or untrustworthy
- `target:next`
  - advanced workflow improvement after the front door is reliable
- `target:later`
  - large extraction, long architecture cleanup, or speculative platform work

### Issue intake

Use issue forms, not blank issues, for normal product work.

- `type:bug`
  - broken behavior, regression, incorrect truth
- `type:friction`
  - usable but annoying or confusing workflow
- `type:feature`
  - new capability or missing affordance

Mark `product-gap` when code exists but the product promise still should not be trusted.

### PR rules

Every PR should include:

- `## Summary`
- `## Product impact`
- `## Evidence`
- `## Review evidence`
- `## Linked issue`

Each PR should link at least one issue and state which promise it affects:

- `repo coordination`
- `delivery swarm`
- `ops visibility`
- `none/internal`

### Release rules

- while pre-1.0, `0.y.0` carries one promise train
- `0.y.z` releases stabilize the current promise only
- `1.0.0` stays reserved until the front-door promise is trustworthy without release-truth caveats
- do not tag with open `release-blocker`
- do not tag if version truth is broken across `dune-project`, `masc_mcp.opam`, `ROADMAP.md`, and `CHANGELOG.md`

## 6-8 Week Tracks

### Track A. Product truth and onboarding

- rewrite the README around repo coordination first
- keep advanced delivery paths visible but clearly secondary
- align roadmap, changelog, and product review
- replace stale or ambiguous “what is this product?” prose with one consistent promise

### Track B. GitHub as operating system

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
- delivery-swarm readiness and verifier budget reliability
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

Do not describe `sb glm-cascade` results as proof that direct GLM itself worked. That path is a multi-model chain, not a pure GLM call.
