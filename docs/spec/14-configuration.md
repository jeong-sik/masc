# Configuration

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `lib/env_config*.ml`, `lib/mode.ml`, `lib/capability_registry.ml`, `lib/tool_catalog.ml`, `lib/runtime_params.ml`, `config/` |
| Dependencies | 02-types-and-invariants |

---

## 1. 목적

설정 시스템은 MASC MCP 서버의 모든 조정 가능한 동작을 12-Factor App 원칙에 따라 환경변수로 외부화한다. 5개 계층(Core, Runtime, Governance, Keeper, Level2/Level4)으로 분류되며, 런타임 오버라이드 + 감사 경로를 제공한다.

---

## 2. 설정 해석 계층

```
┌────────────────────────────────────────────────────┐
│ Layer 1: Env_config_core        (경로, 포트, 네트워크)  │
│ Layer 2: Env_config_runtime     (타이머, 캐시, 세션)    │
│ Layer 3: Env_config_governance  (모델, 추론, Autonomy)   │
│ Layer 4: Env_config_keeper      (Keeper 부트/알림/감독)  │
│ Layer 5: Level2/Level4_config   (메트릭, Swarm, 학습)   │
│ Layer 6: Runtime_params         (런타임 오버라이드)       │
│ Layer 7: config/cascade.json    (Cascade 모델 순서)     │
└────────────────────────────────────────────────────┘
```

해석 우선순위: `Runtime_params override > env var > default value`.

---

## 3. 환경변수 레퍼런스

### 3.1 Core (Env_config_core)

