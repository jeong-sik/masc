# Cascade Routes Authoring Guide

`cascade.toml`의 `[routes.<logical_use>]` 섹션을 운영자 시점에서 어떻게 채울지 정리.
schema/syntax 는 [`CASCADE-TOML.md`](./CASCADE-TOML.md), copy-paste 예시는 [`CASCADE-COOKBOOK.md`](./CASCADE-COOKBOOK.md).
이 문서는 두 문서가 다루지 않는 **각 route 의 의미 + lane 선택 + alias 활용**을 다룬다.

- SSOT: `lib/cascade/cascade_routes.ml` 의 `logical_use` closed variant.
- 관련 RFC: [RFC-0038](./rfc/RFC-0038-cascade-routing-intent-preservation.md) (intent preservation, 254/2620 silent substitution 사고), [RFC-0041](./rfc/RFC-0041-cascade-routing-group-item-hierarchy.md) (group/item hierarchy + health-aware fallback), [RFC-0058](./rfc/RFC-0058-declarative-cascade-config.md) (5-layer schema).

---

## 1. 5-Layer 흐름 (한 그림)

```
providers   → 누구한테 보낼지 (auth, protocol, endpoint)
  └─ models → 어떤 모델 (api-name, context, capability)
      └─ bindings  → provider × model 묶음 (max-concurrent, is-default)
          └─ aliases → 호출 시나리오별 cap 덮어쓰기 (max-output, temperature)
              └─ tiers       → failover 멤버 순서
                  └─ tier-groups → tier 들의 추가 fallback chain
                      └─ routes  → logical_use → 타겟
```

route 는 기본적으로 **`tier-group` 을 가리킨다**. 단일 `tier` 나 binding 을 직지정하면
fallback chain 이 끊긴다 (RFC-0058 §4 R6). 의도일 때만, 주석으로 이유를 명시.

---

## 2. 19 개 logical_use — 의미와 lane 분류

각 route 는 `Cascade_routes.<Constructor>` 로 코드에서 호출되고
`[routes.<key>] target = "..."` 가 어디로 보낼지 정한다. 누락 시 catalog 의
첫 entry 로 silent fallback 한다 (RFC-0038 §2.1 사고의 직접 원인).

### 2.1 Fast lane (출력 ≤ 2KB, latency 민감)

응답 시간이 user-visible 한 verdict/scoring 류. 1차 멤버에 작고 빠른 모델.

| route key | 의도 | 호출자 위치 | 출력 |
|---|---|---|---|
| `routing` | 다음 cascade/모델 선택 결정 (L1 proactive routing) | `lib/keeper/keeper_cascade_selector.ml`, `lib/config/env_config_governance.ml:175` | <1KB |
| `llm_rerank` (`Tool_rerank_use`) | 후보 도구/결과 재정렬 점수 | tool rerank engine | 2-4KB |
| `governance_judge` | 정책 판정 (승인/거부) | `lib/server/server_bootstrap_loops.ml:613` fork_subsystem | 2-8KB |
| `operator_judge` | 운영자 개입 의사결정 | `lib/server/server_bootstrap_loops.ml:632` fork_subsystem | 2-8KB |
| `auto_responder` | PR/이슈 자동 ack 분류·라우팅 | `lib/masc_oas_bridge.ml`, `lib/auto_responder.ml` | 2-4KB |
| `phase_buffer` | phase 사이 짧은 컨텍스트 버퍼링 | keeper turn cascade budget | <1KB |
| `phase_recovery` | cascade 실패 직후 로컬 복구 시도 | keeper turn cascade budget | 1-2KB |
| `tool_required` | tool calling capability 강제 turn verdict | `lib/tool_call_quality_benchmark_loader.ml`, `lib/prometheus.mli:926` | <1KB |
| `simple_task` | 분류기가 "simple" 로 라벨한 task | complexity router (`lib/relay.ml`) | 2-4KB |
| `verifier` | 완료/contract 검증 (합격/불합격 + 점수) | `lib/verifier_oas.ml`, `lib/worker_oas.ml` | 2-6KB |
| `openai_compat` | 외부 OpenAI-호환 inbound passthrough | `lib/server/server_openai_compat.ml` | API client SLA |

