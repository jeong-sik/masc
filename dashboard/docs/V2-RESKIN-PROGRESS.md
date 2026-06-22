# Dashboard v2 big-bang reskin — progress & plan

Branch: `feat/dashboard-v2-skin-bigbang` (worktree). Goal: 100% match the
keeper-v2 design prototype (icons, fonts, colors, margins, padding, weight),
SSOT CSS, production-grade, no stub/hardcode/silent-failure.

## Ground truth (prototype)
- Source: keeper-v2 design prototype (jsx + `styles/`), provided out-of-repo by the
  designer. Point `$KEEPER_V2_PROTO` at its local checkout; the vendored SSOT copy of
  its CSS lives in `src/styles/keeper-v2/` (the in-repo source of truth for the skin).
- Standalone (rendered target): the `Keeper Agent v2 (standalone)` HTML from that
  prototype, served locally (`?surface=<id>` deep-links) — e.g.
  `python3 -m http.server` inside `$KEEPER_V2_PROTO`.
- Maps (transient investigation output, regenerable, not committed):
  proto-data-contract, proto-keepers-dom, proto-css-tokens, live-store-mapping,
  current-shell-inventory.

## Dev
- Worktree dev server: `pnpm dev` → http://localhost:5174/dashboard/ (proxies API to 8935 live backend).
- Live backend: 8935.

## Key realization
The dashboard was already ~80% migrated to keeper-v2 CSS class vocabulary
(.ov-*, .kp-row, .thread, .bubble, .ctx-*). It looked "far" only because of
drifted legacy *-v2.css + a cluttered Tailwind shell. Vendoring the prototype
CSS as SSOT + a clean prototype-DOM shell snapped most surfaces into place.
=> Strategy: surgical per-surface DOM alignment where close; rebuild where far.

## Done (verified in-browser)
- [x] Foundation (c480ecabb4): vendored 14 prototype CSS SSOT + new shell + v2 components.
- [x] Keepers roster (9b025cff2b) + context rail (4aa94fba8e) → prototype .roster/.kp-row/.ctx DOM.
- [x] Overview (ea93e8fed5): trimmed to prototype (dropped fleet grid + v1 rollup).
- [x] Schedule SHELL (1366bc3228): .ov.sch-surf header + KPIs. (panel still TODO)
- [x] v2 constants (ea579f312c): schedule-constants.ts, fusion-constants.ts.
- [x] 6 near-match surfaces (e69cae4254): approvals/board/connectors/logs/settings/workspace.

## Surface match landscape (audit)
DONE + verified in-browser (11 surfaces): overview, keepers (roster/rail/chat header),
approvals, board, connectors, logs, settings, workspace, schedule (shell+panel), code/IDE,
fusion. Far-surface rebuilds (schedule-panel, ide, fusion) landed cleanly.

REMAINING (reverted — rate-limited mid-rewrite, need careful redo):
- monitoring/Monitor (agent-roster.ts): fl-* row retarget worked, but the rebuild left a
  DUPLICATE "Keeper Fleet" header (shell SurfaceLead + a second header) + misplaced foot
  ticker + skeleton stat bars. Note: monitoring is in dashboard-shell's "no own header"
  list → SurfaceLead renders the title; a rebuild must NOT add a second top header.
- runtime-editor (runtime-environment-editor.ts + runtime-toml-editor.ts): structure good
  (.rt-nav sections switch, .rt-lane/.rt-card), but EMBEDDED in settings narrower than the
  prototype full surface → .rt-lane flex (label-l flex:1 + wide .rt-select control) squeezes
  the label to ~50px → vertical text wrap. Fix: full-width embed and/or cap .rt-select and/or
  stack .rt-lane label-above-control when narrow.
- mobile bottom tab bar (.v2-nav.is-mnav) in nav-rail-v2.ts (desktop-only so far).
- keepers chat thread/composer (KeeperConversationPanel, board-shared) still .kw-*.

## Remaining deltas (adversarial, prioritized)
- [ ] Keepers roster header: current = verbose stat grid (12/9/0/3) + chips;
      prototype = compact `.roster-filters` (전체/실행/주의 + search icon + sort).
- [ ] Keepers roster rows: show time + basepath + phase dot (proto) vs "최근 활동"+summary.
- [ ] Keepers ctx rail: prototype = 처리량/런타임/컨텍스트(window bar + 지금 컴팩트 +
      컴팩션 스냅샷 + 메모리 보기)/소유 태스크. Current has "운영 상세" link + "윈도우 사용률 미수신"
      (live ctx window data gap — keeper.context_ratio/tokens/max).
- [ ] Keepers 4-col `.v2-body` grid (roster|chat|ctx) vs current single-column internal grid.
- [ ] Keepers chat header actions = FSM_ACTIONS glyphs (⏸◉⇄■⚙).
- [ ] Per-surface audit: overview (도메인 현황 cards), board, schedule, runtime,
      monitor, approvals, work, logs, ide, connectors, settings.
- [ ] Mobile bottom tab bar (.v2-nav.is-mnav) + more-sheet.
- [ ] Stray focus-mode toggle bottom-left on non-primary surfaces.
- [ ] Final cleanup PR: remove legacy *-v2.css / v2-shell.css / app-shell-v2.css once surfaces migrated.

## Notes
- Live data gaps (mark, don't fake): schedule/cron (no signal), context window
  (keeper.context_*), model (keeper.metrics_window.primary_model).
- KeeperPhase live enum == prototype FSM_STATES + Zombie.

## Deferred polish (after far surfaces)
- Keepers chat (keeper-workspace-chat.ts) still uses .kw-chat-* classes (styled by
  keeper-workspace.css mimic, not SSOT). Retarget header → .chat-head/.name-row/.sub/
  .chat-actions + Pill, and reduce actions to prototype FSM glyphs + ⚙ (drop
  search/archive/trash) — needs WorkspaceCommandButtons changes too. Visually ~95% already.
- Final cleanup PR: remove legacy keeper-workspace.css / *-v2.css / v2-shell.css once all
  surfaces emit prototype classes; run tsc/lint/tests.
