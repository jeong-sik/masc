# RFC-0050 — Dashboard Component Ownership Decomposition

Status: Draft
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-09
Supersedes: —
Related: RFC-0048 (Dashboard IA Phase 2), `prometheus.ml` extraction issue
#14166 (closed by user as "회피형, 근본해결 아님"; informs the rejection
bar in §3 below)

## 1. Problem

`dashboard/src/components/` contains **321 files / 82,086 LoC**. Fifteen
files exceed 800 LoC, totaling 16,810 LoC — roughly **20% of the
component tree concentrated in 5% of the files**.

LoC inventory at origin/main @ eeddea6095:

| File | LoC | What it owns |
|---|---:|---|
| `connector-status.ts` | 1689 | Per-connector display (Discord, Slack, iMessage, Telegram) — metadata, accent colors, sidecar commands, channel icons |
| `cost-dashboard.ts` | 1442 | Cost view types + token formatting + actor summarization |
| `cascade-config-panel.ts` | 1386 | Single render — cascade config editor |
| `keeper-detail.ts` | 1310 | Keeper state signal + detail page lifecycle (open/close/select) |
| `fleet-fsm-matrix.ts` | 1247 | FSM visualization tokens + history constants + state chips |
| `keeper-detail-panels.ts` | 1239 | KPI grid + autonomy hints + formatting utilities |
| `keeper-config-panel.ts` | 1159 | Hook slot filtering + sandbox profiles + config types & renderers |
| `memory-subsystems.ts` | 1055 | Hebbian + episodes + compaction state surface |
| `fsm-hub.ts` | 1055 | Composite FSM snapshot rendering (post-RFC-0046) |
| `telemetry-unified.ts` | 1042 | Telemetry view, multi-section render |
| `journey-panel.ts` | 903 | Journey timeline render |
| `agent-roster.ts` | 850 | Agent directory list |
| `fleet-telemetry-panel.ts` | 822 | Fleet telemetry render |
| `autoresearch.ts` | 806 | Autoresearch loop view |
| `dashboard-shell.ts` | 805 | Shell layout + surface routing |

## 2. The wrong way to do this (anti-pattern)

> "We have a 1689-LoC file. Let's split it on a line-count cap."

That is the path #14166 took for `prometheus.ml` and was rejected with
"회피형, 근본해결 아님 — 이거 해결책이 너무 바보같음." The split moved 367
metric constants to N files and re-exported them through an `include`
shim. The central registry pattern stayed; ownership stayed centralized;
the cap-fix only changed shape. Mechanical line-count splits in this
repo will be rejected on the same grounds.

This RFC does **not** propose a LoC cap. It proposes a small number of
splits, each justified by **a clear ownership boundary**, leaving
files that lack such a boundary alone — even if they are large.

## 3. Decomposition criteria

A split is in scope when **all five** hold:

1. **Plurality of distinct domains** in the file. "Slack metadata,
   Discord metadata, iMessage metadata, Telegram metadata" is plural;
   "one complex render with shared local helpers" is not.
2. **No cross-domain shared mutable state**. If two domains read/write
   the same closure variable, splitting requires a state-management
   refactor first — that's a separate RFC.
3. **Domain count ≥ 3** OR **single boundary that splits the file by
   ≥ 60%**. Two-domain splits with weak separation produce churn
   without simplification.
4. **No Hyrum-effect callers** — no external module imports private
   helpers via path-based reach. (Verified via `rg "from.*<file>"`
   before each split.)
5. **The split does not require an API rename**. Public exports keep
   their names; only the internal file boundary moves. Renames belong
   in a separate refactor RFC.

A file that fails any one of the five stays as-is.

## 4. Decomposition proposals

For each candidate, this section gives: the file, current LoC, proposed
split shape, and a *one-line ownership justification*.

### 4.1 In scope (clear ownership boundary)

#### `connector-status.ts` (1689 → ~4 × ~300 + shared 200)

**Boundary**: per-connector. Slack, Discord, iMessage, Telegram each
have distinct sidecar commands, accent colors, channel icons,
authentication shapes, and runbooks.

