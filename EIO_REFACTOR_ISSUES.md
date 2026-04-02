# OCaml 5.x / Eio Refactoring & Improvement Issues

이 문서는 OCaml 5.x 및 Eio의 베스트 프랙티스(Direct-style, Structured Concurrency, Message Passing)를 기준으로 `masc-mcp` 메인 브랜치의 현재 상태를 진단하고 작성된 개선 이슈 목록입니다.

**최종 업데이트: 2026-03-26** — 4개 이슈 모두 해결됨.

---

## Issue 1: [Low — Dedup] File Lock Retry 코드 중복 제거

> **심각도 하향 (Critical → Low)**: 탐색 결과, `Unix.sleepf` 호출 4건 모두 `Eio_unix.run_in_systhread` (= `run_blocking_lock_op`) 내부에서 실행되어 Eio 이벤트 루프를 블로킹하지 않음. 원래 진단(Critical: event loop blocking)은 오진. 실제 문제는 동일 retry 패턴의 copy-paste 중복.

**상태: 해결됨** — PR #3193 (`feature/eio-flock-dedup`) + #3189 (systhread 주석)

**변경 내용:**
- `File_lock_eio.acquire_flock_retry`를 중앙 함수로 추출
- `backend.ml`, `governance_v2.ml`, `hebbian_eio.ml`의 inline retry를 중앙 함수 호출로 교체
- 모든 `Unix.sleepf` 호출에 systhread-safe 주석 추가

**원래 발견된 위치 (중복이었던 곳):**
- `lib/process/file_lock_eio.ml` — `acquire_flock_fd` (원본, 이제 `acquire_flock_retry` 호출)
- `lib/backend/backend.ml` — `with_locked_rw_fd` (중복 제거됨)
- `lib/hebbian_eio.ml` — `with_graph_lock` (중복 제거됨)

---

## Issue 2: [Architecture] Mutex → Stream 전환 (chain fanout)

> 원래 이슈는 100건+ `Eio.Mutex`의 전면적 리팩토링이었으나, 감사 결과 대부분의 Mutex는 장기 공유 상태 보호 용도로 정당함. 실제로 Mutex가 불필요한 곳은 chain executor의 parallel fanout 결과 수집 6건.

**상태: 해결됨** — PR #3197 (`feature/eio-stream-fanout`)

**변경 내용:**
- `chain_executor_eio.ml`: 4개 fanout 사이트(execute_fanout, execute_parallel_group, execute_merge, checkpoint parallel)에서 mutex+ref → `Eio.Stream` 전환
- `chain_executor_search.ml`: 2개 사이트(MCTS sim_results, evaluator candidates)에서 동일 전환
- `chain_executor_search.ml:214`의 `tree_mutex`는 장기 mutable state이므로 유지

**판단 근거:** `Eio.Fiber.all`이 동기화 배리어를 제공하므로, one-shot 결과 수집에 Mutex는 불필요. Stream의 bounded capacity가 자연스러운 backpressure를 제공.

---

## Issue 3: [Resilience] Fiber.fork 예외 경계 강화

**상태: 해결됨** — PR #3192 (`fix/3182-fiber-exception-leak`, 병렬 세션에서 작업)

**변경 내용:**
- `server_runtime_bootstrap.ml`: 3개 bare fork를 `fork_subsystem`으로 전환 (keeper lifecycle, board_listener, SSE maintenance)
- `keeper_keepalive.ml`: 2개 bare fork에 try/catch 예외 경계 추가 (gRPC heartbeat, heartbeat loop)
- `Eio.Cancel.Cancelled`는 모든 경계에서 반드시 re-raise
- `Subsystem_health` 모듈과 연동하여 장애 fiber 상태 추적

**핵심 패턴:**
```ocaml
let fork_subsystem name f =
  Subsystem_health.register name;
  Eio.Fiber.fork ~sw (fun () ->
    try f ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Subsystem_health.mark_dead name; Log.Server.error ...)
```

---

## Issue 4: [Performance] Executor_pool 확장 — CPU-bound 작업 offload

**상태: 해결됨** — PR #3199 (`feature/eio-executor-pool-chain`) + PR #3210 (`feature/eio-chain-adapter-offload`)

**변경 내용:**

Phase A (PR #3199): 공유 pool ref 추출
- `Executor_pool_ref` 모듈을 `lib/core/`에 추가 (get/set/submit_or_inline)
- `server_dashboard_http_core.ml`의 로컬 pool ref를 공유 ref로 전환
- `submit_or_inline`은 pool 미설정 시 inline fallback 제공

Phase B (PR #3210): Chain adapter offload
- `chain_adapter_eio.ml`의 Extract, ValidateSchema, ParseJson 변환에 `submit_or_inline` 적용
- Domain-safety 감사 완료: 3개 모두 Yojson + stdlib만 사용, `Str` 모듈 미사용
- `Str` 의존 변환(Template, Regex, Conditional, Split)은 domain-unsafe이므로 미변경

**Domain-Safety 감사 결과:**

| Transform | Domain-safe | 근거 |
|-----------|-------------|------|
| Extract | O | Yojson + String.split_on_char |
| ValidateSchema | O | Yojson + local ref |
| ParseJson | O | Yojson.Safe.from_string |
| Template | X | Str.global_replace (global state) |
| Regex | X | Str.regexp (global state) |
| Conditional | X | Str.regexp_string (global state) |
| Split | X | Str.regexp, Str.split (global state) |

---

## Summary

| Issue | 원래 심각도 | 실제 심각도 | 해결 PR | 상태 |
|-------|-----------|-----------|---------|------|
| 1. Unix.sleepf/flock dedup | Critical | Low (dedup) | #3193, #3189 | 해결 |
| 2. Mutex → Stream | Architecture | Low-Medium | #3197 | 해결 |
| 3. Fiber.fork 예외 | Resilience | Medium | #3192 | 해결 |
| 4. Executor_pool 확장 | Performance | Medium-High | #3199, #3210 | 해결 |
