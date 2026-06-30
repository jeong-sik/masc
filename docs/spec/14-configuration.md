---
status: reference
last_verified: 2026-06-26
code_refs:
  - lib/config/
  - lib/config/env_config.mli
  - lib/fusion/
  - lib/fusion_core/
  - config/
---

# Configuration

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `lib/env_config*.ml`, `lib/mode.ml`, `lib/capability_registry.ml`, `lib/tool_catalog.ml`, `lib/runtime_params.ml`, `config/` |
| Dependencies | 02-types-and-invariants |

---

## 1. 목적

설정 시스템은 MASC MCP 서버의 모든 조정 가능한 동작을 12-Factor App 원칙에 따라 환경변수로 외부화한다. Core, Runtime, Governance, Keeper, numeric tuning, process RNG 계층으로 분류되며, 런타임 오버라이드 + 감사 경로를 제공한다.

운영 reload 계약은 별도 문서로 분리한다:

- [`../ENV-CONTRACT.md`](../ENV-CONTRACT.md)
- [`../TOML-RELOAD-MATRIX.md`](../TOML-RELOAD-MATRIX.md)

---

## 2. 설정 해석 계층

```
┌────────────────────────────────────────────────────┐
│ Layer 1: Env_config_core        (경로, 포트, 네트워크)  │
│ Layer 2: Env_config_runtime     (타이머, 캐시, 세션)    │
│ Layer 3: Env_config_governance  (모델, 추론, Autonomy)   │
│ Layer 4: Env_config_keeper      (Keeper 부트/알림/감독)  │
│ Layer 5: Level2                 (메트릭, 학습)          │
│ Layer 6: Runtime_params         (런타임 오버라이드)       │
│ Layer 7: config/runtime.toml    (Runtime 모델 순서)     │
└────────────────────────────────────────────────────┘
```

해석 우선순위: `Runtime_params override > env var > default value`.

---

## 3. 환경변수 레퍼런스

### 3.1 Core (Env_config_core)

경로 해석, 네트워크 주소, 외부 서비스 연결 설정.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_BASE_PATH` | string | unset | workspace/base 경로. 설정 시 runtime data root는 `<MASC_BASE_PATH>/.masc` |
| `MASC_CONFIG_DIR` | string | 자동 탐색 | resolved config root override. 하위 항목: `runtime.toml`, `prompts/`, `keepers/`, `personas/` |
| `MASC_PERSONAS_DIR` | string | unset | persona root override. 설정 시 resolved config root의 `personas/` 대신 이 디렉토리를 사용 |
| `MASC_HTTP_PORT` | string | `"8935"` | HTTP 서버 포트 |
| `MASC_HTTP_BASE_URL` | string | - | 전체 base URL (설정 시 host/port 무시) |
| `MASC_HOST` | string | - | 바인드 호스트 (base URL 미설정 시 필수) |
| `LIBDATACHANNEL_PATH` | string | 자동 탐색 | WebRTC 라이브러리 경로 |

runtime data root는 `MASC_BASE_PATH` 자체가 아니라 `<MASC_BASE_PATH>/.masc`다. `MASC_BASE_PATH`에는 workspace root를 넣고, `.masc` 디렉토리 자체를 넣지 않는다. 서버 launchers는 명시 base path를 넘겨야 하며, 미설정 fallback은 일부 helper/legacy 경로에서만 현재 작업 디렉토리 기준으로 동작한다.
resolved config root는 별도 탐색 규칙을 가진다: `MASC_CONFIG_DIR` -> `<MASC_BASE_PATH>/.masc/config` -> missing/uninitialized. repo `config/`는 체크인된 default/example seed source이며, live root fallback이 아니다.

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
| `MASC_TELEMETRY_RETENTION_DAYS` | int | 30 | `.masc/telemetry/YYYY-MM/DD.jsonl` day-file retention. 양수는 override, 0 이하는 retention 비활성화 |
| `MASC_TELEMETRY_MAX_BYTES` | int | 52428800 | `.masc/telemetry` byte cap. 오래된 완료 day-file부터 삭제하며 현재 day-file은 보존. 양수는 override, 0 이하는 cap 비활성화 |
| `NEO4J_URI` | string | `bolt://turntable.proxy.rlwy.net:11490` | Neo4j 접속 URI |
| `NEO4J_HTTP_URI` | string | `""` | Neo4j HTTP API URI |
| `NEO4J_USER` | string | `"neo4j"` | Neo4j 사용자 |
| `NEO4J_PASSWORD` | string | (필수) | Neo4j 비밀번호 |
**Voice Configuration** (`MASC_BASE_PATH/.masc/voice_config.json`):

