# llama-server 로컬 레인 Runbook — KV 재사용 극대화

RFC-0382의 실측을 운영 절차로 옮긴 문서다. 대상은 llama.cpp `llama-server`로 로컬 모델을 keeper 레인에 붙이는 배포이며, 목표는 멀티턴 keeper의 턴당 prefill 비용을 "새 입력 분량"으로 유지하는 것이다.

검증 기준 빌드: llama.cpp **b10180 (11b068d06)**, 모델 Qwen3.8-27B UD-Q4_K_XL. 다른 빌드에서는 `llama-server --help`로 플래그 존재를 재확인한다 (`--reasoning-preserve`, `--ctx-checkpoints`는 2026년 추가분).

## 1. 기동

```sh
llama-server \
  -m <gguf-path> \
  --alias <model-alias>            # runtime.toml api-name과 일치시킨다 \
  --host 127.0.0.1 --port <port> \
  -c <ctx> -np <slots> \
  --jinja \
  --reasoning-format deepseek \
  --cache-reuse 256
```

| 플래그 | 값 | 이유 |
|---|---|---|
| `--jinja` | 필수 | GGUF 내장 chat template 사용. `chat_template_kwargs`(enable_thinking / preserve_thinking)가 이 경로로만 동작한다 |
| `--reasoning-format` | `deepseek` | thinking을 `message.reasoning_content`로 분리. MASC의 `reasoning_streaming_format = "delta:reasoning_content"` 행과 짝 |
| `--cache-reuse` | `256` | 프리픽스 중간이 달라진 요청에서 KV shifting으로 청크 재사용. 기본 0(꺼짐). **hybrid(SSM) 모델에서는 서버가 로드 시 무효화한다** (`cache_reuse is not supported by this context` — Qwen3.8 실측). 그 경우 프리픽스 재사용은 슬롯 LCP + `--ctx-checkpoints`가 담당 |
| `--ctx-checkpoints` | 기본 32 유지 | hybrid(SSM)/SWA 모델의 부분 롤백 지점. Qwen3.8 같은 hybrid에 필수 (llama.cpp PR #15293) |
| `-sps` | 기본 0.10 유지 | 슬롯 선택이 프리픽스 유사도로 이미 동작. 다수 keeper가 한 서버를 공유할 때 슬롯 오염을 줄인다 |
| `--slot-save-path <dir>` | 선택 | 서버 재시작 간 슬롯 KV 영속화. `POST /slots/{id}?action=save\|restore` |
| (운영 주의) 벤치 요청 금지 | — | `-np 1` 운영 서버에 즉석 벤치/테스트 요청을 보내면 단일 슬롯의 은행된 keeper KV를 덮어쓰고 측정도 경합으로 오염된다. 성능 측정은 별도 포트의 전용 인스턴스에서 |
| `--reasoning-preserve` | 켜지 않는다 | 서버 전역 강제 대신 MASC가 요청별 `chat_template_kwargs {"preserve_thinking": true}`로 제어한다. 템플릿이 `supports_preserve_reasoning`을 선언하면 로드 로그에 안내가 찍힌다 |
| `cache_prompt` | 건드리지 않는다 | 요청 기본값이 이미 true |

슬롯 수(`-np`)는 이 서버를 공유하는 keeper 수에 맞춘다. `-np 1`로 keeper 여럿을 태우면 대기 굶김이 생긴다 (2026-08-11 HITL 사례: 84KB 요청이 30분간 로그에도 못 들어옴). 슬롯당 컨텍스트는 `-c / -np`로 쪼개지므로 함께 계산한다.

## 2. KV 재사용 계약 (클라이언트 쪽)

llama-server의 프리픽스 캐시는 요청 토큰열이 슬롯의 기존 열과 **바이트 단위로 이어질 때만** 작동한다. MASC agent-core는 이미 이 계약을 지킨다:

1. **안정 프리픽스**: system prompt는 세대 내 고정 (`keeper_unified_prompt.mli`), 히스토리는 append-only, 윈도우 컷은 atoms_per_window 배수로 양자화 (`runtime_model_input_tail_window.mli`).
2. **변동 정보는 꼬리로**: world_state·타임스탬프·recall 주입은 extra_system_context로 히스토리 **뒤에** 붙는다 (`agent_turn.ml:31`). 프리픽스 헤드에 매턴 변하는 내용을 넣으면 재처리 비용이 히스토리 길이에 비례해 커진다 — 실측 31배 (RFC-0382 §3.1).
3. **reasoning 보존**: `preserve_thinking` 활성 시 이전 턴 생성물(thinking 포함)의 KV가 그대로 이어져 턴당 prefill이 새 user 메시지 분량(26~34 tok)으로 수렴한다.

실측 요약 (Qwen3.8-27B, 4턴, max_tokens 512 — 원값 `docs/evidence/kv-cache-harness-2026-08-16.jsonl`):

| 히스토리 정책 | 턴4 재처리 |
|---|---|
| preserve + append-only | 26 tok / 0.7s |
| strip (Qwen 기본) | 32~122 tok |
| volatile-head (system에 타임스탬프) | 1,892 tok / 14.4s |
| volatile-tail | 61 tok / 1.0s |

재현: `python3 scripts/bench-kv-cache.py --base http://127.0.0.1:<port> --turns 4 --max-tokens 512`

## 3. MASC 등록

### 3.1 `<MASC_BASE_PATH>/config/agent-core-models-overlay.toml`

```toml
[[providers]]
id = "llama_cpp"
kind = "openai_compat"
base_url = "http://127.0.0.1:<port>"
request_path = "/v1/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat_extended"

[[models]]
id_prefix = "<model-alias>"
provider_name = "llama_cpp"
base = "openai_chat"
max_context_tokens = <slot-ctx>          # -c/-np, 모델 카드가 아니라 서버 실효값
supports_tools = true
supports_tool_choice = true
supports_reasoning = true
supports_extended_thinking = true
supports_reasoning_budget = false
thinking_control_format = "chat_template_kwargs"
preserve_thinking_control_format = "chat_template_kwargs_preserve_thinking"
reasoning_streaming_format = "delta:reasoning_content"
supports_response_format_json = true
supports_structured_output = true        # llama-server json_schema 지원
supports_native_streaming = true
input_per_million = 0.0
output_per_million = 0.0

[[targets]]
id = "llama_cpp.<model-row-id>"
provider_ref = "llama_cpp"
model_id = "<model-alias>"
```

### 3.2 `<MASC_BASE_PATH>/config/runtime.toml`

```toml
[providers.llama_cpp]
display-name = "Local llama-server (llama.cpp)"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:<port>/v1"

[models.<model-row-id>]
api-name = "<model-alias>"
max-context = <slot-ctx>
tools-support = true
thinking-support = true        # keeper 대화 레인: thinking on
preserve-thinking = true       # 이전 턴 reasoning_content 재주입 (KV 연속 + 사고 연속)
streaming = true

[llama_cpp.<model-row-id>]
# prefill 동안 prompt_progress SSE 청크를 요청한다 (#28791). 콜드/딥 prefill이
# first-event/idle 데드라인에 생존신호를 먹여, 타임아웃이 본래 역할(죽은 서버
# 감지)로 돌아간다. 미지원 서버는 필드를 무시한다.
return-progress = true
```

exact-output(JSON) 레인에 같은 서버를 쓸 때는 **별도의 모델 행**을 만들어 `thinking-support = false`로 둔다. reasoning이 출력 예산을 소진해 JSON이 잘리는 결함(2026-08-10 librarian 사례)은 thinking off로만 막는다.

### 3.3 반영과 검증

overlay는 서버 부트스트랩에서 로드된다(`Model_catalog.set_global_overlay`) — **재시작 필요**. runtime.toml은 dashboard API로 핫 반영 가능:

```sh
# 검증만 (저장 안 함)
curl -s -X POST localhost:8935/api/v1/runtime/config/raw/preview \
  -H "Authorization: Bearer $(cat <MASC_BASE_PATH>/auth/dashboard.token)" \
  --data-binary @runtime.toml
# 저장 + 핫 리로드
curl -s -X POST localhost:8935/api/v1/runtime/config/raw ...
```

반영 후 반드시 확인한다 (조용한 미materialize 전례: 2026-08-12 키 점 표기 사고):

1. `GET /api/v1/runtime/resolved`에 `llama_cpp.<model-row-id>`가 나타나는가.
2. 첫 keeper 턴 로그에 `cache_n=… prompt_n=…`이 찍히는가 (턴 2부터 cache_n > 0).
3. `timings.cache_n`이 0에 고정이면 프리픽스가 매턴 깨지고 있다는 뜻이다 — 요청 캡처로 어느 위치에서 바이트가 달라지는지 비교한다.
4. 콜드 prefill이 `stream_idle_timeout_sec`(fleet 전역)보다 길면 first-event 타임아웃으로 취소된다 — 취소돼도 prefill은 슬롯 KV에 적립되어 재시도가 이어받지만(2026-08-16 실측: 12K→22K→32K 적립 후 4번째 완주), `return-progress = true`가 근본 해법이다.

## 4. 알려진 함정

| 함정 | 증상 | 근거 |
|---|---|---|
| mlx_vlm.server를 같은 자리에 쓰기 | 매 요청 풀 re-prefill (Metal 캐시 소거), `apc_enabled:false` | Blaizzy/mlx-vlm#999 |
| hybrid 모델 + 프리픽스 헤드 변형 | 체크포인트 고갈 → cache_n 붕괴 (실측: 559→68) | RFC-0382 §3.1 |
| ollama 경유 서빙 | 같은 GGUF에서 decode 1/5 (3.2 vs 17.6 t/s, qwen35 arch 기준) + cache_n 무보고 | RFC-0382 §3.3 |
| `-np 1`에 다중 keeper | 뒤 요청 무기한 대기 | 2026-08-11 HITL 사례 |
| draft(speculative) + response_format | 서버가 거부 | 2026-08-15 mlx 실측과 동일 계열 — draft 미사용 인스턴스 분리 |
