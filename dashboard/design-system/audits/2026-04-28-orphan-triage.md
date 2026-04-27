# Orphan Triage — Phase 1 supplement (2026-04-28)

Re-classification of the 7 "orphan" CSS files flagged by Phase 0 (PR #11300, audit `2026-04-28-production-css-drift.md`) before Phase 1 preview-gallery dispatch (W05, W06, W07, W08, W09, W13, W14).

Phase 0 brief: *"7 of 19 files are orphans (no `import` reference in any .ts/.tsx/.jsx/.html)."*

## TL;DR

| Classification | Count | Files |
|---|---|---|
| **live** | 7 | all of them |
| **dead** | 0 | — |
| **zombie** | 0 | — |

**Phase 0 false negative root cause**: the orphan check used `rg -g '!*.css'`, which excluded `.css` files from the search and therefore missed the `@import` cascade through `dashboard/src/styles/global.css`. All 7 files are imported into `global.css`, which is itself imported by `dashboard/src/main.ts:1` (`import './styles/global.css'`). They reach the runtime through one indirection — they are not orphans.

Recommendation: proceed with all 7 workstreams as planned, but Phase 1 supervisor should treat the Phase 0 orphan column as invalid and re-derive liveness from `global.css @import` chain.

## Methodology

For each candidate file:

1. `rg -l "<basename>\.css"` across `.ts/.tsx/.js/.jsx/.html/.css/.toml/.json/.ml` — direct + cascade imports.
2. `rg "@import.*<basename>" dashboard/src/` — cascade specifically.
3. `rg -c "<distinctive-class>" dashboard/src/components/ dashboard/src/pages/` — at least one usage in TSX/TS code.
4. `git log --oneline -5 -- <file>` — recency check (60d threshold for stale).

## Per-file table

| File | LOC | basename rg hits | className uses (sample) | Last commit | Classification | Recommendation |
|---|---|---|---|---|---|---|
| `chat.css` | 85 | `main.ts`, `global.css` (@import), self | `chat-bubble` 2× in `components/chat/primitives.ts` | `44104a2192` 2026-04 (#11095) | **live** | W05 dispatch as planned |
| `pipeline.css` | 97 | `global.css` (@import), self | `pipeline-stage*` 11× across `keeper-pipeline-stage.ts`, `keeper-detail.ts`, `agent-monitor/runtime-strip.ts` | `75f43bb12a` recent (#8443) | **live** | W06 dispatch as planned |
| `live-monitor.css` | 55 | `global.css` (@import), self | `pulse-bubble`/`pulse-working` 2× in `components/live/pulse-strip.ts` | `44104a2192` 2026-04 (#11095) | **live** | W07 dispatch as planned |
| `keeper-detail.css` | 16 | `global.css` (@import), self | `keeper-detail*` 5+ across `components/keeper-detail-*`, `goals/task-activity-list.ts`, `keeper-supervisor-diagnostics.ts` | `f556558363` (#6187) | **live** | W08 dispatch as planned (but only 16 LOC — small preview) |
| `pixel-avatar.css` | 112 | `global.css` (@import), self | `pixel-avatar` 9× in `components/overview/agent-avatar.ts` | `44104a2192` 2026-04 (#11095) | **live** | W09 dispatch as planned |
| `responsive.css` | 81 | `global.css` (@import), `variables.css`, self | `@media` rules — no className grep needed (tag/state selectors) | `44f2109186` (#8421) | **live** | W13 dispatch as planned (responsive is media-query orchestration, preview must include viewport variants) |
| `a11y.css` | 99 | `global.css` (@import), `keyframes.css`, `focusable.ts`, `motion.ts` | imported as comment cross-reference in `focusable.ts`, `motion.ts`; `prefers-reduced-motion`/`focus-visible` rules | `f9b7ce3465` 2026-04 (#11224) | **live** | W14 dispatch as planned |

## Evidence — global.css cascade

```
$ rg "^@import" dashboard/src/styles/global.css
@import "tailwindcss";
@import "./tokens.generated.css";
@import "./variables.css";
@import "./base.css";
@import "./keyframes.css";
@import "./board.css";
@import "./chat.css";
@import "./dashboard.css";
@import "./governance.css";
@import "./governance-agent.css";
@import "./keeper-detail.css";
@import "./live-monitor.css";
@import "./ops.css";
@import "./pipeline.css";
@import "./pixel-avatar.css";
@import "./tools.css";
@import "./ui.css";
@import "./responsive.css";
@import "./a11y.css";  /* after feature styles so reduced-motion overrides win */
```

```
$ rg "global\.css" dashboard/src/main.ts
dashboard/src/main.ts:1:import './styles/global.css'
```

Cascade: `main.ts → global.css → {chat, pipeline, live-monitor, keeper-detail, pixel-avatar, responsive, a11y}.css`. Every one of the 7 reaches runtime.

Tailwind v4 `@utility` syntax: 5 of 7 files (chat, pipeline, live-monitor, keeper-detail, pixel-avatar) declare Tailwind v4 `@utility` blocks. A `^\.` selector grep returns 0 hits for those, which can also mislead a naive "no selectors → dead" heuristic. The utilities are referenced by class name in TSX, not by traditional `.foo` rules.

## Phase 1 dispatch recommendation table

| Workstream | File | Classification | Mode | Notes |
|---|---|---|---|---|
| W05 | `chat.css` | live | preview gallery (chat-bubble user/assistant/system/error variants + chat-transcript + role-chip + detail-callout) | 4 bubble variants + transcript surface |
| W06 | `pipeline.css` | live | preview gallery (pipeline-stage-node × {idle, thinking, tool_use, error, success} active states) | OAS pipeline visual — 5 active states from selectors |
| W07 | `live-monitor.css` | live | preview gallery (pulse-bubble × {default, working, selected} states) | 3 pulse variants |
| W08 | `keeper-detail.css` | live | preview gallery (overlay + content frame) | small surface (16 LOC) — 1 overlay pattern |
| W09 | `pixel-avatar.css` | live | preview gallery (pixel-avatar × {active, working, busy, idle, listening} status) | 5 status variants |
| W13 | `responsive.css` | live | preview gallery with viewport switcher (sm/md/lg breakpoints applied to existing patterns) | media-query orchestration — preview needs viewport sizing controls, not a static page |
| W14 | `a11y.css` | live | preview gallery with `prefers-reduced-motion` toggle + focus-visible demo | requires interactive toggle for reduced-motion media query |

## Phase 0 audit correction request

The Phase 0 audit (`dashboard/design-system/audits/2026-04-28-production-css-drift.md`) marks these 7 files as orphans. That column is incorrect. The Phase 0 reviewer's reproduction recipe explicitly used `rg -g '!*.css'`, which guaranteed the false negative. A follow-up note or PR-comment correction on #11300 is recommended so downstream Phase 1 work does not propagate the wrong claim.

The dead-code workstream Phase 0 implicitly proposed (delete vs preview) collapses to zero files — no W## should switch to a "DELETE recommendation" PR title.
