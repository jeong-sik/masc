---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/supervisor.ml
  - lib/keeper/keeper_keepalive.ml
  - lib/keeper/keeper_supervisor.ml
---

# MASC 고가용성 서버 로드맵

> 목표: 장애 복구와 운영 안정성을 강화하는 MCP 서버

## 현재 상태

### ✅ 있는 것
- `resilience.ml` - ZeroZombie (좀비 에이전트 정리)
- `rate_limit.ml` - 요청 제한
- `cancellation.ml` - 취소 처리

### ❌ 없거나 부족한 것
- Supervision Tree
- Health Check 시스템
- Graceful Shutdown
- Auto Recovery
- Circuit Breaker
- State Persistence (재시작 복구)

---

## Phase 1: 생존 기반 (P0)

### 1.1 Supervision Tree
```
                    ┌─────────────────┐
                    │   Supervisor    │
                    │  (최상위 감독)   │
                    └────────┬────────┘
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                 ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ MCP Server   │  │ HTTP Server  │  │ Background   │
    │ Supervisor   │  │ Supervisor   │  │ Tasks Sup    │
    └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
           │                 │                 │
     [workers]          [workers]         [workers]
```

**구현 파일**: `lib/supervisor.ml`
```ocaml
type restart_strategy = 
  | OneForOne      (* 하나 죽으면 그것만 재시작 *)
  | OneForAll      (* 하나 죽으면 전부 재시작 *)
  | RestForOne     (* 하나 죽으면 그 이후 것들 재시작 *)

type child_spec = {
  id: string;
  start: unit -> unit Eio.Promise.t;
  restart: [ `Permanent | `Transient | `Temporary ];
  shutdown: [ `Brutal_kill | `Timeout of float ];
}
```

### 1.2 Health Check System
```ocaml
(* lib/health.ml *)
type health_status =
  | Healthy
  | Degraded of string
  | Unhealthy of string

type component = {
  name: string;
  check: unit -> health_status;
  critical: bool;  (* true면 이게 죽으면 서버 종료 *)
}

(* 주기적 체크 + 외부 /health 엔드포인트 *)
```

### 1.3 Graceful Shutdown
```ocaml
(* lib/shutdown.ml *)
type shutdown_phase =
  | StopAccepting      (* 새 연결 거부 *)
  | DrainConnections   (* 기존 연결 처리 완료 대기 *)
  | CleanupResources   (* 리소스 정리 *)
  | SaveState          (* 상태 저장 *)
  | Exit

(* SIGTERM/SIGINT 핸들링 *)
```

---

## Phase 2: 자가 치유 (P1)

### 2.1 Auto Recovery
```ocaml
(* lib/recovery.ml *)
type recovery_action =
  | Restart
  | RestartWithBackoff of { max_attempts: int; base_delay: float }
  | Escalate  (* 상위 supervisor에게 알림 *)
  | Ignore

(* Exponential backoff: 1s → 2s → 4s → 8s → ... → max 60s *)
```

### 2.2 Circuit Breaker
```ocaml
(* lib/circuit_breaker.ml *)
type state = Closed | Open | HalfOpen

type t = {
  mutable state: state;
  mutable failure_count: int;
  mutable last_failure: float;
  threshold: int;        (* 이 횟수 실패하면 Open *)
  timeout: float;        (* Open 상태 유지 시간 *)
  half_open_max: int;    (* HalfOpen에서 허용할 요청 수 *)
}

(* 외부 서비스 호출 시 사용 *)
let call breaker f =
  match breaker.state with
  | Open -> Error `CircuitOpen
  | _ -> try Ok (f ()) with e -> record_failure breaker; raise e
```

### 2.3 State Persistence
```ocaml
(* lib/checkpoint.ml - 기존 것 강화 *)
type checkpoint = {
  version: int;
  timestamp: float;
  agents: agent_state list;
  sessions: session_state list;
  pending_tasks: task list;
}

(* 주기적 저장 + 시작 시 복원 *)
```

---

## Phase 3: 고가용성 심화 (P2)

### 3.1 Hot Reload
- 코드 변경 시 서버 재시작 없이 적용
- OCaml dynlink 또는 외부 프로세스 교체

### 3.2 Cluster Mode
- 다중 노드 지원
- 리더 선출 (Raft?)
- 상태 동기화

### 3.3 Chaos Engineering
- 랜덤 장애 주입 테스트
- 복구 시간 측정
- 약점 발견

---

## 구현 우선순위

| Phase | 항목 | 예상 시간 | 효과 |
|-------|------|----------|------|
| 1.1 | Supervision Tree | 2-3일 | ⭐⭐⭐⭐⭐ |
| 1.2 | Health Check | 1일 | ⭐⭐⭐⭐ |
| 1.3 | Graceful Shutdown | 1일 | ⭐⭐⭐⭐ |
| 2.1 | Auto Recovery | 1-2일 | ⭐⭐⭐⭐⭐ |
| 2.2 | Circuit Breaker | 1일 | ⭐⭐⭐ |
| 2.3 | State Persistence | 2일 | ⭐⭐⭐⭐ |
| 3.x | Advanced | 추후 | - |

---

## OpenClaw 참고 포인트

1. **Gateway 중심** - 모든 통신이 한 곳 통과 → 장애 감지 용이
2. **영속 레지스트리** - 재시작 후 sub-agent 복구
3. **Health State** - `server.impl.ts`의 상태 관리
4. **Lazy Loading** - 필요할 때만 로드 → 메모리 효율

---

## 시작점

```bash
# Phase 1.1부터 시작
touch lib/supervisor.ml lib/supervisor.mli
```

**첫 번째 목표**: MCP 서버 프로세스가 죽어도 Supervisor가 자동 재시작
