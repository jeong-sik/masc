# Dashboard v2 big-bang reskin — progress & plan

Branch: `feat/dashboard-v2-skin-bigbang` (worktree). Goal: 100% match the
keeper-v2 design prototype (icons, fonts, colors, margins, padding, weight),
SSOT CSS, production-grade, no stub/hardcode/silent-failure.

## Ground truth (prototype)
- Source: the keeper-v2 design prototype is now IN-REPO at
  `dashboard/prototypes/keeper-v2/` (v5 export, 2026-08-22) — `$KEEPER_V2_PROTO`
  indirection is no longer needed. The vendored SSOT copy of its CSS lives in
  `src/styles/keeper-v2/` (the in-repo source of truth for the skin).
- Standalone (rendered target): `Keeper Agent v5.html` from that directory —
  the `data-tone="tempered"` entry point, which is the tone the dashboard runs.
  Served locally (`?surface=<id>` deep-links) — e.g.
  `python3 -m http.server` inside `dashboard/prototypes/keeper-v2/`.
- **Measured, not eyeballed:** `docs/DESIGN-PARITY.md` describes the harness that
  renders the prototype's own DOM under the dashboard's stylesheets, so the SSIM
  between the two is skin drift with the data variable removed. It also carries
  the divergence ledger — every surface still short of parity, what holds it
  there, and what closing it would cost.
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
- [x] keepers chat header: CLOSED as written — the audit found the item stale in four
  places, so PR-6 pinned the divergences instead of executing it. Evidence:
  - `chat-head` is already dual-emitted (`keeper-workspace-chat.ts:385`), so the vendored
    skin already owns the header's shared properties.
  - The `.sub` row it asked to retarget to is **deliberately absent**: the guard test
    `keeps runtime scope/path out of the slim chat header`
    (`keeper-workspace-chat.test.ts:322`) asserts `.chat-head .sub .sub-ns` is null.
  - Adopting `.chat-id` would zero the desktop `min-width: 9rem` (prototype sets 0, and
    keeper-v2 loads later), undoing the documented flex-wrap overflow fix. `.name-row`
    is only defined as `.chat-id .name-row`, so it cannot be adopted independently.
  - "drop search/archive/trash" describes buttons that do not exist: there is no trash
    action, and Archive is the artifacts-panel *icon*. `search`/`turn`/`artifacts`/
    `detail`/`config` are wired operator capability (`workspaceUtilityCommands`,
    `keeper-workspace-chat.ts:98`); deleting them to match a static mock would be
    capability loss, not a reskin.
  Divergences now guarded by `styles/keeper-chat-header-divergence.test.ts`.

## Remaining deltas (adversarial, prioritized)
- [x] Keepers roster header: STALE as written — `keeper-workspace-roster.ts`
      already renders the compact `.roster-filters` + sort, and 2026-08-23 added
      the design's `.roster-head` search band below it (kit rule in v2.css).
- [x] Keepers roster rows: STALE as written — rows already show time +
      basepath + phase dot, and 2026-08-23 added the design's `.kp-sandbox` ⬡
      marker on `sandbox_profile === 'local'` rows.
