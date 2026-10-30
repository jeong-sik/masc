# RFC 0025 — Live Execute Output Drawer

- **Status**: Draft
- **Author**: Vincent + Agent Runtime A (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Depends on**: (없음, 신규 표면)
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **GitHub Issue**: #13200
- **Prototype reference**: `Downloads/MASC Cockpit (3)/cockpit-kit/Drawer.jsx::TerminalPanel` (mock data, lines 33-62)

---

## 1. Motivation

cockpit UI Kit prototype `Drawer.jsx::TerminalPanel` (`dashboard/design-system/ui_kits/cockpit/Drawer.jsx`) 의 mock terminal lines (`{ t: "01:42:18", k: "tx", txt: "$ git fetch --all" }` 하드코딩) 을 실제 Execute stdout/stderr ring buffer 로 교체. 단일 cockpit 에서 multi-keeper Execute stream 을 동시에 watch (마치 tmux pane).

memory `feedback_keeper-reaction-chain-break-analysis-2026-05-04` 의 9 termination paths + 6 partial recovery 를 실시간 시각으로 본다.

## 2. Non-Goals

- input wire-in (read-only v1; input 은 별도 RFC + RBAC 검토)
- multi-keeper split pane (single-keeper-at-a-time v1)
- shell history persistence (ring buffer 만; persistent log 는 audit 영역)
- Execute/Shell IR 자체 변경 (consumer only)

## 3. Public API

### 3.1 SSE 채널

```
GET /api/dashboard/execute-output/<keeper_id>
Accept: text/event-stream
```

첫 이벤트는 `snapshot`(완료된 작업이 없으면 `no_task`)이고, 그 뒤로 live 이벤트가 이어져요.

```json
{ "kind": "snapshot", "keeper_id": "sangsu", "lines": [ShellLine...], "last_seq": 1042, ... }
{ "kind": "task_opened", "keeper_id": "sangsu", "seq": 1043, "task_id": "..." }
{ "kind": "line", "keeper_id": "sangsu", "seq": 1044, "line": ShellLine }
{ "kind": "task_closed", "keeper_id": "sangsu", "seq": 1045, "status": {...} }
{ "kind": "gap", "keeper_id": "sangsu", "missing_from_seq": 1046, "missing_to_seq": 1070, "missing_count": 25 }
```

- 서버는 keeper마다 번호 붙은 로그 하나를 둬요. `line`, `task_opened`, `task_closed`가 한 번호 체계를 나눠 써요.
- live 이벤트는 snapshot의 `last_seq` 다음 번호부터 시작해요. 그래서 같은 줄이 두 번 오지 않아요.
- 구독자가 로그 보관 한도보다 뒤처지면, 서버에서도 사라진 번호 범위를 `gap` 한 번으로 알리고 가장 오래 남은 번호부터 이어가요.

### 3.2 ShellLine

```json
{
  "seq": 1044,
  "ts_ms": 1777981200123,
  "stream": "stdout" | "stderr",
  "text": "...",
  "ansi": false
}
```

로그 보관 한도: keeper마다 이벤트 5000개(`Dashboard_execute_output.event_log_capacity`).

### 3.3 Drawer client

```tsx
// dashboard/src/components/ide/drawer.tsx
interface DrawerProps {
  readonly activeTab: 'terminal' | 'output' | 'runtime' | 'audit' | 'cost'
  readonly keeperId: string | null      // for terminal tab
}
```

`?keeper=<name>` URL 파라미터 → SSE 구독. tab 전환 시 SSE 정리.

## 4. Server-side

### 4.1 Capture point

Execute runtime/receipt boundary 에 ring buffer broadcast 추가:

```ocaml
val attach_capture :
  keeper_id:string ->
  buffer:Ring_buffer.t ->
  unit
(** Hook into Execute stdout/stderr; appends each line to ring buffer
    and emits SSE event to subscribers. *)
```

### 4.2 SSE handler

`lib/dashboard/dashboard_execute_output.ml(i)` 신규.

```ocaml
val sse_handler :
  sw:Eio.Switch.t ->
  keeper_id:string ->
  Eio.Net.stream_socket_ty Eio.Resource.t ->
  unit
```

snapshot (since_ms 이후 ring buffer 라인) → live patches.

## 5. Rendering

terminal tab 본문:

```
[01:42:18] cmd  $ git fetch --all
[01:42:18] stdout  fetching origin (5 refs)
[01:42:25] stderr    ✗ runtime.fanout.cycle_detection    (timeout)
```

ANSI sequences → CSS class via `parseAnsi()` (existing helper). 자동 스크롤 (latest line 보임), reduced-motion 시 jump.

## 6. ARIA

- region: `role="log"` + `aria-live="polite"` + `aria-label="Execute output — {keeper_id}"`
- 각 line: `role="listitem"` (parent `role="list"`)
- aria-atomic false (각 line 개별 announce)

## 7. Test plan

- unit: `drawer.test.tsx` — SSE 연결, 끊김 reconnect, tab 전환 cleanup
- integration: 16 keeper sustained env 에서 메모리 leak 없음 (heap snapshot delta)
- e2e: `?keeper=sangsu` 방문 → 라이브 stdout 표시 (Playwright)

## 8. Performance

- 5000 lines × 16 keeper = 80k lines max in memory if all attached. v1: 1 keeper at a time → 5k lines. Solid fine-grained reactivity 로 line append 시 전체 re-render 안 됨.
- ring buffer 라인 길이 truncate 4096 chars (long stdout 보호).

## 9. Open questions

1. **ANSI sequences vs plain text**: 보존 시 보안 (escape injection) 검토 필요. v1: whitelist (color, bold, dim 만).
2. **PTY 멀티플렉싱**: 현 lib/keeper 가 PTY 1개 per keeper 인지 multiplex 인지 확인 필요. multiplex 면 ring buffer 도 multiplex.
3. **input 단계 권한**: PR-7+ 에서 RBAC + per-keeper allow-list. v1 read-only.
