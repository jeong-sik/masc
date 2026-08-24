---
status: runbook
---

# MASC 고가용성 서버 로드맵

> 목표: 장애 복구와 운영 안정성을 강화하는 MCP 서버

## 현재 상태

### 있는 것
- `workspace_resilience.ml` — 시간 파싱과 관찰 헬퍼
- `rate_limit.ml` — 요청 제한
- `cancellation.ml` — 취소 처리
- `lib/keeper/keeper_supervisor.ml` — keeper 단위 감독. `.mli`가 스스로 AGENT_CORE `Agent.run` 생명주기는 감독하지 않는다고 한정한다
- `lib/dashboard/dashboard_feature_health.ml` — `Feature_flag_registry.all_flags` 의 플래그별 health
- `lib/dashboard/dashboard_harness_health.ml` — harness health 판정을 기록하는 원장 (판정은 다른 곳에서 온다)
- `lib/fs_compat/capability_recovery_*.ml`, `publication_recovery_*.ml` — 기동 시 파일 표면 정합 복구. `mcp_server.ml` 까지 배선됨
- `lib/shutdown.ml`, `lib/shutdown_hooks.ml` — 단계가 정의된 graceful shutdown. `bin/main_eio.ml:664` 가 SIGINT/SIGTERM 에 물려 있다
- `lib/server/proactive_refresh.ml` — circuit breaker 를 가진 refresh 루프. `lib/dashboard/dashboard_cache.ml:109,664` 에 timeout circuit
- `lib/session.ml` `restore_from_disk` — 재시작 시 세션 복구. `lib/server/server_runtime_bootstrap.ml:570` 에서 호출

### 없는 것
- 프로세스 전체를 덮는 Supervision Tree. `lib/subsystem_health.ml` 이 전역 alive/dead 레지스트리를 갖지만 `server_bootstrap_loops.ml:963` 은 죽음을 표시할 뿐 재시작하지 않는다

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

아래는 설계 스케치다. 배선되는 감독자만 만든다 — 소비자 없는 감독 트리는 이전에 한 번 만들었다가 아무도 부르지 않아 사라졌다.
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
