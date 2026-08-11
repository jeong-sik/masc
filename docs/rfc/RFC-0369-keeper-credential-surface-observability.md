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

- New `lib/credential_observation/`: runs
  `gh auth status --hostname <target> --json hosts` without `--show-token`
  and strictly decodes the machine schema (host, login, active account,
  state, token source, scopes, git protocol), using the same non-interactive
  env discipline as `Repo_git` (`GIT_TERMINAL_PROMPT=0`, empty askpass).
  Invalid JSON, unknown fields/enums, duplicate keys, host mismatches, or a
  token-bearing response are typed `Unknown`, never a permissive default.
- Probes evaluate **per keeper profile and target repository host**: the probe
  runs under the keeper's projected environment (`local_env_for_keeper`; the Docker
  profile probes with the projected `--env-file`), so the verdict reflects
  what that keeper's shell would actually resolve — including the case where
  a host-keyring credential is shadowed by a projected `GH_TOKEN`, the
  documented `gh` footgun where `gh auth refresh` silently no-ops.
  Measured on gh 2.87.3, shadowing takes two shapes: `GITHUB_TOKEN` leaves the
  keyring row `✓` with `Active account: false`, while `GH_TOKEN` marks the
  config entry `X`. Both are `Shadowed` — routing the second to
  `unauthenticated` would send the operator to a no-op `gh auth login`.
  A third shape needs no failure at all: a valid env token over a logged-in
  keyring renders both rows `✓`, yet the stored credential is not what
  authenticates. This is why the verdict keys on the env row's presence beside
  a stored credential on that same host. The JSON `active` field is the
  authority for which account the target host will use; credentials on a
  different host, and inactive environment rows, cannot shadow it.
- Read surface: `GET /api/v1/keepers/:name/credential-surface` returning
  `{schema, host, status: authenticated | unauthenticated | shadowed |
  unknown, account?, token_source?, scopes?, probed_at, next_action}` — never
  a token value, and the store stays write-only as today.
  `token_source?` is the label gh itself prints — `keyring`, or the shadowing
  variable's own name (`GH_TOKEN`, `GITHUB_TOKEN`, …) so `next_action` can
  name exactly what to unset. Parsed as
  `Keyring | Environment of string | Config_file of string`, never collapsed
  to a bare `env`.
- Dashboard: a credential card on the keeper detail panel rendering exactly
  those fields, with a manual re-probe action.
- Probe budget: the process has a bounded timeout. Results are cached per
  `(profile, target-host, projected-environment-revision)` with separate
  success/error TTLs and manual refresh; bounded concurrency prevents a fleet
  of N keepers from multiplying `gh` API calls without making one hung host a
  global head-of-line blocker (the fleet shares one personal rate limit —
  audit G4).

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
timeout, cache, and concurrency limit); the decoder follows the CLI's exported
JSON schema and therefore needs a compatibility fixture against the pinned gh
version.

## 5. Verification

- Unit: an actual gh 2.87.3 JSON-shape fixture plus keyring/env/shadowed/GHES
  and mixed-host isolation cases; unknown fields/enums and token-bearing JSON
  map to `Unknown`.
- The probe never reads `gh auth status`'s exit code as a verdict: JSON mode
  exits zero for per-account authentication failures. The target host's typed
  active/state/source fields decide.
- Integration: probe under a projected fake `GH_TOKEN` reports `env` source;
  probe with an empty projection on a logged-in host reports `keyring`.
- E2E completion bar (per the audit's production-use standard): the verdict
  visible on a live instance's keeper detail card, wrong-credential keeper
  showing `unauthenticated` before its next push attempt fails.