- [x] Keepers ctx rail: structure aligned 2026-08-23 — the 컨텍스트 card now
      uses the design's `.ctx-usage` (마지막 턴 input / 창 크기) and the typed
      `.ctx-notobs` line. Documented divergences stand: 처리량 removed (#22681),
      컴팩션 스냅샷 purged (no backend writer, #29503), last-turn meter kept.
      Live in-flight ctx occupancy is still a marked data gap
      (keeper.context_ratio/tokens/max) — mark, don't fake.
- [ ] Keepers 4-col `.v2-body` grid (roster|chat|ctx) vs current single-column internal grid.
- [x] Keepers chat header actions: done 2026-08-23 — header + composer use the
      prototype's FSM_ACTIONS glyphs (⏸ ⏹ ▶ ↻ ⚙), dual-emitting `.act.icon`
      (mobile: `.chat-ovf` + `.chat-ovf-menu`). Two deliberate deviations:
      boot keeps ⏻ (keeper-action-panel.ts documents why boot must not share
      resume's ▶), and the utility commands keep their marks — wired operator
      capability the mock does not have.
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
  2026-08-23 update: the re-vendor restored the `.sch-decision` tone mapping
  and the three 720px rules (`.sch-cadsum` / `.sch-poll-list` / `.sch-ev-time`)
  — those are live-surface styling, not mock-only selectors. The mock
  operator-action selectors (.sch-act/.sch-reject/…) still have zero DOM
  consumers and stay unvendored.
- Still queued (separate PRs): v2.css (PR-2), surfaces.css (PR-3),
  fusion/runtime/keeper-config (PR-4), prompt-book (PR-4b), fleet + monitor.css
  vendoring + agent-roster ctx column (PR-5). PR-6 closed the chat-header item by
  guarding its divergences rather than retargeting — the instruction was stale.
  2026-08-23 update: the re-sync below closed the v2.css / surfaces.css /
  keeper-config.css / fleet.css vendoring items.

## v2-masc re-sync (2026-08-23)
The 2026-08-23 design drop (`~/Downloads/v2-masc`) was diffed against the
in-repo prototype: identical except two files, both synced in place —
`prompt-book-data.jsx` (the managed-assets families now list
`judge.catchup.md`) and `notes/grounding.md` (`moderation` recorded as a
hidden workspace section).

CSS re-vendor of the five drifted sheets (the other twelve diffed clean apart
from the repo's font-size tokenization):
- v2.css: dropped the local `.cmp-coverage*` block (the design never drew it),
  restored `.wk-kcard-goal` to the design's 10px (`var(--fs-10)`), and moved
  the `.wka-pulse` / `.wka-done-mark.*` / `.wk-lin-*` / `.wk-kcard-goal` rules
  out of the appended delta block into their design positions so the copy
  diffs clean against its source.
- surfaces.css: restored the design's `.ap-viewseg`/`.ap-viewbtn`/`.on` rule
  order, put `.ap-hist-dec.warn` back inline with its sibling tone rules, and
  restored `.bd-stateblock` rule order.
- schedule.css: see the note above.
- keeper-config.css: removed the duplicated `.kasm*` block and the dead
  `.kcf-tool-toggle` rules.
- fleet.css: adopted the design's responsive tiers (1320px → four tracks,
  720px → three). The live six-cell row (`.fl-runtime`) keeps its own tiers,
  moving to `v2-monitoring.css` under `.v2-monitoring-surface` — separate
  change, same split pattern as the base `--fl-cols`.

Component alignment landed in the same pass:
- `internal-agents-monitor.ts` rebuilt onto the design's `.ia-*`/`.ai-*`
  vocabulary (`.ia-head`, `.ia-count`, `.ia-badge`, `.ai-strip`, `.ai-table`),
  replacing the inline Tailwind assembly.
- approvals history: decider pills backed by the live `decision_source` field
  (HITL 수동 / Auto Judge / Always), `.ap-hist-reason` fed by the audit
  record's `decision_reason` (rendered only when the server recorded one —
  mark, don't fake), Auto Judge added to the summary stats.
- keepers roster: `.roster-head` search band and the `.kp-sandbox` glyph
  (see Remaining deltas above).
- chat header FSM glyphs + ctx rail `.ctx-usage`/`.ctx-notobs` (see Remaining
  deltas above).

## Notes
- Live data gaps (mark, don't fake): schedule/cron (no signal), context window
  (keeper.context_*), model (keeper.metrics_window.primary_model).
- KeeperPhase live enum == prototype FSM_STATES + Zombie.

## Deferred polish (after far surfaces)
- Keepers chat header: settled 2026-08-19 (see REMAINING above). keeper-workspace.css is
  not a mimic here — the surviving `.kw-chat-*` rules are the desktop min-width/flex-wrap
  overflow fix and the warn/bad/busy pill states the prototype does not have. The header
  already emits `chat-head` and already uses the shared Pill.
- Final cleanup PR: remove legacy keeper-workspace.css / *-v2.css / v2-shell.css once all
  surfaces emit prototype classes; run tsc/lint/tests.