All voice paths resolve relative to `MASC_BASE_PATH/.masc/`. The config file
contains four sections: `tts`, `stt`, `session`, `local_playback`.

| Section | Required endpoints | Notes |
|---------|-------------------|-------|
| `tts.endpoints` | At least 1 | TTS provider (e.g. `elevenlabs_direct`, `openai_compat`) |
| `stt.endpoints` | At least 1 | STT provider (e.g. `elevenlabs_direct`) |
| `session.endpoints` | 0 or more | Voice MCP session server. Empty `[]` is valid for HTTP-only TTS. |
| `local_playback` | N/A | Optional local audio playback via ffplay/mpg123. |

**Timeout 모듈** (통합 타임아웃):

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_TIMEOUT_GCLOUD_AUTH_SEC` | float | 15.0 | GCP 인증 타임아웃 |
| `MASC_TIMEOUT_OPENAI_COMPAT_SEC` | int | 60 | OpenAI-compatible API 타임아웃 |
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
| `MASC_MESSAGE_MAX_COUNT` | int | 200 | Workspace당 메시지 최대 보유 수 |
| `MASC_CHAIN_JUDGE_MODEL` | string | `""` | Chain judge 모델 (legacy; 현재 사용처 없음) |

### 3.3 Governance (Env_config_governance)

모델 선택, 추론 캐시, Keeper Autonomy 자율 에이전트, Thompson Sampling 설정.

| 환경변수 | 타입 | 기본값 | 설명 |
|----------|------|--------|------|
| `MASC_INFERENCE_TIMEOUT_SEC` | float | 30.0 | 모델 API 호출 타임아웃 |
| `MASC_INFERENCE_CACHE_ENABLED` | bool | true | 추론 캐시 활성화 |
| `MASC_INFERENCE_CACHE_TTL_SEC` | int | 300 | 캐시 TTL (초) |
| `MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS` | int | 48000 | 캐시 대상 최대 프롬프트 길이 |
| `MASC_INFERENCE_CACHE_MAX_TEMP` | float | 0.0 | 캐시 허용 최대 온도 |
| `MASC_INFERENCE_CACHE_L1_MAX_ENTRIES` | int | 512 | L1 인메모리 캐시 상한 |
| `MASC_SPAWN_CACHE_POLICY` | string | `"safe_only"` | Spawn 캐시 정책 (`off`/`safe_only`) |
| `ZAI_DEFAULT_MODEL` | string | OAS runtime binding/catalog default | 설정 시 `glm` provider `auto` 기본 모델로 사용. 미설정이면 OAS runtime binding/catalog default에 위임한다. |
| `ZAI_CODING_DEFAULT_MODEL` | string | OAS runtime binding/catalog default | 설정 시 `glm-coding` provider `auto` 기본 모델로 사용. 미설정이면 OAS runtime binding/catalog default에 위임한다. |
| `OPENAI_DEFAULT_MODEL` | string | OAS runtime binding/catalog default | 설정 시 `openai`/`openai-compatible` provider `auto` 기본 모델로 사용. |
| `OLLAMA_DEFAULT_MODEL` | string | `""` | `ollama` provider `auto` 기본 모델 (lib/config/env_config_runtime.ml:181) |
| `LLAMA_DEFAULT_MODEL` | string | `"explicit-model-required"` | `llama` provider legacy local runtime 기본 모델 (lib/config/env_config_runtime.ml:150) |
| `OPENROUTER_DEFAULT_MODEL` | string | (없음) | `openrouter` provider `auto` 기본 모델 (lib/runtime/runtime_model_resolve.ml:76) |

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

### 3.5 Level2

Level2는 메트릭/드리프트/학습 튜닝이다.

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

Removed `MASC_SWARM_*`, `MASC_FLOCK_*`, and `MASC_STIG_*` knobs are not runtime inputs. Do not add them to new configs.

---

## 4. Tool Surface

Mode/category 기반 필터링은 제거되었다. 현재 공개 도구 표면은 아래 순서로 결정된다.

```
raw_all_tool_schemas (전체 등록 도구)
  -> capability_registry (surface projection: Public_mcp / Keeper / Worker)
  -> tool_catalog (visibility: Default/Hidden, lifecycle: Active)
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
| Keeper_privileged | Keeper_agent + Privileged_executor | Privileged | Keeper 특권 도구 (`tool_execute` 등) |
| Mdal_auditable | Strict_mdal_worker | Audited | MDAL 감사 대상 |
| Privileged_executor_surface | Privileged_executor | Privileged | 특권 실행 전용 |

