# Play room SSE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove successful periodic Play room HTTP reads and bind presence to the existing Observer SSE lifecycle while preserving durable messages and real change notifications.

**Architecture:** `Play_room.perform_with_change` exposes actual transaction effects. `Server_play_room_events` binds presence to an exact Observer `client_id` and guards HTTP presence effects, while TUI reads only on entry, change, failure, replay gap, or trailing change.

**Tech Stack:** OCaml 5.5.1, Eio, SQLite, existing `Sse`/`Workspace_dataset_event`, Alcotest, Python PTY fixtures.

**Spec:** `docs/superpowers/specs/2026-11-05-play-room-sse-design.md`

## Global Constraints

- Follow `docs/constitution.xml`: no local Dune build, no CI watch/wait loop, no merge/rebase, no runtime configuration change.
- No new dependency. Reuse existing Observer, 30-second ping, 60-second presence expiry, and SQLite transactions.
- `who` and role come from the exact register-returned `Sse.client`; require `Masc_domain.has_permission role CanPlayMachine`.
- `machine` controls only Control advance; `play_machine` controls only room membership.
- The transcript is shared across machines. Dataset machine is source metadata, never a transcript filter.
- Read/Say never upsert membership. HTTP Join/Leave are lease-guarded so an old request cannot overwrite/delete replacement presence.
- No-op/idempotent actions and seen_at-only renewal produce no event. Public per-name membership changes produce events; invisible raw-row churn does not.
- Pending changes require one trailing Read; successful active reads never restart a periodic cadence.
- Commit with `git -c core.hooksPath=/dev/null commit ...`. Verify exact heads with remote suites and exact-source PTY.

## Review Focus

- Idempotent send/no-op join/seen_at-only renewal emits no event (Task 1).
- Tool-originated writes announce and cannot overwrite a lease (Tasks 1 and 2).
- Replaced Observer and old HTTP Leave cannot remove successor presence (Task 2).
- Reconnect creates replacement presence before closing the old connection (Task 2).
- `play_machine` does not advance Watch and injected permission denial rejects presence (Task 2).
- Connect/renew failures and disconnect cancellation preserve truthful presence (Task 2).
- Pending changes produce one trailing Read; successful/hidden idle produces none (Task 3).

---

### Task 1: Actual transaction changes and notifications

**Files:**
- Modify: `lib/play/play_room.ml`, `lib/play/play_room.mli`
- Modify: `lib/workspace_dataset_event.ml`, `lib/workspace_dataset_event.mli`
- Modify: `lib/server/server_routes_http_routes_play_room.ml`, `lib/tool_misc.ml`
- Modify: `bin/masc_tui_play_room.ml`, `bin/masc_tui.ml`
- Modify: `test/test_play_room.ml`, `test/test_tui_observer.ml`, `test/test_tui_play_room.ml`

**Interfaces:**
- Produces: `Play_room.change = { machine : Machine_lane.t; message_committed : bool; membership_changed : bool }`.
- Produces: `Play_room.perform_with_change : base_path:string -> who:string -> speaker:speaker -> now:float -> action -> (snapshot * change, error) result`.
- Preserves: `Play_room.perform` returns only the snapshot from `perform_with_change`.
- Produces: `Workspace_dataset_event.Play_room of { machine : Machine_lane.t }`, dataset name `play_room`, using the existing machine field decoder.
- Produces: `Masc_tui_play_room.revalidate : t -> t`, setting `next_read=0` and `changed_since` when pending. Any open room revalidates because the transcript is shared.
- Route and tool announce only when `message_committed || membership_changed` after an `Ok` transaction.

- [ ] **Step 1: Write failing tests**
  - `test_play_room.ml`: first Say sets message_committed and first public membership change; identical retry has both false; conflicting retry returns Error without a new change.
  - seen_at-only Join renewal has both false. New public member, final Leave, machine change, and public expiry have membership_changed=true with no message_committed.
  - Read/Say do not upsert membership: an old Read cannot revive it or change its machine, and Say records only the message.
  - Same-principal second tab does not emit a duplicate public membership event; last-tab Leave emits one.
  - `test_tui_observer.ml`: decode `play_room` with `machine="dos"`; reject unknown/missing machine without changing other datasets.
  - `test_tui_play_room.ml`: `revalidate` only sets `next_read=0` and pending `changed_since`; no no-polling assertion belongs to this task.

- [ ] **Step 2: Verify RED remotely**
  - Run `test_play_room,test_tui_observer,test_tui_play_room` with `gh workflow run test.yml --ref feat/play-room-sse -f minimal=true -f suite_timeout_sec=1200 -f suite='test_play_room,test_tui_observer,test_tui_play_room'`.
  - Expect missing `perform_with_change`, `Play_room` constructor, or `revalidate`. Do not mistake a compile-only first step for behavior proof.

