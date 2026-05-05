# RFC 0033 — Worktree Status SSE Channel

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode 2026-05-05)
- **Created**: 2026-05-05
- **Sister RFC**: design-system `dashboard/design-system/RFC/0022-ide-plane-assembly.md`
- **Depends on**: `lib/coord/coord_worktree.ml` (existing)
- **Blocks**: GitHub Issue #13197 (P0-A worktree-aware IDE plane)

---

## 1. Motivation

Dashboard IDE plane (`dashboard/src/components/ide/keeper-presence-store.ts`)이 `workspace_label` 필드 contract 를 갖고 있지만 `rg "worktree" lib/dashboard/` 가 0 hit — 서버가 worktree 정보를 dashboard 에 노출하지 않는다.

이 세션 (2026-05-05) 에서 본 cwd 누락 사고들 — PR #13174 작업 중 배경 dune build 가 worktree 가 아닌 main root 를 빌드한 사례 — 을 cockpit 에서 시각으로 막을 수 있다 (cf. memory `feedback_pre_push_check_pr_state_must_be_active`).

또 `feedback_check_open_prs_before_unblock_pr_chore` 의 race-window rule 이 시각화되어 사용자가 stale PR head 와 main HEAD 차이를 cockpit topbar 에서 즉시 본다.

## 2. Non-Goals

- worktree 생성/삭제 등 mutating action (read-only)
- multi-repo (현 시점 single repo `masc-mcp` 만; multi-repo 는 keeper-repo-mapping 어댑터 별도 RFC)
- per-keeper attach state — 별도 store (`keeper-presence-store`)
- branch 전환 등 git plumbing 자동화

## 3. Public API

### 3.1 SSE 채널

```
GET /api/dashboard/worktree-status
Accept: text/event-stream
```

이벤트 형식 (newline-delimited JSON, SSE `data:` 프리픽스):

```json
{
  "kind": "snapshot" | "patch",
  "ts_ms": 1777981200000,
  "entries": [WorktreeEntry...],         // kind=snapshot
  "added": [WorktreeEntry...],           // kind=patch
  "removed": ["worktree_path"...],       // kind=patch
  "updated": [WorktreeEntry...]          // kind=patch
}
```

snapshot: 최초 1회 + reconnect 시. patch: filesystem watcher debounced 1s.

### 3.2 REST snapshot fallback

```
GET /api/dashboard/worktree-status?snapshot=1
```

returns `{ "ts_ms": ..., "entries": [...] }`.

### 3.3 WorktreeEntry

```json
{
  "worktree_path": "/Users/dancer/me/.../.worktrees/feature/ide-plane-rfc-umbrella",
  "branch": "feature/ide-plane-rfc-umbrella",
  "head_sha": "7df987d030",
  "is_main": false,
  "is_detached": false,
  "is_bare": false,
  "changed_count": 3,
  "staged_count": 0,
  "untracked_count": 1,
  "ahead_count": 0,
  "behind_count": 0,
  "pr_number": 13197,
  "pr_state": "OPEN" | "MERGED" | "CLOSED" | null,
  "pr_is_draft": true,
  "keeper_attached": "sangsu" | null,
  "last_activity_ms": 1777981200000
}
```

## 4. Implementation

### 4.1 Module

`lib/dashboard/dashboard_worktree_status.ml(i)` 신규.

서명 (.mli):