---

## 6. Tool Catalog

### 6.1 Metadata 구조

```ocaml
type visibility = Default | Hidden
type lifecycle  = Active
type implementation_status = Real | Adapter | Simulation | Placeholder
type tier = Essential | Standard | Full
```

### 6.2 Lifecycle 관리

| 상태 | 가시성 | 동작 |
|------|--------|------|
| Active + Default | 도구 목록에 노출 | 정상 사용 |
| Active + Hidden | 목록 비노출 | `allow_direct_call_when_hidden=true`이면 직접 호출 가능 |

### 6.3 3-Tier System

| Tier | 도구 수 | 용도 |
|------|---------|------|
| Essential | ~21 | 핵심 워크플로우 (`join`, `add_task`, `broadcast`, `heartbeat`, repo worktree workflow 등) |
| Standard | ~50 | Essential + Board, Governance V2, Handover, Spawn |
| Full | 전체 | 모든 등록 도구 |

Tier는 mode/category와 독립적으로 적용되는 추가 필터 레이어다.

---

## 7. Runtime Configuration

### 7.1 config/runtime.toml 구조

`runtime.toml`은 RFC-0058 선언형 runtime catalog의 유일한 런타임
소스다. Catalog discovery는 TOML의 선언형 namespace를 materialize한
검증 결과에서 수행하며, legacy flat JSON catalog 키는 사용하지 않는다.

구조는 여섯 레이어로 나뉜다.

| 레이어 | TOML namespace | 역할 |
|--------|----------------|------|
| Provider | `[providers.<id>]` | transport/protocol/credential 정의 |
| Model | `[models.<id>]` | provider-neutral model metadata/capability 정의 |
| Binding | `[<provider>.<model>]` | provider-model 결합, capacity, pricing |
| Alias | `[<provider>.<model>.<alias>]` | 호출 목적별 temperature/max-output override |
| Tier/Route | `[tier.*]`, `[runtime.*]`, `[routes.*]` | 실행 후보 묶음, fallback chain, logical route |
| WebSearch | `[web_search]` | MASC-owned WebSearch provider startup defaults |
| Fusion | `[fusion]`, `[fusion.presets.*]` | `masc_fusion` 패널/심판 심의 policy와 preset |

```toml
[providers.cli-tool-a]
protocol = "openai-compatible-cli"
command = "agent-code"
is-non-interactive = true

[models.agent-code-spark]
api-name = "model-d-spark"
max-context = 128000
tools-support = true
streaming = true

[cli-tool-a.agent-code-spark]
is-default = true
max-concurrent = 1

[tier.primary]
members = ["cli-tool-a.agent-code-spark"]
strategy = "failover"

[runtime.primary]
tiers = ["primary"]
strategy = "priority_tier"
fallback = true

[routes.keeper_turn]
target = "runtime.primary"

[web_search]
searxng_url = "http://localhost:8888"
```

#### 7.1.1 `[fusion]` 심의 설정

`masc_fusion`의 패널/심판 심의 설정은 `runtime.toml`의 `[fusion]`에 둔다. 같은
runtime authoring surface에서 모델 binding, preset, 동시성 cap을 함께 검토하게 하기
위함이다.

| TOML key | Type | Repo seed | 의미 |
|----------|------|-----------|------|
| `enabled` | bool | `true` | `false`면 `masc_fusion` 게이트가 모델 호출 없이 `Deny` |
| `default_preset` | string | `"trio"` | 요청이 preset을 지정하지 않을 때 사용하는 `[fusion.presets.*]` 이름 |
| `max_concurrent_panels` | int >= 1 | `2` | 패널 답변 fan-out 상한 |
| `max_concurrent_judges` | int >= 1 | `3` | `judge_of_judges` 계열 judge wave fan-out 상한. 패널 backpressure와 독립 |
| `staged_judge_group_size` | int >= 2 | `3` | `staged_judge_of_judges`가 1차 심판을 묶는 고정 reducer group 크기 |

Legacy flat preset-level keys:

