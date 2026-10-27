# Keepers List View Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MASC TUI Keepers 목록을 세 가지 밀도·그룹 보기로 전환하면서, 실제 작업/대기 상태와 복합 활동을 정확하고 읽기 쉽게 보여준다.

**Architecture:** 기존 `GET /api/v1/keepers/turns`에 public-read waiting 요약을 얹고, CanAdmin async inventory는 기존 독립 읽기로 유지한다. 순수 `Masc_tui_keeper_list_model`이 상태 분류와 정렬을 결정하고, 렌더러·커서·검색·마우스가 같은 정렬된 Keeper 목록을 공유한다. 세 렌더 모드는 같은 projection을 쓰며 기존 Theme/glyph와 Kitty/mosaic 초상화 경로를 재사용한다.

**Tech Stack:** OCaml 5.5, Eio, existing MASC HTTP/JSON projections, Alcotest, MASC TUI ANSI/Kitty rendering.

**Spec:** 이 파일의 **Approved Specification** (2026-10-26 대화에서 승인; 별도 설계 문서 없음). 실행 시 이 계획을 `docs/superpowers/plans/2026-10-26-keepers-list-view-modes.md`에도 복사해 요구사항과 계획을 함께 보존한다.

## Approved Specification

- 기본은 A 한 줄이며 `v`로 A 한 줄 → B 두 줄 → C 상태 그룹 → A로 순환한다.
- `o`로 priority → recent → name 정렬을 순환한다. 기존 `s:shutdown/start server`, `f:files`, `/` 이름 검색은 유지한다.
- priority는 사람의 확인 필요 → 실제 진행 → 모델/동기 도구/delegation/verification 대기 → idle/paused다.
- streaming/preparing/running과 async 작업을 둔 채 계속하는 상태를 구분하고, 턴의 NOW와 async/delegate/verification 배지를 합치지 않는다.
- 질문·held call·실패·예약 wake 같은 MASC 신호를 일반 Working과 구분한다. 관측 불가를 idle로 만들지 않는다.
- 모드·정렬·갱신 후에도 선택한 Keeper 이름과 검색어를 유지하고 선택 행을 보이게 한다. 세 모드 전환에 재조회를 하지 않는다.
- 간격과 공간 낭비를 줄이고, 적당한 시각적 거리·색상·아이콘을 사용한다. 색 없이도 기호와 단어로 구분한다.
- 상세 모드에 여유 공간이 있을 때만 선택 Keeper의 기존 초상화를 Kitty pixels 또는 mosaic으로 표시한다. 그림이 없거나 좁으면 텍스트가 모든 공간을 다시 사용한다.

## Global Constraints

- `docs/constitution.xml`의 execution_protocol을 따른다. 외부 코딩 세션에서 로컬 Dune 빌드/전체 회귀/CI watch를 실행하지 않는다.
- 새 TUI 화면 문구·배치·행 순서·호출 횟수 검사는 만들지 않는다. 검사는 요청, 저장 상태, 순수 분류/정렬/선택 결정에 한정한다.
- `GET /api/v1/keepers/turns`는 public read이고 `/api/v1/async-requests`는 CanAdmin이다. async를 turns에 포함하지 않는다.
- `masc.keeper_turns.v1`을 유지하고 새 필드는 선택 사항으로 읽는다. 누락은 미관측이며 idle이 아니다. 알 수 없는 상태/source/producer는 디코드 오류다.
- 상태는 문자열 추론이 아니라 closed sum과 canonical projection으로 결정한다. 마지막 정상 관측을 갱신 실패로 지우지 않는다.
- 새 의존성·환경변수·지속 설정은 추가하지 않는다. 보기와 정렬 선택은 현재 TUI 세션에 둔다.
- 작업은 별도 worktree에서 시작하고 기존 dirty/untracked 파일을 보존한다. 사용자가 요청하지 않은 commit/push/PR/CI dispatch는 하지 않는다.
- 검증 산출물은 `artifacts/keepers-list-view-modes/`에 두고, 계획 문서만 skill 규칙에 따라 `docs/superpowers/plans/`에 둔다.

## Review Focus

1. 이전 서버 또는 권한 없는 서버가 waiting/async를 주지 않는 경우: 해당 정볧만 미관측이어야 하며 기존 turn 상태와 마지막 정상 관측은 남아야 한다 — Task 1/2의 디코드·갱신 검사.
2. recent/priority/name 변경과 roster 갱신이 겹치는 경우: 커서·검색·마우스·실제 Keeper action이 같은 이름을 가리켜야 한다 — Task 3/4의 정렬·선택 검사.
3. streaming과 async, delegation과 verification이 동시에 있는 경우: primary activity를 바꿔도 보조 배지가 사라지지 않아야 한다 — Task 3의 복합 상태 검사.
4. Kitty·색상·폭이 없는 터미널과 한글/이모지가 있는 경우: 텍스트 fallback이 남고 display cell이 어긋나지 않아야 하며 초상화가 양보해야 한다 — Task 5의 기존 portrait/width 검사와 실측 범위.
5. waiting inventory 갱신 실패와 async 403이 다른 시점에 발생하는 경우: 두 독립 실패가 서로의 관측을 지우거나 idle을 만들지 않아야 한다 — Task 2의 독립 읽기 검사.