경로 해석, 네트워크 주소, 외부 서비스 연결 설정.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_BASE_PATH` | string | `.` | `.masc` 데이터 디렉토리의 기준 경로 |
| `MASC_CONFIG_DIR` | string | 자동 탐색 | repo-managed config root (`config/cascade.json`, `config/prompts`, `config/keepers`, `config/personas`) |
| `MASC_PERSONAS_DIR` | string | unset | persona root override. 설정 시 `config/personas` 대신 이 디렉토리를 사용 |
| `MASC_HTTP_PORT` | string | `"8935"` | HTTP 서버 포트 |
| `MASC_HTTP_BASE_URL` | string | - | 전체 base URL (설정 시 host/port 무시) |
| `MASC_HOST` | string | - | 바인드 호스트 (base URL 미설정 시 필수) |
| `LIBDATACHANNEL_PATH` | string | 자동 탐색 | WebRTC 라이브러리 경로 |

runtime data root는 `MASC_BASE_PATH`를 사용한다. 미설정 시 일부 경로는 현재 작업 디렉토리 기준 fallback을 사용한다.
repo-managed config는 별도 규칙을 가진다: `MASC_CONFIG_DIR` -> `<MASC_BASE_PATH>/.masc/config` -> `~/.masc/config` -> `cwd/config` -> executable-relative `config/`.

### 3.2 Runtime (Env_config_runtime)

타이머, 세션, 캐시, 프로세스 관리 파라미터.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_ZOMBIE_THRESHOLD_SEC` | float | 300.0 | 좀비 감지 임계값 (초) |
| `MASC_KEEPER_ZOMBIE_THRESHOLD_SEC` | float | 3600.0 | Keeper 좀비 감지 (1시간) |
| `MASC_ZOMBIE_CLEANUP_INTERVAL_SEC` | float | 60.0 | 좀비 정리 루프 주기 |
| `MASC_LOCK_TIMEOUT_SEC` | float | 1800.0 | 잠금 만료 (30분) |
| `MASC_LOCK_EXPIRY_WARNING_SEC` | float | 300.0 | 만료 경고 임계값 |
| `MASC_SESSION_MAX_AGE_SEC` | float | 3600.0 | 세션 최대 수명 |
| `MASC_SESSION_RATE_LIMIT_WINDOW_SEC` | float | 60.0 | 속도 제한 윈도우 |
| `MASC_TEMPO_MIN_INTERVAL_SEC` | float | 60.0 | 최소 폴링 주기 |
| `MASC_TEMPO_MAX_INTERVAL_SEC` | float | 600.0 | 최대 폴링 주기 |
| `MASC_TEMPO_DEFAULT_INTERVAL_SEC` | float | 300.0 | 기본 폴링 주기 |
| `MASC_DECISION_TTL_SEC` | float | 3600.0 | 결정 TTL (1시간) |
| `MASC_CACHE_MAX_ENTRY_SIZE` | int | 102400 | 캐시 엔트리 최대 크기 (100KB) |
| `MASC_CACHE_MAX_ENTRIES` | int | 1000 | 캐시 최대 항목 수 |
| `MASC_CLAIM_TTL_SECONDS` | float | 3600.0 | Task claim 자동 해제 TTL |
| `MASC_ORCHESTRATOR_INTERVAL` | float | 300.0 | Orchestrator 점검 주기 |
| `MASC_ORCHESTRATOR_AGENT` | string | `"orchestrator"` | Orchestrator 에이전트명 |
| `MASC_SPAWN_TIMEOUT_SEC` | float | 600.0 | 스폰 기본 타임아웃 (10분) |
| `MASC_SPAWN_CODING_TIMEOUT_SEC` | float | 7200.0 | 코딩 모드 타임아웃 (2시간) |
| `MASC_SPAWN_GRACE_PERIOD_SEC` | float | 60.0 | SIGTERM 유예 기간 |
| `LLAMA_SERVER_URL` | string | `Agent_sdk.Defaults.local_llm_url` | 로컬 OpenAI-compatible runtime URL |
| `LLAMA_DEFAULT_MODEL` | string | `explicit-model-required` | 로컬 기본 모델 |
| `MASC_LOCAL_MAX_TOKENS` | int | 32768 | 로컬 LLM max_tokens 상한 (fallback: `MASC_LLAMA_MAX_TOKENS`) |
| `MASC_CANCELLATION_TOKEN_MAX_AGE_SEC` | float | 3600.0 | 취소 토큰 최대 수명 |
| `NEO4J_URI` | string | `bolt://turntable.proxy.rlwy.net:11490` | Neo4j 접속 URI |
| `NEO4J_HTTP_URI` | string | `""` | Neo4j HTTP API URI |
| `NEO4J_USER` | string | `"neo4j"` | Neo4j 사용자 |
| `NEO4J_PASSWORD` | string | (필수) | Neo4j 비밀번호 |
| `VOICE_MCP_HOST` | string | `"127.0.0.1"` | Legacy voice session fallback host. Prefer `.masc/voice_config.json` `session.endpoints` or `MASC_HTTP_*`. |
| `VOICE_MCP_PORT` | int | 8936 | Legacy voice session fallback port. Prefer `.masc/voice_config.json` `session.endpoints` or `MASC_HTTP_*`. |

**Timeout 모듈** (통합 타임아웃):

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_TIMEOUT_GCLOUD_AUTH_SEC` | float | 15.0 | GCP 인증 타임아웃 |
| `MASC_TIMEOUT_ANTHROPIC_SEC` | int | 120 | Anthropic API 타임아웃 |
| `MASC_TIMEOUT_OPENAI_COMPAT_SEC` | int | 60 | OpenAI 호환 API 타임아웃 |
| `MASC_TIMEOUT_MODEL_GRACE_SEC` | float | 5.0 | 모델 호출 네트워크 유예 |
| `MASC_TIMEOUT_GRAPHQL_SEC` | float | 5.0 | GraphQL 쿼리 타임아웃 |
| `MASC_TIMEOUT_KEEPER_STATUS_SEC` | float | 5.0 | Keeper 상태 확인 타임아웃 |

**Inference Defaults**:

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_INFERENCE_DEFAULT_MAX_TOKENS` | int | 4096 | 기본 max_tokens |
| `MASC_SSE_RETRY_MS` | int | 3000 | SSE 재접속 힌트 (ms) |
| `MASC_LOG_TRUNCATION_LEN` | int | 1500 | 로그 출력 절삭 길이 |
| `MASC_CP_CLEANUP_DAYS` | int | 14 | CP 데이터 정리 임계일 |
| `MASC_MESSAGE_MAX_COUNT` | int | 200 | Room당 메시지 최대 보유 수 |
| `MASC_CHAIN_JUDGE_MODEL` | string | `"gemini"` | Chain judge 모델 |

