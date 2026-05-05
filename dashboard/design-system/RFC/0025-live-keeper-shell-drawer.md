# RFC 0025 — Live Keeper Shell Drawer

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Depends on**: (없음, 신규 표면)
- **Parent RFC**: RFC 0022 (IDE Plane Assembly v1)
- **GitHub Issue**: #13200
- **Prototype reference**: `Downloads/MASC Cockpit (3)/cockpit-kit/Drawer.jsx::TerminalPanel` (mock data, lines 33-62)

---

## 1. Motivation

cockpit-kit prototype `Drawer.jsx::TerminalPanel` 의 mock terminal lines (`{ t: "01:42:18", k: "tx", txt: "$ git fetch --all" }` 하드코딩) 을 실제 keeper shell stdout/stderr ring buffer 로 교체. 단일 cockpit 에서 multi-keeper shell 을 동시에 watch (마치 tmux pane).

memory `feedback_keeper-reaction-chain-break-analysis-2026-05-04` 의 9 termination paths + 6 partial recovery 를 실시간 시각으로 본다.

## 2. Non-Goals

- input wire-in (read-only v1; input 은 별도 RFC + RBAC 검토)
- multi-keeper split pane (single-keeper-at-a-time v1)
- shell history persistence (ring buffer 만; persistent log 는 audit 영역)
- keeper shell 자체 변경 (`lib/keeper/keeper_shell_*` 의 consumer only)

## 3. Public API

### 3.1 SSE 채널

```
GET /api/dashboard/keeper-shell/<keeper_id>?since_ms=<ts>
Accept: text/event-stream
```

이벤트:

```json
{
  "kind": "snapshot" | "line",
  "ts_ms": 1777981200000,
  "keeper_id": "sangsu",
  "lines": [ShellLine...]    // kind=snapshot
  "line": ShellLine           // kind=line (single)
}
```

### 3.2 ShellLine

```json
{
  "ts_ms": 1777981200123,
  "stream": "stdout" | "stderr" | "cmd" | "system",
  "text": "...",
  "ansi": true | false           // ANSI escape sequences 보존 여부
}
```

ring buffer 크기: 5000 lines (env `MASC_KEEPER_SHELL_RING_BUFFER=5000`).

### 3.3 Drawer client

```tsx
// dashboard/src/components/ide/drawer.tsx
interface DrawerProps {
  readonly activeTab: 'terminal' | 'output' | 'cascade' | 'audit' | 'cost'
  readonly keeperId: string | null      // for terminal tab
}
```

`?keeper=<name>` URL 파라미터 → SSE 구독. tab 전환 시 SSE 정리.

## 4. Server-side

### 4.1 Capture point

`lib/keeper/keeper_shell_*` 또는 `lib/keeper_shell_capture` 에 ring buffer broadcast 추가:

```ocaml
val attach_capture :
  keeper_id:string ->
  buffer:Ring_buffer.t ->
  unit
(** Hook into keeper PTY stdout/stderr; appends each line to ring buffer
    and emits SSE event to subscribers. *)
```

### 4.2 SSE handler

`lib/dashboard/dashboard_keeper_shell.ml(i)` 신규.

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
[01:42:25] stderr    ✗ cascade.fanout.cycle_detection    (timeout)
```

ANSI sequences → CSS class via `parseAnsi()` (existing helper). 자동 스크롤 (latest line 보임), reduced-motion 시 jump.

## 6. ARIA

- region: `role="log"` + `aria-live="polite"` + `aria-label="keeper shell — {keeper_id}"`
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