---

### Task 1: Canonical waiting을 turns wire에 연결

**Files:**
- Modify: `lib/server_keeper_waiting_inventory.mli`
- Modify: `lib/server_keeper_waiting_inventory.ml:1114-1146,1273-1335`
- Modify: `lib/server/server_routes_http_keeper_stream.ml:459-525`
- Modify: `lib/tui_decode.mli:4490-4533`
- Modify: `lib/tui_decode.ml:4490-4709`
- Modify: `bin/masc_tui_loader.ml:1109-1115`
- Modify: `bin/masc_tui_async_protocol.mli`
- Modify: `bin/masc_tui_async_protocol.ml`
- Test: `test/test_keeper_turns_route.ml`
- Test: `test/test_tui_decode.ml`

**Interfaces:**
- Produces: `Server_keeper_waiting_inventory.keeper_json_by_name : Workspace.config -> (string * Yojson.Safe.t) list`, computed from one inventory snapshot.
- Produces: optional `waiting` object in each public `masc.keeper_turns.v1` row; no async inventory in this response.
- Produces: `Tui_decode.keeper_turns_projection = { rows : keeper_turn_row list; waiting : keeper_waiting_row list }` and `decode_keeper_turns_projection`. Existing `decode_keeper_turns` keeps returning only rows for current callers.
- Produces: closed `keeper_waiting_state`, `waiting_source`, `wake_producer`, `waiting_item`, `keeper_waiting_row` decoders. `waiting` items keep `source`, `waiting_on`, `what`, `wake_producer`, `since`, `due_at`, `next_action`; missing `waiting` maps to no observation for that Keeper.

- [ ] **Step 1: Add the failing route and wire tests**

`test_keeper_turns_route` asserts an installed idle Keeper receives the canonical waiting object with `state = "idle"` and `waiting_count = 0`. `test_tui_decode` covers a complete waiting row containing `wake_producer = "keeper_delegate"`, missing waiting as unobserved, and unknown state/source/producer as errors.

- [ ] **Step 2: Record the focused checks without violating the external-session build boundary**

Keeper lane/operator command: `dune exec test/test_keeper_turns_route.exe` and `dune exec test/test_tui_decode.exe`.
Expected before implementation: the new assertions fail because `waiting` is absent. External coding session records **not run locally** rather than claiming red/green evidence.

- [ ] **Step 3: Implement the server and typed decoder**

Build `keeper_json_by_name` from the same `read_inventory_snapshot` used by `dashboard_json`. Call it once in `handle_keeper_turns_list`, attach the matching object to each row, and use `null` only when the canonical snapshot has no row for that name. Keep the existing schema and public-read authorization. Add strict decoders and thread `keeper_turns_projection` through `load_keeper_turns` and `Keeper_turns_loaded` without changing `keeper_turn_row` and breaking its record fixtures.

- [ ] **Step 4: Verify the boundary**

Keeper lane/operator reruns the two commands; expected PASS. External session inspects the diff and runs `git diff --check`, explicitly leaving execution evidence unverified.

### Task 2: Independent async read and atomic list observations

**Files:**
- Modify: `bin/masc_tui_types.ml:4180-4319,8261-8270,8837-8955,9348-9355`
- Modify: `bin/masc_tui.ml:3241-3261,3677-3723,13740-13755,21113-21159,21835-21860,34370-34380`
- Modify: `test/test_tui_surface_needs.ml`
- Modify: `test/test_tui_server_identity_refresh.ml`
- Modify: affected async-read tests found during the diff

**Interfaces:**
- Consumes: Task 1's `Tui_decode.keeper_turns_projection`.
- Produces: `state.keeper_waiting : Tui_decode.keeper_waiting_row list`, replaced in the same accepted message as `state.keeper_turns` and retained on a failed read.
- Produces: `launch_tools_async_observation_load` with its own generation/in-flight guard, separate from the Tools inventory/catalog generation and from the public turns read.
- Produces: Keepers list `needs_operator_approvals = true` and `needs_asks = true`; other Keeper submodes retain their current needs.

- [ ] **Step 1: Add failing state/request tests**

Cover independent async generation replacement and in-flight release, failed turns retaining the previous waiting observation, and Keepers list requesting approvals/questions while detail does not gain new datasets. Include a CanAdmin refusal case that sets an error without converting rows to idle or deleting the last good async observation.