### 3.3 Governance (Env_config_governance)

모델 선택, 추론 캐시, Keeper Autonomy 자율 에이전트, Thompson Sampling 설정.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_INFERENCE_TIMEOUT_SEC` | float | 30.0 | 모델 API 호출 타임아웃 |
| `MASC_OPERATOR_JUDGE_TIMEOUT_SEC` | int | (inference fallback) | Operator judge 타임아웃 |
| `MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC` | int | (inference fallback) | Dashboard governance judge 타임아웃 |
| `MASC_INFERENCE_CACHE_ENABLED` | bool | true | 추론 캐시 활성화 |
| `MASC_INFERENCE_CACHE_TTL_SEC` | int | 300 | 캐시 TTL (초) |
| `MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS` | int | 48000 | 캐시 대상 최대 프롬프트 길이 |
| `MASC_INFERENCE_CACHE_MAX_TEMP` | float | 0.0 | 캐시 허용 최대 온도 |
| `MASC_INFERENCE_CACHE_L1_MAX_ENTRIES` | int | 512 | L1 인메모리 캐시 상한 |
| `MASC_SPAWN_CACHE_POLICY` | string | `"safe_only"` | Spawn 캐시 정책 (`off`/`safe_only`) |
| `MASC_GLM_DEFAULT_MODEL` | string | `"glm-4.7"` | GLM 기본 모델 |
| `MASC_GLM_FLASH_MODEL` | string | `"glm-4.7-flash"` | GLM flash 모델 |
| `MASC_GEMINI_DEFAULT_MODEL` | string | `"gemini-2.5-pro"` | Gemini 기본 모델 |
| `MASC_GEMINI_FLASH_MODEL` | string | `"gemini-2.5-flash"` | Gemini flash 모델 |
| `MASC_CLAUDE_DEFAULT_MODEL` | string | `"claude-sonnet-4-6"` | Claude 기본 모델 |
| `MASC_OPENAI_DEFAULT_MODEL` | string | `"gpt-4.1"` | OpenAI 기본 모델 |

**Keeper Autonomy (자율 에이전트)**: `MASC_AUTONOMY_*` prefix.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_AUTONOMY_QUIET_START` | int | 3 | 조용한 시간대 시작 (KST) |
| `MASC_AUTONOMY_QUIET_END` | int | 7 | 조용한 시간대 종료 (KST) |

> 이전에 존재하던 `MASC_AUTONOMY_TICK_INTERVAL_SEC`, `MASC_AUTONOMY_AGENTS_PER_TICK` 등 13개 Autonomy 변수는 v2.161.0에서 소비자 0 확인 후 제거됨. legacy pre-keeper 접두 env도 지원 중단.

