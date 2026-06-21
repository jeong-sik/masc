# Keeper v2 Standalone Gap Snapshot

Source reviewed: `/Users/dancer/Downloads/Keeper Agent v2 (standalone) (1).html`.

Current implementation surface: `dashboard/src` on branch `codex/keeper-v2-schedule-cards-20260621`.

Extraction note: the standalone file is a bundled HTML shell. Its `__bundler/template`
and gzip/base64 resource manifest expose prototype modules including `WorkSurface`,
`BoardSurface`, `FusionSurface`, `ConnectorsSurface`, `SettingsSurface`,
`RuntimeEditor`, `IdeSurface`, `FleetSurface`, `Composer`, `CopilotDock`,
`ApprovalsSurface`, and `ScheduleSurface`.

## Exists In Current Page

- Top-level dashboard routes already exist for Overview, Work, Keepers, Board,
  Schedule, Approvals, Fusion, IDE, Connectors, Settings, and Logs.
- Runtime TOML editing is already represented by `dashboard/src/components/runtime-toml-editor.ts`
  and is backed by the dashboard runtime config API rather than prototype globals.
- Approvals are already represented by `dashboard/src/components/approvals/approvals-surface.ts`
  and use the live approval queue API.
- Schedule automation data is already exposed by `/api/v1/dashboard/tools` as
  `scheduled_automation` with request rows, derived counts, execution readiness,
  keeper next action/tool, approval policy, payload metadata, and last execution.
- The Tools surface already hosts the schedule automation projection under
  `예약 자동화 FSM`.

## Implemented In Current Worktree

- `dashboard/src/components/tools/scheduled-automation-panel.ts` now renders the
  schedule projection as v2 cards instead of a wide table.
- Schedule cards expose effective status, raw status drift, readiness, operator
  posture, risk, approval policy, recurrence, due time, source, keeper next step,
  payload, payload digest, separate-human-grant marker, and last execution.
- The schedule panel now has local read-only filters for all, pending, due,
  ready, scheduled, and done states.
- The schedule panel now has a selected-detail side panel, matching the prototype
  detail concept without opening an overlay or adding fake mutations.
- The wake signal area now preserves a due-ordered feed across all requests even
  when the card list is filtered.
- The selected-detail panel now renders schedule actor and timing metadata:
  requested by, scheduled by, requested time, due time, and expiration time.
- The selected-detail panel now renders bounded `last_execution.detail` rows
  when present, collapsing nested JSON to object/array counts instead of
  dumping raw execution JSON into the card list.
- `/api/v1/dashboard/tools` now includes bounded durable schedule runner
  signals from `Schedule_runner.read_recent_signals`, and the panel prefers that
  feed over the request-derived fallback when signals are present.
- The durable wake signal feed now uses a compact standalone-like row structure:
  `at`, kind, schedule id, secondary signal/payload evidence, and right-aligned
  risk. Schedule ids in that read-only feed select the existing schedule detail
  panel instead of creating mutation controls.
- `dashboard/src/components/board/composer-v2.ts` now exposes the live compose
  envelope as explicit mode, target, media, and delivery command groups before
  send, matching the standalone Composer's tighter command grouping while still
  using the existing broadcast and keeper-message transports.
- Composer attachment drafts now keep and display MIME metadata in the local
  tray so binary/file context is visible before dispatch without inventing a
  new upload API or changing the current text-transport serialization.
- `dashboard/src/components/copilot-dock.ts` now sends and renders richer
  co-view context for Overview, Keepers, Board, Schedule, Approvals, Fusion,
  Settings, and focused keeper routes using only the existing router and keeper
  store. The Keepers route now uses the selected dock/route keeper as a backed
  1:1 context card and keeps the fleet summary as the no-selection fallback.
- CopilotDock now uses route-specific starter prompts for Overview, Keepers,
  Board, Schedule, Approvals, Fusion, IDE, Connectors, Settings, and Logs
  instead of a single generic starter set.
- The floating Copilot FAB is now suppressed on the Keepers surface, where the
  primary route already owns a chat workspace, while the top-bar Chat control
  remains available.
- CopilotDock now forces a full-width docked panel on mobile viewports even when
  a desktop session persisted `mode: float`, and hides the float/dock mode
  toggle in that mobile sheet so the chat cannot open as an off-screen narrow
  floating panel.
- The mobile shell now propagates the keeper workspace pane as `data-mpane` and
  hides the bottom navigation only while the chat pane is active. Returning to
  the keeper roster restores bottom navigation and reserves safe-area space so
  roster content clears the fixed tab bar.
- `dashboard/src/components/approvals/approvals-surface.ts` now renders a
  selected request dossier beside the live approval queue, using only
  `KeeperApprovalQueueItem` fields such as keeper, tool, risk, waiting time,
  task/goal refs, runtime contract, disposition, rule match, and input preview.
- Approvals mobile layout now moves the same backed selected request dossier
  inline directly after the selected queue card at the existing responsive
  breakpoint, while desktop keeps the right-side detail rail. No new approval
  mutations or local-only history state were added.
- Approvals was audited against the standalone `ApprovalsSurface` route states.
  The current backed route keeps the live decision set to approve,
  approve-with-rule, and reject; defer/undo/history remain absent because there
  is no endpoint for those prototype flows. The selected-model row stays hidden
  until the backend stops redacting approval queue `selected_model` as `null`.
- `dashboard/src/components/keeper-workspace/keeper-workspace-roster.ts` now
  renders a read-only fleet summary band above the keeper roster, using the
  live `keepers` store to show total, running, paused, offline, attention,
  approval-gate, and high-context counts before row scanning.
- `dashboard/src/components/schedule/schedule-surface.ts` now exposes a
  dedicated top-level `#/schedule` surface. It reuses the backed
  `ScheduledAutomationPanel`, adds projection summary KPIs and a refresh
  affordance, and keeps schedule mutation controls absent until a real API is
  available.
- The dedicated `#/schedule` KPI strip now uses the standalone's direct
  pending, due, scheduled, and running labels. Pending/scheduled/running are
  derived from existing schedule status counts or request rows; due continues
  to use the backend's `derived_counts.due_effective`.
- Schedule card/detail copy and the dedicated schedule metadata row now use
  operator-facing Korean labels for filters, card fields, detail rows,
  fallback/empty states, source/signal/generated metadata, and request-derived
  wake-feed explanation while preserving raw backend enum values in chips and
  detail values.
- The route/nav shell now treats Schedule as a primary sectionless surface with
  its own nav icon, lazy route, bespoke header, canonical hash behavior, and
  Copilot co-view label.
- `dashboard/src/components/work.ts` now exposes the standalone Goal Store's
  WIP, verification-waiting, and claimable-backlog signals as first-class KPIs
  derived from the live `tasks` store. The unassigned section labels how many
  no-goal rows are claimable, but does not add the standalone's local-only claim
  mutation.
- Work now exposes a route-selected read-only task dossier at
  `#workspace?section=work&task=...`. Job rows get a small detail affordance
  that writes the existing `task` route param; the dossier reads live
  task/goal/keeper fields, contract evidence, gate state, handoff notes, and
  execution links from the hydrated stores. Awaiting-verification tasks route
  to the backed Verification panel, while local claim/approve mutation controls
  remain absent.
- Work no longer exposes the standalone's local-only `＋ 새 목표` placeholder
  in the header. The header action now opens the existing backed Planning /
  Plans & Goals surface at `#workspace?section=planning` until a durable
  create-goal mutation contract exists.
- Connectors were audited against the standalone `ConnectorsSurface`. The
  current backed route already exposes a gate status strip, four connector
  cards, recent audit log, operations rollup, overview strip, live detail panel,
  keeper matrix, paths strip, and gate analytics from `/api/v1/gate/*` data.
  No duplicate prototype-only connector strip was added.
- `dashboard/src/components/connector-status.ts` now removes connector mutation
  affordances that had no durable backend contract: the placeholder Add
  connector buttons, the drawer's local-only gate enablement toggle, bot/reply
  mode drafts, binding add/delete/direction editor, token reissue placeholder,
  and connection-test placeholder. The drawer now shows read-only live state
  from `/api/v1/gate/connectors` while keeping the real sidecar schema/config
  form backed by `/api/v1/sidecar/*`.
- Connector channel-to-keeper binding rows now behave like the standalone's
  keeper handoff affordance while staying read-only: backed
  `configured_bindings` rows render as keyboard/clickable links to the existing
  keeper conversation route (`#keepers?keeper=...`) instead of inert text.
- Connector sub-states are now route-addressable through a compact route
  switcher. Valid `#connectors?section=connector-status&connector=...` hashes
  for Discord, iMessage, Slack, and Telegram select the corresponding
  backed connector panel; invalid connector ids are stripped from canonical
  route params; the `All` scope remains
  `#connectors?section=connector-status`.
- `dashboard/src/components/fusion/fusion-surface.ts` now renders structured
  judge evidence from existing fusion board metadata: consensus, contradictions,
  partial coverage, unique insights, blind spots, missing inputs, and
  recommendation. The existing synthesis and resolved-answer rendering remains
  the fallback for older/simple metadata.
- Fusion was re-audited against live metadata. The current route has two backed
  sources only: board posts with `meta.source = "fusion"` or
  `meta.fusion_deliberation`, and `/api/v1/dashboard/fusion-runs` registry
  status. `dashboard/src/components/fusion/fusion-runs-panel.ts` now renders a
  compact registry-backed pipeline strip per run: keeper turn, registry,
  panel/judge, and sink. The strip derives only from the closed live status enum
  (`running`, `completed`, `failed`) so it does not invent denied-path detail,
  per-model panel counts, or sink evidence that the registry does not expose.
  The Fusion route now reads board-sink evidence through a dedicated
  `fusionBoardPosts` signal and `refreshFusionBoard()` fetcher, so Board-route
  filters such as `exclude_system=true` cannot hide live Fusion sink posts from
  the Fusion audit surface. The route now also reconciles the two backed Fusion
  sources in a read-only `Registry ↔ board sink` lane, separating matched rows,
  registry-only in-progress/recent rows, and board-sink-only rows without
  inventing missing panel/judge detail. Live runtime currently exposes
  board-sink fusion posts but zero active registry rows, so denied-path detail
  and richer sink/wake tracks remain deferred instead of copied as fixture UI.