### 2.2 Deep lane (출력 16KB+, 품질 민감)

긴 codegen/review/research. 30 초 ~ 수 분 용인. 1 차 멤버에 큰 추론 모델.

| route key | 의도 | 호출자 위치 | 출력 |
|---|---|---|---|
| `keeper_turn` | keeper 본 작업 turn (default) | `lib/keeper/keeper_turn_driver.ml`, `lib/governance_registry.ml:547` | 4-200KB |
| `cross_verifier` | anti-rationalization 평가자 (3-pass) | `lib/anti_rationalization.{ml,mli}` (180s timeout) | 4-8KB |
| `autoresearch` | research loop 의 codegen + 최적화 cycle | `lib/autoresearch_codegen.ml:136` | 16-64KB |
| `adversarial_reviewer` | PR/코드 심층 review subagent | `lib/tool_deep_review.ml` (180s timeout) | 8-12KB |
| `persona_generation` | keeper persona 초기화 (boot 1 회) | persona generator | 2-4KB, 품질 우선 |
| `moderate_task` | 중간 복잡도 task | complexity router | 8-12KB |
| `complex_task` | 복잡 task | complexity router | 16-64KB |

### 2.3 Sweep lane (배경 측정)

| route key | 의도 | 호출자 위치 |
|---|---|---|
| `provider_benchmark` | 전체 provider inventory 성능 측정 | `lib/dashboard_provider_runs.ml` |

latency / 품질 어디에도 묶이지 않음. **별도 tier-group + `keeper-assignable = false`**.

### 2.4 분류 결정 흐름

```
새 route 를 어디 보내야 할지 모를 때:
  1. 출력이 1-2KB 로 끝나면        → fast
  2. 사용자/keeper 가 응답 기다리면 → fast 우선
  3. 16KB+ codegen/review 면        → deep
  4. 백그라운드 sweep 이면          → 별도 sweep
  5. 위로 안 잡히면                 → deep (보수적 기본)
```

---

## 3. alias 활용 패턴

alias 는 `[<provider>.<model>.<alias-name>]` 으로 같은 binding 에
**호출 시나리오별 cap 을 덮어쓴다**. 코드 변경 0 줄, 정책만 표현.

### 3.1 흔한 alias 4 종

```toml
# (a) fast-judge cap — short verdict 강제
[gemini.gemini-api-flash.fast_judge]
max-output = 2048
temperature = 0.1

# (b) scoring cap — rerank/score 를 더 좁힘
[claude_code.claude-haiku.for-scoring]
max-output = 1024
temperature = 0.0

# (c) tool-strict cap — tier-group 멤버 ceiling 정렬
#     (cascade ceiling = min(member cap) 이라 한 멤버만 cap 안 두면
#      다른 멤버가 사전 reject 됨)
[claude_code.claude-auto.tool_candidate]
max-output = 16384
temperature = 0.2

# (d) recovery cap — 로컬 fallback 짧게
[ollama.ollama-local-default.recovery]
max-output = 8192
temperature = 0.2
```

### 3.2 alias 가 해결하는 문제

- **ceiling 강제**: tier-group ceiling = min(member cap). 한 멤버가 cap 을
  안 두면 다른 멤버가 사전 reject. alias 로 모든 멤버를 같은 값에 정렬.
- **같은 binding 두 lane 재사용**: `claude_code.claude-auto` 를 deep 은 raw,
  fast 는 `.fast_judge` alias 로. 별도 binding 불필요.
- **운영자 의도 표현**: alias 이름이 binding 의 용도 문서가 된다
  (`.keeper`, `.recovery`, `.tool_candidate`).

### 3.3 alias 명명 규칙

- **시나리오로 명명**: `.fast_judge`, `.tool_candidate`, `.recovery`, `.for-scoring`.
- 모델 특성으로 명명하지 않는다 (`.fast`, `.cheap`). 같은 binding 이
  다른 lane 에서 재사용될 때 의미가 어긋난다.
- alias 가 한 곳에서만 raw 와 동일하게 쓰이면 만들지 않는다. 의미를 표현할
  때만 추가.

### 3.4 spawn provider 의 한계