**Thompson Sampling** (`MASC_AUTONOMY_*` prefix):

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_AUTONOMY_MAX_STARVATION_TICKS` | int | 12 | 기아 방지 최대 tick 수 |
| `MASC_AUTONOMY_THOMPSON_WEIGHT` | float | 0.7 | Thompson score 비중 |
| `MASC_AUTONOMY_VOTE_DECAY_FACTOR` | float | 0.95 | Vote decay 계수 |

### 3.4 Keeper (Env_config_keeper)

Keeper 부트스트랩, 메트릭 로테이션, 알림 팬아웃, Supervisor 설정.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_KEEPER_BOOTSTRAP_ENABLED` | bool | true | 부트스트랩 스캔 활성화 |
| `MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC` | float | 3600.0 | Stale turn 임계값 |
| `MASC_KEEPER_BOOTSTRAP_MAX_SCAN` | int | 10000 | 최대 스캔 파일 수 |
| `MASC_KEEPER_METRICS_MAX_BYTES` | int | 10485760 | 메트릭 파일 로테이션 크기 (10MB) |
| `MASC_KEEPER_METRICS_MAX_ROTATED` | int | 1 | 보관할 로테이션 파일 수 |
| `MASC_KEEPER_ALERT_ENABLED` | bool | true | 알림 마스터 스위치 |
| `MASC_KEEPER_ALERT_MIN_SCORE` | float | 0.70 | 알림 최소 점수 |
| `MASC_KEEPER_ALERT_BOARD_ENABLED` | bool | true | Board 팬아웃 |
| `MASC_KEEPER_ALERT_SLACK_ENABLED` | bool | true | Slack 팬아웃 |
| `MASC_KEEPER_ALERT_GITHUB_ENABLED` | bool | false | GitHub Issue 팬아웃 |
| `MASC_KEEPER_ALERT_GITHUB_MIN_SCORE` | float | 0.85 | GitHub 최소 점수 |
| `MASC_KEEPER_SUPERVISOR_MAX_RESTARTS` | int | 5 | 최대 재시작 시도 |
| `MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S` | float | 10.0 | 지수 백오프 기본 지연 |
| `MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S` | float | 300.0 | 백오프 상한 |
| `MASC_KEEPER_SUPERVISOR_SWEEP_SEC` | float | 30.0 | Supervisor sweep 주기 |

### 3.5 Level2 / Level4 Config

L2는 메트릭/드리프트/학습 튜닝, L4는 Swarm 행동 파라미터.

**Level2** (`lib/level2_config.ml`):

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_METRICS_CACHE_TTL` | float | 300.0 | 메트릭 캐시 TTL |
| `MASC_TOKEN_CACHE_SIZE` | int | 1000 | 토큰 캐시 최대 항목 |
| `MASC_DRIFT_THRESHOLD` | float | 0.85 | 드리프트 감지 임계값 |
| `MASC_LOCK_WARN_MS` | float | 100.0 | 잠금 경합 경고 임계 (ms) |
| `MASC_HEBBIAN_RATE` | float | 0.075 | Hebbian 학습률 |
| `MASC_HEBBIAN_DECAY` | float | 0.01 | Hebbian 감쇠율 |
| `MASC_FITNESS_HALFLIFE` | float | 7.0 | Fitness 반감기 (일) |

**Level4** (`lib/level4_config.ml`):

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_SWARM_SEED` | int | (시각 기반) | RNG 시드 (재현성) |
| `MASC_SWARM_INITIAL_FITNESS` | float | 0.5 | 신규 에이전트 초기 fitness |
| `MASC_SWARM_SELECTION_PRESSURE` | float | 0.3 | 선택 압력 |
| `MASC_SWARM_MUTATION_RATE` | float | 0.1 | 변이율 |
| `MASC_SWARM_QUORUM_THRESHOLD` | float | 0.6 | 정족수 임계값 |
| `MASC_SWARM_MAX_AGENTS` | int | 50 | Swarm 최대 에이전트 |
| `MASC_FLOCK_SEPARATION` | float | 1.5 | 분리 가중치 |
| `MASC_FLOCK_ALIGNMENT` | float | 1.0 | 정렬 가중치 |
| `MASC_FLOCK_COHESION` | float | 1.0 | 응집 가중치 |
| `MASC_STIG_DEPOSIT` | float | 0.2 | 페로몬 증착율 |
| `MASC_STIG_THRESHOLD` | float | 0.1 | 페로몬 추종 임계값 |

Level4는 `Normalized.t` (0.0-1.0 범위 보장) 추상 타입을 제공한다. `of_float`는 범위 밖 입력에 `None`을 반환하고, `of_float_clamped`는 clamping한다.

---

## 4. Tool Surface