- Keeper chat Fusion cards now expose read-only route actions back to the
  backed Fusion run view and source Board post. The card still lazy-fetches
  panel/judge detail only when expanded, so route clicks do not invent local
  state or trigger the evidence fetch.
- Keeper chat Fusion cards now share the Board evidence path's Fusion failure
  normalization for `reason_detail`, legacy `Fusion_types.*` constructor
  strings, provider attribution, and judge `error` fallback, so live/legacy
  board-sink metadata is not rendered as raw backend internals in chat.
- Board was audited against the standalone `BoardSurface`. The current backed
  route already has hearth/sub-board rail, feed filters, post/thread detail,
  mention inbox, state blocks, reactions/votes, comments, and composer modes.
  `dashboard/src/components/board/board-surface.ts` now also fixes the desktop
  mention queue badge to count explicit mention messages from the live
  `messages` store instead of reusing `boardPosts.length`; this matches the
  standalone queue semantics and the current mobile queue.
- Board mobile master-detail panels now reserve the app shell's fixed bottom
  tab-bar clearance for both thread detail and mention inbox detail overlays,
  preventing the detail panels from sitting underneath the mobile navigation
  while leaving the desktop right-rail layout unchanged.
- `dashboard/src/components/board/board-surface.ts` now exposes a
  keyboard-accessible Board detail rail resize separator. The right rail width
  is clamped to 290-520px, persisted in `localStorage` as a per-user UI
  preference, applied through `--bd-detail-width`, and hidden by the existing
  responsive breakpoint so mobile overlays keep their backed responsive width.
- IDE was audited against the standalone `IdeSurface`. The current backed route
  already has repository selection/scanning, workspace file tree, source,
  unified, split-diff, and blame views, current-file find, breadcrumbs,
  presence/cursor overlays, annotation/layer chips, activity/bridge-event
  ingestion, context/conversation panels, and streamed Execute output.
- `dashboard/src/components/ide/ide-shell.ts` now makes the right rail's
  Context, Activity, and Cursors tabs functional instead of inert labels. The
  new Cursors tab reads the existing `cursorOverlaySignal` from the durable IDE
  cursor stream and renders active file, collision summary, keeper focus mode,
  tool, turn, path/line/selection, age, and a Focus action that writes the
  normal IDE context focus anchor.
- `dashboard/src/components/ide/ide-shell.ts` now exposes a keyboard-accessible
  file-tree resize separator. The tree width is clamped to 180-360px, persisted
  in `localStorage` as a per-user UI preference, applied to the IDE grid through
  `--ide-tree-width`, and still hidden by the existing mobile breakpoint.
- Settings was audited against the standalone `SettingsSurface` and
  `RuntimeEditor`. The standalone runtime-management section opens a local
  provider/model/binding editor; current Settings now routes `런타임 관리` to
  the existing `RuntimeTomlEditor`, backed by `/api/v1/runtime/config/raw`, and
  removes the fake local runtime target cards from that section.
- Settings now marks non-runtime sections as `preview only`, marks runtime
  management as `runtime.toml live-backed`, and removes unsupported local
  mutation affordances from the prototype shell: global `Save changes`, account
  `Reissue`/`Log out`, fake endpoint verification timers, and `＋ Add gate`.
  The remaining prototype controls are now locked/read-only until individual
  Settings APIs exist: toggles, segmented controls, steppers, and sliders are
  disabled, preview text values are read-only, account token reveal is removed,
  the logs filter remains local view-only, and the Connectors link remains an
  enabled navigation affordance.
- Settings section nav is now route-addressable without adding a secondary
  sidebar: valid hashes such as `#settings?section=logs` and
  `#settings?section=runtimes` select the matching Settings section, invalid
  section ids fall back to the default account view, and account remains the
  canonical `#settings` route.
- Logs was audited as a current-dashboard live surface rather than a standalone
  fixture import. The route keeps `/api/v1/dashboard/logs` as the primary event
  stream, exposes stable row/filter selectors for verification, and moves
  provider-log tail output behind an explicit collapsed `Provider diagnostics`
  disclosure whenever `/api/v1/dashboard/provider-logs` has configured
  providers, so operational support logs do not sit above the primary stream by
  default.
- Keepers/Fleet was audited route-by-route against the standalone `FleetSurface`
  rhythm. The current backed route already renders the live fleet summary band,
  compact roster, selected conversation, lifecycle/utility command bar, context
  rail, mobile context drawer, mobile roster/chat master-detail transition, and
  full 운영 상세 state without copying standalone-only fixture controls.
- Memory inspector was audited against the standalone memory-inspector section.
  Lab now exposes the backed `MemorySubsystems` view as
  `#lab?section=memory-subsystems`, with `focus` route params passed through
  for public episode/user-model/Hebbian inspection and the existing sensitive
  `focus=entries` gate preserved. No pinned-fact editor, local store
  composition controls, or fake recall timeline was copied because
  `include_memory_entries=true` is still auth-gated and those prototype
  controls do not have a durable dashboard API contract.
- The previous Lab `Memory Explore` tab, which composed the memory graph/dossier
  primitives over hard-coded sample data, is removed from visible navigation.
  Legacy `#lab?section=memory-explore` hashes now normalize to the backed
  `#lab?section=memory-subsystems` route while preserving useful focus params.
- The previous Lab `Design Canvas` tab, which rendered keeper-v2 prototype
  fixture data rather than live dashboard state, is removed from visible
  navigation. Legacy `#lab?section=design-canvas` hashes now normalize to the
  backed Lab tools inventory at `#lab?section=tools`.
- Focused tests cover card rendering, filters, detail selection, and the absence
  of prototype-only approve/reject/cancel mutation controls. Composer tests
  cover the command envelope, attachment MIME display, existing send transport,
  and the unchanged attachment-only text transport. Copilot tests cover backed
  Keepers context, normalized field tone classes, stream surface-context
  posting, the FAB visibility predicate, and the keeper mobile roster/chat pane
  bottom-nav contract. Approvals tests cover live queue field binding, selected
  dossier switching, inline mobile dossier placement, approve routing, empty
  state, and absence of prototype-only defer/undo/history controls. Keeper
  roster tests cover fleet-wide summary
  counts, search/filter independence, and the absence of local-only fleet
  mutation semantics in the summary helper. Schedule route tests cover primary
  route exposure, hash canonicalization, projection loading/error handling,
  backed card reuse, and continued absence of local-only schedule mutations.
  Board tests cover mention queue counts, mobile detail clearance, and desktop
  detail rail width normalization, hydration, pointer/keyboard resizing, and
  persistence.
  IDE shell tests cover default context rail rendering, Activity tab switching,
  Cursors tab rendering from stream-shaped cursor overlay data, and cursor
  Focus writing `ideContextFocus`.

## Still Missing Vs Prototype

- The standalone detail overlay includes approve/reject/cancel buttons and
  post-action banners. Current implementation intentionally omits these because
  no schedule mutation callback/API contract is wired into this panel.
- The standalone Approvals surface includes prototype affordances such as
  defer/undo/history-like operator flow. Current live approvals surface has a
  backed selected-detail rail, mobile inline selected-detail placement, and
  rendered empty-state validation, but remains intentionally limited to
  backend-supported approval/rejection semantics.
- The standalone Settings surface is a broad local operator console. Current
  Settings now has a backed runtime.toml editor under `런타임 관리`, explicit
  preview-only guardrails elsewhere, and route-addressable sub-states for the
  existing sections. Other controls should stay locked/read-only until a
  per-control API contract, permission model, persistence/error state, and
  tests exist.
- The standalone Composer/Copilot flow still has richer microphone/STT
  affordances than the current dashboard. Board/ops Composer now covers command
  grouping and visible binary attachment metadata, and CopilotDock now covers
  backed co-view context, route-specific starters, selected-keeper Keepers
  context, Keepers FAB suppression, and mobile full-width dock fallback for
  persisted desktop floating state. Voice/STT should not be copied until there
  is a real audio capture/transcription/send contract.
- The standalone mobile pane/chrome behavior is now normalized for the
  Keepers/keeper chat workspace (`data-mpane`, chat-pane bottom-nav hiding, and
  roster safe-area padding), Board's mobile thread/mention detail overlays, and
  Approvals' mobile selected-detail dossier. Other master-detail routes still
  need the same route-by-route check before claiming global mobile parity.
- Fusion still has prototype-only presentation not copied yet: denied-path
  detail, per-model running detail, and richer sink/wake tracks. The registry
  pipeline strip and source reconciliation lane are backed by
  `/api/v1/dashboard/fusion-runs` plus board-sink Fusion posts from the
  unfiltered recent board fetch. Current live runtime has fusion board posts
  but zero live registry rows, and the remaining richer paths should still wait
  for consistent backend metadata fields before becoming durable dashboard
  claims.
- Connectors now has a first-pass audit and no longer exposes the unsupported
  drawer/toolbar placeholder mutations, backed binding rows can route to the
  linked keeper conversation, and connector scopes are route-addressable through
  valid `connector` params. Remaining parity should stay limited to backed
  connector lifecycle, binding, and sidecar config contracts; do not add
  connector catalog/create, token rotation, reply-mode editing, or connection
  test UI until those APIs exist.