| TOML key | Type | Default | 의미 |
|----------|------|---------|------|
| `panel` | string[] | required | legacy flat panel model list |
| `judge` | string | required | simple/refine/conditional judge and JOJ meta judge runtime id |
| `panel_system_prompt` | string | required | legacy flat panel system prompt |
| `judge_system_prompt` | string | required | judge system prompt |
| `panel_timeout_s` | float | `300.0` | legacy flat panel structural timeout |
| `judge_timeout_s` | float | `300.0` | judge structural timeout |
| `max_tool_calls_per_panel` | int 0..16 | `0` | panel tool-call budget; `0` means unlimited |
| `max_output_tokens_per_panel` | int > 0 | runtime default | panel output token budget override |
| `judge_max_output_tokens` | int > 0 | runtime default | simple/refine/meta judge output token budget override |
| `min_answered` | int 1..panel count | `1` | judge 실행에 필요한 answered panel quorum |

Fusion judge/refine/meta calls request provider-native structured output; every
configured judge runtime must therefore resolve to a model that declares
`supports-structured-output=true`. Panel runtimes remain free-text producers and
do not need that capability.

Heterogeneous presets move model lists into group tables:

- `[[fusion.presets.<name>.panels]]`: each group owns `models`,
  `system_prompt`, `max_tool_calls_per_panel`, `max_output_tokens_per_panel`,
  and optional routing labels.
- `[[fusion.presets.<name>.judges]]`: each judge owns `model`,
  `system_prompt`, `max_tool_calls`, and `max_output_tokens`.

Omitted output-token keys preserve the Runtime_agent default.

`max_concurrent_judges`는 topology를 늘리는 값이 아니라 독립 judge 호출을 동시에 몇 개까지
실행할지 정하는 cap이다. Topology는 `masc_fusion.topology` 문자열로 선택한다.

- `judge_of_judges`: preset에 9개의 `[[fusion.presets.<name>.judges]]`가 있으면 flat
  JoJ로 9개 1차 심판을 실행한 뒤 meta 심판이 한 번 reconcile한다.
- `staged_judge_of_judges`: 같은 9개 1차 심판과 `staged_judge_group_size = 3`이면
  `3 + 3 + 3` stage meta 결과를 만든 뒤 final meta가 최종 reconcile한다. judge 수가
  group size로 나누어떨어지지 않거나 두 개 이상의 full group을 만들 수 없으면 실행 전
  에러로 fail-closed한다.

두 topology 모두 기존 `Fusion_sink.emit` 경로로 canonical judge 결과를 board/chat에 append한다.
staged topology도 nested `masc_fusion` 호출을 하지 않으므로 depth guard는 그대로 유지된다.

### 7.2 모델 식별자 형식

Tier member는 `<provider_id>.<model_id>` 또는
`<provider_id>.<model_id>.<alias>` 형식의 선언형 binding identifier를
사용한다. Runtime adapter는 검증된 binding을 provider별 실행 spec으로
변환한다.

- checked-in repo defaults는 explicit label을 사용한다.
- `auto`는 provider-specific runtime convenience일 수 있지만, repo에 커밋되는 runtime 기본값으로는 권장하지 않는다.

| Provider | Env Config 모듈 | 기본 모델 |
|----------|----------------|----------|
| `ollama` | `Local_runtime` | `OLLAMA_DEFAULT_MODEL` (port 11434, 262k context) |
| `llama` | `Local_runtime` | `LLAMA_DEFAULT_MODEL` (legacy local OpenAI-compatible runtime) |
| `glm` | `Glm` | `ZAI_DEFAULT_MODEL` |
| `glm-coding` | `Glm` | `ZAI_CODING_DEFAULT_MODEL` |
| `openai-compatible` | OpenAI-compatible runtime | `OPENAI_DEFAULT_MODEL` |
| `openrouter` | `OpenRouter` | `OPENROUTER_DEFAULT_MODEL` |

### 7.3 Per-runtime 추론 파라미터

Temperature/max-output 같은 호출 목적별 override는 alias 레이어에 둔다.
미설정 시 호출자 기본값 또는 provider/model capability 기본값을 사용한다.

```toml
[cli-tool-d.haiku.for-scoring]
temperature = 0.1
max-output = 1024
```

### 7.3.1 Keeper assignability metadata

`keeper-assignable`은 dashboard/runtime manager가 keeper에 할당 가능한
profile인지 명시하는 bool metadata다. `tier` 또는 `runtime`에 선언할
수 있으며 기본값은 `true`.