Mode/category 기반 필터링은 제거되었다. 현재 공개 도구 표면은 아래 순서로 결정된다.

```
raw_all_tool_schemas (전체 등록 도구)
  -> capability_registry (surface projection: Public_mcp / Keeper / Worker)
  -> tool_catalog (visibility: Default/Hidden, lifecycle: Active/Deprecated)
  -> profile/auth/runtime checks
```

즉, 도구 노출 제어는 `Full` / `Managed_agent` / `Operator_remote` profile, tool catalog,
auth/RBAC, 그리고 개별 runtime guard에 의해 이뤄진다.

---

## 5. Capability Registry

### 5.1 구조

```ocaml
type risk_class = Safe | Audited | Privileged
type audience   = External_mcp_client | Spawned_managed_agent
                | Local_worker_agent | Keeper_agent
                | Strict_mdal_worker | Privileged_executor
type surface    = Public_mcp | Spawned_agent_mcp | Local_worker
                | Keeper_standard | Keeper_privileged
                | Mdal_auditable | Privileged_executor_surface
```

하나의 capability는 여러 surface에 projection을 가진다. 같은 도구가 `Public_mcp`와 `Keeper_standard`에 서로 다른 schema로 노출될 수 있다.

### 5.2 Surface 매핑 규칙

| Surface | Audience | Risk | 용도 |
|---------|----------|------|------|
| Public_mcp | External_mcp_client | Safe | 외부 MCP 클라이언트 |
| Spawned_agent_mcp | Spawned_managed_agent | Audited | 스폰된 에이전트 |
| Local_worker | Local_worker_agent | Audited | 로컬 워커 |
| Keeper_standard | Keeper_agent | Audited | Keeper 표준 도구 |
| Keeper_privileged | Keeper_agent + Privileged_executor | Privileged | Keeper 특권 도구 (`keeper_bash` 등) |
| Mdal_auditable | Strict_mdal_worker | Audited | MDAL 감사 대상 |
| Privileged_executor_surface | Privileged_executor | Privileged | 특권 실행 전용 |

---

## 6. Tool Catalog

### 6.1 Metadata 구조

```ocaml
type visibility = Default | Hidden
type lifecycle  = Active | Deprecated
type implementation_status = Real | Adapter | Simulation | Placeholder
type tier = Essential | Standard | Full
```

### 6.2 Lifecycle 관리

| 상태 | 가시성 | 동작 |
|------|--------|------|
| Active + Default | 도구 목록에 노출 | 정상 사용 |
| Active + Hidden | 목록 비노출 | `allow_direct_call_when_hidden=true`이면 직접 호출 가능 |
| Deprecated + Default | 목록 노출 (경고) | canonical_name/replacement 안내 |
| Deprecated + Hidden | 목록 비노출 | 호환성 유지, 내부 호출만 |

### 6.3 3-Tier System

| Tier | 도구 수 | 용도 |
|------|---------|------|
| Essential | ~21 | 핵심 워크플로우 (`join`, `add_task`, `broadcast`, `heartbeat`, `worktree_create` 등) |
| Standard | ~50 | Essential + Board, Team Session, Governance V2, Handover, Spawn |
| Full | 전체 | 모든 등록 도구 |

Tier는 mode/category와 독립적으로 적용되는 추가 필터 레이어다.

---

## 7. Cascade Configuration

### 7.1 config/cascade.json 구조

JSON 파일로 CASCADE별 모델 순서를 정의한다. 키 패턴: `{cascade_name}_models`.

```json
{
  "default_models": ["llama:qwen3.5", "glm:glm-5.1"],
  "keeper_turn_models": ["llama:qwen3.5", "glm:glm-5.1"],
  "briefing_models": ["llama:qwen3.5", "glm:glm-5.1", "gemini:gemini-2.5-pro"],
  "auto_responder_claude_models": ["claude:sonnet", "glm:glm-5.1"],
  "keeper_unified_temperature": 0.4,
  "keeper_unified_max_tokens": 2048
}
```