- Board now has a first-pass audit, a fixed mention queue count, mobile
  bottom-nav clearance for thread/mention detail overlays, and persisted
  desktop detail rail resizing. Remaining standalone Board differences are
  mostly prototype/local presentation details such as local-only reaction
  toggles and other fixture-only Board chrome; do not copy them over existing
  backend-backed vote/reaction/comment contracts.
- IDE now has a first-pass audit and a functional right-rail tab fix. Remaining
  standalone IDE differences are mostly prototype/local presentation details:
  fixture Git origin copy/GitHub link chrome, static sample code/diff rows, and
  local-only fake PR/tool/turn/output events. Current IDE should keep using
  repository metadata, workspace diff rows, activity/bridge-event APIs, cursor
  stream state, and Execute output stream rather than importing fixture globals.
- Logs now has a first-pass audit. Remaining Logs work should stay constrained
  to live `/api/v1/dashboard/logs` and `/api/v1/dashboard/provider-logs`
  contracts; do not add synthetic provider tails, static log fixtures, or
  local-only remediation controls above the primary event stream.
- The standalone memory inspector still has prototype-only pinned facts, store
  composition, scope toggles, and recall timeline controls. Current coverage is
  intentionally limited to the backed Memory OS projections
  (episodes/user-model/Hebbian) and the existing sensitive entries path; local
  pin/forget/store controls should wait for an API, permission model, and audit
  trail. The old sample-backed Lab `Memory Explore` composition is collapsed
  into Memory OS instead of remaining as a parallel fixture surface.

## Should Disappear Or Collapse

- Do not import the standalone's bundled base64/gzip assets or global
  `window.*` fixture data into production dashboard code.
- Do not keep visible Lab tabs that are only static keeper-v2 fixture previews
  when a backed operational route exists. Legacy fixture-preview hashes should
  collapse into backed Lab routes instead.
- Do not add schedule approve/reject/cancel buttons until the dashboard has a
  real schedule mutation API, permission checks, error states, and tests.
- Do not duplicate the schedule projection as both a table and cards in the same
  primary view. The table can stay gone for this v2 schedule path.
- Do not add the standalone Work surface's local optimistic `keeper_task_claim`
  button until a real claim API, permission model, and error path are wired.
  The Work task dossier is intentionally read-only and should stay that way
  until those backend contracts exist.
- Do not show local-only Work goal creation placeholders. Route users to the
  backed Planning / Plans & Goals surface until create-goal permissions,
  validation, persistence, and error handling are wired end to end.
- Do not regress live-backed approvals/runtime/settings surfaces into local-only
  prototype state where a backend contract already exists.
- Do not reintroduce noisy duplicate shell headers around prototype primary
  surfaces; the surface itself should own its main header.
- Do not let old operational diagnostics move above prototype-first content
  unless the diagnostic lane is explicitly selected.

## Next Candidate Slices

1. Schedule mutation design slice: only after the real API is available, add
   approve/reject/cancel controls with permission gating, loading/error states,
   and adversarial tests that prevent fake optimistic completion.
2. CopilotDock multimodal design slice: only after a real audio capture or
   transcription/send contract exists, add voice draft/STT controls with
   loading/error states and tests that prove the transcript is not fixture data.
3. Route-by-route parity audit: remaining Fusion sub-states should get the
   same missing-vs-collapse pass before copying more prototype UI. Connector
   lifecycle/config follow-ups should wait for backed API contracts.
4. Approvals mutation/history design slice: only after real defer, undo, or
   resolved-history endpoints exist, add those controls with permission gating,
   loading/error states, and tests that prove they do not mutate local-only
   fixture state.

## Verification Evidence For Current Worktree

- Focused Vitest: `src/components/tools/scheduled-automation-panel.test.ts`
  and `src/components/tools/tools-main.test.ts` pass, including bounded
  execution-detail rendering and durable signal feed preference.
- Schedule route Vitest: `src/config/navigation.test.ts`, `src/router.test.ts`,
  `src/components/schedule/schedule-surface.test.ts`, `src/components/tools/scheduled-automation-panel.test.ts`,
  `src/components/tools/tools-main.test.ts`, and `src/components/copilot-dock.test.ts`
  pass together (113 tests), covering primary route exposure, hash
  canonicalization, backed schedule card reuse, and Copilot route labeling.
- Schedule KPI copy Vitest after direct pending/due/scheduled/running labels:
  `src/components/schedule/schedule-surface.test.ts`,
  `src/components/tools/scheduled-automation-panel.test.ts`, and
  `src/components/tools/tools-main.test.ts` pass together (10 tests).
- Dashboard TypeScript after the Schedule KPI copy slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Schedule KPI copy slice: `pnpm lint` passes.
- Dashboard production build after the Schedule KPI copy slice: `pnpm build`
  passes with the same existing Vite warnings: unresolved dashboard font
  assets, dynamic/static import chunk warnings, and large chunks.
- Diff hygiene after the Schedule KPI copy slice: `git diff --check` passes.
- Schedule KPI rendered smoke: `agent-browser` loaded the worktree Vite server
  with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5185/dashboard/#schedule`, verified page title
  `MASC · Schedule`, top KPI labels `pending`, `due`, `scheduled`, and
  `running`, absence of the old top labels `active`, `due effective`,
  `blocked approval`, and `ready`, four backed schedule cards, zero
  `data-schedule-mutation` controls, and horizontal overflow `0`. Screenshot:
  `/tmp/masc-schedule-kpis-20260621.png`.
- Schedule KPI mobile rendered smoke: the same `agent-browser` session at
  `390x844` verified the same direct KPI labels, zero mutation controls, and
  horizontal overflow `0`. Screenshot:
  `/tmp/masc-schedule-kpis-mobile-20260621.png`. Browser page errors were
  empty; console noise included Vite debug, one slow-frame warning, and one
  unidentified existing `400` resource line during app bootstrap.
- Schedule Korean-copy Vitest after localizing card/detail and route metadata:
  `src/components/tools/scheduled-automation-panel.test.ts`,
  `src/components/tools/tools-main.test.ts`, and
  `src/components/schedule/schedule-surface.test.ts` pass together
  (10 tests), covering the Korean labels, request-derived feed fallback,
  filter behavior, detail selection, durable signal preference, and continued
  absence of local-only approve/reject/cancel controls.
- Dashboard TypeScript after the Schedule Korean-copy slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Schedule Korean-copy slice: `pnpm lint` passes.
- Dashboard production build after the Schedule Korean-copy slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Schedule Korean-copy rendered smoke: `agent-browser` loaded the worktree Vite
  server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5194/dashboard/#schedule`, against live
  `/health?full=1` status `ok` and `/api/v1/dashboard/tools` source
  `schedule_store` with four terminal request rows and no durable signals.
  Desktop `1440x1000` and mobile `390x844` both verified Korean schedule
  labels and metadata (`출처`, `signal 행`, `생성`, `활성`, `종료`,
  `유효 도래`, `승인 차단`, `실행 준비`, `만료`, `다음 예정`, `전체`,
  `승인 대기`, `기한 도래`, `예약/실행`, `완료`, `키퍼 다음 단계`,
  `페이로드`, `선택한 예약`, `최근 실행`), absence of the old English
  labels (`operator action`, `selected detail`, `keeper next step`,
  `source schedule_store`, `due effective`, `last execution`,
  `No schedule selected`), four backed cards, four request-derived wake-feed
  rows, zero `[data-schedule-mutation]` controls, pending-filter empty state,
  terminal-filter restore, and no horizontal overflow. Screenshots:
  `/tmp/masc-schedule-korean-copy-desktop-20260621.png` and
  `/tmp/masc-schedule-korean-copy-mobile-20260621.png`.
- Schedule Korean-copy browser diagnostics: page errors were empty. Console
  noise included Vite debug/HMR lines, slow-frame warnings, unidentified
  existing `400` resource lines, and a same-origin `/ws` WebSocket timeout
  under the Vite proxy. Direct `GET /ws` discovery returned the configured
  same-origin WebSocket metadata, so this was recorded as residual transport
  diagnostics rather than a schedule-card regression.
- CopilotDock Vitest: `src/components/copilot-dock.test.ts` passes (17 tests),
  covering selected-keeper Keepers context, fleet fallback, route-specific
  starter prompt selection, rendered empty-state starter buttons, normalized
  field tone classes, stream surface-context posting, and keeper picker flow.
- Work Vitest: `src/components/work.test.ts` passes (11 tests), covering
  Goal Store KPI counts for WIP, verification waiting, done, and claimable
  backlog tasks, plus the no-goal unassigned claimable badge.
- Composer Vitest: `src/components/board/composer-v2.test.ts` passes, including
  command envelope rendering and attachment MIME display while preserving the
  current transport shape.
- Connectors Vitest after the placeholder cleanup:
  `src/components/connector-status.test.ts` and
  `src/components/connector-config-form.test.ts` pass together (51 tests),
  covering the absence of Add connector, local drawer reply/binding draft
  editors, token reissue/test placeholders, and the continued presence of the
  real `/api/v1/sidecar/*` config form.
- Dashboard TypeScript after the Connectors placeholder cleanup:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Connectors placeholder cleanup: `pnpm lint` passes.
- Dashboard production build after the Connectors placeholder cleanup:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, and large chunks.
- Diff hygiene after the Connectors placeholder cleanup: `git diff --check`
  passes.
- Connectors rendered smoke: `agent-browser` loaded the worktree Vite server
  with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5184/dashboard/#connectors?section=connector-status`,
  opened the scoped Discord gate-card drawer, verified four connector cards,
  live read-only status/bot/reply/binding summary rows, no Add connector
  button, no reply/binding draft editor, no bot input, no token reissue, no
  Test connection placeholder, and horizontal overflow `0`. Config-tab smoke
  verified the in-process Discord config panel still renders
  `DISCORD_BOT_TOKEN` guidance and has no placeholder Test connection or Save
  control. Screenshots:
  `/tmp/masc-connectors-drawer-readonly-20260621.png` and
  `/tmp/masc-connectors-drawer-config-20260621.png`.
