---
rfc: "0382"
status: Draft
---

# RFC-0382: 런타임별 KV/prompt cache 재사용과 reasoning 연속성

- 상태: Draft
- 날짜: 2026-08-16
- 실측 리포트: `reports/kv-cache-runtime-audit-2026-08-16.html`
- 원본 증거: `docs/evidence/kv-cache-harness-2026-08-16.jsonl`, `~/me/memory/procedural-memory/2026-08-16-llama-server-kv-preserve-thinking-evidence-record.md`
- 측정 도구: `scripts/bench-kv-cache.py`

## 0. 판정 요약

1. MASC의 프롬프트 구조는 이미 캐시 인지형이다 — 안정 system 헤드, append-only 히스토리, window 양자화 컷, 변동 컨텍스트 꼬리 주입까지 설계 근거가 코드에 있다 (`agent_turn.ml:33-34`, `runtime_model_input_tail_window.mli`, `keeper_unified_prompt.mli`).
2. llama-server(b10180) + Qwen3.8-27B 실측에서 preserve-thinking + append-only 정책은 턴당 prefill을 26~34 토큰(≈0.7s)으로 떨어뜨린다. 같은 대화를 시스템 헤드에 타임스탬프 한 줄만 넣고 돌리면 재처리 토큰이 314→863→1,892로 히스토리에 비례해 배증한다(턴4 14.4s). 같은 정보를 꼬리로 옮기면 61~69 토큰 상수로 돌아온다 — 턴4 기준 31배.
3. 스트리밍 경로가 llama-server의 `timings`(cache_n = 캐시 재사용 토큰 수)를 버린다. 로컬 행은 전부 `streaming = true`이므로 정확히 관측이 필요한 지점에서 관측이 사라진다 (`complete_stream.ml:353` Ollama NDJSON 전용).
4. 라이브 fleet(8/15, 762턴)의 캐시 히트는 provider가 결정했다: gemini 84.1%, GLM 68.5%, ollama_cloud(deepseek) 0% — 하루 2,340만 input 토큰이 전량 재프리필. 클라이언트 구조 문제가 아니라 캐시 없는 provider에 멀티턴 keeper를 태운 배치 문제다. (GLM 수치는 최초 게재분 40.6%의 정정 — §3.2)
5. 로컬 8080은 현재 mlx_vlm.server이고 `apc_enabled: false`인 데다 upstream이 요청마다 Metal 캐시를 지운다(Blaizzy/mlx-vlm#999). llama-server b10180은 같은 모델에서 prefill 167 t/s / decode 17.6 t/s로 ollama 경로(3.2 t/s) 대비 5.5배, MLX+draft(19.1 t/s)와 대등하면서 KV 재사용·JSON schema·slot 저장을 전부 지원한다. 로컬 레인의 정답은 llama-server 복원이다.

## 1. 배경

목표: 어떤 Runtime으로도 10턴+, 1~24시간 연속 동작하는 Keeper의 턴 연속성. 이전 턴의 기억(사고 과정 포함)이 다음 턴으로 이어지고, 그 연속성이 KV/prompt cache 재사용으로 비용·지연 이점까지 내는 구조가 맞는지 감사한다.

"Preserve Thinking" 관련 외부 주장 검증 결과:

| 주장 | 판정 | 근거 |
|---|---|---|
| llama-server `--reasoning-preserve` 플래그 존재 | 사실 (b10180) | `--help` 실측; "compatible with certain templates having 'supports_preserve_reasoning'" |
| Qwen3.6+/3.8 `preserve_thinking` chat template kwarg | 사실 | Qwen3.8-27B GGUF 로드 로그 "chat template supports preserving reasoning"; NousResearch/hermes-agent#56004 |
| thinking 보존 + prompt cache 결합 시 다음 턴 prefill ≈ 0 | 사실 (실측) | §3 표 — 턴당 prompt_n 29~38 |
| `--prompt-cache` 플래그로 서버 캐시 제어 | 부정확 | llama-cli 전용. 서버는 `cache_prompt` 요청 필드(기본 true) + `--cache-reuse`/`--slot-save-path` |

## 2. 현재 구조 감사

### 2.1 이미 올바른 것

| 구조 | 위치 | 내용 |
|---|---|---|
| 3채널 프롬프트 | `lib/keeper/keeper_unified_prompt.mli` | system(세대 내 안정) / world_state(매턴 재조립, 비영속) / user_message(영속). #25193에서 world_state 영속화가 943/945 중복 프레임을 만든 사고 이후 분리됨 |
| 변동 컨텍스트 꼬리 주입 | `packages/agent_core/lib/agent/agent_turn.ml:33-34` | extra_system_context를 히스토리 뒤에 append. 주석에 "critical for local LLM KV-cache reuse" 명시 |
| Window 양자화 컷 | `lib/runtime/runtime_model_input_tail_window.mli` | 슬라이딩 컷 대신 atoms_per_window 배수 점프로 프리픽스 바이트 동일 유지 (#26535 실측 기반) |
| Reasoning replay 타입 계약 | `packages/agent_core/lib/llm_provider/reasoning_replay_contract.mli`, `reasoning_history_projection.mli` | replay_policy 5종 + provenance 검증 + rotation policy. provider 이름 비교 없음 |
| preserve_thinking 인코딩 | `reasoning_dialect.ml:294,446` | `chat_template_kwargs: {enable_thinking, preserve_thinking}` 정확한 필드명. GLM `clear_thinking=false` 매핑도 존재 |
| 캐시 관측 파싱(비스트리밍) | `backend_openai_parse.ml:240,286` | llama-server `timings.cache_n` 파싱 → keeper cost events(`keeper_hooks_agent_core_cost_events.ml:141`)까지 배선 |
| Anthropic system+tools 캐시 | `backend_anthropic.ml:346,392` | `cache_system_prompt=true`(keeper 기본, `keeper_agent_run.ml:885`)면 system 블록 + 마지막 tool에 cache_control |

### 2.2 격차

| # | 격차 | 위치/근거 | 영향 |
|---|---|---|---|
| G1 | OpenAI-compat SSE 스트림이 `timings`를 파싱하지 않음 | `complete_stream.ml:353-379` (oll_timings는 Ollama NDJSON 전용). llama-server는 최종 청크(finish_reason 포함)에 top-level `timings`를 opt-in 없이 싣는다 — 2026-08-16 curl 실측, `system_fingerprint: b10180-11b068d06` | 로컬 행 전부 `streaming=true` → llama-server cache_n 관측 불가 |
| G2 | llama-server 레인 부재 | runtime.toml 주석 2026-08-10 "127.0.0.1:8080 LISTEN 없음"; 현재 8080은 mlx(`apc_enabled:false`) | 로컬 멀티턴 KV 재사용 0 (mlx-vlm#999: 요청마다 Metal 캐시 소거) |
| G3 | 로컬 행 `preserve-thinking = false` 일괄 | runtime.toml qwen3-8-27b 행 | reasoning 연속성 유실 + strip 재작성으로 캐시 경계 후퇴. 템플릿은 preserve 지원(로드 로그) |
| G4 | Anthropic 대화 히스토리 캐시 breakpoint 없음 | `backend_anthropic.ml` (system+tools만) | 멀티턴 히스토리 매턴 전액 input 과금. 공식 권장은 top-level 자동 breakpoint (read 0.1x) |
| G5 | 대시보드가 cache를 bool로 축약 | `dashboard_agent_core_bridge.ml:211` | 재사용 비율(cache_n / (cache_n+prompt_n)) 추이 관측 불가 |
| G6 | provider별 usage 의미론(input에 cached 포함 여부) 미감사 | `pricing.ml:63`은 포함 가정, Anthropic wire는 배제형 | 비용 집계 이중 차감/과대 위험 — 후속 감사 |

## 3. 실측

### 3.1 llama-server KV 재사용 (Qwen3.8-27B UD-Q4_K_XL, b10180, M3 Max, -c 16384 -np 1, --reasoning-format deepseek)

4개 히스토리 정책 × 4턴, 동일 대화 시드, max_tokens 512. `prompt_n`(재처리 토큰) / `prompt_ms`:

| 정책 | 턴2 | 턴3 | 턴4 | 경향 |
|---|---|---|---|---|
| preserve (append-only + reasoning replay) | 29 tok / 0.9s | 34 / 0.6s | 26 / 0.7s | 상수 |
| strip (Qwen 기본, reasoning 제거) | 122 / 1.4s | 86 / 1.2s | 32 / 1.2s | 마지막 교환 크기에 비례 |
| volatile-head (system에 타임스탬프 1줄) | 314 / 4.0s | 863 / 7.1s | 1,892 / 14.4s | 히스토리 길이에 비례 — 턴마다 배증 |
| volatile-tail (같은 정보를 꼬리에) | 64 / 1.0s | 69 / 1.1s | 61 / 1.0s | 상수 |

턴4 기준 volatile-head 대 volatile-tail은 31배(1,892 vs 61 tok). 같은 정보를 넣는 위치만 바꿨다.

핵심 기전 두 가지. (1) 생성된 thinking 토큰의 KV는 슬롯에 남아 있으므로, 다음 턴 히스토리에 같은 reasoning_content를 그대로 되돌려주면 재토큰화 비용 없이 프리픽스가 이어진다 — 전이 산술로 확인된다: 턴1이 생성한 295tok는 턴2의 cache_n에(68+516+295≈878), 턴2가 생성한 419tok는 턴3의 cache_n에(878+29+419≈1325) 그대로 편입되고, 각 턴의 신규 처리분은 새 user 메시지(29~34tok)뿐이다. (2) 프리픽스 앞쪽 1바이트 변형은 그 뒤 전체를 무효화하며, hybrid(SSM) 모델은 임의 위치 롤백이 안 되므로 체크포인트(`--ctx-checkpoints`, b10180 기본 32/slot)가 있는 위치까지만 되감는다 — volatile-head 턴4에서 cache_n이 68로 무너진 것이 체크포인트 고갈의 실측이다. 원 수치는 `docs/evidence/kv-cache-harness-2026-08-16.jsonl`. 측정 한계 두 가지(적대적 리뷰 지적): 시나리오 간 슬롯 캐시를 지우지 않아 각 시나리오의 턴1은 직전 시나리오 잔여 캐시에 오염될 수 있다(volatile 턴1 cache_n=559가 그 사례) — 표가 턴1을 제외하는 실제 이유다. 그리고 strip·volatile의 일부 턴은 thinking이 max_tokens를 소진해 content가 빈 퇴화 생성이었다(JSONL의 content_chars=0). 턴2~4의 정책 간 상대 비교에는 영향이 없지만, volatile의 재처리 증가에는 캐시 무효화 외에 프롬프트 변동으로 인한 생성 길이 변화가 혼입될 수 있다.

### 3.2 라이브 fleet 캐시 히트 (8/15, `<MASC_BASE_PATH>/costs/2026-08/15.jsonl`, 762턴)

| 모델 | 턴 | cache_read | input | 히트율 | input 의미론 |
|---|---|---|---|---|---|
| gemini-3.6-flash-high | 127 | 145.5M | 27.6M | 84.1% = r/(r+i) | cached 배제형 |
| GLM-5-Turbo | 364 | 13.1M | 19.2M | **68.5% = r/i** | cached 포함형 (input = cache_read + cache_miss, 표본 불일치 0건) |
| deepseek-v4-flash:0731 (ollama_cloud) | 271 | 0 | 23.4M | 0% | — |

정정 기록 (2026-08-16 적대적 리뷰): 최초 게재분은 GLM에 40.6% = r/(r+i)를 썼으나, GLM의 `input_tokens`는 캐시 재사용분을 이미 포함하므로 분모에서 cache_read가 이중 계산된 오류였다. G6에서 지적한 "provider별 usage 의미론 차이"가 이 표 자체에 실현된 사례다. 히트율 공식은 provider의 input 의미론에 따라 행별로 다르다. 원본 로그는 라이브로 증가하는 파일이라 사후 재현이 불가하며, 위 수치는 8/15 자정 기준 스냅샷 합산이다.

### 3.3 로컬 서빙 경로 비교 (같은 Qwen3.8-27B)

| 경로 | prefill | decode | KV 재사용 | 비고 |
|---|---|---|---|---|
| ollama 0.32.12 /api/chat | 12.3 t/s | 3.2 t/s | (미계측) | 2026-08-15 실측, runtime.toml 주석 |
| mlx_vlm.server 0.6.13 + MTP draft | — | 19.1 t/s | 없음 (apc off + 요청별 캐시 소거) | response_format 미지원(draft) |
| llama-server b10180 | 167 t/s | 17.6 t/s | cache_n 실측 재사용 | JSON schema·slot save·preserve 지원 |

## 4. 계획 (stacked PR)

| PR | 내용 | 격차 |
|---|---|---|
| PR-1 (이 문서) | RFC + 리포트 + 하네스 + 증거 | — |
| PR-2 | agent_core: OpenAI-compat SSE 최종 청크의 `timings` 파싱 → telemetry (Ollama 경로와 동형) | G1 |
| PR-3 | keeper/dashboard: cache_n·prompt_n 원값 노출 (bool 축약 제거는 하지 않고 병기) | G5 |
| PR-4 | llama-server 레인 복원 runbook + 캐파 행(preserve_thinking_control_format 선언) + `<MASC_BASE_PATH>` 설정 반영 (ops) | G2, G3 |
| PR-5 | backend_anthropic: top-level 자동 cache_control 옵트인 | G4 |
| 후속 | usage 의미론 감사 (input_tokens에 cached 포함 여부 provider별 계약 명문화) | G6 |

## 5. 하지 않는 것

- 캐시 히트율 기반 게이트/차단/재시도 없음 — 관측만 한다. 히트율은 진단 신호이지 흐름 제어 입력이 아니다.
- 토큰↔바이트 환산 상수 도입 없음 (기존 원칙 유지 — provider가 window fit의 oracle).
- string 매칭 기반 provider 분기 없음 — 전부 기존 typed capability 축(`preserve_thinking_control_format`, `reasoning_streaming_format`)으로 선언.
- 레거시 필드/마이그레이션 없음.

## 6. 참고

- llama.cpp server README (cache_prompt/cache_n/--cache-reuse/--slot-save-path/-sps/chat_template_kwargs/--reasoning-format)
- llama.cpp PR #15293 (context checkpoints — hybrid/SWA 부분 재사용)
- Anthropic prompt caching 문서 (top-level 자동 breakpoint, read 0.1x/write 1.25x, tools→system→messages 계층)
- Blaizzy/mlx-vlm#999, ml-explore/mlx-lm#980 (mlx 캐시 결함)
- NousResearch/hermes-agent#56004, earendil-works/pi#3325 (preserve_thinking 부재로 인한 multi-turn 결함 사례)
- DeepSeek context caching 문서 (프리픽스 유닛 완전 일치 시에만 히트)

## 7. 라이브 검증 (2026-08-16 04:10~04:25 KST, 추가)

§4 계획의 PR-2(#28777)·PR-3(#28778)·PR-4(#28782)를 병합하고, llama_cpp 레인을 실제 fleet에 올려 keeper 턴으로 검증했다.

절차: overlay + runtime.toml에 `llama_cpp.qwen3-8-27b-llama` 등록 → preview API 검증 → 핫리로드 → `/api/v1/runtime/resolved`에서 `keeper_dispatchable: true` 확인 → `canary-multiturn-localollama-20260814-0839`를 레인에 배정, thinking/preserve on.

| 관측 | 값 | 근거 |
|---|---|---|
| 턴 15 (콜드) | 35K 프리픽스 프리필 중 first-event 120s 데드라인에 3회 취소, 취소마다 슬롯 KV 적립 12K→22K→32K, 4번째 시도 완주 | llama-server 로그 task 0/14/27/70 |
| 턴 16 (웜) | LCP 유사도 0.949, **캐시 재사용 94.6%** — 신규 1,769tok만 19.3s 프리필, ttfrc 27.2s, `finish_reason: completed`, `enable_thinking: true` | turn-record absolute_turn=16, llama-server 로그 |
| 대시보드 | 컨텍스트 미터 34.5k/65.5k(53%)가 provider 실측 입력 토큰으로 표시, 런타임 패널에 `chat-template-kwargs` 축 노출 | keeper 상세 화면 실측 |

파생 수정: 콜드/딥 프리필의 first-event 침묵은 타임아웃 완화가 아니라 llama-server `return_progress`(prefill 중 `prompt_progress{total, cache, processed}` SSE 청크, b10180 검증)로 푼다 — PR-6 (#28791). `[turn] stream_idle_timeout_sec = 120`은 본래 역할(죽은 서버 감지)로 유지.

병합 이력: #28774(본 RFC) → #28777(G1) → #28778(G5) → #28782(G2/G3 runbook) → #28785(G4, anthropic) → #28791(return_progress).