### 7.2 모델 식별자 형식

`{provider}:{model_id}` 형식.

- checked-in repo defaults는 explicit label을 사용한다.
- `auto`는 provider-specific runtime convenience일 수 있지만, repo에 커밋되는 cascade 기본값으로는 권장하지 않는다.

| Provider | Env Config 모듈 | 기본 모델 |
|----------|----------------|----------|
| `ollama` | `Local_runtime` | `OLLAMA_DEFAULT_MODEL` (port 11434, 262k context) |
| `llama` | `Local_runtime` | `LLAMA_DEFAULT_MODEL` (legacy local OpenAI-compatible runtime) |
| `glm` | `Glm` | `MASC_GLM_DEFAULT_MODEL` |
| `gemini` | `Gemini` | `MASC_GEMINI_DEFAULT_MODEL` |
| `claude` | `Claude` | `MASC_CLAUDE_DEFAULT_MODEL` |

### 7.3 Per-cascade 추론 파라미터

`{cascade_name}_temperature`, `{cascade_name}_max_tokens` 키로 cascade별 온도와 토큰 수를 오버라이드할 수 있다. 미설정 시 호출자 기본값 사용.

---

## 8. Runtime Parameters

### 8.1 아키텍처

`Runtime_params` 모듈은 환경변수 기본값 위에 런타임 오버라이드를 제공한다.

- **등록**: `register ~key ~default ~validate ~serialize ~deserialize`로 파라미터 정의
- **읽기/쓰기**: `get`, `set`, `set_by_key` (JSON 경유)
- **동시성**: `Eio.Mutex`로 보호. Eio 스케줄러 부재 시 lock-free fallback.
- **영속화**: `.masc/runtime_params.json`에 atomic write (rename)
- **감사**: `.masc/param_audit.jsonl`에 변경 이력 기록

### 8.2 오버라이드 흐름

```
masc_set_param(key, value)
  -> validate(value)
  -> entry.override <- Some value
  -> persist(base_path)
  -> record_audit(key, old, new, actor)
```

### 8.3 거버넌스 연동

`masc_runtime_params`로 현재 값 조회, `masc_set_param`으로 변경. Governance 결정(`case_id`)과 연결하여 감사 추적이 가능하다.

---

## 9. CLI Arguments

서버 바이너리(`bin/main_eio.ml`)는 Cmdliner로 CLI 인자를 받는다.

| Flag | 기본값 | 설명 |
|------|--------|------|
| `-p`, `--port` | 8935 | HTTP 리스닝 포트 |
| `--host` | `127.0.0.1` | 바인드 주소 |
| `--base-path` | `MASC_BASE_PATH` 또는 `cwd` 기반 | `.masc` 폴더 위치 |

---

## 10. 불변식

- **INV-C1**: 모든 `MASC_*` 환경변수는 `get_string/get_int/get_float/get_bool` 헬퍼를 통해 읽힌다. `Sys.getenv` 직접 호출은 `Env_config_core`의 해석 함수에서만 허용.
- **INV-C2**: `Runtime_params.set`은 반드시 `validate`를 통과해야 한다. 검증 실패 시 `Error`를 반환하고 값은 변경되지 않는다.
- **INV-C3**: `Unknown` category에 매핑된 도구는 어떤 mode preset에서도 노출되지 않는다.
- **INV-C4**: `tool_catalog.is_visible`이 false를 반환하는 도구는 `allow_direct_call_when_hidden=true`가 아닌 한 MCP 클라이언트에 노출되지 않는다.
- **INV-C5**: Cascade JSON의 모델 목록은 순서대로 시도되며, 전부 실패 시 skip한다 (error propagation, fallback 없음).
- **INV-C6**: `Normalized.t` 값은 항상 [0.0, 1.0] 범위이다. `of_float`는 NaN/Inf/범위 밖에 `None`을 반환한다.

---

## 11. Capability Match 설정

