# MASC (Multi-Agent workspace Collaboration)

[![OCaml](https://img.shields.io/badge/OCaml-5.4+-orange.svg)](https://ocaml.org/)
[![OAS](https://img.shields.io/badge/agent__sdk-%E2%89%A50.206.1-blue.svg)](https://github.com/jeong-sik/oas)

> **Personal Infrastructure Invariant**  
> 본 프로젝트는 개발자 1인의 워크플로우를 위해 설계된 개인용 에이전트 오케스트레이션 및 모니터링 시스템입니다. 프로덕션 SLA, 외부 하드웨어 호환성, 혹은 SemVer 기반의 API 호환성을 제공하지 않습니다.

MASC는 **OCaml 5.x + Eio** 기반의 비차단 멀티 파이버(Multi-Fiber) 아키텍처로 구현된 에이전트 자율 협업 및 제어 플레인입니다. 같은 저장소(Repository) 공간을 점유하고 동시에 작업하는 AI 코딩 에이전트들이 충돌 없이 자율적으로 Turn, Lock, Workspace State, Heartbeat, Task Owner를 교환하도록 중재합니다.

---

## 1. MASC vs. OAS Architectural Boundary

MASC와 OAS(agent_sdk)는 명확히 분리된 경계(RFC-0058 / OAS-MASC-BOUNDARY)를 가집니다.

```
┌──────────────────────────────────────────────────┐
│              Consumer / Client                    │
│       (Local Agent, Chat, Slack, Discord)        │
└────────────────┬─────────────────────────────────┘
                 │ MCP / Channel Gate
┌────────────────▼─────────────────────────────────┐
│            MASC (Workspace Collaboration)         │
│  - Multi-Channel & Single-Flight Admission       │
│  - Phase & Turn FSM / Keeper Lifecycle           │
│  - Workspace, Board, Task, Claim primitives      │
│  - CDAL (Decision Audit Layer) & Dashboard       │
└────────────────┬─────────────────────────────────┘
                 │ OAS Bridges (Single-Provider Agent Run)
┌────────────────▼─────────────────────────────────┐
│          OAS / agent_sdk (Agent Runtime)         │
│  - Single Provider Tool dispatch, Context, Retry │
│  - Session memory & checkpoint integrity          │
└──────────────────────────────────────────────────┘
```

*   **MASC (Orchestrator):** "언제, 왜, 어떤 에이전트 프로필(Model & Provider Chain)로 턴을 돌릴 것인가"를 스케줄링하고, 동시성(Single-Flight Admission)을 제어하며, 다중 메시지 채널(Surface)을 조율합니다.
*   **OAS (Agent Runtime):** MASC에 의해 선택 및 할당된 단일 프로바이더 호출의 순수 실행(Tool Dispatch, Context Window 관리, 로컬 재시도)만 처리합니다. MASC의 비즈니스 로직이나 스케줄링 상태를 참조하지 않습니다.

---

## 2. Multi-Channel Inputs & Channel Gate

MASC는 다양한 커뮤니케이션 경로를 `Surface` 타입(`Dashboard`, `Discord`, `Slack`, `Gate`)으로 추상화하여 턴을 트리거하고 제어합니다.

```
                  ┌──────────────┐
                  │  Dashboard   │
                  └──────┬───────┘
                         │
┌──────────────┐  POST   │   REST    ┌──────────────┐
│   Discord    ├────────┼───────────┤    Slack     │
└──────────────┘ /api/v1/gate/message└──────────────┘
                         │
                         ▼
             ┌───────────────────────┐
             │     Channel Gate      │
             └───────────┬───────────┘
                         ▼
             ┌───────────────────────┐
             │ Single-Flight Queue   │
             └───────────────────────┘
```

*   **REST Async Entry:** 외부 연동 커넥터들은 `/api/v1/gate/message`로 메시지를 밀어 넣어 비동기적으로 턴을 트리거합니다.
*   **Polling & Cancellation:**
    *   **결과 폴링:** `GET /api/v1/gate/message/requests/<request_id>`로 턴 진행 상태 및 실행 결과를 비동기적으로 확인합니다.
    *   **턴 취소:** `POST /api/v1/gate/message/requests/<request_id>/cancel`을 통해 활성 상태의 턴을 취소할 수 있습니다.
*   **Discord Gateway:** `DISCORD_BOT_TOKEN` 환경변수가 주어지면 서버 부팅 시 별도 사이드카 없이 자동으로 Discord Gateway WSS에 상주하며 메시지를 파싱하여 라우팅합니다.

---

## 3. Double-Layer FSM Lifecycle

MASC는 데몬의 생명주기를 감시하는 **Phase FSM**과 개별 실행 단위의 세밀한 흐름을 제어하는 **Turn FSM**의 이중 구조로 동작합니다.

### 3.1 Keeper Phase FSM (13-State)
전역 레지스트리에서 관리하는 Keeper의 기동 및 복구 라이프사이클입니다.
```
Offline ──► Running ──► {Failing | Overflowed | Compacting | HandingOff | Draining}
            ──► Paused / Stopped / Crashed ──► Restarting ──► Dead ──► Zombie
```

### 3.2 Turn Execution FSM (8-State)
`lib/keeper/keeper_turn_fsm.mli`에서 정의된 개별 턴 단위의 전이 모델입니다.
```
  [Idle] ──► [Phase_gating] ──► [Runtime_routing] ──► [Awaiting_provider]
                 │                    │
                 ▼ (Skip)             ▼ (Error)
              [Done]               [Failed] ◄── [Completing] ◄── [Streaming]
                                       ▲                            ▲   │
                                       │ (Cancel)                   │   ▼
                                  [Cancelled] ◄─────────────────────┴─ [Awaiting_tool]
```

---

## 4. Single-Flight Turn Admission Control

MASC는 동일한 Keeper에 대해 **단 하나의 Active Turn만 허용**하는 극도의 상호 배제 정책(RFC-0225)을 준수하여 Checkpoint 훼손 및 메타데이터 역행을 차단합니다.

*   **Autonomous Lane (자율 스케줄링):** Heartbeat 주기 루프에서 세계 상태(World Observation)를 관측하여 턴을 실행하려 할 때, 이미 해당 Keeper가 챗 턴을 실행 중이면 틱을 즉시 스킵(`PhaseGateSkip`)하고 다음 주기에 재시도합니다.
*   **Direct Lane (챗/직접 메시지):** API나 메신저 등을 통해 들어오는 챗 턴은 Phase Gate를 우회하여 실행됩니다. 만약 해당 Keeper가 이미 턴을 수행 중인 경우, 요청은 거부되지 않고 **FIFO 직렬화 큐**에 삽입되어 순차 대기한 뒤 처리됩니다.
*   **CAS Integrity:** 체크포인트 저장 및 메타데이터 갱신 시 `monotonically increasing max` 정책과 CAS(Compare-And-Swap) 버전을 대조하여 역행을 물리적으로 원천 차단합니다.

---

## 5. Directory Structure & Document Map

### 5.1 Directory Layout
*   `lib/keeper/`: FSM, Heartbeat 루프, Single-flight Admission 제어부.
*   `lib/server/`: Eio 기반 HTTP/SSE/gRPC/WebSocket/WebRTC 트랜스포트 엔진 및 Channel Gate API.
*   `lib/gate/`: Surface 모듈화 및 외부 어댑터 프로토콜 추상화.
*   `lib/runtime/`: TOML 스키마 파싱 및 단일 프로바이더 정책 수렴.
*   `lib/dashboard/` + `dashboard/` (TS): 뷰어 및 웹 모니터링 컨트롤 패널.
    주요 진입점: Monitoring `dashboard#monitoring?section=journey` ·
    Ops `dashboard#command?section=operations` ·
    Connectors `dashboard#connectors?section=connector-status` ·
    Workspace `dashboard#workspace?section=verification`.
*   `lib/ide/`: Multi-keeper 커서, region tracker, LSP 프록시 브리지.

### 5.2 Key Document Map
*   **[docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md):** 스케줄러와 런타임 간의 경계 정의.
*   **[docs/keeper-turn-lifecycle.md](docs/keeper-turn-lifecycle.md):** 턴 기동 경로와 FSM 상태 전이 다이어그램.
*   **[docs/rfc/RFC-0223-*.md](docs/rfc/RFC-0223-typed-connector-surfaces-presence-pull-speaker.md):** 다중 Surface presence 및 Lane Context 풀(pull) 설계서.
*   **[docs/rfc/RFC-0225-*.md](docs/rfc/RFC-0225-per-keeper-turn-single-flight.md):** Single-flight turn admission 및 직렬 큐잉 사양.
*   **[docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md):** 관리 패널 인증 런북.
*   **[docs/RELEASE-EVIDENCE.md](docs/RELEASE-EVIDENCE.md):** 릴리즈 smoke + proof bundle 증적 절차 (`make release-evidence`).

---

## 6. Quick Start

### 6.1 Installation (Pre-built arm64/x86_64)
```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
```

### 6.2 Source Build & Local Run
외부 의존성 및 OAS 라이브러리를 고정한 뒤 Eio 서버 빌드를 기동합니다:
```bash
# 외부 라이브러리 고정 및 의존성 설치
scripts/opam-pin-external-deps.sh
opam install . --deps-only

# 빌드 및 기동
scripts/dune-local.sh build bin/main_eio.exe
scripts/run-local.sh --target-dir "$PWD"
```

*   `scripts/dune-local.sh`는 동시 컴파일 충돌을 피하기 위해 글로벌 락 파일(`/tmp/me-dune-local.lock`)을 소유하여 worktree 간 빌드 순서를 강제 제어합니다.

### 6.3 Local Activation Modes
*   **Loopback Mode (`scripts/start-loopback.sh`):** 고정 포트 `8935` 기동, Keeper 스케줄러 비활성화 (순수 로컬 Mock 디버깅용).
*   **Dir-Local Mode (`scripts/run-local.sh --target-dir /path`):** 특정 폴더 기준 격리 기동. 포트는 폴더 경로 해시에 기반해 `9100-9999` 범위 내에서 자동 부여.
*   **Full Runtime Mode (`./start-masc.sh --http`):** Keeper 스케줄러 자동 기동, 대시보드 백그라운드 빌드(`scripts/build-dashboard-if-needed.sh`) 수반.

---

## 7. Verification

```bash
# 로컬 유닛 테스트 실행 (Mock Transport)
make test

# 전체 통합 CI Suite 실행
make ci

# telemetry/trajectory 윈도우 수동 증적 수집
make release-evidence
```

---

## 8. License

MIT. No warranties or SLAs. Use at your own risk.