- [ ] **Step 3: Implement metadata and notification**
  - Compute public membership identity from `(name, speaker, machine)`, excluding `seen_at`. Compare before/after snapshots within the same transaction; do not use raw per-client churn as a public event.
  - Change Read/Say to avoid membership upsert while preserving message dedup, snapshot, and existing Leave behavior.
  - Announce route and `masc_play_room` tool writes only on actual effects. Keep response and wire formats unchanged.
  - Add exhaustive dataset branches and the state-only `revalidate` transition, preserving pending identity.

- [ ] **Step 4: Verify GREEN remotely**
  - Rerun those three suites plus `test_h2_play_room,test_tui_acting`.
  - Expect all selected suites to pass, including tool write notification, idempotent HTTP retry, and no public-event regressions.

- [ ] **Step 5: Commit**
  - `git add lib/play/play_room.ml lib/play/play_room.mli lib/workspace_dataset_event.ml lib/workspace_dataset_event.mli lib/server/server_routes_http_routes_play_room.ml lib/tool_misc.ml bin/masc_tui_play_room.ml bin/masc_tui.ml test/test_play_room.ml test/test_tui_observer.ml test/test_tui_play_room.ml`
  - `git -c core.hooksPath=/dev/null commit -m "feat(play): announce actual room changes"`

### Task 2: Observer-owned presence and lease-safe HTTP/handoff

**Files:**
- Create: `lib/server/server_play_room_events.ml`, `lib/server/server_play_room_events.mli`
- Modify: `lib/server/server_mcp_transport_http.ml`, `lib/server/server_routes_http_routes_play_room.ml`
- Modify: `lib/sse.ml`, `lib/sse.mli`, preserving `Sse.register` while returning the exact client through `register_with_client`
- Modify: `lib/play/play_room.ml`, `lib/play/play_room.mli` with a typed Join/Leave client projection
- Create: `test/test_server_play_room_events.ml`, `test/stanzas/test_server_play_room_events.inc`
- Modify: `test/test_tui_execute_stream_http.ml` for the real Observer handoff contract
- Modify: `test/dune` only if the generated stanza include is not automatic

**Interfaces:**
- Produces: `Server_play_room_events.room_scope_of_request_target : string -> (room_scope option, string) result`; `play_client_id` requires valid `play_machine`, and absence of both returns `Ok None`.
- `room_scope` contains only `play_client` and `machine`, using the existing identifier and machine decoders.
- Produces: `connect`, `renew`, `disconnect`, each taking `~base_path ~agent_name ~role ~scope ~sse_client_id` and returning `(unit, Play_room.error) result`.
- Produces: `perform_http ~base_path ~agent_name ~role ~action`, allowing Join only without an active lease and Leave only without an active lease; Read/Say call `Play_room.perform_with_change` without membership upsert.
- `Sse.register_with_client` returns the exact committed `Sse.client`; transport passes its `agent_name`, `role`, `event_stream`, and `id`, not a current-session lookup.
- `Play_room.presence` exposes only the typed Join/Leave operation and client identity needed by the HTTP lease guard.

- [ ] **Step 1: Write failing tests**
  - `connect` creates membership and a `play_room` event; renew updates seen_at but emits nothing; disconnect removes membership.
  - Replacement with a new `sse_client_id` makes old renew/disconnect no-ops. Old HTTP Leave is ignored while a lease exists and does not delete replacement presence.
  - Connect failure leaves no lease and rejects the Observer. Renew failure keeps the lease for the next ping and does not close the Observer. Disconnect completes registry removal and Leave under a cancellation barrier, preserving the original cancellation afterward.
  - Injected permission denial rejects presence without using a role-specific fixture; invalid `play_client_id`, missing `play_machine`, and `play_machine` without `play_client_id` are rejected or inert as declared.
  - Machine metadata changes membership only; no Machine step is invoked. Include `test_sse_stream,test_tui_execute_stream_http` in regression scope.

- [ ] **Step 2: Verify RED remotely**
  - Run `test_server_play_room_events,test_sse_stream,test_tui_execute_stream_http`.
  - Expect the new module to be absent; implement to green only after the test is executable.

- [ ] **Step 3: Implement presence registry and transport wiring**
  - Use an Eio mutex around key replacement and DB effects, never an Sse registry or other store mutex.
  - `connect` joins before registering the lease; `renew` requires exact id; `disconnect` requires exact id. Cancellation-protect registry removal and Leave without hiding the original cancellation.
  - `who` comes from `Sse.client.agent_name`; enforce `Masc_domain.has_permission role CanPlayMachine` and fail closed. Add a narrow `For_testing` permission seam instead of a false role claim.
  - Start presence only after workspace/readiness admission. Renew from the existing 30-second ping and cleanup from the existing disconnect hook, preserving the original hook and queues.
  - Create the new Observer/lease before closing the old connection, and close the old connection before publishing the new transport connection. Keep `client_id`-guarded unregister so old cleanup cannot remove the new connection.
  - Guard HTTP Join/Leave against the active lease; Read/Say use Task 1's no-membership-upsert path.

- [ ] **Step 4: Verify GREEN remotely**
  - Rerun those suites and `test_play_room,test_h2_play_room,test_tui_execute_stream_http`.
  - Expect all selected suites to pass; no extra Machine step, public SSE regression, or Leave/Join gap in the handoff contract.

