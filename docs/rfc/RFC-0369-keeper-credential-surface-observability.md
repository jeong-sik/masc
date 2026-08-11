---
rfc: "0369"
title: "Keeper credential-surface observability for repo-hosting CLIs"
status: Draft
created: 2026-08-11
updated: 2026-08-11
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0312", "0343"]
implementation_prs: ["28133"]
---

# RFC-0369: Keeper credential-surface observability for repo-hosting CLIs

## 1. Problem

A keeper that opens PRs authenticates to GitHub through whatever its execution
environment resolves: the host `gh` keyring, a projected `GH_TOKEN` secret, or
nothing. No surface can answer "is this keeper able to push right now?":

- `Keeper_secret_projection.dashboard_status_json` exposes `env_names`
  presence only — it cannot say whether a projected token is valid, expired,
  or missing a scope, and it knows nothing about host-keyring credentials the
  Local profile inherits through `HOME`.
- `scripts/lib/gh-preflight.sh` checks `gh auth status` but only inside the
  PR scripts' own run, invisible to the operator.
- A keeper whose push fails on credentials burns its turn on a terminal error
  the dashboard renders as a generic tool failure.

The 2026-08-11 orca comparison audit (G3) measured the contrast: orca surfaces
a three-state connection card with account, scopes, token source, and the
env-token-shadowing footgun; masc surfaces nothing.

One constraint shapes the whole design. RFC-0309 (typed gh capability gating)
was withdrawn by #24332 because generic execution and Gate layers must not
know a particular CLI, credential scheme, or verb family
(`docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate`).
Any credential-surface feature that reintroduces product knowledge into
exec/Gate repeats the withdrawn design.

## 2. Decision

Add a product-specific **observation** module, structurally parallel to the
connector modules that already know Discord or Slack, and keep it entirely
outside exec/Gate:

- New `lib/credential_observation/`: runs `gh auth status` and parses the
  stable field labels (host, account, token source `keyring | env`, scopes),
  using the same non-interactive env discipline as `Repo_git`
  (`GIT_TERMINAL_PROMPT=0`, empty askpass). Unknown or unparseable output is
  a typed `Unknown` verdict, never a permissive default.
- Probes evaluate **per keeper profile**, not per host: the probe runs under
  the keeper's projected environment (`local_env_for_keeper`; the Docker
  profile probes with the projected `--env-file`), so the verdict reflects
  what that keeper's shell would actually resolve — including the case where
  a host-keyring credential is shadowed by a projected `GH_TOKEN`, the
  documented `gh` footgun where `gh auth refresh` silently no-ops.
  Measured on gh 2.87.3, shadowing takes two shapes: `GITHUB_TOKEN` leaves the
  keyring row `✓` with `Active account: false`, while `GH_TOKEN` marks the
  config entry `X`. Both are `Shadowed` — routing the second to
  `unauthenticated` would send the operator to a no-op `gh auth login`.
- Read surface: `GET /api/v1/keepers/:name/credential-surface` returning
  `{schema, host, status: authenticated | unauthenticated | shadowed |
  unknown, account?, token_source?, scopes?, probed_at, next_action}` — never
  a token value, and the store stays write-only as today.
  `token_source?` is the label gh itself prints — `keyring`, or the shadowing
  variable's own name (`GH_TOKEN`, `GITHUB_TOKEN`, …) so `next_action` can
  name exactly what to unset. Parsed as `Keyring | Environment of string`,
  never collapsed to a bare `env`.
- Dashboard: a credential card on the keeper detail panel rendering exactly
  those fields, with a manual re-probe action.
- Probe budget: results are cached with a TTL (default 10 minutes) and a
  manual refresh; probes serialize through a single in-process slot so a
  fleet of N keepers cannot multiply `gh` API calls (the fleet shares one
  personal rate limit — audit G4).

## 3. Non-goals

- No gh awareness in exec, Gate, or policy layers (INV-KEEPER-008 stands).
- No credential values in any response, log, or trace.
- No automatic remediation: the surface reports `next_action` text
  (for example `gh auth login`), it never runs it.
- No new credential storage or rotation semantics; `Keeper_secret_projection`
  remains the only carrier.

## 4. Consequences

Positive: credential failures move from silent turn-burn to a first-class
keeper-detail verdict; the Local-profile asymmetry (env boundary without a
file boundary) becomes visible because the probe reports which source
resolved.

Negative: a probe consumes the operator's own `gh` API budget (bounded by the
TTL and the single-slot serialization); parser follows `gh auth status` text,
which is stable-labeled but not a formal API and needs a compatibility test
against the pinned gh version.

## 5. Verification

- Unit: parser fixtures for keyring/env/shadowed/GHES-host outputs, including
  future-unknown labels mapping to `Unknown`.
- The probe never reads `gh auth status`'s exit code as a verdict: a healthy
  keyring shadowed by an invalid env token exits 1 exactly like a logged-out
  host; only per-entry marks and labels decide.
- Integration: probe under a projected fake `GH_TOKEN` reports `env` source;
  probe with an empty projection on a logged-in host reports `keyring`.
- E2E completion bar (per the audit's production-use standard): the verdict
  visible on a live instance's keeper detail card, wrong-credential keeper
  showing `unauthenticated` before its next push attempt fails.