```
dashboard/src/components/connectors/
  connector-types.ts        # shared interfaces (AccentColor, SidecarCommand)
  slack.ts                  # ~300 LoC
  discord.ts                # ~300 LoC
  imessage.ts               # ~300 LoC
  telegram.ts               # ~300 LoC
  index.ts                  # re-export glue, picker render
```

**Justification**: each connector has its own subsection in the dashboard,
its own backend sidecar process, and its own failure modes. The current
file is a flat `switch` over four mutually-exclusive cases.

**Risk**: minor. None of the four connectors share mutable state.
Picker render lives in `index.ts` and consumes the per-connector
exports.

#### `cost-dashboard.ts` (1442 → 3 × ~400-500)

**Boundary**: types vs. formatters vs. summarizer logic.

```
dashboard/src/components/cost/
  cost-types.ts             # CostView, AuditFocus, etc. — ~250 LoC
  cost-formatters.ts        # token / duration / percent formatting — ~400 LoC
  audit-summarizer.ts       # actor + window aggregation — ~600 LoC
  index.ts                  # render entry point
```

**Justification**: types are a pure-data contract; formatters are
side-effect-free utilities; summarizer is business logic that consumes
both. The three layers form a natural staircase.

**Risk**: low. `cost-formatters.ts` may be reused by future PRs (e.g.,
billing surfaces); extracting it makes that reuse possible without an
import cycle.

### 4.2 Out of scope (organic unity)

The following large files are **not** decomposed in this RFC because
they fail criterion 1 (plurality of distinct domains):

- **`cascade-config-panel.ts` (1386)** — single render of a single
  domain (cascade config editor). Split would fragment the visual tree.
- **`goal-tree.ts` (1390 — referenced in research)** — single component
  render, internal helpers tightly coupled. Same.
- **`keeper-detail-panels.ts` (1239)** — 13 sub-components of one
  detail view. Splitting would create 13 import lines for what visually
  reads as one panel.
- **`keeper-detail.ts` (1310)** — keeper state signal + lifecycle. The
  state signal is shared; splitting it requires upgrading state
  management, which belongs in a separate RFC.
- **`fleet-fsm-matrix.ts` (1247)** — visualization tokens are not a
  separate domain; they're style constants for one render. Extract
  would not reduce reader load.

If one of these later grows a *new* second domain (e.g., keeper-detail
gains its own settings sub-page), it becomes a candidate at that point —
not before.

### 4.3 Deferred (need refactor first)

- **`memory-subsystems.ts` (1055)** — three sub-systems (Hebbian,
  episodes, compaction) but they share the keeper-state signal at the
  top of the file. Splitting requires lifting state management; defer
  until that infrastructure is in place.
- **`telemetry-unified.ts` (1042)** — Phase 1 already merged
  telemetry/fleet/tool-quality/governance into this file (see RFC-0048
  §1.3). Re-splitting would undo Phase 1 and fight RFC-0048's hide-
  before-delete sequence. Defer until RFC-0048 PR-D produces telemetry
  data showing one of the consolidated views is high-traffic enough
  to warrant its own surface.

## 5. Sequencing

Each split is its own PR. No batched super-refactor.

```
PR-1   connector-status.ts   → 5 files     (this RFC's smallest delta)
PR-2   cost-dashboard.ts     → 4 files     (depends on no other PR)
```

Each PR must:

1. Open as Draft. Self-review against `~/me/agents/best-programmer/AGENT.md`
   per `instructions/workflow-pr.md`.
2. Cite this RFC in the PR body.
3. Carry a **mechanical-only diff** — no logic changes, no rename of
   public exports, no removal of dead code (those go in separate PRs).
4. Pass vitest in full (`pnpm test`) — the goal of an ownership split
   is that all existing tests stay green by name.
5. Reduce per-file LoC for the target while not increasing total LoC
   by more than ~10% (some glue is acceptable; substantial growth
   means the split is wrong).

If a PR's diff includes any logic change, the PR is split into a
mechanical move + a follow-up logic change. RFC-0048 §5.2 same
discipline.

## 6. What this RFC does *not* do

