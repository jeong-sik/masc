# RFC-0252 — Fusion: 패널+심판(panel+judge) 심의 루프 (MASC 내장)

- Status: Draft
- Author: Vincent (yousleepwhen) + Claude
- Created: 2026-06-16
- Scope: `lib/fusion/` (신규), `lib/runtime/` (config 확장), `.masc/config/runtime.toml` (`[fusion]` 테이블)
- Boundary: OAS(`~/me/workspace/yousleepwhen/oas`)는 **0줄 변경**. 본 루프는 OAS의 범용 프리미티브만 소비한다.
- 참조: OpenRouter Fusion API — [plugin](https://openrouter.ai/docs/guides/features/plugins/fusion), [router](https://openrouter.ai/docs/guides/routing/routers/fusion-router)

---

## 1. 동기 (Motivation)

단일 모델 한 번의 답은 종종 사각지대를 가진다. OpenRouter Fusion은 같은 프롬프트를 **패널 N개 모델**에 병렬로 던지고, **심판(judge) 모델 1개**가 그 답들을 `consensus / contradictions / partial_coverage / unique_insights / blind_spots`로 구조화해 종합한다. 실측은 +3.7pp(65.3%→69.0%)를 **비용 ~4×·지연 ~7×**에 샀다.

MASC는 이미 멀티 fiber로 N개 키퍼를 상시 병렬 구동한다. 같은 메커니즘을 "같은 질문을 여러 모델에 부채질→심판 종합"이라는 **수렴형(fan-out→join) 심의**로 쓰면, 키퍼가 고위험 결정 앞에서 단일 모델의 편향을 교차검증할 수 있다.

### 1.1 비판 — ROI가 fusion을 "선택적"으로 강제한다

+3.7pp를 4× 비용·7× 지연에 사는 거래는 **모든 턴에 쓰면 손해**다. 키퍼는 턴을 연속으로 도는데 한 턴을 7× 지연으로 막으면 그 키퍼가 멈춘다. 따라서 본 설계의 두 축은:

1. **선택적 발동** — 결정론적 게이트가 "이 턴은 심의 가치가 있다"를 판정할 때만(§6).
2. **루프 비차단** — 키퍼 턴을 동기 치환하지 않고 **out-of-band 심의 잡**으로 분리, 결과는 비동기로 키퍼 chat lane + board에 도착(§4, §8).

이 두 축이 없으면 fusion은 신앙으로 토큰 4배를 태우는 안티패턴이다. 그래서 **측정 하네스(§11)가 Phase 0, 비협상**이다.

---

## 2. Non-goals / 경계

- **OAS 변경 금지.** OAS는 single-provider completion + 범용 fan-out(`Async_agent.all`) + 구조화 출력(`Structured.extract`)만 제공한다. 멀티모델 오케스트레이션·심판 프롬프트·게이트·가시성은 전부 MASC.
- **죽은 합의 코드에 의존 금지.** MAGI 삼두정치·walph·cascade·board curation은 작동/사용된 적 없음(사용자 확인). 본 루프는 그 위에 쌓지 않고 새로 만든다. (죽은 3종의 *삭제*는 본 RFC 범위 밖, 별도 정리.)
- **v1은 advisory만.** 패널/심판은 분석·종합을 산출하는 read-only. tool-call을 패널이 제안하고 심판이 골라 *실행*하는 action 모드는 side-effect atomicity가 필요 → v2(§14).
- **재귀 금지.** 패널·심판은 fusion을 다시 못 부른다(§10). OpenRouter의 `x-openrouter-fusion-depth`에 대응하는 타입드 depth guard.

---

## 3. 참조에서 가져오는 것 / 바꾸는 것

| 항목 | OpenRouter Fusion | MASC 구현 |
|---|---|---|
| 패널 | 1–8 모델 병렬, 각자 web 도구 | 비어 있지 않은 typed 모델 집합 전체를 `Async_agent.all`로 실행, web 도구는 MASC가 주입 |
| 심판 구조화 | JSON `{consensus, contradictions, partial_coverage, unique_insights, blind_spots}` | 동일 5필드 + `resolved_answer` + `decision`, **`Structured.extract` provider-native JSON schema 강제**(닫힌 타입, substring 파싱 아님) |
| 발동 | 모델이 `openrouter:fusion` 자가 호출(비결정) | **결정론적 게이트 우선**(§6), 모델 요청은 budget cap에 종속 |
| 재귀 | depth 헤더로 1단계 차단 | 타입드 `Fusion_depth.t` (`Top`/`Nested`, descend가 2단계 거부) |
| 비용 | 추상화(개별 완성 합산) | MASC가 패널 N + 심판 1 토큰/비용 명시 회계(§10) |
| 가시성 | (없음) | **사용자 요구**: 키퍼 chat lane + 대시보드 board에 패널/심판 메시지 증명·표시(§8) |

---

## 4. 아키텍처 — out-of-band 심의 잡

```
키퍼 턴 ──▶ masc_fusion(request) ──▶ (키퍼는 즉시 계속 진행)
                  │
       Fusion_orchestrator (별도 Eio.Switch / fiber, root_sw 하위)
                  │
        ┌─────────┴───────── gate: Fusion_policy.decide ──▶ Allow req | Deny reason
        │ (Deny면 사유를 chat lane에 1줄로 남기고 종료)
        ▼
   Fusion_panel.run ── Async_agent.all ── (model×N, 각자 web 도구)
        │   → (name × api_response result) list → panel_outcome list (실패 격리)
        ▼
   Fusion_judge.run ── Structured.extract(judge_synthesis schema, provider=judge model)
        │   → judge_synthesis { consensus; contradictions; ...; resolved_answer; decision }
        ▼
   Fusion_sink.emit ── ① 패널 답 N개 + 심판 종합을 keeper chat lane에 authored 메시지로 append
                       ② board post(meta_json = fusion_deliberation 구조) 1건
                       ③ 둘 다 SSE로 대시보드 실시간 반영 (correlation: fusion_run_id)
                  │
          키퍼가 다음 턴에 observation으로 resolved_answer 수령
```

키퍼 턴 루프는 단일 모델로 유지(응답성) — fusion은 그 옆에서 도는 가시적 미니 라운드테이블.

---

## 5. 타입드 계약 (`lib/fusion/fusion_types.mli`)

모든 분기는 **catch-all 없는 닫힌 합**. 새 변형 추가 시 컴파일러가 누락 사이트를 강제로 드러낸다(CLAUDE.md §FSM Sparse Match 회피).

```ocaml
(* 재귀 가드: int 비교 ad-hoc가 아니라 닫힌 합 *)
module Fusion_depth : sig
  type t = Top | Nested
  val descend : t -> t option   (* Top -> Some Nested ; Nested -> None (2단계 거부) *)
end

(* 패널 한 명의 결과 — 실패도 닫힌 합, silent default 없음 *)
type panel_failure =
  | Timeout
  | Provider_error of string
  | Empty_response of string
  | Budget_exhausted

type panel_outcome =
  | Answered of { model : string; answer : string; confidence : float option; usage : Usage.t }
  | Failed   of { model : string; reason : panel_failure }

(* 심판 구조화 출력 — Structured.extract로 provider-native JSON schema 강제 *)
type claim          = { text : string; supporting_models : string list }
type contradiction  = { topic : string; positions : (string * string) list (* model × stance *); evidence : string list }
type coverage_gap   = { topic : string; addressed_by : string list; missing : string }
type insight        = { text : string; model : string }

type judge_decision =
  | Answer        of string                       (* resolved 텍스트 답 *)
  | Recommend     of { action : string; rationale : string }  (* 키퍼가 평소대로 수행할 권고 (advisory) *)
  | Insufficient  of { missing : string list }    (* 패널이 부족 → 심의 무효 *)

type judge_synthesis =
  { consensus        : claim list
  ; contradictions   : contradiction list
  ; partial_coverage : coverage_gap list
  ; unique_insights  : insight list
  ; blind_spots      : string list
  ; resolved_answer  : string
  ; decision         : judge_decision
  }

(* 게이트 입력 — 발동 이유 라벨, catch-all 없음. 게이트는 종류로 적격성을 판정하지
   않는다(심의 가치는 키퍼=LLM 판단). score/task_kind 매칭 페이로드를 두지 않는다. *)
type fusion_trigger =
  | Explicit_tool_call                              (* 키퍼가 masc_fusion을 직접 호출 *)
  | Low_confidence                                  (* 키퍼가 자기 확신이 낮다고 판단해 요청 *)
  | High_stakes     of string                       (* 키퍼가 high-stakes로 판단한 task 설명 *)
  | Contested_board of { post_id : string }
  | Operator_requested
  | Harness_eval                                    (* eval 하네스가 결정론적으로 구동 *)

type fusion_request =
  { run_id    : string                              (* correlation: fusion_run_id *)
  ; keeper    : string                              (* 결과를 받을 키퍼 chat lane *)
  ; prompt    : string
  ; preset    : string                              (* runtime.toml [fusion.presets.*] 이름 *)
  ; depth     : Fusion_depth.t
  ; trigger   : fusion_trigger
  }

(* 게이트 출력 *)
type deny_reason =
  | Disabled | Preset_unknown of string | Depth_exceeded
  | Over_hourly_budget

type gate_decision = Allow of fusion_request | Deny of deny_reason
```

> 비용 *제약*(cost cap / per-call USD 상한)은 v1에서 제외한다 — 모델별 가격
> 추정기가 없으면 inert한 결정론 게이트가 되기 때문(괴상한 제약 제거 원칙).
> 비용은 *관측*만 한다: panel 응답의 `usage`(실측 토큰)를 sink가 합산·표시한다.
> 발동 통제는 `per_hour_budget`(실측 카운터)가 담당한다.

> `Usage.t`는 기존 MASC usage 타입 재사용(없으면 `{ input_tokens:int; output_tokens:int }` 최소 정의).

---

## 6. 게이트 (`fusion_policy`) — 구조는 결정론, 판단은 LLM

게이트는 **구조/자원 안전**만 결정론적으로 본다. "이 턴이 심의할 가치가 있나"라는 *판단*은 게이트가 score 임계값(`score < low_confidence_threshold`)이나 task_kind 문자열 매칭(`task_kind ∈ high_stakes_task_kinds`)으로 대신 내리지 않는다 — 그건 memory-os 점수머신과 같은 안티패턴(가치 미입증 수치 판정)이다. 심의 가치는 키퍼(이미 LLM)가 스스로 판단해 `masc_fusion`을 호출하는 것으로 표현되고, 발동 남용은 결정론적 `per_hour_budget` cap이 막는다. **판단=LLM, 억제=구조적 cap.**

```ocaml
val decide
  :  policy:Fusion_policy.t          (* runtime.toml [fusion] + [fusion.gate]에서 로드 *)
  -> fusion_request
  -> gate_decision
```

판정 규칙(순수 함수, side-effect 없음 — 구조/자원만):

1. `policy.enabled = false` → `Deny Disabled`.
2. `preset`이 `policy.presets`에 없음/크기 위반 → `Deny (Preset_unknown name)`. (fail-fast, silent default 금지)
3. `depth = Nested` → `Deny Depth_exceeded`.
4. 그 외 → `Allow request`.

`trigger`는 "왜 발동했나"의 이유 라벨일 뿐 적격성 판정에 쓰이지 않는다 (board meta·로그용). `per_hour_budget` 초과는 호출자가 `Fusion_budget.try_incr_if_under`로 원자적으로 강제해 `Deny Over_hourly_budget`을 낸다 (TOCTOU 회피, §10).

키퍼가 `masc_fusion`을 호출하는 것 자체가 "심의가 필요하다"는 LLM 판단이다. 게이트는 그 판단을 score로 재판정하지 않고 구조적 안전과 시간당 cap만 강제한다. (MEMORY: 키퍼 wake-cascade thrash는 score 게이트가 아니라 `per_hour_budget` cap으로 막는다.)

---

## 7. 패널 + 심판 (OAS 프리미티브 소비)

### 7.1 패널 — `Async_agent.all`

`oas/lib/async_agent.mli:78`:
```ocaml
val all : sw:Eio.Switch.t -> ?clock:_ -> ?max_fibers:int
       -> (Agent.t * string) list
       -> (string * (Types.api_response, Error.sdk_error) Result.t) list
```
- per-agent 에러 격리(한 패널 실패가 나머지 안 죽임), 부모 switch 취소 전파.
- `Fusion_panel.run`: preset의 모델 목록 → 각 모델별 `Agent.t` 생성(provider config + web 도구 주입) → 입력된 전체 모델을 `Async_agent.all`로 실행 → 결과를 `panel_outcome list`로 매핑. 각 호출은 `Masc_oas_bridge.run_safe ~caller:"fusion_panel" ~timeout_s`로 감싼다.

### 7.2 심판 — `Structured.extract`

`oas/lib/structured.mli:38` (provider-native JSON schema 강제, 미지원 provider fail-fast):
```ocaml
val extract : sw:_ -> net:_ -> ?provider:Provider.config -> config:agent_config
           -> schema:'a schema -> string -> ('a, Error.sdk_error) result
```
- `Judge.judge`(score/risk 고정 레코드)는 **쓰지 않는다** — 5필드 종합엔 빈약.
- `Fusion_judge.run`: `judge_synthesis schema`(= `{name; description; params; parse}`)를 정의하고, 패널 답들을 임베드한 judge 프롬프트로 `Structured.extract` 1회 호출. `parse`는 Yojson→`judge_synthesis`. `caller:"fusion_judge"`.

> `schema.parse`가 닫힌 타입으로 강제하므로 "문자열 분류기"(CLAUDE.md 워크어라운드 시그니처 #2)에 해당하지 않는다. surface-string 리스트가 없다.

---

## 8. 가시성 (`fusion_sink`) — 사용자 1순위 요구

"대시보드 + 키퍼 개별 채팅에서 panel/judge 메시지가 증명·표시." v1은 **코어 스키마 변경 없이** 달성:

### 8.1 키퍼 chat lane (결론만) — "결과를 키퍼 흐름에 녹이기"

judge 결론만 키퍼 **메인** conversation에 남긴다. 패널 트랜스크립트는 board(§8.2)로 옮긴다 — 이유: `Keeper_chat_store.load`는 conversation을 필터하지 않으므로, 긴 패널 답변을 chat lane에 쌓으면 키퍼 `recent_direct_conversation` observation의 최근 N개를 도배한다(관측 오염).

- chat lane: `Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name ~content ()` (conversation_id **생략** = 메인 lane) → `chat_appended` → SSE → 대시보드. `content = "Fusion deliberation (run <id>) — <decision>\n\n<resolved_answer>"`. judge 실패면 생략(메인 흐름 비오염; board에는 실패 증거를 남긴다).
- **키퍼 통합**: 메인 chat 결론을 키퍼가 다음 턴 observation으로 수령하고, librarian이 그것을 memory-os fact로 추출한다. fusion이 memory-os `fact` 타입(재설계 중)에 직접 의존하지 않으므로 강결합 없이 기존 memory 파이프라인에 흡수된다.
- 상세(패널 답변 N개 + 심판 종합)는 board meta_json(§8.2)에서 본다.

### 8.2 board post (구조화 증거)

`masc_board_post` / `Board_dispatch.create_post`, `meta_json : Yojson.Safe.t option`(board_types.mli:99)에:
```json
{ "fusion_deliberation": {
    "run_id": "...", "preset": "...", "trigger": "...",
    "panel": [ { "model": "...", "answer": "...", "confidence": 0.0, "usage": {...} } ],
    "judge": { "model": "...", "consensus": [...], "contradictions": [...],
               "blind_spots": [...], "resolved_answer": "...", "decision": {...} },
    "cost_usd": 0.0, "latency_ms": 0 } }
```
- 기존 직렬화(board_core_json.ml:37-39)가 `meta_json`을 그대로 통과 → 대시보드 BoardPost.meta로 도달.
- 대시보드 meta 렌더 전용 UI는 현재 없음(gap) → v1은 raw로 도달, PostDetail meta 뷰어는 후속(§14).

### 8.3 증명(correlation)

`run_id`가 패널 N + 심판 메시지 + board post를 하나의 심의로 묶는다. 대시보드는 timestamp가 아니라 `run_id`/`conversation_id`로 응집성 보장.

---

## 9. Config (`.masc/config/runtime.toml` `[fusion]`) — SSOT, fail-fast, 기본 OFF

```toml
[fusion]
enabled = false                       # opt-in. 기본 OFF (fail-safe)
default_preset = "budget"

[fusion.gate]
low_confidence_threshold = 0.55
high_stakes_task_kinds = ["goal_decision", "architecture"]
per_hour_budget = 20                  # 시간당 발동 상한 (유일한 비-disabled deny 노브)

[fusion.presets.budget]
panel = ["deepseek.v4-flash", "glm.5-turbo", "ollama.gemma4-26b"]
judge = "deepseek.v4-flash"
panel_system_prompt = "..."           # 행동 정의 — 코드 default 없음, 비면 Missing_prompt
judge_system_prompt = "..."
panel_timeout_s = 120.0               # 생략 시 default_timeout_s
judge_timeout_s = 120.0
max_output_tokens_per_panel = 4096    # 생략 시 Runtime_agent 기본 출력 예산
judge_max_output_tokens = 4096        # 생략 시 Runtime_agent 기본 출력 예산
```

- panel/judge 모델 식별자는 기존 `provider.model` opaque 문자열(runtime.toml bindings와 동일 컨벤션). 미존재 모델 → parse/resolve 에러(fail-fast).
- 패널 모델 집합은 비어 있지 않아야 한다. 알 수 없는 preset/모델은 silent default로 압축하지 않는다(CLAUDE.md §Unknown→Permissive 회피).
- `max_output_tokens_per_panel`, `judge_max_output_tokens`, `[[...judges]].max_output_tokens`는 optional positive int다. 생략하면 기존 Runtime_agent 기본값을 보존하고, 0 이하 값은 config load에서 fail-fast한다.
- `Runtime_toml` 파서 확장(또는 별도 `Fusion_config` 파서)로 `[fusion.*]` 로드 → `Fusion_policy.t`.

---

## 10. 재귀 가드 · 발동 예산 · 비용 관측

- **재귀**: 패널/심판 `Agent.t`는 fusion 도구를 주입받지 않는다(도구 목록에서 배제). 추가로 `request.depth = Nested`면 게이트가 `Deny Depth_exceeded`. 이중 차단.
- **발동 예산**: `per_hour_budget`(UTC hour bucket 카운터, `Fusion_budget` CAS)가 시간당 발동 수를 제한. 유일한 비-disabled deny 노브.
- **비용 관측(제약 아님)**: 패널 응답의 `usage`(실측 input/output 토큰)를 sink가 합산해 심의 메시지에 표시한다. v1은 비용을 *제약*하지 않는다 — 모델별 가격 추정기가 없으면 cost cap은 inert 게이트(괴상한 제약)가 되기 때문. 가격 추정기 도입 시 별도 RFC로 cost cap을 다시 추가한다.

---

## 11. 하네스 (Phase 0, 비협상) — "4× 비용이 정말 좋아지나"

CLAUDE.md §Harness First: 측정 없이 AI 에이전트 코드 진행 금지. fusion의 전 존재 이유가 "cost-matched 대안보다 낫다"이므로 이를 **재현 가능하게 측정·판정**하는 게 최우선. 측정(출력·토큰 비용)은 결정론, 우열 판정은 판단이다 — 정답을 string-match로 채점해 정답률 delta를 자동 게이트로 쓰는 건 표현 변이를 못 잡고 심의를 단답 정답률로 환원하는 어거지다.

`test/fusion/fusion_harness.ml`:

| 구성 | 내용 |
|---|---|
| 입력 | 고정 eval 셋: `question` N개 (+ 선택적 참고 컨텍스트) (`test/fusion/cases/*.json`). 재현성을 위해 질문만 고정하고, string-match 채점용 정답은 두지 않는다(우열은 판단). |
| 비교군 | 같은 질문 · **같은 토큰 예산**에서 4-way: (A) single 1×, (B) self-consistency(같은 모델 N회 샘플 + 다수결) ~N×, (C) Self-MoA(최강 모델 1개를 N회 샘플 → judge 종합) ~N×, (D) fusion(다른 모델 panel → judge) ~N× |
| 산출 | 각 전략의 **출력 전문** + **토큰 비용 실측**(panel + judge 합산) + (self-consistency) **다수결 집계**. 자동 정답률·delta 수치는 내지 않는다 — 정답을 string-match로 채점하는 건 표현 변이("42" vs "The answer is 42")를 못 잡고 심의 가치를 단답 정답률로 환원하는 어거지다. 채점·우열은 판단 몫. |
| 게이트 | fusion이 **cost-matched 대안(B/C)보다 나은가를 판단**한다 — 리뷰어(사람), 또는 별도 evaluator judge(후속). 비용이 실제로 비슷한지는 토큰 실측으로 확인. single(A) 대비 우위는 "더 많은 컴퓨트"로 자명해 정당화 근거가 못 된다. fusion의 고유 기여(모델 다양성 + judge 종합)가 같은 비용의 self-consistency/Self-MoA보다 나아야 4×를 정당화한다. |

이 하네스가 **fusion 머지의 정당화 근거**다. 판단 결과 fusion이 cost-matched 대안보다 낫지 않으면 preset 구성 또는 트리거를 재설계한다(코드를 머지하지 않는다). "낫다"는 자동 수치가 아니라 출력·비용을 본 판단이다.

> **왜 비교군이 single이 아니라 cost-matched 4-way인가** — MAD 연구(Smit et al., "Should we be going MAD?", ICML 2024)는 multi-agent debate가 self-consistency를 안정적으로 이기지 못한다고 보고했고, Self-MoA(arXiv:2502.00674, 2025)는 "모델 다양성" 가정을 반박하며 *최강 모델 단일을 N회 샘플*하는 쪽이 이종 모델 혼합보다 나을 수 있다고 했다. fusion의 전제(이종 panel + judge)는 이 두 결과에 직접 노출된다. 따라서 하네스는 single 대비가 아니라 **같은 비용을 다르게 쓴 대안 대비**로 fusion의 존재 가치를 측정해야 한다. (인용 수치는 각 논문 abstract 기준 — 자체 eval 셋 재현으로 검증.)

추가: TLA+ 모델(선택) — 패널 실패 격리 불변식, depth guard("Nested는 절대 패널을 못 띄움")를 `Fusion_depth` action + invariant로 검증(CLAUDE.md §TLA+ Bug Model).

---

## 12. 모듈 배치 · 빌드 · 테스트

```
lib/fusion/                          # 단일 masc 라이브러리에 자동 포함 (include_subdirs)
  fusion_types.ml(i)                 # §5 닫힌 합 (외부 의존 최소, 독립 컴파일)
  fusion_config.ml(i)                # [fusion.*] 파싱 -> Fusion_policy.t (fail-fast)
  fusion_policy.ml(i)                # §6 결정론 게이트 (순수)
  fusion_panel.ml(i)                 # §7.1 Async_agent.all fan-out
  fusion_judge.ml(i)                 # §7.2 Structured.extract 종합
  fusion_sink.ml(i)                  # §8 chat lane + board 가시성
  fusion_orchestrator.ml(i)          # §4 gate->panel->judge->sink 루프 (Eio.Switch)
  fusion_tool.ml(i)                  # masc_fusion 키퍼 도구 (dispatch table 등록)
test/fusion/
  fusion_harness.ml                  # §11 전략별 출력+비용 수집 (판정 입력, 필수)
  test_fusion_policy.ml              # 게이트 전 분기 + deny 사유 (alcotest)
  test_fusion_depth.ml               # descend Top->Nested->None (qcheck)
  test_fusion_judge_schema.ml        # judge_synthesis parse round-trip + 악성 입력
  test_fusion_panel_failure.ml       # panel_outcome 실패 격리 (mock provider)
```

- 모듈명 `fusion_*` 전역 유일(단일 라이브러리 flat namespace).
- 빌드: `DUNE_CACHE=disabled dune build --root .`(MEMORY: cross-lib `.mli` stale `.cmx` 회피). `@check` 단독 종료 금지.
- 테스트: alcotest + qcheck. `make test` 또는 focused.
- 파일 300줄 초과 시 분할.

---

## 13. 단계별 롤아웃 (flag OFF 기본)

| Phase | 산출물 | 완료 기준 |
|---|---|---|
| **0** | `fusion_types` + `fusion_harness` + mock provider | 하네스가 전략별 출력+토큰 비용을 나란히 산출(실제 모델 1셋), 판정 입력 제공 |
| **1** | `fusion_config` + `fusion_policy` + 단위 테스트 | 게이트 전 분기 green, unknown preset fail-fast |
| **2** | `fusion_panel` + `fusion_judge` | 실모델 패널 3 + 심판 1 round-trip, judge_synthesis 닫힌 타입 파싱 |
| **3** | `fusion_sink` + `fusion_orchestrator` + `fusion_tool` | chat lane + board에 심의 가시(대시보드 확인), out-of-band 비차단 |
| **4** | 실 keeper 통합(게이트 wire) + `enabled` 토글 | `enabled=true` 카나리 1 키퍼, 판단상 fusion 우위 확인 후 |

각 Phase는 독립 Draft PR. `enabled=false` 기본이라 main에 들어가도 다크.

---

## 14. 리스크 · 오픈 퀘스천

1. **ROI 미검증**: 자체 eval 셋에서 fusion 우위가 불명확할 수 있음 → Phase 0 하네스가 출력·비용을 제시하고 판단으로 게이트. 우위 없으면 머지 안 함.
2. **지연/비용**: 7× 지연. out-of-band가 키퍼 루프는 보호하나 board 결과 도착이 느림 → 고위험 결정에만.
3. **대시보드 meta 뷰어 부재**: v1은 meta_json raw 도달. PostDetail 뷰어는 후속.
4. **chat lane author 필드**: v1 content-prefix. 구조화 author는 코어 스키마 변경(코덱 마이그레이션 필요) → v2.
5. **action fusion(v2)**: 패널이 tool-call 제안 → 심판 선택·실행. tool-call consensus + side-effect atomicity 필요. 별도 RFC.
6. **provider 동시성**: Fusion은 입력된 패널 전체를 실행한다. 실제 전송 용량과 backpressure는 provider/runtime 경계가 관리한다.
7. **`run_with_caller` vs `run_safe`**: v1은 string caller `run_safe`. 타입드 `Env_config_oas_bridge.caller` 변형 추가는 후속(해당 모듈 침습).

---

## 15. CLAUDE.md 준수 self-audit (워크어라운드 시그니처)

| 체크 | 결과 |
|---|---|
| 텔레메트리-as-fix | N/A — 가시성은 fusion의 *기능*(사용자 요구)이지 silent failure 은폐가 아님 |
| string/substring 분류기 | **회피** — judge는 `Structured.extract` 닫힌 타입, surface-string 리스트 없음 |
| N-of-M 패치 | N/A — 신규 서브시스템, 단일 abstraction |
| catch-all `_ ->` 추가 | **회피** — 모든 분기 닫힌 합(trigger/decision/failure/deny) |
| cap/cooldown/dedup/repair | 실행 예산과 고정 동시성 정책은 Fusion 기능 게이트가 아니다. 전송 backpressure는 provider/runtime 경계의 책임이다. |
| test backdoor | mock provider는 test 디렉토리 한정, prod 경로 비노출 |
| Unknown→Permissive | **회피** — unknown preset/model = fail-fast 에러, silent default 없음 |

RFC 게이트(CLAUDE.md agent_delegation): 본 변경은 credential/identity/operator/sandbox/hooks/workflow subsystem 비해당. 그래도 코어 키퍼 루프 인접이라 본 RFC를 선행 산출물로 둔다.
