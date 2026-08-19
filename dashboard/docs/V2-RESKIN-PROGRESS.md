# Dashboard v2 big-bang reskin — progress & plan

Branch: `feat/dashboard-v2-skin-bigbang` (worktree). Goal: 100% match the
keeper-v2 design prototype (icons, fonts, colors, margins, padding, weight),
SSOT CSS, production-grade, no stub/hardcode/silent-failure.

## Ground truth (prototype)
- Source: the keeper-v2 design prototype is now IN-REPO at
  `dashboard/prototypes/keeper-v2/` (v3 export, #29046) — `$KEEPER_V2_PROTO`
  indirection is no longer needed. The vendored SSOT copy of its CSS lives in
  `src/styles/keeper-v2/` (the in-repo source of truth for the skin).
- Standalone (rendered target): `Keeper Agent v3.html` from that directory,
  served locally (`?surface=<id>` deep-links) — e.g.
  `python3 -m http.server` inside `dashboard/prototypes/keeper-v2/`.
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

REMAINING (re-audited 2026-08-19 against the tree — three of four were stale):
- [x] monitoring duplicate header: RESOLVED in-tree. `status.ts:105-117` skips the
  SurfaceHeader for `section === 'agents'`; `agent-roster.ts` `.fl-top` owns the header
  alone, and `monitoring` sits in dashboard-shell's SURFACE_OWN_LEAD_IDS.
- [x] runtime-editor embed squeeze: RESOLVED in-tree. `keeper-v2/runtime.css` carries the
  local contract (`.rt-lane` flex-wrap + `.rt-select` max-width 320px), documented at
  `runtime-environment-editor.ts:498`. Browser re-verify only.
- [x] mobile bottom tab bar: SHIPPED. `.v2-nav.is-mnav` + more-sheet in
  `nav-rail-v2.ts:124`, guarded by `mobile-bottom-reserve.test.ts`.
- [ ] keepers chat thread/composer (KeeperConversationPanel, keeper-shared) still .kw-* —
  the one real remaining rework (see Deferred polish; planned as v3-delta PR-6).

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
- [x] Mobile bottom tab bar (.v2-nav.is-mnav) + more-sheet — shipped (see above).
- [ ] Stray focus-mode toggle bottom-left on non-primary surfaces.
- [ ] Final cleanup PR: remove legacy *-v2.css / v2-shell.css / app-shell-v2.css once surfaces migrated.

## v3 delta sync (2026-08-19, prototype #29046)
The in-repo prototype is the v3 export; the vendored CSS was v2-era plus local
evolution. Per-file disposition of the v2→v3 delta (base `2782405bc3`):
- craft.css: adopted the v3 desktop `--pad-surface` horizontal tightening
  (42→30 / 26→18 / 18→14); the local ≤900px media-query tiers stay.
- memory.css: adopted `.mem-ttl` (salience-bar replacement, RFC-0247) and
  `.mem-retain*` (retention notice) — mirrored into memory-inspector-v2.css per
  that file's SYNC CONTRACT. Everything else was already pre-applied.
- colors_and_type.css: NO-OP — the whole v3 delta is the local-ttf @font-face
  block, superseded by the dashboard font policy (fonts.css owns fonts).
- schedule.css / logs.css: VERIFIED, kept as-is. logs has zero missing
  selectors; schedule's 36 v3-only selectors (.sch-act/.sch-risk/.sch-decision/
  .sch-reject/…) have zero DOM consumers — the surface renders real projection
  data with shared ActionButton/StatusChip instead of the prototype's mock
  operator actions (mark-don't-fake), so the dead selectors are not vendored.
- Still queued (separate PRs): v2.css (PR-2), surfaces.css (PR-3),
  fusion/runtime/keeper-config (PR-4), prompt-book (PR-4b), fleet + monitor.css
  vendoring + agent-roster ctx column (PR-5), chat .kw-* retarget (PR-6).

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