- **No LoC cap added to CI.** A cap forces splits without ownership
  boundaries — the exact pattern #14166 was rejected for. This RFC's
  governance is "at PR review, justify the split with §3 criteria,"
  not "at CI gate, fail PRs above N lines."
- **No barrel exports** (`index.ts` that re-exports everything from
  N siblings). Barrels hide the dependency graph and undo the
  ownership benefit. Each split's `index.ts` only exports the public
  render entry point; consumers import from `connectors/slack.ts`
  directly when they need Slack-specific symbols.
- **No file moves of files not enumerated in §4.1.** Even if a future
  reader thinks `agent-roster.ts` (850) deserves a split, that requires
  a new RFC step or an amendment to this one.
- **No prefactor for hypothetical futures.** "We might want to add a
  fifth connector someday" is not justification for splitting today.

## 7. Compatibility & risk

### 7.1 Imports

External modules import from `connector-status.ts` and `cost-dashboard.ts`
today. After the split, the public render entry point lives at
`connectors/index.ts` and `cost/index.ts` respectively. To preserve
import paths during the transition:

- PR-1 keeps `connector-status.ts` as a thin re-export shim for one
  release window. Removing the shim is a follow-up cleanup PR after
  all callers have migrated. Same for PR-2.
- The shim has zero logic — only `export * from './connectors'` etc.
  The shim is deleted in the next PR after caller migration.

Re-export shim is the *only* form of barrel allowed in §6 — and only
during the migration window.

### 7.2 Test split

Existing tests for `connector-status.ts` likely instantiate the picker
with a specific connector. After the split they'll either:

- live alongside the connector file (`connectors/slack.test.ts`), if
  they exercise Slack-specific behavior
- live at `connectors/index.test.ts`, if they exercise the picker

PR-1 does not rewrite test logic. Tests move 1:1 by content to the
file location dictated by what they test. Vitest's
`--no-file-parallelism` mode (already configured in `package.json`)
means moved tests don't change ordering side effects.

### 7.3 HMR / dev server

Vite HMR boundary is per-file. Smaller files = smaller HMR reload
units. This is a positive side effect, not a justification — same
HMR behavior would be achieved by *any* file split, regardless of
quality.

### 7.4 LoC math

Connector split adds ~50 LoC of glue (interfaces, re-exports). Cost
split adds ~30 LoC. Net change: ~+80 LoC across the dashboard tree.
Well within the ~10% allowance per PR.

## 8. Open questions

1. **Public API exposure.** Should `connectors/slack.ts` exports be
   considered part of the dashboard's public surface, or
   internal-only? Default: internal. Anyone wanting to render a Slack
   chip from outside `dashboard/` should consume `connectors/index.ts`
   (the picker) instead of reaching into the per-connector file.

2. **Future fifth connector.** If a fifth connector is ever added
   (e.g., Telegram→Matrix migration introduces Matrix), it lands as
   `connectors/matrix.ts` with no glue change. The `index.ts` picker
   gains one case. Pre-committing scaffolding for hypothetical
   connectors is forbidden by §6.

3. **`cost-formatters.ts` reuse.** If billing surfaces want token
   formatting, they import from `cost/cost-formatters.ts` directly.
   This is exactly the cross-module reuse the split enables; it's not
   a new dependency.

## 9. Done criteria

RFC-0050 is "Done" when both of:

1. PR-1 (`connectors/`) and PR-2 (`cost/`) are merged. Each merged
   alone counts toward partial completion.
2. The re-export shims at `connector-status.ts` and `cost-dashboard.ts`
   have been removed in follow-up PRs after all callers migrated.
   Shims left in place forever defeat the ownership benefit.

If a future audit finds a sixth or seventh godfile that meets §3
criteria, that's an amendment to this RFC, not a new RFC.

## 10. Out of scope (cross-references)

- IA cleanup: RFC-0048.
- Dashboard surface telemetry: RFC-0049.
- Dashboard component file moves driven by *visual* design refresh:
  separate design RFC (post-IA).
- Any backend OCaml file split: separate RFC; this is dashboard-only.