- Connectors mobile rendered smoke: the same `agent-browser` session at
  `390x844` opened the Discord drawer, verified the live summary rendered, the
  removed actions stayed absent, and horizontal overflow was `0`. Screenshot:
  `/tmp/masc-connectors-drawer-mobile-20260621.png`. Browser page errors were
  empty; console noise was limited to Vite debug and slow-frame warnings.
- Connectors binding-link Vitest:
  `pnpm exec vitest run src/components/connector-status.test.ts --testTimeout 90000`
  passes (36 tests), including the live `configured_bindings` row rendering as
  a keeper route link and clicking to `#keepers?keeper=luna`.
- Dashboard TypeScript after the Connectors binding-link slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Connectors binding-link slice: `pnpm lint` passes.
- Dashboard production build after the Connectors binding-link slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Connectors binding-link slice: `git diff --check`
  passes.
- Connectors binding-link rendered smoke: `curl -fsS
  'http://127.0.0.1:8935/api/v1/gate/connectors'` returned live Discord
  `configured_bindings` for two channels bound to `sangsu`. `agent-browser`
  loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5199/dashboard/#connectors`, which normalized to
  `#connectors?section=connector-status`. Desktop `1440x1000` and mobile
  `390x844` both verified two `[data-testid="connector-binding-keeper-link"]`
  rows, first channel `1493253256019972230`, keeper `sangsu`, no
  Add-connector/binding-add/reissue/Test-connection text, and no horizontal
  overflow. Clicking the live binding routed to
  `http://127.0.0.1:5199/dashboard/#keepers?keeper=sangsu` and rendered the
  Keepers surface with `sangsu` present.
- Connectors binding-link screenshots:
  `/tmp/masc-connectors-binding-link-desktop-20260621.png`,
  `/tmp/masc-connectors-binding-route-desktop-20260621.png`,
  `/tmp/masc-connectors-binding-link-mobile-20260621.png`, and
  `/tmp/masc-connectors-binding-route-mobile-20260621.png`. Browser page errors
  were empty. Console output included Vite debug lines and existing
  PerformanceMonitor slow-frame warnings; the mobile session also logged one
  unidentified existing `401 Unauthorized` resource line during app bootstrap.
- Connectors route-switcher Vitest:
  `pnpm exec vitest run src/components/connector-status.test.ts --testTimeout 90000`
  passes (37 tests), including direct `connector=imessage` route selection,
  All-route restoration, Telegram route selection without a dead-end panel, and
  continued absence of unsupported connector placeholder actions.
- Connectors route normalization Vitest:
  `pnpm exec vitest run src/config/navigation.test.ts src/router.test.ts --testTimeout 90000`
  passes (92 tests), covering valid connector route filter preservation and
  invalid connector filter stripping.
- Dashboard TypeScript after the Connectors route-switcher slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Connectors route-switcher slice: `pnpm lint` passes.
- Dashboard production build after the Connectors route-switcher slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Connectors route-switcher slice:
  `git diff --check` passes.
- Connectors route-switcher rendered smoke: live `curl -fsS
  'http://127.0.0.1:8935/api/v1/gate/connectors'` returned four connector
  rows: Discord connected with two `sangsu` bindings, and iMessage, Slack, and
  Telegram as offline/stale gate metadata. `agent-browser` loaded the worktree
  Vite server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5201/dashboard/#connectors?section=connector-status&connector=discord`.
  Desktop `1440x1000` verified the route switcher, active Discord chip, hidden
  all-connector grid, no Add-connector/binding-add/reissue/Test-connection
  placeholder text, and no horizontal overflow. Clicking `All` normalized the
  URL to `#connectors?section=connector-status`, restored four gate cards and
  four overview tiles, then clicking `Telegram` updated the URL to
  `#connectors?section=connector-status&connector=telegram`, activated the
  Telegram chip, rendered live offline/status-file evidence, kept placeholder
  mutation text absent, and had no horizontal overflow.
- Connectors route-switcher mobile rendered smoke: after wrapping the route
  switcher, `agent-browser` at `390x844` loaded the corrected worktree server at
  `http://127.0.0.1:5202/dashboard/#connectors?section=connector-status&connector=telegram`
  directly and verified the active Telegram chip was visible within the
  viewport, the switcher wrapped to a 75px-tall control, offline/status-file
  evidence rendered, placeholder mutation text was absent, and horizontal
  overflow stayed `0` (`scrollWidth: 390`, `innerWidth: 390`). Screenshots:
  `/tmp/masc-connectors-route-discord-desktop-20260621.png`,
  `/tmp/masc-connectors-route-telegram-desktop-20260621.png`, and
  `/tmp/masc-connectors-route-telegram-mobile-20260621.png`. Browser page
  errors were empty. Console output included Vite debug lines and one existing
  PerformanceMonitor slow-frame warning.
- Focused OCaml: `scripts/dune-local.sh build test/test_schedule_tool_wiring.exe`
  and `./_build/default/test/test_schedule_tool_wiring.exe` pass, including
  dashboard projection of schedule runner signals.
- Focused OCaml nav telemetry: `scripts/dune-local.sh build test/test_dashboard_nav_event.exe`
  and `./_build/default/test/test_dashboard_nav_event.exe` pass after adding
  `schedule` to the strict nav-event surface allowlist.
- TypeScript: `pnpm typecheck` passes.
- ESLint: touched dashboard files pass `pnpm exec eslint`.
- CopilotDock type/lint: `pnpm exec tsc --noEmit --pretty false` passes, and
  `pnpm lint` passes for the dashboard `src` tree after the starter/context
  update.
- Work type/lint: `pnpm exec tsc --noEmit --pretty false` passes, and
  `pnpm lint` passes for the dashboard `src` tree after the Work backlog KPI
  update.
- Production build: `pnpm build` passes with existing Vite warnings only.
- Keeper roster Vitest: `src/components/keeper-workspace/keeper-workspace-roster.test.ts`
  and `src/components/keeper-detail-page.test.ts` pass, including the backed
  fleet summary band and filter/search independence.
- Keeper roster rendered smoke: Playwright loaded
  `http://127.0.0.1:5177/dashboard/#/monitoring/agents?keeper=albini` against
  the local backend, waited for nonzero `[data-testid="kw-roster-summary"]`
  counts, verified no local-only batch fleet actions rendered, and saved
  `/tmp/masc-keeper-roster-summary-live-20260621.png`. The only captured
  console warning was an existing slow-frame hydration warning.
- Live smoke: `/api/v1/dashboard/tools` returns scheduled automation rows from
  the existing local backend, and Playwright waited successfully for
  `[data-schedule-id]` on
  `http://127.0.0.1:5176/dashboard/#/lab/tools` while the worktree dev server
  was running. This confirms the worktree frontend renders against the local
  API shape; the running backend still needs a rebuild/restart before this
  worktree's new durable signal JSON is live runtime truth.
- Schedule route rendered smoke: Playwright loaded
  `http://127.0.0.1:5177/dashboard/#/schedule` against the local backend,
  verified hash `#schedule`, active nav `Schedule`, h1 `예약 자동화`, 4 live
  schedule rows, KPI/feed presence, and zero `[data-schedule-mutation]`
  controls, then saved `/tmp/masc-keeper-schedule-route-20260621.png`. The only
  captured browser error was `POST /api/v1/dashboard/nav-event` returning 400
  from the already-running backend; the worktree backend parser is fixed by the
  focused nav-event OCaml test above, but live runtime still needs rebuild/restart
  before that telemetry path is current.
- CopilotDock rendered smoke: Playwright loaded the worktree Vite server with
  stubbed dashboard shell/execution/tools responses, opened Chat on `#/schedule`,
  verified the three schedule-specific starter prompts, then loaded
  `#/keepers?keeper=masc-improver` and verified the selected-keeper co-view
  card (`MASC Improver`, `/keepers`, `ctx80%`). Screenshots:
  `/tmp/masc-copilot-schedule-starters-20260621.png` and
  `/tmp/masc-copilot-keepers-selected-context-20260621.png`.
- Work rendered smoke: Playwright loaded the worktree Vite server with stubbed
  dashboard bootstrap/planning/execution responses at `#/workspace?section=work`,
  verified the six KPI values (goals/jobs/WIP/review/done/backlog), verified the
  unassigned claimable badge, and saved
  `/tmp/masc-work-backlog-kpis-20260621.png`.
- Fusion Vitest: `src/components/fusion/fusion-surface.test.ts` passes
  (7 tests), including structured judge evidence derived from board metadata
  with tuple-style contradiction positions and no local prototype state.
- Dashboard TypeScript after the Fusion structured-evidence slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion structured-evidence slice: `pnpm lint`
  passes.
- Dashboard production build after the Fusion structured-evidence slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, and large chunks.
- Diff hygiene after the Fusion structured-evidence slice: `git diff --check`
  passes.
- Fusion rendered smoke: a temporary fake API on `127.0.0.1:18937` backed a
  worktree Vite server at `http://127.0.0.1:5179/dashboard/#fusion`. The page
  rendered structured judge evidence from a real-shaped board payload, desktop
  and mobile horizontal overflow were both `0`, and screenshots were saved to
  `/tmp/masc-fusion-structured-judge-20260621.png` and
  `/tmp/masc-fusion-structured-judge-mobile-20260621.png`. The fake API did not
  model unrelated config/telemetry endpoints, so the browser console also showed
  unrelated schema/404 warnings outside the Fusion evidence path.
