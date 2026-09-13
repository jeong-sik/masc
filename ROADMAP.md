# masc Roadmap

> Current package version: v0.35.15
> Latest changelog entry: v0.35.15 (2026-09-12)
> Latest published GitHub release: v0.35.14 (2026-09-12)
> Updated: 2026-09-12

A planning view, not a release promise. The operating model behind it
(labels, priority, pull-request and release rules) is
[docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md). The
historical feature-train rules are
[docs/VERSIONED-ROADMAP.md](docs/VERSIONED-ROADMAP.md).

## Scope

`masc` is a harness for running several coding agents against one repository.

| Level | Surface | Meaning |
|---|---|---|
| Front door | The TUI and the MCP workspace | What a user meets first, and what a release must not break |
| Supporting | Keepers, sandboxes, the Gate | Advanced paths; behaviour depends on runtime and configuration |
| Maintained | Dashboard | Kept building, type-checked, and truthful. New operator features land in the TUI first |
| Deferred | Extraction, cluster mode, broad architecture cleanup | Visible, not scheduled |

## Where the backlog comes from

Every issue carries a `masc-triage` block, and its `impact` axis ranks the
backlog: `breaks-continuity`, then `breaks-collab`, `blinds-operator`,
`degrades`, `internal`. `must-do: true` marks what breaks the product promise
now. Counted on 2026-09-07:

| Open | Count |
|---|---|
| Issues | 1,210 |
| `must-do` | 74 |
| `impact/breaks-continuity` | 174 |
| `impact/breaks-collab` | 26 |
| `impact/blinds-operator` | 250 |
| `impact/degrades` | 451 |
| `impact/internal` | 285 |

The live list is
[open `must-do` issues](https://github.com/jeong-sik/masc/issues?q=is%3Aissue+is%3Aopen+label%3Amust-do).
This file names groups and examples from it; the query is the source.

## Now

Open `must-do` issues, grouped. Numbers are issues.

- **Keeper continuity.** A Keeper that cannot boot, or drops what it already
  decided: #32463 (meta file reset on boot), #32461 (an undecodable snapshot
  still blocks the keeper), #31738 (a blocked-shutdown record makes a keeper
  unbootable), #33267 (a rejected `max_tokens` response kept in the
  checkpoint), #32504 (schema hard cut reconciled in one place at boot).
- **Sandbox truth.** #33638 (an observe run allowed network writes in
  production), #33492 (the microvm adapter cannot express
  drop-all-capabilities and read-only rootfs on `msb`).
- **Server lifecycle.** #33600 (`start-masc.sh` hijacked by the TUI hand-over),
  #31711 (servers receive external SIGTERM).
- **CI truth on `main`.** #32372, #32522, #32507, #32503 (suites red on
  `main`), #31801 (a ratchet that counts zero on CI runners and passes),
  #32181 (hangs that burn the test budget).
- **Operator visibility.** #32828 (a rejected prompt override is invisible),
  #32747 (a Gate record shows the pre-routing command), #31729 (decision-feed
  token, cost, and stop-reason fields never written), #31722 (the dashboard
  snapshot materialises 440k events per cycle).
- **Verification.** #31862 (the judge cannot read producer evidence), #31629
  (launcher provenance for verifier-grade proof), #32061 (non-Keeper owners
  cannot submit completion over MCP).

## Next

- TUI: every operator action reachable without the dashboard. The two screens
  that exist only in the dashboard (the IDE shell, the Lab diagnostics) are
  not on the TUI path; whether they move or retire is open.
- microVM backends beyond `apple_container`: `microsandbox` boot,
  `nerdctl_kata` measured on a Linux host, `network_mode = "policy"` on more
  than one backend.
- Auth and API contract for non-local operation.
- Verifier and delegation: turn-budget reliability, and the runtime and model
  visible in proof.
- Read-only diagnosis bundles for operators.

## Later

- Extraction and package separation: `masc-games`, the kitchen-sink breakup,
  large module decomposition.
- Deep Eio and architecture cleanup: less global mutable state,
  actor and message-passing conversions, interface and error-pipeline
  refactors.
- Distribution and platform work: cluster mode, a chaos framework.

## Release lane rules

- The active line is pre-1.0: `0.y.0` opens a user-visible train and `0.y.z`
  stabilizes it.
- `1.0.0` does not open until the TUI, the MCP workspace, and release truth
  hold without caveats.
- `v2.*` tags are audit history only.
- No tag while `must-do` issues remain open.
- No tag while version truth is broken across `dune-project`, `masc.opam`,
  `ROADMAP.md`, and `CHANGELOG.md`.
- The backlog is ordered by `impact/*`.

## References

- [CHANGELOG.md](CHANGELOG.md), release by release
- [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md)
- [docs/VERSIONED-ROADMAP.md](docs/VERSIONED-ROADMAP.md)
- [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md)