- `true` 또는 미설정: keeper assignment dropdown에 노출 가능
- `false`: system-only profile. runtime manager에는 보이지만 keeper에는 할당 불가

예:

```toml
[runtime.scoring]
tiers = ["scoring", "__safe_lane"]
strategy = "priority_tier"
fallback = true
keeper-assignable = false
```

### 7.4 Pluggable Strategy

각 `tier` 또는 `runtime`은 `strategy` 키로 provider 선택 전략을
지정한다. 미설정 시 `failover`로 동작한다. Operator config에서
지원되는 strategy 값은 현재 `failover`, `priority_tier` 두 개뿐이다.

| 전략 | 키 값 | 설명 |
|------|-------|------|
| S1 Failover | `failover` | members 입력 순서 유지 |
| S5 Priority tier | `priority_tier` | runtime의 `tiers` 순서대로 fallback |

Retired experimental strategy 값은 더 이상 `Runtime_strategy.kind`에 남기지 않는다.
오래된 `runtime.toml`이 해당 값을 지정하면 parser 단계에서 실패한다.

관련 선언형 키:

| 키 | 타입 | 기본값 | 적용 전략 |
|-----|------|--------|-----------|
| `members` | string list | `[]` | tier 후보 binding/alias 목록 |
| `tiers` | string list | `[]` | runtime fallback chain |
| `fallback` | bool | `false` | runtime fallback hint 노출 |
| `strategy` | string | `failover` | tier/runtime provider 선택 |
| `keeper-assignable` | bool | `true` | keeper 할당 가능 여부 |

Unknown strategy 값은 catalog validation error로 취급한다.

### 7.4.1 WebSearch provider defaults

`[web_search]`는 runtime catalog provider가 아니라 MASC-owned WebSearch /
WebFetch backend의 startup default namespace다. 서버 bootstrap에서
process-local boot override로 주입되며, process env var가 있으면 env var가
우선한다. `runtime.toml` 수정은 재시작 후 반영된다.

```toml
[web_search]
searxng_url = "http://localhost:8888"
provider = "auto"
provider_order = "searxng,brave,tavily,exa,bing_api"
fallbacks = "duckduckgo,bing_rss"
timeout_sec = 15
cache_ttl_sec = 30.0
rate_limit_window_sec = 30.0
rate_limit_max_calls = 30
```

`Runtime_toml` parser는 `web_search`를 reserved top-level namespace로 취급해
provider binding table로 해석하지 않는다.

### 7.5 Client Capacity (Phase A/C3, #7606/#7623)

Provider-model binding의 `max-concurrent`는 선택적 operator override다.
누락은 정상값이며 "no static per-binding cap"을 뜻한다. 기본 provider 보호는
global `Provider_http` gate, live health/backoff, provider-reported throttling,
그리고 provider별 discovery/probe가 담당한다. 사람이 모든 binding에 cap을
채우는 방식은 기본 운영 모델이 아니다.

`max-concurrent`를 설정하는 경우는 slot API나 provider-side admission signal이
없는 취약 endpoint를 수동으로 보호해야 할 때뿐이다. 이 값은 runtime catalog
metadata로 보존되지만, OAS multi-turn/tool 실행 전체를 제한하는 keeper-attempt
cap으로 해석하면 안 된다. enforcement가 필요하면 provider HTTP transport call
단위 또는 endpoint-discovery 단위에서 적용해야 한다.

명시된 값은 반드시 **양의 정수**여야 한다. `0`이나 음수는 누락과 다르게
fail-fast parse error로 거부된다. (`0`은 과거 omission sentinel로 쓰였으므로
조용히 무시하면 "차단" 의도가 "무제한"으로 뒤집힐 수 있다.)
```toml
[cli-tool-a.agent-code-spark]
is-default = true
max-concurrent = 1
```

`cli-tool-a:auto`, `cli-tool-d:auto`는 기본적으로 concrete 후보 목록을 코드에 갖지 않는다. 미설정 기본값은 `auto` 1개이며 각 CLI transport의 현재 기본 모델 선택에 위임한다. 특정 모델 rotation이 필요하면 binding의 `auto_models` 또는 호출 목적 alias를 통해 operator가 명시한 후보를 사용한다. Direct API provider의 concrete 후보 목록과 기본값은 OAS runtime binding/catalog가 제공하는 값을 projection해서 사용한다. binding이 supported model 목록을 제공하지 않으면 MASC는 `auto`를 임의 concrete model로 확장하지 않는다.