- Fusion registry pipeline Vitest:
  `pnpm exec vitest run src/components/fusion/fusion-runs-panel.test.ts src/components/fusion/fusion-surface.test.ts --testTimeout 20000`
  passes (17 tests), including the conservative status-to-pipeline mapping:
  running marks panel/judge active and sink pending, completed marks all stages
  done, and failed marks panel/judge plus sink failed without inventing a
  denied-path stage.
- Dashboard TypeScript after the Fusion registry pipeline slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion registry pipeline slice: `pnpm lint` passes.
- Dashboard production build after the Fusion registry pipeline slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Fusion registry pipeline live-state check: `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/fusion-runs'` returned `count: 0`
  and no rows, while the live board endpoint returned zero fusion board posts
  in the sampled dashboard board payload. Rendered smoke therefore injected
  API-shaped `fusionRuns` rows into the real Vite-served store to exercise the
  component path without claiming live fusion activity.
- Fusion registry pipeline rendered smoke: `agent-browser` loaded the worktree
  Vite server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5197/dashboard/#fusion`, injected running/completed/failed
  registry rows, verified title `MASC · Fusion`, canonical hash `#fusion`,
  three registry cards, the expected per-stage pipeline states for each status,
  no framework overlay text, and desktop horizontal overflow `0`.
- Fusion registry pipeline mobile rendered smoke: the same Vite server at
  `390x844` verified three registry cards, two-column pipeline layout, the
  expected running/failed stage states, and horizontal overflow `0`.
- Fusion registry pipeline screenshots:
  `/tmp/masc-fusion-registry-pipeline-desktop-20260621.png` and
  `/tmp/masc-fusion-registry-pipeline-mobile-20260621.png`. Browser page errors
  were empty. Console output was limited to Vite debug connection lines.
- Fusion source-split Vitest:
  `pnpm exec vitest run src/components/fusion/fusion-surface.test.ts src/components/fusion/fusion-runs-panel.test.ts src/tab-refresh.test.ts src/board-metrics.test.ts --testTimeout 90000`
  passes (42 tests), covering the dedicated `fusionBoardPosts` source, the
  route-refresh plan `fusionBoard + fusionRuns`, registry-only running rows, and
  the board-sink-specific empty state.
- Dashboard TypeScript after the Fusion source-split slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion source-split slice: `pnpm lint` passes.
- Dashboard production build after the Fusion source-split slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Fusion source-split slice: `git diff --check` passes.
- Fusion source-split live API check: `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/fusion-runs'` returned `count: 0`.
  The unfiltered recent board fetch
  `curl -fsS 'http://127.0.0.1:8935/api/v1/dashboard/board?sort_by=recent&limit=500&blind_votes=true'`
  returned five fusion board-sink posts, while the persisted-Board-filter shape
  with `exclude_system=true` returned zero. This is the regression the
  dedicated Fusion board fetch avoids.
- Fusion source-split rendered smoke: `agent-browser` loaded the worktree Vite
  server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5203/dashboard/#fusion`. Desktop `1440x1000` verified title
  `MASC · Fusion`, canonical hash `#fusion`, `board runs = 5`, `registry = 0`,
  five run rows, selected run `fus-bece178da21a3182769258485ddb0c47`, live
  `PR #21805 BLOCKER Resolution` detail text, no old `No fusion runs found`
  copy, no framework overlay, no horizontal overflow, and Refresh requests for
  `/api/v1/dashboard/board?sort_by=recent&limit=500&voter=dashboard&blind_votes=true`
  without `exclude_system`.
- Fusion source-split mobile rendered smoke: the same `agent-browser` session
  at `390x844` verified the KPI stack, run list/detail after scrolling the
  dashboard scroll container, selected run `fus-bece178da21a3182769258485ddb0c47`,
  live prompt detail, and horizontal overflow `0` (`scrollWidth: 390`,
  `innerWidth: 390`).
- Fusion source-split screenshots:
  `/tmp/masc-fusion-source-split-desktop-20260621.png`,
  `/tmp/masc-fusion-source-split-mobile-20260621.png`, and
  `/tmp/masc-fusion-source-split-mobile-detail-20260621.png`. Browser page
  errors were empty. Console output was limited to Vite debug connection lines
  plus the app's existing transport reconnect banner in the rendered chrome.
- Fusion source-reconciliation Vitest:
  `pnpm exec vitest run src/components/fusion/fusion-surface.test.ts src/components/fusion/fusion-runs-panel.test.ts --testTimeout 90000`
  passes (19 tests), including matched registry/board rows, registry-only rows
  that do not route to fake detail, board-only rows that select the existing
  `#fusion?run_id=...` detail, and the prior registry-pipeline helpers.
- Dashboard TypeScript after the Fusion source-reconciliation slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion source-reconciliation slice: `pnpm lint`
  passes.
- Dashboard production build after the Fusion source-reconciliation slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Fusion source-reconciliation slice:
  `git diff --check` passes.
- Fusion source-reconciliation live API check: after a transient local backend
  restart during mobile QA, `curl -fsS
  'http://127.0.0.1:8935/health?full=1'` returned `status: ok`, version
  `0.19.47`, and fresh uptime. `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/fusion-runs'` returned `count: 0`,
  while the unfiltered board fetch
  `curl -fsS 'http://127.0.0.1:8935/api/v1/dashboard/board?sort_by=recent&limit=500&voter=dashboard&blind_votes=true'`
  returned five Fusion board-sink posts in a 500-row sample.
- Fusion source-reconciliation rendered smoke: `agent-browser` loaded the
  worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5209/dashboard/#fusion`. Desktop `1440x1000` verified
  title `MASC · Fusion`, visible `Registry ↔ board sink`, summary
  `0 matched · 0 registry-only · 5 board-only`, zero registry cards, five run
  rows, four preview board-only reconciliation rows plus `+1 more`, no old
  `No fusion runs found` copy, no framework overlay, and no horizontal
  overflow. Clicking the first board-only row routed to
  `#fusion?run_id=fus-bece178da21a3182769258485ddb0c47`, preserved one active
  run row, and rendered the live `PR #21805 BLOCKER Resolution` detail.
- Fusion source-reconciliation mobile rendered smoke: a fresh `agent-browser`
  session at `390x844` verified the same summary, zero registry-only rows,
  four preview board-only rows, no horizontal overflow, and no summary clipping
  (`summary.scrollWidth == summary.clientWidth`). Clicking the first board-only
  row routed to the same `#fusion?run_id=...` detail and rendered the live
  prompt panel. Browser page errors were empty; the clean rerun console output
  was limited to Vite debug/HMR lines. An earlier mobile pass logged four Vite
  proxy `500` resource errors while `127.0.0.1:8935` temporarily refused
  `/api/v1/dashboard/runtime-probe` and `/api/v1/dashboard/nav-event`; backend
  health recovered before the clean rerun.
- Fusion source-reconciliation screenshots:
  `/tmp/masc-fusion-reconcile-desktop-before-20260621.png`,
  `/tmp/masc-fusion-reconcile-desktop-after-20260621.png`,
  `/tmp/masc-fusion-reconcile-mobile-before-20260621.png`, and
  `/tmp/masc-fusion-reconcile-mobile-detail-20260621.png`.
- Fusion chat-card route-action Vitest:
  `pnpm exec vitest run src/components/chat/primitives.test.ts --testTimeout 90000`
  passes (84 tests), including collapsed Fusion-card buttons routing to
  `#fusion?run_id=fus-1` and `#board?post=p-1` without expanding the lazy
  detail pane or calling `fetchBoardPost`.
- Dashboard TypeScript after the Fusion chat-card route-action slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion chat-card route-action slice: `pnpm lint`
  passes.
- Dashboard production build after the Fusion chat-card route-action slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Fusion chat-card route-action slice:
  `git diff --check` passes.
- Fusion chat-card route-action rendered smoke: `agent-browser` loaded the
  worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5204/dashboard/`, rendered the real `ChatTranscript`
  module into a same-page harness with a Fusion block
  `{ board_post_id: "post-smoke-1", run_id: "fus-smoke-1" }`, verified the
  collapsed card rendered `Fusion` and `Board` route buttons, no lazy
  `[data-fusion-detail]` pane, route click results
  `#fusion?run_id=fus-smoke-1` and `#board?post=post-smoke-1`, and desktop
  plus mobile viewport fit with no horizontal overflow. Screenshots:
  `/tmp/masc-fusion-chat-card-actions-desktop-20260621.png` and
  `/tmp/masc-fusion-chat-card-actions-mobile-20260621.png`.
- Fusion chat-card normalization Vitest:
  `pnpm exec vitest run src/components/chat/primitives.test.ts src/components/board/board-surface.test.ts --testTimeout 90000`
  passes (139 tests), including modern `reason_detail`, legacy
  `Fusion_types.Provider_error`, `Fusion_types.Timeout`, provider attribution
  normalization, judge `error` fallback, and the Board Fusion evidence consumer
  still rendering.
- Dashboard TypeScript after the Fusion chat-card normalization slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Fusion chat-card normalization slice: `pnpm lint`
  passes.