`MASC_CAPABILITY_MATCH_MODE` 환경변수로 Task-Agent 매칭 전략을 선택한다.

| 값 | 동작 |
|------|------|
| `keyword` | 키워드 오버랩 휴리스틱. 0 지연, 외부 호출 없음. |
| `model` | LLM semantic scoring. 실패 시 0점 반환. |
| `hybrid` (기본값) | LLM 우선, 실패 시 keyword fallback. |

점수 공식 (keyword mode): `total = trait_overlap * 0.4 + interest_overlap * 0.4 + capability_match * 0.2`.

---

## 12. Keeper 설정 소스와 우선순위

### 12.1 설정 소스

Keeper의 행동을 결정하는 설정은 3곳에서 공급된다.

| 소스 | 경로 | 형식 | 역할 |
|------|------|------|------|
| TOML declaration | `<CONFIG_ROOT>/keepers/<name>.toml` | TOML | Persona 없이 선언적으로 keeper 정의 |
| Persistent meta | `.masc/keepers/<name>.json` | JSON | 런타임 상태. turn 카운트, context ratio 등 포함 |

별도 keepalive 설정 파일은 없다. keeper 선언과 런타임 상태는 `.masc/keepers/<name>.json`에 모이고, keeper는 durable always-on으로 취급된다. runtime 중지 여부는 `paused` 또는 `keeper_down`으로 표현한다.

### 12.2 설정 적용 우선순위

**새 keeper 생성 시** (`keeper_up`, meta 없음):

```text
inline args > TOML (<CONFIG_ROOT>/keepers/) > persona template (<PERSONAS_ROOT>/) > 하드코딩 기본값
```

**기존 keeper resume 시** (`keeper_up`, meta 존재):

```text
inline args > stored keeper_meta > TOML/persona template fallback > 하드코딩 기본값
```

코드 경로: `keeper_turn_up_args.ml:parse()` → `load_keeper_profile_defaults()`가 TOML > persona 순서로 로드.

### 12.3 Persona 디렉토리 탐색 순서

`personas_root_opt()` (`keeper_types_profile.ml`):

```text
$MASC_PERSONAS_DIR
> resolved config root의 personas/
> where resolved config root =
  $MASC_CONFIG_DIR
  > $MASC_BASE_PATH/.masc/config
  > ~/.masc/config
  > cwd/config
  > executable-relative config/
```

암묵적 secondary search(`~/.masc/personas`, `$MASC_BASE_PATH/.masc/personas`)는 사용하지 않는다.
Persona, keeper TOML, prompt markdown, cascade, tool_policy 같은 repo-managed 설정은 모두 같은 resolved config root를 기준으로 해석한다.

### 12.4 Template 변경 반영

Template 변경은 기존 keeper에 자동 전파되지 않는다. 반영 방법:

1. `keeper_down <name>` — keeper 중지 + meta 파일 삭제
2. `keeper_up <name>` — template에서 fresh로 재생성

### 12.5 `--base-path`와 `.masc/` 의존성

`--base-path` CLI 인자가 `.masc/` 디렉토리 위치를 결정한다. `scripts/run-local.sh`는 `<target>/.masc/`를 기본으로 사용하고, shared/full-runtime 경로는 별도 launcher가 유지한다.

dir-local local-dev에서는 `.masc/`가 target 디렉토리 내부를 가리키므로 shared repo keeper 상태와 분리된다. shared state가 필요하면 canonical shared launcher를 사용해야 한다.

이 값은 runtime data root를 결정하고, explicit `MASC_CONFIG_DIR`가 없을 때는 `<MASC_BASE_PATH>/.masc/config`를 repo-managed config의 첫 fallback으로도 사용한다.

### 12.6 모델 실행

모델 선택은 `cascade.json`이 유일한 권위다. keeper_meta의 `cascade_name` (기본 `"keeper_unified"`)이 cascade를 지정하고, `Oas_model_resolve`가 실행 모델을 결정한다. keeper 설정에 모델 필드를 직접 지정하지 않는다.