- [ ] **Step 5: Commit**
  - `git add lib/server/server_play_room_events.ml lib/server/server_play_room_events.mli lib/server/server_mcp_transport_http.ml lib/server/server_routes_http_routes_play_room.ml lib/sse.ml lib/sse.mli lib/play/play_room.ml lib/play/play_room.mli test/test_server_play_room_events.ml test/stanzas/test_server_play_room_events.inc test/test_tui_execute_stream_http.ml test/dune`
  - `git -c core.hooksPath=/dev/null commit -m "feat(sse): bind play presence to observers"`

### Task 3: Stop successful polling and retain exact revalidation

**Files:**
- Modify: `bin/masc_tui_play_room.ml`, `bin/masc_tui.ml`, `bin/masc_tui_http.ml`
- Modify: `test/test_tui_play_room.ml`
- Create: `test/test_tui_play_room_push.py`, `test/stanzas/test_tui_play_room_push.inc`

**Interfaces:**
- Consumes: Task 1's `Masc_tui_play_room.revalidate` and `Play_room` dataset.
- Observer accepts optional `~play:(Machine_lane.t * string)`; HTTP emits `play_machine` and `play_client_id` only for the currently open room. It does not alter Control `machine` or Browser scopes.
- Every open room revalidates on `Play_room` regardless of source machine; hidden rooms preserve Leave and do not read.

- [ ] **Step 1: Write failing tests**
  - After a successful active Read, polling produces no new request at `now=3` and `now=3600`.
  - A failed Read retries at `now+2`; `revalidate` during pending produces exactly one trailing Read; `active=false` preserves Leave and its retries.
  - `test_tui_play_room_push.py` records initial POST 1, idle POST 0 after 2.4s, dataset POST 1, pending trailing POST 1, reconnect POST 1, hidden POST 0, and `play_machine`/`play_client_id` query.

- [ ] **Step 2: Verify RED remotely**
  - Run `test_tui_play_room,test_tui_play_room_push`.
  - Expect successful polling and absent Play revalidation to fail. Preserve these as real PTY RED logs.

- [ ] **Step 3: Implement TUI behavior**
  - Set successful active `next_read=infinity`; keep failed reads at `now+2` and inactive Leave behavior.
  - Response with `changed_since` schedules immediate trailing read, otherwise success becomes infinity. Cross-machine events use the same path.
  - Add the optional play query without moving ownership from render state or enabling machine advance in Watch.

- [ ] **Step 4: Verify GREEN remotely**
  - Rerun those suites and `test_tui_observer,test_tui_spectator_push,test_tui_execute_stream_http`.
  - Expect all selected suites to pass. Record actual phase request counts rather than claiming them from source.

- [ ] **Step 5: Commit**
  - `git add bin/masc_tui_play_room.ml bin/masc_tui.ml bin/masc_tui_http.ml test/test_tui_play_room.ml test/test_tui_play_room_push.py test/stanzas/test_tui_play_room_push.inc`
  - `git -c core.hooksPath=/dev/null commit -m "feat(tui): replace play polling with SSE revalidation"`

### Task 4: Full regression, measurements, evidence, and independent review

**Files:**
- Create: `docs/evidence/tui-play-room-sse-20261105/README.md`, `summary.json`, `request-counts.json`, `independent-review.json`
- Modify: `docs/superpowers/specs/2026-11-05-play-room-sse-design.md` only if implementation disproves a decision

**Interfaces:**
- Final evidence binds exact production head, test run IDs, PTY request counts, remaining Browser sampling and closed-PR state.

- [ ] **Step 1: Run full regression and exact-source proof**
  - Run the previous 24 suites plus `test_play_room`, `test_h2_play_room`, `test_tui_play_room`, `test_server_play_room_events`, `test_tui_play_room_push` and `pr-type-check.yml` on the final production head.
  - Obtain an exact-source macOS `masc_tui` artifact and run the new PTY locally without installing it. Confirm embedded build commit, no idle POST, trailing/reconnect reads, and no runtime data changes.

- [ ] **Step 2: Independent adversarial review**
  - Request read-only review of the complete branch diff, including idempotency, stale-disconnect and HTTP lease races, auth, cancellation/lock order, Watch machine advance, shared-machine transcript, and pending trailing semantics.
  - Fix P0-P2 findings with new failing tests first; record P3 and unverified Browser behavior separately.

- [ ] **Step 3: Write and verify evidence**
  - Record actual pass/fail, run IDs, request counts, binary hash, review verdict, Browser sampling limitation, and no merge/install actions.
  - Validate JSON and `git diff --check`; do not call full native push complete while Browser sampling remains.

- [ ] **Step 4: Commit**
  - `git add docs/evidence/tui-play-room-sse-20261105 docs/superpowers/plans/2026-11-05-play-room-sse.md docs/superpowers/specs/2026-11-05-play-room-sse-design.md`
  - `git -c core.hooksPath=/dev/null commit -m "docs(play): record SSE transition evidence"`