- Dashboard production build after the Fusion chat-card normalization slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Fusion chat-card normalization live rendered smoke: `agent-browser` loaded
  the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5205/dashboard/`, rendered the real `ChatTranscript`
  module with live board post `p-6fc92e6b227922d1988e540d997bd5ad`, expanded
  the card through the actual `fetchBoardPost` path, and verified normalized
  `Provider 'ollama_cloud.minimax-m3'`, no raw
  `Fusion_types.Provider_error`, no `Provider 'unknown'`, judge synthesis
  content, desktop/mobile viewport fit, and mobile `scrollWidth: 390`.
  Screenshots:
  `/tmp/masc-fusion-chat-card-normalized-live-desktop-20260621.png` and
  `/tmp/masc-fusion-chat-card-normalized-live-mobile-20260621.png`.
- Memory OS Lab route Vitest:
  `pnpm exec vitest run src/config/navigation.test.ts src/components/lab.test.ts src/components/memory-subsystems.focus.test.ts --testTimeout 90000`
  passes (58 tests), covering Lab navigation exposure, route fallback behavior,
  `focus` param pass-through, and the existing MemorySubsystems focus handling.
- Dashboard TypeScript after the Memory OS Lab route slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Memory OS Lab route slice: `pnpm lint` passes.
- Dashboard production build after the Memory OS Lab route slice: `pnpm build`
  passes with the same existing Vite warnings: unresolved dashboard font
  assets, dynamic/static import chunk warnings, large chunks, and the Node
  `module.register()` deprecation warning.
- Memory OS Lab live rendered smoke: `agent-browser` loaded the worktree Vite
  server at
  `http://127.0.0.1:5206/dashboard/#lab?section=memory-subsystems&focus=episodes`,
  verified title `MASC · Memory OS`, route hash preservation, visible
  `Memory OS`, `User model`, and `에피소드 기록` content, live episode count
  `총 458개`, and no horizontal overflow on `1440x1000` and `390x844`
  viewports. The captured browser request for the episodes focus was
  `/api/v1/dashboard/memory-subsystems?limit=100` with no
  `include_memory_entries=true`; a direct status-only check of
  `include_memory_entries=true` returned `401`, preserving the sensitive entry
  gate. Browser page errors were empty; console noise was Vite debug plus
  existing bootstrap `400` resource lines unrelated to the Memory OS fetch.
  Screenshots:
  `/tmp/masc-memory-os-lab-episodes-desktop-20260621.png` and
  `/tmp/masc-memory-os-lab-episodes-mobile-20260621.png`.
- Memory Explore collapse Vitest:
  `pnpm exec vitest run src/config/navigation.test.ts src/components/lab.test.ts src/components/memory-subsystems.focus.test.ts --testTimeout 90000`
  passes (59 tests), covering removal from visible Lab navigation, legacy
  `#lab?section=memory-explore` normalization to the backed Memory OS route,
  Lab fallback behavior, focus param pass-through, and the existing
  MemorySubsystems focus handling.
- Dashboard TypeScript after the Memory Explore collapse slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Memory Explore collapse slice: `pnpm lint` passes.
- Dashboard production build after the Memory Explore collapse slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Memory Explore collapse slice:
  `git diff --check` passes.
- Memory Explore collapse live rendered smoke: `agent-browser` loaded the
  worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5210/dashboard/#lab?section=memory-explore&focus=episodes`
  on `1440x1000` and `390x844` viewports. Both viewports settled on
  `#lab?section=memory-subsystems&focus=episodes`, title
  `MASC · Memory OS`, visible `Memory OS` content, zero
  `[data-testid="memory-explore-surface"]` nodes, no `Memory Linkage Explore`
  sample header, and horizontal overflow `0`. Browser page errors were empty;
  console noise was Vite debug plus existing bootstrap `400` resource lines.
  Screenshots:
  `/tmp/masc-memory-collapse-desktop-20260621.png` and
  `/tmp/masc-memory-collapse-mobile-20260621.png`.
- Design Canvas fixture-preview collapse Vitest:
  `pnpm exec vitest run src/config/navigation.test.ts src/components/lab.test.ts --testTimeout 90000`
  passes (56 tests), covering visible Lab navigation without the fixture
  preview, legacy `#lab?section=design-canvas` normalization to backed
  `#lab?section=tools`, and Lab fallback behavior.
- Dashboard TypeScript after the Design Canvas collapse slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Design Canvas collapse slice: `pnpm lint` passes.
- Dashboard production build after the Design Canvas collapse slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning. The Lab chunk drops
  from about `120.88 kB` to `81.45 kB` after removing the preview module.
- Diff hygiene after the Design Canvas collapse slice:
  `git diff --check` passes.
- Design Canvas collapse live rendered smoke: `agent-browser` loaded the
  worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5211/dashboard/#lab?section=design-canvas&view=fixtures`
  on `1440x1000` and `390x844` viewports. Both viewports settled on
  `#lab?section=tools`, title `MASC · Tools`, visible Tools content, zero
  `[data-design-canvas]` and `[data-design-canvas-fixture]` nodes, no
  `Design Canvas` text, and horizontal overflow `0`. Browser page errors were
  empty; console noise was Vite debug only. Screenshots:
  `/tmp/masc-design-collapse-desktop-20260621.png` and
  `/tmp/masc-design-collapse-mobile-20260621.png`.
- Work task-dossier Vitest:
  `pnpm exec vitest run src/components/work.test.ts --testTimeout 90000`
  passes (14 tests), covering route-selected task dossier rendering, row detail
  navigation, close-route behavior, verification-panel routing, selected-row
  state, and the absence of fake task-claim controls in the dossier.
- Dashboard TypeScript after the Work task-dossier slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Work task-dossier slice: `pnpm lint` passes.
- Dashboard production build after the Work task-dossier slice: `pnpm build`
  passes with the same existing Vite warnings: unresolved dashboard font
  assets, dynamic/static import chunk warnings, large chunks, and the Node
  `module.register()` deprecation warning.
- Work task-dossier live rendered smoke: `agent-browser` loaded the worktree
  Vite server at
  `http://127.0.0.1:5207/dashboard/#workspace?section=work&task=task-1454`,
  backed by live `/api/v1/dashboard/execution` and
  `/api/v1/dashboard/planning` responses (`200` through the Vite proxy).
  Desktop `1440x1000` verified title `MASC · Work`, preserved route param,
  live task title, goal `goal-pm-flow`, contract text, required evidence
  `reviewable_evidence_ref`, one selected job row, 18 row detail affordances,
  zero `work-task-claim` controls, and no horizontal overflow. The interaction
  loop closed the dossier back to `#workspace?section=work`, then reopened it
  via the `task-1454 상세 열기` row button. Mobile `390x844` verified the same
  route-selected dossier and no horizontal overflow; an additional mobile
  scrolled capture verified the long Korean description wraps inside the
  stacked dossier. Browser page errors were empty; console output was limited
  to Vite debug connection lines. Screenshots:
  `/tmp/masc-work-task-dossier-desktop-20260621.png`,
  `/tmp/masc-work-task-dossier-mobile-20260621.png`, and
  `/tmp/masc-work-task-dossier-mobile-contract-20260621.png`.
- Work Planning-link Vitest:
  `pnpm exec vitest run src/components/work.test.ts --testTimeout 90000`
  passes (15 tests), including the header action that removes the fake
  `＋ 새 목표` placeholder and routes to `navigate('workspace', { section:
  'planning' })`.
- Dashboard TypeScript after the Work Planning-link slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Work Planning-link slice: `pnpm lint` passes.
- Dashboard production build after the Work Planning-link slice: `pnpm build`
  passes with the same existing Vite warnings: unresolved dashboard font
  assets, dynamic/static import chunk warnings, large chunks, and the Node
  `module.register()` deprecation warning.
- Work Planning-link live rendered smoke: `agent-browser` loaded the worktree
  Vite server at
  `http://127.0.0.1:5208/dashboard/#workspace?section=work`. Desktop
  `1440x1000` and mobile `390x844` verified title `MASC · Work`, one
  `work-planning-link` action, no visible `＋ 새 목표`, no horizontal overflow,
  and browser page errors empty. Clicking `목표 관리자` on both viewports routed
  to `http://127.0.0.1:5208/dashboard/#workspace?section=planning`, verified
  title `MASC · Plans & Goals`, visible goal-manager content, and no Work KPI
  residue. Console output was limited to Vite debug connection lines.
  Screenshots:
  `/tmp/masc-work-planning-link-desktop-before-20260621.png`,
  `/tmp/masc-work-planning-link-desktop-after-20260621.png`,
  `/tmp/masc-work-planning-link-mobile-before-20260621.png`, and
  `/tmp/masc-work-planning-link-mobile-after-20260621.png`.
- Board Vitest: `src/components/board/board-surface.test.ts` passes with
  `--testTimeout 20000` (51 tests), including the desktop mention-queue
  regression that proves two board posts plus one explicit mention renders the
  desktop rail badge as `1`. The first default-timeout run passed 49 tests and
  timed out on two existing slow pagination tests; the rerun had no assertion
  failures.
- Dashboard TypeScript after the Board rail fix:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Board rail fix: `pnpm lint` passes.
- Dashboard production build after the Board rail fix: `pnpm build` passes with
  the same existing Vite warnings: unresolved dashboard font assets,
  dynamic/static import chunk warnings, and large chunks.
- Board rendered smoke: Playwright fallback via `agent-browser` loaded
  `http://127.0.0.1:5180/dashboard/#board`, injected the existing app signals
  with two board posts plus one explicit `@dashboard` message, verified the
  rendered desktop rail text `멘션 인박스1`, measured horizontal overflow `0`,
  and saved `/tmp/masc-board-mention-rail-20260621.png`. Browser page errors
  were empty; console noise was limited to the expected local auth-probe 401 and
  dev-shell slow-frame warnings.
- Board detail rail resize Vitest:
  `pnpm exec vitest run src/components/board/board-surface.test.ts --testTimeout 20000`
  passes (54 tests), including persisted width normalization, hydration into
  `--bd-detail-width`, pointer-drag resize, keyboard Home/End/arrow clamp
  behavior, and `localStorage` persistence.