CLI spawn 형 provider (`protocol = "*-cli"`, e.g. `gemini_cli`, `codex_cli`,
`claude_code`) 는 alias 의 `max-output` 이 운영자 의도 표현일 뿐
**실제 강제력은 CLI 가 그 flag 를 인지하는지에 의존**한다. 추가로 subprocess
fork + JSON parse 사이클이 매 호출마다 ~100-500ms overhead 를 발생시키므로
fast lane 1차로는 부적합한 경우가 많다. fallback 멤버로 두고 1차는 HTTP
direct provider 를 권장.

---

## 4. 권장 토폴로지 (live cascade reference)

운영자 머신에 GLM Coding plan + Claude/Kimi/Gemini CLI + Ollama Cloud + Ollama
로컬이 있다는 가정의 reference. 실제 토폴로지는 비용/quota/속도 선택에 따라 다르다.

**경고**: 멤버 우선순위는 *실측*으로 결정한다. 아래 reference 는 한 운영자
(M3 Max 128GB + Ollama keep-alive 10m + GLM Coding plan + Ollama Cloud + Gemini
CLI OAuth) 의 2026-05-14 측정 결과 기반. 다른 머신/quota 조합에서는 순서가 바뀐다.

```toml
# ── Fast lane: short verdict / scoring / ack ─────────────────
# 실측 latency (prompt = "reply OK only", max-tokens = 2048, 3-run median):
#   ollama-local gemma4:31b-it-q4_K_M  : warm 1.7s / cold 11s (keep-alive=10m)
#   ollama-cloud kimi-k2.6:cloud       : median 6.75s, variance 작음 (5-10s)
#   ollama-cloud deepseek-v4-flash:cloud: median 6.36s, variance 큼 (1-9s)
#   ollama-cloud glm-5.1:cloud         : median 14.66s — fast 부적합, 제외
#   gemini_cli noninteractive          : 9-12s (subprocess spawn + JSON parse)
#
# 1차: ollama 로컬 — M3 Max + Q4 quantization, warm cache 활용.
# 2차: kimi-k2.6:cloud — local daemon down 시 1차 fallback. cloud 중 안정적.
# 3차: deepseek-v4-flash:cloud — kimi-cloud 가용성 문제 시 fallback.
# 4차: gemini_cli — OAuth quota 무료지만 spawn cost 9-12s. 마지막 안전망.
# 모든 멤버는 2KB cap alias 로 ceiling 정렬됨.
# (max-tokens 측정 cap = alias 와 일치 2048. max=10 이면 thinking-support
#  모델의 reasoning chain 에 다 소진돼 content 빈 응답을 줌)
[tier.fast_judge_primary]
members = [
  "ollama.ollama-local-default.fast_judge",
  "ollama_cloud.ollama-cloud-kimi.fast_judge",
  "ollama_cloud.ollama-cloud-deepseek-v4-flash.fast_judge",
  "gemini_cli.gemini-cli-auto.fast_judge",
]
strategy = "failover"
keeper-assignable = false   # system-only; keeper 가 직접 잡지 못하게

[tier-group.fast_judge]
tiers = ["fast_judge_primary", "glm-coding-primary", "local_recovery"]
strategy = "failover"
fallback = true

# ── Deep lane: keeper turn / review / research ───────────────
# 1차 GLM-Coding (비용 최적),
# 2차 strict_tool_candidates (Claude/Kimi 다양화),
# 3차 ollama_cloud, 4차 local.
[tier-group.glm-coding-with-spark]
tiers = ["glm-coding-primary", "strict_tool_candidates",
         "ollama_cloud_primary", "local_recovery"]
strategy = "failover"
fallback = true

# ── Sweep lane: provider benchmark only ──────────────────────
[tier-group.provider_benchmark]
tiers = ["glm-coding-primary", "strict_tool_candidates",
         "cli_manual", "direct_api_manual",
         "ollama_cloud_primary", "local_recovery"]
strategy = "failover"
fallback = true
```

routes 는 §2 분류대로 매핑. 19 개 모두 명시 (누락 = silent fallback).