- [ ] **Step 2: Record focused checks**

Keeper lane/operator command: `dune exec test/test_tui_surface_needs.exe` and `dune exec test/test_tui_server_identity_refresh.exe`.
Expected before implementation: new assertions fail. External session does not run Dune locally.

- [ ] **Step 3: Implement independent reads and state updates**

Split async fetching out of `launch_tools_load`; remove `Tools_async_read` from the inventory/catalog pending set and settle it with `tools_async_request_generation` plus `tools_async_observation_inflight`. Poll it on the existing two-second path for Tools and Keepers list, never on every render. Keep `Tools_async_observation_loaded` as the message constructor. Apply Task 1's projection atomically in `Keeper_turns_loaded`; clear workspace-owned observations on workspace reset, not on transient failure.

- [ ] **Step 4: Verify independent failure behavior**

Keeper lane/operator reruns the checks; expected PASS. External session checks that no async field was added to turns and runs `git diff --check`.

### Task 3: Pure Keeper list model

**Files:**
- Create: `bin/masc_tui_keeper_list_model.mli`
- Create: `bin/masc_tui_keeper_list_model.ml`
- Modify: `bin/dune`
- Create: `test/test_tui_keeper_list_model.ml`
- Modify: `test/dune`

**Interfaces:**
- Produces: `layout = Compact | Detailed | Grouped`, `sort = Priority | Recent | Name`, and `attention = Needs_you | Active | Waiting | Inactive`.
- Produces: `next_layout`, `next_sort`, `layout_label`, `sort_label`, `group_of_row`, `primary_activity_of_row`, `badges_of_row`, `order_rows`, and `group_counts`.
- Produces: a `row` containing the original `Tui_decode.keeper`, `Masc_tui_keeper_control.reading`, optional turn/waiting/approval/task, open-question count, matching async phases, and a computed `last_activity_at`. The model performs no I/O and does not mutate TUI state.

- [ ] **Step 1: Add failing classification and ordering tests**

Pin `Compact → Detailed → Grouped → Compact` and `Priority → Recent → Name → Priority`; held calls/questions/failures before streaming; streaming/preparing/running and async-running before model/tool/delegate/verification waiting; idle/paused last; name ordering and stable ties; unknown observations remaining distinct. Include one row that is streaming with two async requests and another waiting on both delegation and verification, asserting all secondary badges survive.

- [ ] **Step 2: Record the focused check**

Keeper lane/operator command: `dune exec test/test_tui_keeper_list_model.exe`.
Expected before implementation: module absent. External session does not run Dune locally.

- [ ] **Step 3: Implement the pure model**

Use typed turn preview activity, canonical waiting source/producer/state, existing approval/ask rows, `Masc_domain.AwaitingVerification`, and `Tui_decode.async_request_phase`. Do not match display strings. `last_activity_at` prefers preview update, then running-turn start, then last finished turn; waiting `since` is used only when no fresher turn reading exists. Unknown timestamps sort last under Recent with name as the deterministic tie-break.

- [ ] **Step 4: Verify decisions, not screen rows**

Keeper lane/operator reruns the model tests; expected PASS. External session reviews exhaustive matches and runs `git diff --check`.

### Task 4: One ordered list for selection, search, mouse, and keys

**Files:**
- Modify: `bin/masc_tui_types.ml:14011-14140,15753-15810`
- Modify: `bin/masc_tui_loader.ml:350-455`
- Modify: `bin/masc_tui_surface_search.ml:41-44`
- Modify: `bin/masc_tui_render_keepers.ml:421-706`
- Modify: `bin/masc_tui_keys.ml:511-519`
- Modify: `bin/masc_tui.ml:15002,15150-15165,30260-30280,32245-32270,32585-32610,32975-32990,33200-33245,33635-33665`
- Modify: `test/test_tui_keys.ml`
- Modify: `test/test_tui_keeper_list_model.ml`

**Interfaces:**
- Consumes: Task 3's model and Task 2's `state.keeper_waiting`.
- Produces: `state.keeper_list_layout` default `Compact`, `state.keeper_list_sort` default `Priority`, `keeper_list_rows`, `ordered_keepers`, `keeper_index`, `cycle_keeper_list_layout`, and `cycle_keeper_list_sort`.
- Produces: `v` and `o` only on `Keepers Keeper_list`; existing key meanings elsewhere remain unchanged.

- [ ] **Step 1: Add failing selection and key tests**

Select `beta`, change layout/sort and replace observations, then assert the selected Keeper is still `beta`; search results and `Press_keeper_row` use the same order; removing the selected name clamps without choosing an out-of-range row. Assert `v`/`o` appear on the list and do not alter `v` on Metrics/Items or existing `s`/`f` behavior.

- [ ] **Step 2: Record focused checks**

