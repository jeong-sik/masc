# masc Roadmap

> Updated: 2026-11-19

A planning view, not a release promise. The operating model behind it
(labels, priority, pull-request and release rules) is
[docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md).

## Scope

`masc` is a harness for running several coding agents against one repository.

| Level | Surface | Meaning |
|---|---|---|
| Front door | The TUI and the MCP workspace | What a user meets first, and what a release must not break |
| Supporting | Keepers, sandboxes, the Gate | Advanced paths; behaviour depends on runtime and configuration |
| Maintained | Dashboard | Kept building, type-checked, and truthful under the Proposal A+ 6-Trunk Renewal (#54554); IDE shell and Lab diagnostics surfaces retired |
| Deferred | Extraction, cluster mode, broad architecture cleanup | Visible, not scheduled |

## Release train

The cut date holds and scope varies.

The cut order for each train is: freeze, `release/v0.y.0`, version bump and
changelog assembly, release candidate (`v0.y.0-rc*`), an independent release
approval bound to the exact head SHA and completed full Release/Tag CI run,
tag, and publish check.

## Where the backlog comes from

Every issue carries a `masc-triage` block, and its `impact` axis ranks the
backlog: `breaks-continuity`, then `breaks-collab`, `blinds-operator`,
`degrades`, `internal`. `must-do: true` marks what breaks the product promise
now.

The live list is
[open `must-do` issues](https://github.com/jeong-sik/masc/issues?q=is%3Aissue+is%3Aopen+label%3Amust-do).
This file names groups and examples from it; the query is the source.

## Now

Open `must-do` issues, grouped. Numbers are issues.

- **Sandbox truth.** #33492 (the microvm adapter cannot express
  drop-all-capabilities and read-only rootfs on `msb`).
- **Operator visibility.** #32747 (a Gate record shows the pre-routing command).
- **Verification.** #31629 (launcher provenance for verifier-grade proof).

## Next

- TUI: every operator action reachable without the dashboard. The two former
  dashboard-only screens (the IDE shell and the top-level Lab diagnostics
  surface) have been explicitly retired as part of the Dashboard Renewal (#54554);
  active tool, memory, and repository inspection live inside the 6-trunk IA.
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
- No `0.y.0` tag while that train's entry-condition issues remain open. The
  milestone is the list, not the label: an issue blocks the tag when it sits on
  that train's GitHub milestone. The label states the risk; putting the issue
  on that milestone is the separate act that makes it block. Other `must-do`
  issues do not block a tag; they stay ordered by `impact/*` in the backlog.
- `0.y.z` tags are date-fixed and scope-variable: the cut date holds and
  whatever has not passed the gates moves to the next tag.
- No tag while version truth is broken across `dune-project`, `masc.opam`,
  and `CHANGELOG.md`.
- The backlog is ordered by `impact/*`.

## References

- [CHANGELOG.md](CHANGELOG.md), release by release
- [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md)
- [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md)