### 7.6 HTTP Probe Capacity (Phase C2, #7619)

등록된 HTTP probe provider는 provider별 probe endpoint를 가진다. MASC는 cycle 시작마다 등록된 URL들을 순차적으로 조회하여 (`Runtime_capacity_probe.refresh_many` → registered probe 내부 `refresh_many`) 실제 활성 모델 수를 capacity로 변환한다. 캐시 TTL 2초. 응답 실패 시 silent fail → Phase A client-capacity semaphore로 fallback. 병렬 fan-out이 필요해지면 probe adapter의 `refresh_many`에서 `Eio.Fiber.both` 로 전환.

capacity 조회 순서: `Runtime_throttle` (llama-server /slots 기반) → `Runtime_capacity_probe` (discovered via registered probes, e.g. `/api/ps`) → `Runtime_client_capacity` (declared semaphore).

### 7.7 예시

```toml
[glm-coding.glm-4-7-coding]
is-default = false

[openai-compatible.gpt-4.1-mini]
is-default = true

[tier.tier_medium]
members = ["glm-coding.glm-4-7-coding", "openai-compatible.gpt-4.1-mini"]
strategy = "failover"

[runtime.tier_medium]
tiers = ["tier_medium", "primary"]
strategy = "priority_tier"
fallback = true

[routes.moderate_task]
target = "runtime.tier_medium"
```

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
| `--base-path` | `MASC_BASE_PATH` 또는 `cwd` | workspace/base 경로. runtime root는 `<base-path>/.masc` |

---

## 10. 불변식

- **INV-C1**: 모든 `MASC_*` 환경변수는 `get_string/get_int/get_float/get_bool` 헬퍼를 통해 읽힌다. `Sys.getenv` 직접 호출은 `Env_config_core`의 해석 함수에서만 허용.
- **INV-C2**: `Runtime_params.set`은 반드시 `validate`를 통과해야 한다. 검증 실패 시 `Error`를 반환하고 값은 변경되지 않는다.
- **INV-C3**: `Unknown` category에 매핑된 도구는 어떤 mode preset에서도 노출되지 않는다.
- **INV-C4**: `tool_catalog.is_visible`이 false를 반환하는 도구는 `allow_direct_call_when_hidden=true`가 아닌 한 MCP 클라이언트에 노출되지 않는다.
- **INV-C5**: Runtime JSON의 모델 목록은 순서대로 시도되며, 전부 실패 시 skip한다 (error propagation, fallback 없음).

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
  > missing/uninitialized
```

암묵적 secondary search(운영자 home personas, base-path root personas)는 사용하지 않는다.
Persona, keeper TOML, prompt markdown, runtime, tool_policy는 모두 같은 resolved config root를 기준으로 해석한다.

### 12.4 Template 변경 반영

Template 변경은 기존 keeper에 자동 전파되지 않는다. 반영 방법:

1. `keeper_down <name>` — keeper 중지 + meta 파일 삭제
2. `keeper_up <name>` — template에서 fresh로 재생성

### 12.5 `--base-path`와 `.masc/` 의존성

`--base-path` CLI 인자는 workspace/base 경로다. runtime root는 항상 `<base-path>/.masc/`로 계산한다. `scripts/run-local.sh`는 `MASC_BASE_PATH=<target>` 및 `--base-path <target>`을 넘기며, 그 결과 data root가 `<target>/.masc/`가 된다. shared/full-runtime 경로는 별도 launcher가 유지한다.

dir-local local-dev에서는 `.masc/`가 target 디렉토리 내부를 가리키므로 shared repo keeper 상태와 분리된다. shared state가 필요하면 canonical shared launcher를 사용해야 한다.

이 값은 runtime data root를 결정하고, explicit `MASC_CONFIG_DIR`가 없을 때는 `<MASC_BASE_PATH>/.masc/config`를 resolved config root의 첫 fallback으로도 사용한다.

### 12.6 모델 실행

모델 선택은 `runtime.toml`이 유일한 권위다. keeper_meta의 `runtime_id` (기본 `"primary"`)가 keeper-assignable runtime을 지정하고, runtime resolver가 실행 모델을 결정한다. keeper 설정에 모델 필드를 직접 지정하지 않는다.