```toml
# Deep — keeper 본 작업 / 검증 / 생성
[routes.keeper_turn]          target = "tier-group.glm-coding-with-spark"   # keeper 본 turn (default)
[routes.cross_verifier]       target = "tier-group.glm-coding-with-spark"   # anti-rationalization 평가 (3-pass)
[routes.autoresearch]         target = "tier-group.glm-coding-with-spark"   # research codegen + 최적화 cycle
[routes.adversarial_reviewer] target = "tier-group.glm-coding-with-spark"   # PR/코드 심층 review subagent
[routes.persona_generation]   target = "tier-group.glm-coding-with-spark"   # keeper persona 초기화 (boot 1회)
[routes.moderate_task]        target = "tier-group.glm-coding-with-spark"   # complexity router moderate 라벨
[routes.complex_task]         target = "tier-group.glm-coding-with-spark"   # complexity router complex 라벨

# Fast — verdict / score / ack / passthrough
[routes.routing]            target = "tier-group.fast_judge"   # 다음 cascade/모델 선택 결정
[routes.llm_rerank]         target = "tier-group.fast_judge"   # 도구/결과 rerank 점수
[routes.governance_judge]   target = "tier-group.fast_judge"   # 정책 판정 (승인/거부)
[routes.operator_judge]     target = "tier-group.fast_judge"   # 운영자 개입 결정
[routes.auto_responder]     target = "tier-group.fast_judge"   # PR/이슈 ack 분류
[routes.phase_buffer]       target = "tier-group.fast_judge"   # phase 사이 버퍼링
[routes.phase_recovery]     target = "tier-group.fast_judge"   # cascade 실패 후 로컬 복구
[routes.tool_required]      target = "tier-group.fast_judge"   # tool capability 강제 turn verdict
[routes.simple_task]        target = "tier-group.fast_judge"   # complexity router simple 라벨
[routes.verifier]           target = "tier-group.fast_judge"   # completion/contract 검증 점수
[routes.openai_compat]      target = "tier-group.fast_judge"   # OpenAI-호환 inbound passthrough

# Sweep — 배경 측정
[routes.provider_benchmark] target = "tier-group.provider_benchmark"   # 전체 inventory 성능 측정
```

---

## 5. 흔한 실수