- Dashboard TypeScript after the Board detail rail resize slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Board detail rail resize slice: `pnpm lint` passes.
- Dashboard production build after the Board detail rail resize slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Board detail rail resize live rendered smoke: `curl -fsS
  'http://127.0.0.1:8935/health?full=1'` returned status `ok`, effective MASC
  root `/Users/dancer/me/.masc`, and server `masc`. `agent-browser` loaded the
  worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5196/dashboard/#board`. Desktop `1440x1000` verified title
  `MASC · Board`, canonical hash `#board`, default width `360`, drag resize to
  `460` persisted in `dashboard:board-detail-width`, reload hydration at `460`,
  keyboard Home/End/arrow clamp behavior at `290` and `520`, CSS grid final
  column matching the persisted width, visible resize handle, and horizontal
  overflow `0`.
- Board detail rail resize mobile rendered smoke: the same live worktree server
  at `390x844` seeded `dashboard:board-detail-width=520`, verified the
  persisted value hydrated on `.v2-board-surface`, the resize handle was hidden,
  the closed mention detail rail was `display: none`, the opened mobile mention
  overlay stayed within the 324px board body, and document/body horizontal
  overflow stayed `0`.
- Board detail rail resize screenshots:
  `/tmp/masc-board-detail-resize-desktop-20260621.png` and
  `/tmp/masc-board-detail-resize-mobile-20260621.png`. Browser page errors were
  empty. Console noise was limited to Vite debug reconnect lines and existing
  PerformanceMonitor slow-frame warnings during app bootstrap.
- IDE shell Vitest: `src/components/ide/ide-shell.test.ts` passes (30 tests),
  including functional right-rail tab switching and stream-shaped cursor rail
  focus behavior.
- IDE tree resize Vitest: `src/components/ide/ide-shell.test.ts` passes
  (33 tests), including width normalization, persisted width hydration into the
  IDE grid, pointer-drag resize, keyboard Home/End clamp behavior, and
  `localStorage` persistence.
- Dashboard TypeScript after the IDE right-rail fix:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard TypeScript after the IDE tree resize slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the IDE right-rail fix: `pnpm lint` passes.
- Dashboard lint after the IDE tree resize slice: `pnpm lint` passes.
- Dashboard production build after the IDE right-rail fix: `pnpm build` passes
  with the same existing Vite warnings: unresolved dashboard font assets,
  dynamic/static import chunk warnings, and large chunks.
- Dashboard production build after the IDE tree resize slice: `pnpm build`
  passes with the same existing Vite warnings: unresolved dashboard font
  assets, dynamic/static import chunk warnings, large chunks, and the Node
  `module.register()` deprecation warning.
- IDE rendered smoke: `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5181/dashboard/#code?section=ide-shell&view=source`,
  injected the existing `cursorOverlaySignal` with one editing cursor and one
  collision, clicked the real `Cursors` tab, verified the cursor rail text
  (`KEEPER CURSORS`, `sangsu`, `str_replace`, `scheduler/round.ml:94-96`),
  measured horizontal overflow `0`, and saved
  `/tmp/masc-ide-cursor-rail-20260621.png`.
- IDE tree resize rendered smoke: `agent-browser` loaded the worktree Vite
  server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5195/dashboard/#code?section=ide-shell&view=source`,
  against live `/health?full=1` status `ok`. Desktop `1440x1000` cleared the
  persisted tree width, verified the default 230px grid column, dragged the
  real resize separator to 315px, verified `data-tree-width`, `aria-valuenow`,
  computed grid columns, and `localStorage` all changed to `315`, reloaded and
  verified 315px persisted, then verified keyboard Home/End clamp to 180px and
  360px. Mobile `390x844` seeded a 360px persisted width, reloaded, and verified
  the existing breakpoint still hides the tree and resize handle with no
  horizontal overflow. Screenshots:
  `/tmp/masc-ide-tree-resize-desktop-20260621.png` and
  `/tmp/masc-ide-tree-resize-mobile-20260621.png`. Browser page errors were
  empty; console noise was limited to Vite debug connect lines.
- Settings/runtime Vitest after the locked-preview hardening:
  `src/components/settings-surface.test.ts` and
  `src/components/runtime-toml-editor.test.ts` pass together (22 tests). The
  Settings tests open `런타임 관리`, verify the live `RuntimeTomlEditor`
  mounts, confirm `/api/v1/runtime/config/raw` is called with the bootstrapped
  bearer token, assert the old fake `.set-rt` runtime cards/Add runtime action
  are absent, and prove preview token reveal, toggles, and segmented controls
  no longer mutate local-only Settings state.
- Dashboard TypeScript after the Settings runtime-management/locked-preview
  slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Settings runtime-management/locked-preview slice:
  `pnpm lint` passes.
- Dashboard production build after the Settings runtime-management/locked-preview
  slice: `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, and large chunks.
- Diff hygiene after the Settings runtime-management/locked-preview slice:
  `git diff --check` passes.
- Settings rendered smoke: `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5182/dashboard/#settings`, clicked `런타임 관리`, verified
  the live runtime.toml editor status `saved`, path
  `/Users/dancer/me/.masc/config/runtime.toml`, source length `35840`, zero
  fake runtime cards/actions, and desktop horizontal overflow `0`; screenshot:
  `/tmp/masc-settings-runtime-toml-20260621.png`.
- Settings mobile rendered smoke: the same `agent-browser` session at
  `390x844` kept the runtime editor visible, measured page overflow `0` and
  code-frame overflow `0`, and saved
  `/tmp/masc-settings-runtime-toml-mobile-20260621.png`. Browser page errors
  were empty; console noise was limited to existing Vite debug, one slow-frame
  warning, and SSE schema-drift warnings from the running backend.
- Settings locked-preview rendered smoke: `agent-browser` loaded the worktree
  Vite server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5191/dashboard/#settings`. Desktop `1440x1000` and mobile
  `390x844` both verified title `MASC · Settings`, canonical hash `#settings`,
  default preview state `preview only`, `data-preview-locked="true"` on
  non-runtime cards, no `token-toggle`, read-only token value with `redacted`
  badge, disabled/unchanged account and runtime segmented controls, disabled
  runtime toggles/steppers/sliders, unchanged gate toggle, enabled Connectors
  link, logs filter still changing visible rows from `10` to `4`, and no
  horizontal overflow.
- Settings live runtime management rendered smoke: the same locked-preview
  sessions opened `런타임 관리` and verified `runtime.toml live-backed`,
  `data-preview-locked="false"`, mounted `runtime-toml-editor`, visible path
  `/Users/dancer/me/.masc/config/runtime.toml`, zero fake `set-verify` runtime
  cards/actions, and no horizontal overflow. Screenshots:
  `/tmp/masc-settings-preview-locked-desktop-20260621.png` and
  `/tmp/masc-settings-preview-locked-mobile-20260621.png`. Browser page errors
  were empty; console noise was limited to Vite debug connect lines.
- Settings section-route Vitest:
  `pnpm exec vitest run src/components/settings-surface.test.ts src/config/navigation.test.ts src/router.test.ts --testTimeout 90000`
  passes (102 tests), covering valid Settings section hashes, invalid-section
  fallback, mounted route sync, Settings nav hash writes, and preservation of
  sectionless sidebar behavior.
- Dashboard TypeScript after the Settings section-route slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Settings section-route slice: `pnpm lint` passes.
- Dashboard production build after the Settings section-route slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Settings section-route slice: `git diff --check`
  passes.
- Settings section-route rendered smoke: `curl -fsS
  'http://127.0.0.1:8935/health?full=1'` returned live MASC status `ok`.
  `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5200/dashboard/#settings?section=logs`. Desktop
  `1440x1000` verified title `관측 · 시스템 로그`, active logs nav,
  `preview only`, `data-preview-locked="true"`, 10 log rows, no fake mutation
  text, and no horizontal overflow. Clicking `런타임 관리` updated the URL to
  `#settings?section=runtimes`, activated runtimes nav, rendered
  `runtime.toml live-backed`, mounted `runtime-toml-editor`, showed
  `/api/v1/runtime/config/raw` and `runtime.toml`, kept fake mutation text
  absent, and had no horizontal overflow.
- Settings section-route mobile rendered smoke: the same `agent-browser`
  session at `390x844` loaded
  `http://127.0.0.1:5200/dashboard/#settings?section=runtimes` directly and
  verified active runtimes nav, `runtime.toml live-backed`, mounted
  `runtime-toml-editor`, visible API/path text, no fake mutation text, and no
  horizontal overflow. Screenshots:
  `/tmp/masc-settings-section-route-logs-desktop-20260621.png`,
  `/tmp/masc-settings-section-route-runtimes-desktop-20260621.png`, and
  `/tmp/masc-settings-section-route-runtimes-mobile-20260621.png`. Browser
  page errors were empty. Console output included Vite debug lines and two
  unidentified existing `400 Bad Request` resource lines; `agent-browser`
  network request capture did not retain the corresponding request details.
- CopilotDock Vitest after the mobile dock slice:
  `src/components/copilot-dock.test.ts` passes (18 tests), including a mobile
  regression that seeds persisted `mode: float` and proves the panel renders as
  `.dock.docked`, `data-mobile-docked="true"`, with no float/dock mode toggle.
- Dashboard TypeScript after the CopilotDock mobile dock slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the CopilotDock mobile dock slice: `pnpm lint` passes.
- Dashboard production build after the CopilotDock mobile dock slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, and large chunks.
- Diff hygiene after the CopilotDock mobile dock slice: `git diff --check`
  passes.
- CopilotDock mobile rendered smoke: `agent-browser` loaded the worktree Vite
  server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5183/dashboard/#overview`, set viewport `390x844`, seeded
  persisted `dashboard:copilot-dock` state with `mode: "float"` and off-screen
  coordinates, clicked the mobile top-bar Chat control, and verified the open
  dock rendered as fixed `.dock.docked`, `data-mobile-docked="true"`, rect
  `x=0 y=50 w=390 h=794`, no float/dock mode toggle, close control present,
  co-view/starter content present, and horizontal overflow `0`. Screenshot:
  `/tmp/masc-copilot-mobile-docked-20260621.png`. Browser page errors were
  empty; console noise was limited to Vite debug and an existing SSE
  schema-drift warning from the running backend.