Keeper lane/operator command: `dune exec test/test_tui_keys.exe` and `dune exec test/test_tui_keeper_list_model.exe`.
Expected before implementation: missing bindings/projection. External session does not run Dune locally.

- [ ] **Step 3: Implement the shared projection and key dispatch**

Build model rows once per call and map those same rows for rendering and `ordered_keepers`. Only `Keepers Keeper_list` applies the new order; chat/detail retain their current roster behavior. Reconcile loader IDs through the ordered list and replace raw `List.nth_opt state.keepers state.keeper_cursor` in list action paths with `selected_keeper`. Preserve the selected name before changing mode/sort, restore its new index, and let the existing visibility clamp show it.

- [ ] **Step 4: Verify no control drift**

Keeper lane/operator reruns the checks; expected PASS. External session inspects every changed direct cursor use and runs `git diff --check`.

### Task 5: Three dense renderers, status styling, and optional portrait

**Files:**
- Modify: `bin/masc_tui_render_keepers.ml:35-285,421-706`
- Modify: `bin/masc_tui_render_schedule.ml`
- Modify: `bin/masc_tui_keeper_mark.mli`
- Modify: `bin/masc_tui_keeper_mark.ml`
- Modify: `bin/dune` only if the render dependency graph requires it
- Verify with existing tests: `test/test_tui_chat_portrait.ml`, `test/test_tui_theme_contrast.ml`, `test/test_tui_message_layout.ml`

**Interfaces:**
- Consumes: the same Task 4 `keeper_list_rows` for every layout.
- Produces: Compact one-line rows, Detailed two-line rows, Grouped rows under nonempty attention headings; no data refetch or different state classification between them.
- Consumes: `Masc_tui_chat_portrait.shown` for a selected Keeper with `Ready` equipment in Detailed mode only.

- [ ] **Step 1: Fix the visual allocation rules before drawing**

Compact keeps one row per Keeper and puts summary counts on one existing chrome line. Detailed uses two rows with no blank row between Keepers. Grouped suppresses the duplicate summary and lets group headings own their counts. The detailed portrait uses the existing caption/picture/spacer contract and its `roster_rows` budget; it is omitted before text navigation capacity is reduced.

- [ ] **Step 2: Implement adaptive columns and status marks**

Extend `Render_schedule.allocate_keeper_columns` so long names/details yield before NOW, health, or selected-row markers disappear. Use `Message_layout.display_width`/`fit_middle` for Korean and emoji. Reuse Theme contrast-safe tones and existing glyph vocabulary: attention `!/?`, active spinner/stream mark, waiting `◌/→/◇`, async `&` or `>`, schedule `▸`, idle `○`, paused `Ⅱ`. Every icon has a text label; healthy rows stay quiet while attention and active states carry the stronger color.

- [ ] **Step 3: Implement the three render paths and portrait placement**

Render Compact and Grouped from the same one-line row builder and Detailed from the two-line builder. Anchor Kitty placement to the actual emitted picture row plus `Masc_tui_render_prim.strip_rows`; mosaic uses the same reserved cells. Do not create a second graphics protocol or draw pixels while scrolled/clipped. Present waiting/async read errors as observation warnings, never as an invented current row state.

- [ ] **Step 4: Verify capability fallbacks and visual evidence**

Keeper lane/operator commands: `dune exec test/test_tui_chat_portrait.exe`, `dune exec test/test_tui_theme_contrast.exe`, and `dune exec test/test_tui_message_layout.exe`; expected PASS. Add no screen wording/layout/row-order tests.
Exercise the real matched server/TUI through the repository's focused native-TUI path when the operator requests it: cycle all three layouts and all three sort modes, resize narrow/wide, test color/no-color and Kitty/mosaic/no-picture, and capture selected evidence under `artifacts/keepers-list-view-modes/`. External session reports any unexecuted runtime scenario instead of claiming visual completion.

### Task 6: Final source review and evidence handoff

**Files:**
- Create only when execution evidence exists: `artifacts/keepers-list-view-modes/`
- Create: `docs/superpowers/plans/2026-10-26-keepers-list-view-modes.md` (copy of this approved plan)

- [ ] **Step 1: Review the complete diff against the approved specification**

Use independent function/logic/code-cleanliness review as required by the constitution; the primary implementer also rereads every finding. Confirm no admin async payload entered public turns, no screen-contract tests were added, no old key behavior changed, and no unobserved state became idle.

- [ ] **Step 2: Run only permitted local checks and collect results**

Run `git diff --check`. Record exact focused commands as **not run locally** in the external session; do not substitute imports, generated mockups, or source inspection for real runtime evidence. Do not watch CI or dispatch it without user authorization.

- [ ] **Step 3: Hand off the bounded result**

Report changed behavior, remaining runtime/visual verification, and the exact next focused check. Leave the worktree and all pre-existing user files intact; do not commit, push, or open a PR without an explicit user request.