```ocaml
(** Worktree status snapshot for dashboard IDE plane.

    Read-only snapshot of git worktrees registered in this repo.
    Source: [Coord_worktree] for filesystem ops + [gh pr list] for PR state.
    Cached in-memory with 5s TTL; FS watcher invalidates eagerly. *)

type pr_state = Open | Merged | Closed

type entry = {
  worktree_path : string;
  branch : string;
  head_sha : string;
  is_main : bool;
  is_detached : bool;
  is_bare : bool;
  changed_count : int;
  staged_count : int;
  untracked_count : int;
  ahead_count : int;
  behind_count : int;
  pr_number : int option;
  pr_state : pr_state option;
  pr_is_draft : bool;
  keeper_attached : string option;
  last_activity_ms : int64;
}

val snapshot : sw:Eio.Switch.t -> base_path:string -> entry list
(** Snapshot of all worktrees rooted under [base_path].  Hits cache
    if fresh (< 5s); otherwise re-reads via [Coord_worktree] and
    invokes [gh pr list] once for the full branch set. *)

val sse_handler :
  sw:Eio.Switch.t ->
  base_path:string ->
  Eio.Net.stream_socket_ty Eio.Resource.t ->
  unit
(** SSE handler emits `snapshot` once then `patch` events on FS change. *)
```

### 4.2 Data sources

1. `Coord_worktree.run_argv_lines ["git"; "worktree"; "list"; "--porcelain"]`
2. each worktree: `git -C <path> status --porcelain` (changed/staged/untracked count)
3. `git -C <path> rev-list --count <branch>..origin/<branch>` (ahead/behind)
4. `gh pr list --json number,state,isDraft,headRefName --limit 200` (1 호출, branch list 와 join)
5. keeper attach: `Keeper_state_store` lookup (별도 모듈; v1 nullable)

### 4.3 Cache

- in-memory `entry list ref` + `last_refresh_ts_ms`
- TTL: 5초 (env `MASC_WORKTREE_STATUS_TTL_SEC` 가능)
- FS watcher on `.git/worktrees/*` + `.git/refs/heads/*` → eager invalidate
- 33 worktree env 에서 cold response < 500ms 측정 후 조정

### 4.4 Pagination

- 200 worktree 초과 시 cursor pagination: `?after=<worktree_path>&limit=50`
- v1 default: 모든 entry 반환 (warn log 시점에 page 분할 검토)

### 4.5 Routing

`bin/main_eio` 또는 `lib/dashboard/dashboard_routes.ml` 에 path 등록:
- `GET /api/dashboard/worktree-status` → `sse_handler`
- `GET /api/dashboard/worktree-status?snapshot=1` → JSON snapshot

## 5. Client wire-up (참조)

DS RFC-0022 §3 Sub-task 매핑 P0-A 참조. `keeper-presence-store.ts` 의 `workspace_label` 매퍼가 `worktree_path` 의 last segment 를 라벨로 사용 (예: `feature/ide-plane-rfc-umbrella`). topbar chip 에서 `pr_number` 가 있으면 `#13197` suffix.

## 6. Test plan

- **unit**: `test/test_dashboard_worktree_status.ml` — 빈 list, 1 worktree, 33 worktree, malformed `git worktree list` 라인, `gh pr list` 0 PRs 케이스
- **integration**: localhost SSE 구독 + JSON event 검증 (snapshot → patch 흐름)
- **benchmark**: 33 worktree cold response < 500ms (`time curl -s http://localhost:8935/api/dashboard/worktree-status?snapshot=1`)
- **stale data**: cache miss + 동시 5 클라이언트 → coalesce 검증

## 7. Migration / Rollback

- env knob `MASC_WORKTREE_STATUS_ENABLED=true` (default true after PR-2 머지)
- 끔 시 client 는 빈 entries 표시 (graceful degrade — chip 영역 빈 채로)
- rollback: env false 만으로 disable; 핸들러 자체 제거는 RFC withdraw 시

## 8. Open questions

1. **`gh pr list` rate limit**: 5초 TTL 으로 분당 최대 12회. github API rate limit 5000/hr 의 아주 작은 비율이지만 cache miss 폭주 시 spike 가능 → coalesce 락.
2. **bare worktree 처리**: `--porcelain` 출력에 `bare` flag. v1: `is_bare=true` 만 표시, 다른 필드 0.
3. **keeper_attached 산출**: keeper 가 branch 와 1:1 mapping 인가 1:N 인가? v1 best-effort (1 keeper → 1 branch); 다중 시 first-wins.

이 질문들은 PR-2 시작 전 close 한다.