| 패턴 | 증상 | 처방 |
|---|---|---|
| `[routes.X]` 누락 | catalog 첫 entry 로 silent fallback. RFC-0038 §2.1 사고 (254/2620 turns, 9.69%) 직접 원인. | 19 개 모두 명시. `Cascade_routes.all_logical_uses` 와 1:1 점검. |
| `target = "tier.X"` (group 아님) | fallback chain 끊김. 1차 tier 다운 시 즉시 실패. | 의도일 때 주석 명시. 아니면 `tier-group.X`. |
| 멤버 `max-output` 불일치 | ceiling = min, 큰 멤버 사전 reject. | alias 로 모든 멤버 같은 cap 정렬 (§3.1 c). |
| alias 이름을 모델 특성으로 명명 | 같은 binding 이 다른 lane 재사용될 때 의미 충돌. | 시나리오 명명 (`.fast_judge`, `.tool_candidate`). |
| sweep 을 production fallback 에 끼움 | benchmark 가 본 작업 자원 점유. | 별도 `tier-group.provider_benchmark`. |
| system-only tier 에 `keeper-assignable` 누락 | keeper 가 자기 cascade 를 fast_judge 로 잘못 설정. | system-only 는 `keeper-assignable = false`. |
| RFC 번호 동시 claim 충돌 | 작업자 split 시 같은 번호 두 PR (#14396 vs #14394 선례). | 새 RFC 직전 `git fetch origin main && ls docs/rfc/`. |
| endpoint quota / auth 미검증 멤버 등록 | fast_judge_primary 1차가 production 호출 시 "Insufficient balance" / 401 로 매번 fail → 2차로 silent fallback. RFC-0038 substitution 사고와 동형. | alias 추가 전 `curl <endpoint>/chat/completions` probe 의무 (§6.7 참조). |
| Direct API 와 Cloud variant 의 quota 를 같은 quota 로 가정 | z.ai general direct (`glm-5.1`) 가 quota 0 라도 Ollama Cloud variant (`glm-5.1:cloud`) 는 별도 quota 로 살아있을 수 있고 그 반대도 가능. 한쪽 측정만으로 멤버 등록/제외하면 다른 쪽의 가용 자원을 놓치거나 죽은 멤버를 등록한다. | provider boundary 별로 probe — `https://api.z.ai/...` (direct) 와 `https://ollama.com/v1/...` 에 `<model>:cloud` 가 별도. cascade.toml 의 `models.X.api-name` 이 `:cloud` suffix 인지 확인. |
| thinking-support 모델에 짧은 `max-tokens` 으로 측정 | max-tokens=10 이면 reasoning chain 에 모두 소진되어 `choices[0].message.content = ""` 빈 응답. "모델 죽음"으로 오진할 수 있음. | latency / 동작 측정 시 max-tokens 을 alias 의 cap (보통 2048) 과 일치시켜 `finish_reason="stop"` + `content` 존재 확인. |
| "flash" 명칭 모델을 fast lane 1차로 가정 | thinking-support=true 모델은 verdict 호출에도 reasoning chain 돌아 7s+. | `models.X.thinking-support` 확인. fast lane 멤버는 thinking 꺼진 모델 또는 `reasoning_effort:"none"` 강제 가능한 endpoint 만. |
| CLI spawn provider 를 fast lane 1차로 | subprocess fork + JSON parse 사이클이 매 호출 9-12s. fast lane SLA 위반. | HTTP-direct provider 우선, CLI 는 fallback. (§3.4) |

---

## 6. 편집 체크리스트

cascade.toml 편집 후 push 전:

1. **19 개 route 모두 명시됐는가** — `Cascade_routes.all_logical_uses` 와 1:1.
2. **각 route 가 `tier-group.X` 를 가리키는가** — 단일 tier 직지정이면 주석에 이유.
3. **tier-group 멤버 alias 가 max-output 정렬됐는가** — group ceiling = min.
4. **fast lane tier 에 200K-context 모델이 끼지 않았는가** — Claude Sonnet / Kimi 200K 는 fast 가 아니다.
5. **`keeper-assignable` 명시했는가** — system-only 는 false, 기본은 true.
6. **provider credentials env 변수가 실제로 export 됐는가** — `echo $ZAI_API_KEY` 같은 식.
7. **새 멤버 추가 시 endpoint probe** — env var 가 있어도 quota / auth 가
   살아 있는지 확인. 예:
   ```bash
   curl -sS -m 10 -H "Authorization: Bearer $ZAI_API_KEY" \
        -H "Content-Type: application/json" \
        -X POST https://api.z.ai/api/paas/v4/chat/completions \
        -d '{"model":"glm-5.1","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
   ```
   응답이 `"Insufficient balance"` / `"Invalid Authentication"` 이면
   `tier.fast_judge_primary` 같은 hot path 멤버에 넣지 않는다.
   evidence record 형태로 cascade.toml 주석에 측정 시각 + 응답 요약 남길 것.
8. **latency 실측** — fast/deep lane 멤버는 hot prompt 로 3-run 측정해
   median 으로 우선순위 결정. "flash" 명칭 / "fast" 가정 금지 — 측정값만 신뢰.
9. **검증**:
   ```bash
   scripts/dune-local.sh build test/test_cascade_config_validity.exe
   scripts/dune-local.sh build test/test_cascade_declarative_parser.exe
   ```
10. **새 logical_use 를 추가했다면**: `lib/cascade/cascade_routes.ml` 의
   - `logical_use` variant (closed sum — 컴파일러 강제)
   - `spec_for_use` exhaustive match (컴파일러 강제)
   - `all_logical_uses` list (manual append, 컴파일러 강제 안 됨)

   세 곳 모두 추가. 마지막은 빠지기 쉬우니 PR 셀프리뷰에서 명시 확인.

---

## 7. 참고

- `lib/cascade/cascade_routes.{ml,mli}` — logical_use SSOT
- `lib/cascade/cascade_toml_materializer.ml` — TOML → in-memory cascade
- `lib/cascade/cascade_declarative_hotpath.ml` — runtime dispatch
- `config/cascade.toml` — repo seed (small)
- `$MASC_BASE_PATH/.masc/config/cascade.toml` — live (개인/머신별)
- 사고 사례: [`RFC-0038`](./rfc/RFC-0038-cascade-routing-intent-preservation.md) §2.1 — 254 turn substitution audit