- Keepers/Fleet route audit rendered smoke: `agent-browser` loaded the worktree
  Vite server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5188/dashboard/#keepers`, against live backend
  `/health?full=1` status `ok`. Desktop `1440x1000` verified title
  `MASC · Keepers`, canonical hash `#keepers`, 3-pane layout
  roster/chat/context rail, 12 live keeper rows, summary `12 전체 / 5 실행 /
  0 대기 / 7 중지`, flags `주의 2 / 승인 0 / CTX 80%+ 0`, lifecycle/utility
  command icons, context sections, no standalone-only fake text, and horizontal
  overflow `0`.
- Keepers/Fleet desktop interaction smoke: clicked `운영 상세`, verified
  `data-detail="open"` with roster plus full detail body and no overflow, then
  returned to chat plus rail. Screenshot:
  `/tmp/masc-keepers-fleet-desktop-20260621.png`.
- Keepers/Fleet mobile interaction smoke: at `390x844`, verified the mobile
  chat pane, opened the context drawer with the same live rail sections, closed
  it, opened the compact command menu with the same lifecycle/utility commands,
  switched back to roster, selected `garnet`, and verified
  `#keepers?keeper=garnet`, selected row/chat name `garnet`, and horizontal
  overflow `0`. Screenshot:
  `/tmp/masc-keepers-fleet-mobile-20260621.png`.
- Keepers/Fleet browser diagnostics: page errors were empty. Desktop console
  noise was limited to Vite debug, slow-frame warnings, existing
  `keeper-detail-alert-strip` unknown `stale_turn_timeout` /
  `inspect_stale_turn_root_cause` warnings, and one Vite HMR WebSocket timeout.
  Mobile console noise was limited to Vite debug and slow-frame warnings.
- Approvals live empty-state smoke: `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/governance'` returned
  `approval_queue: []`, and `agent-browser` loaded the worktree Vite server
  with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5189/dashboard/#approvals`. Desktop `1440x1000` and mobile
  `390x844` both verified title `MASC · Approvals`, canonical hash
  `#approvals`, empty-state copy, KPI values `열린 승인 0`, `위험 · 높음 0`,
  `최장 대기 —`, `관련 키퍼 0`, zero cards, no detail panel, no
  defer/undo/history strings, zero `.ap-act` buttons in the empty state, and
  horizontal overflow `0`. Screenshots:
  `/tmp/masc-approvals-empty-desktop-20260621.png` and
  `/tmp/masc-approvals-empty-mobile-20260621.png`.
- Approvals contract audit: `lib/keeper/keeper_approval_queue.ml` keeps the
  pending entry's internal `selected_model`, but `pending_entry_json_fields`
  intentionally emits `"selected_model": null`; `test/test_hitl_approval.ml`
  asserts audit selected-model redaction. The frontend was left aligned with
  that backend redaction contract. Browser page errors were empty; console noise
  was limited to Vite debug and one slow-frame warning per viewport.
- Approvals inline-detail Vitest:
  `pnpm exec vitest run src/components/approvals/approvals-surface.test.ts --testTimeout 20000`
  passes (6 tests), including the selected inline dossier rendering directly
  after the selected card and the continued absence of defer/undo/history text.
- Dashboard TypeScript after the Approvals inline-detail slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Approvals inline-detail slice: `pnpm lint` passes.
- Dashboard production build after the Approvals inline-detail slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Approvals inline-detail slice: `git diff --check`
  passes.
- Approvals inline-detail rendered smoke: `agent-browser` loaded the worktree
  Vite server with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5198/dashboard/#approvals`. The live governance endpoint
  currently exposes an empty approval queue, so the smoke injected API-shaped
  approval rows into the actual `governanceResource` signal to exercise the
  non-empty UI path without claiming live pending approvals. Desktop `1440x1000`
  verified title `MASC · Approvals`, canonical hash `#approvals`, two cards,
  selected `appr-2`, visible right rail, hidden inline panel, no
  defer/undo/history strings, and no horizontal overflow. Mobile `390x844`
  verified the right rail was hidden, the inline detail panel was visible,
  `data-approval-id="appr-2"`, directly preceded by the selected `appr-2`
  card, and no horizontal overflow.
- Approvals inline-detail screenshots:
  `/tmp/masc-approvals-inline-detail-desktop-20260621.png` and
  `/tmp/masc-approvals-inline-detail-mobile-20260621.png`. Browser page errors
  were empty. Console output was limited to Vite debug connection lines.
- Fusion live empty-state smoke: `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/board?limit=200&voter=dashboard&blind_votes=true'
  | jq` found zero posts with `meta.source = "fusion"` or
  `meta.fusion_deliberation`, and `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/fusion-runs'` returned `count: 0`.
  `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5190/dashboard/#fusion`. Desktop `1440x1000` and mobile
  `390x844` both verified title `MASC · Fusion`, canonical hash `#fusion`, run
  status panel `0 / No active or recent fusion runs`, empty board-meta state,
  KPI values `runs 0`, `running 0`, `failed 0`, `source board meta`, no detail
  panel, no structured evidence panel, and horizontal overflow `0`.
  Screenshots: `/tmp/masc-fusion-empty-desktop-20260621.png` and
  `/tmp/masc-fusion-empty-mobile-20260621.png`. Browser page errors were empty;
  console noise was limited to Vite debug and one slow-frame warning per
  viewport.
- Logs Vitest after the provider-diagnostics audit:
  `src/components/logs.test.ts` passes (9 tests), including stable
  `logs-row`/category-filter selectors, Code route links from structured log
  evidence, unsafe absolute-path rejection, provider-log tail rendering from a
  configured provider path, and the new default-collapsed
  `logs-provider-diagnostics` disclosure.
- Dashboard TypeScript after the Logs provider-diagnostics audit:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Logs provider-diagnostics audit: `pnpm lint`
  passes.
- Dashboard production build after the Logs provider-diagnostics audit:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Logs live rendered smoke: `curl -fsS 'http://127.0.0.1:8935/health?full=1'`
  returned status `ok`, `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/logs?limit=20&level=INFO'`
  returned live `masc_log_ring` rows, and `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/provider-logs'` returned
  `providers: []`. `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5192/dashboard/#logs`. Desktop `1440x1000` and mobile
  `390x844` both verified title `MASC · Logs`, canonical hash `#logs`, h1
  `이벤트 로그`, 200 live rows, provenance including `masc_log_ring` and
  `dashboard_logs`, no provider diagnostics panel for the empty live provider
  catalog, Tool category filter changing the stream from `200` to `0`, All
  restoring `200`, no framework overlay, and no horizontal overflow.
- Logs rendered screenshots: `/tmp/masc-logs-live-stream-desktop-20260621.png`
  and `/tmp/masc-logs-live-stream-mobile-20260621.png`. Browser page errors
  were empty; console noise was Vite debug plus existing PerformanceMonitor
  slow-frame warnings. Browser network stubbing was attempted for provider-log
  catalog/tail but did not affect the same-origin fetch in `agent-browser`, so
  the configured-provider collapsed state is covered by Vitest rather than the
  live rendered smoke.
- Board mobile-clearance Vitest after the master-detail audit:
  `src/styles/board-v2.test.ts` and
  `src/components/board/board-surface.test.ts` pass together with
  `--testTimeout 20000` (52 tests). The CSS source test locks the
  `max-width: 900px` thread/mention detail overlay bottom clearance so future
  edits cannot silently return to `bottom: 0` under the fixed mobile tab bar.
- Dashboard TypeScript after the Board mobile-clearance slice:
  `pnpm exec tsc --noEmit --pretty false` passes.
- Dashboard lint after the Board mobile-clearance slice: `pnpm lint` passes.
- Dashboard production build after the Board mobile-clearance slice:
  `pnpm build` passes with the same existing Vite warnings: unresolved
  dashboard font assets, dynamic/static import chunk warnings, large chunks,
  and the Node `module.register()` deprecation warning.
- Diff hygiene after the Board mobile-clearance slice: `git diff --check`
  passes.
- Board mobile-clearance live rendered smoke: `curl -fsS
  'http://127.0.0.1:8935/health?full=1'` returned status `ok`, effective MASC
  root `/Users/dancer/me/.masc`, and `curl -fsS
  'http://127.0.0.1:8935/api/v1/dashboard/board?limit=20&voter=dashboard&blind_votes=true'`
  returned 20 live posts. `agent-browser` loaded the worktree Vite server with
  `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:8935` at
  `http://127.0.0.1:5193/dashboard/#board`. Mobile `390x844` verified title
  `MASC · Board`, canonical hash `#board`, 53 rendered posts, fixed bottom tabs
  at `y=798 h=46`, thread detail `bottom=767`, mention detail `bottom=767`,
  both clearing the tabs, no framework overlay, and horizontal overflow
  `390/390`.
- Board desktop regression smoke: the same live worktree server at desktop
  `1440x1000` verified title `MASC · Board`, canonical hash `#board`, visible
  200px rail, visible 588px feed, default mention rail `display: flex` with
  width 360px, no mobile tabs, 53 posts, clicked thread detail reusing the
  right rail at `x=1047 w=360`, no framework overlay, and horizontal overflow
  `1440/1440`.
- Board rendered screenshots:
  `/tmp/masc-board-mobile-detail-clearance-20260621.png` and
  `/tmp/masc-board-desktop-detail-20260621.png`. Browser page errors were
  empty. Console noise included Vite debug/HMR lines, PerformanceMonitor
  slow-frame warnings, generic 401/500 resource logs from the live/dev
  bootstrap, and one Vite WebSocket timeout; `agent-browser network requests
  --filter 401` and `--filter 500` did not retain matching captured requests
  after the smoke.
