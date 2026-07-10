# RFC-0321: hard_forbidden 거부 위장(is_error=false) — agent_sdk `Block` variant

| | |
|---|---|
| 상태 | Draft (설계만. 구현은 별도 PR) |
| 관련 이슈 | masc #23542 (hard_forbidden = Hooks.Override → is_error=false 위장) |
| 영역 | agent_sdk(oas repo, 외부 opam package) + masc keeper_guards |
| agent_sdk pin | `0.208.20` @ `git+https://github.com/jeong-sik/oas.git#abfffbd88d8810519bee9415c54d55f3e186493d` |
| 검증 기준 switch | `~/.opam/5.4.1` (real pin). **5.4.0 install은 stale(6 variants)이므로 분석에 사용 금지** |

## 1. Problem — 거부가 정상 ToolResult로 위장된다

masc keeper governance guard가 파괴적/금지 도구를 거부할 때 `Agent_sdk.Hooks.Override of string`을 반환한다. agent_sdk의 `agent_tools.ml` PreToolUse top-level match에서 Override는 `(id, value, false)` — `is_error=false` — 로 변환된다. 거부가 정상 도구 결과로 LLM에게 전달된다.

검증된 6곳의 Override 사용처 (`lib/keeper/keeper_guards.ml`, 직접 읽음):

| Line | guard | reason_code | 의미 |
|---|---|---|---|
| 636 | `pre_tool_use_guard` | `pre_tool_use_guard` | user custom guard, soft nudge |
| 692 | streak gate | `streak_gate` | "다른 도구 사용" retry nudge |
| 755 | readonly dedup | `readonly_observation_duplicate` | soft dedup nudge |
| 831 | `keeper_deny` | `keeper_deny` | static deny list, **unconditional** |
| 902 | destructive guard | `destructive_guard` | destructive pattern, **unconditional** |
| 958 | `governance_approval_guard` | `hard_forbidden` | HITL 무관 **무조건 차단** |

이 중 3곳(831/902/958)은 의미상 unconditional hard block이지만 soft nudge 3곳(636/692/755)과 동일하게 `is_error=false`로 위장된다.

### 1.1 관측 가능한 영향 (분석 단계 산출)

- `keeper_librarian.ml:42`은 직접 확인됨 (`is_error`가 episode 기록에 반영되는 지점)
- `keeper_context_core.ml:225,266,300,434`는 분석 산출 기반이며 구현 PR에서 재검증 필요

- `keeper_librarian.ml:42` — `is_error=%b`가 episode 메모리에 영구 기록 → 거부가 success로 학습
- `keeper_tool_dispatch_runtime.ml:251-255` — `classify_tool_result_payload`가 Override payload `[tool_skipped] ...`를 기존엔 `Plain_text` 경로로 다뤄 `inferred_outcome=Success`가 발생하는 것으로 확인
- `[tool_skipped] code=hard_forbidden` 문자열은 keeper system prompt sources 전수 grep 0건으로 LLM에게 설명되지 않음 → LLM이 자유 텍스트 해석에 의존 (RFC-0042급 string 분류기 암시)

## 2. 원칙 — typed policy rejection

거부는 variant로 표현한다. 문자열 content로 LLM이 "거부인지 안내인지" 분류하는 구조를 끊는다 (Parse, Don't Validate). CLAUDE.md MANIFEST: *"OCaml 같은 경우 String 나열보다는 Variant 같은 합타입으로 코드레벨에서 명확한 제어가 가능한데 불구하고 당장의 구현을 위해 포기하지 말고 시간이 걸리더라도 단단하게 만들도록"*.

## 3. 근본 원인 — `hook_decision`에 의도적 policy rejection variant가 없다

검증 (`~/.opam/5.4.1/lib/agent_sdk/base/hooks.ml`, 직접 읽음):

```
line 195: type hook_decision =
line 196:   | Continue
line 197:   | Skip
line 199:   | Override of string  (* PreToolUse only: return this value instead *)
line 200:   | ApprovalRequired
line 202:   | AdjustParams of turn_params
line 204:   | ElicitInput of elicitation_request
line 205:   | Nudge of string
line 207:   | HookFailed of { stage; detail }   (* "Internal failure decision" *)
```

8개 variant 중 **의도적으로 `is_error=true`를 생산하는 variant가 없다**. `HookFailed`(:207)는 is_error=true를 생산하지만 의미가 "인프라 실패"지 "policy 거부"가 아니다.

`Reject of string`은 별개의 `approval_decision` type(`base/hooks.ml:216-218`)에만 존재하며, `ApprovalRequired` 반환 후 approval callback 내부(`agent_tools.ml:773`)에서만 match된다. PreToolUse에서 직접 반환할 수 없다.

제어 흐름 (검증, `agent_tools.ml` 직접 읽음):

```
line 717:  | Hooks.Override value   -> { is_error=false; ... }   ← THE BUG (단락)
line 725:  | Hooks.ApprovalRequired -> (approval callback 진입)
line 749:      | Hooks.Reject_without_callback -> ...
line 773:      | Hooks.Reject reason -> { is_error=true; ... }   ← callback 내부
line 845:  | Hooks.HookFailed { stage; detail } -> { is_error=true; Non_retryable; Deterministic }
```

`keeper_guards.ml:958`의 hard_forbidden 분기는 Override 반환 → `agent_tools.ml:717`에서 `is_error=false`로 단락 → callback에 도달하지 못함.

### 3.1 이미 올바른 경로가 존재한다 (인접 사실)

`lib/governance_pipeline.ml`(직접 읽음)은 approval callback 안에서 이미 `Hooks.Reject`로 `is_error=true`를 생산한다:

```
line 104: let auto_approval_hard_forbidden ~risk meta = ...
line 330: let reject_hard_forbidden ~config ... () =
line 356:   let decision = Agent_sdk.Hooks.Reject reason in
line 379: let to_oas_approval_callback ...
line 406:   let hard_forbidden = auto_approval_hard_forbidden ~risk meta in
line 408:   if hard_forbidden then ... reject_hard_forbidden ...
```

즉 is_error=true를 만드는 코드는 이미 mascot 안에 있다. 문제는 PreToolUse에서 Override가 callback 전에 단락한다는 것.

## 4. 후보 평가

### 후보 A — `hook_decision`에 `Block of string` variant 추가 (채택)

agent_sdk(oas repo)의 `hook_decision`에 PreToolUse 직접 `is_error=true` variant를 추가하고, keeper_guards 3 hard-block 사이트를 전환.

### 후보 B — mascot-only post-processing (기각)

`[tool_skipped]` content를 OAS 경계에서 재구성해 `is_error=true`로 만드는 래퍼. **3가지 치명적 결함**:

1. **거짓 전제**: §3.1에서 이미 approval callback이 `Hooks.Reject` → `is_error=true`를 생산함을 확인. "mascot가 is_error=true를 표현 못한다"는 전제가 거짓. 실제 버그는 `keeper_guards.ml:958`의 Override 단락.
2. **목표 달성 불가**: `agent_tools.ml:717`의 `(id, value, false)` triple이 LLM message list로 직행. mascot는 SDK와 LLM 사이에 코드를 끼울 수 없다. post-turn 재구성(`keeper_context_core.ml` sanitize_checkpoint_message)은 compaction/checkpoint 시에만 trigger → LLM은 이미 `is_error=false`로 학습해 행동한 후.
3. **워크어라운드 거부기준 3종 위반**: 텔레메트리-as-fix 변종(post-turn is_error "정정" = repair), String 분류기(reason_code를 content에서 재추출), N-of-M(6개 사이트 각각 side-table 등록).

### 후보 C — 기존 variant(ApprovalRequired/HookFailed)로 교체 (기각)

1. **stale version 기반 분석**: 후보 C가 "HookFailed 부재"를 단언한 것은 5.4.0 stale install(6 variants) 기준. real pin 0.208.20(8 variants)에는 HookFailed가 존재. 전제가 잘못.
2. **N-of-M (기준 #3 위반, 후보 자인)**: ApprovalRequired로 `is_error=true`를 달성할 수 있는 건 hard_forbidden(958) 1곳뿐. 나머지 5곳은 approval callback이 risk 기반 hard_forbidden 재평가만 하고 streak/deny/destructive/duplicate/custom 판정 로직을 모름 → 의미상 다른 동작.
3. **의미론 모순**: ApprovalRequired는 "operator 승인 필요(HITL)"이지만 hard_forbidden은 "HITL 무관 무조건 차단"이 의도.

### 후보 A' — `HookFailed` 재사용 (Critique 제기, 기각)

비용은 최소(`legal_decisions_for_stage` 1줄)이나 semantic 부정확:

1. telemetry label `hook_failed`(`agent_lifecycle.ml:91`)에 policy block과 infra failure가 혼합 → 운영자 구분 불가
2. `agent_tools.ml:845-856` content format `"Tool execution blocked: hook pre_tool_use failed at <stage>: <detail>"`가 고정 → keeper의 reason_code(`hard_forbidden`/`keeper_deny`/`destructive_guard`)가 detail에 압축 = semantic 손실
3. 향후 진짜 infra failure와 policy block을 분리해야 할 때 `HookFailed` 사용처 전수 재audit = 기술 부채 이전

선택: **`Block` 신규 variant.** telemetry 분리 가치(policy block = keeper 행동 조정, infra failure = 디버깅)가 match site 갱신 비용을 정당화.

## 5. 설계 — `Block of string` variant

### 5.1 제어 흐름

현재 (buggy):
```
keeper_guards.ml:958 hard_forbidden
  → Agent_sdk.Hooks.Override (render_inline_skip_reason_with_source ...)
  → agent_tools.ml:717 | Hooks.Override value -> { is_error=false }
  → LLM이 거부를 정상 결과로 학습
```

목표:
```
keeper_guards.ml:958 hard_forbidden
  → Agent_sdk.Hooks.Block (render_inline_skip_reason_with_source ...)
  → agent_tools.ml:(신규) | Hooks.Block reason -> { is_error=true; Non_retryable; Deterministic }
  → LLM이 거부를 error 결과로 인식
```

### 5.2 agent_sdk (oas repo) 변경

**`oas/lib/base/hooks.ml:195-207`** — 9번째 variant 추가:

```ocaml
type hook_decision =
  | Continue
  | Skip
  | Override of string
  | ApprovalRequired
  | AdjustParams of turn_params
  | ElicitInput of elicitation_request
  | Nudge of string
  | HookFailed of { stage : string; detail : string }
  | Block of string
      (** PreToolUse only: intentional policy rejection. Produces is_error=true
          with Non_retryable_tool_error. Distinct from HookFailed (unintentional
          infra failure) and Override (soft nudge, is_error=false). The string
          payload becomes the tool result content verbatim. *)
```

이름 선택: `Reject`가 아닌 `Block`. `approval_decision`(`base/hooks.ml:218`)에 이미 `Reject of string`이 존재하므로 `hook_decision`에 같은 이름을 추가하면 expression position에서 `Hooks.Reject "x"`가 양 type에 fit 가능 → 리팩터링 시 silent wrong-type 위험. `Block`은 충돌 없음.

**`oas/lib/base/hooks.ml:285-310`** — `hook_decision_kind`, `classify_decision`, `decision_kind_to_string`에 `K_Block` / `Block _ -> K_Block` / `K_Block -> "Block"` 추가.

**`oas/lib/base/hooks.ml` `legal_decisions_for_stage`** — PreToolUse legal list에 `Block` 추가. 다른 stage(OnIdle, BeforeTurn, PostToolUse)에는 illegal → `validate_decision`이 Block을 PreToolUse 외 stage에서 Error 반환.

**`oas/lib/base/hooks.mli`** — `Block` / `K_Block` 노출.

**`oas/lib/agent/agent_tools.ml`** — HookFailed arm(`:845-856`) 다음에 삽입:

```ocaml
| Hooks.Block reason ->
  { tool_use_id = id
  ; tool_name = name
  ; content = reason
  ; is_error = true
  ; failure_kind = Some Non_retryable_tool_error
  ; error_class = Some Types.Deterministic
  }
```

`find_and_execute_tool`을 호출하지 않고 직접 record 반환. 동작은 `Hooks.Reject`(`:773-779`, callback 내) 및 `Hooks.HookFailed`(`:845-856`)와 동일한 코드 경로. `Reject_without_callback`(`:749`)이 이미 callback 우회 선례로 존재.

### 5.3 masc 변경

**`keeper_guards.ml` 3 hard-block 사이트 전환** (Override → Block):

| Line | 함수 | reason_code | 전환 |
|---|---|---|---|
| 831 | `keeper_deny` | `keeper_deny` | Override → **Block** |
| 902 | destructive guard | `destructive_guard` | Override → **Block** |
| 958 | `governance_approval_guard` | `hard_forbidden` | Override → **Block** |

`render_inline_skip_reason_with_source` 호출은 유지(반환 문자열이 Block reason). `broadcast_tool_skipped`, `log_gate_rejection`, `report_gate_decision` 텔레메트리는 유지하되 `~decision:Gate_override` → `~decision:Gate_block`.

**soft nudge 3곳(636/692/755)은 Override 유지** (아래 §5.4).

**`keeper_guards.ml:174-186` `gate_decision` 확장** (직접 읽은 현재 type에 추가):

```ocaml
type gate_decision =
  | Gate_override
  | Gate_continue
  | Gate_approval_required
  | Gate_block   (** intentional hard block via Hooks.Block *)

let gate_decision_to_string = function
  | Gate_override -> "override"
  | Gate_continue -> "continue"
  | Gate_approval_required -> "approval_required"
  | Gate_block -> "block"

let gate_decision_is_rejection = function
  | Gate_override | Gate_block -> true
  | Gate_continue | Gate_approval_required -> false
```

`report_gate_decision`(`:318-`)와 `mark_turn_gate_rejected_by_name` 경로가 `Gate_block`을 올바르게 처리하는지 확인. `gate_rejection_log_severity` 점검.

**`keeper_hooks_oas.ml:71` `idle_decision_to_label`** — compiler가 arm 추가 강제:

```ocaml
| Agent_sdk.Hooks.Block _ -> "block"
```

### 5.4 Hard vs Soft 분류 (N-of-M 방지)

6곳을 "전부 Block"으로 바꾸면 soft nudge를 hard block으로 만드는 의미론 회귀. 분류 기준 = "unconditional 즉시 차단" vs "retry 유도 soft nudge":

| Line | guard | 분류 | variant | 근거 |
|---|---|---|---|---|
| 636 | pre_tool_use_guard | soft | Override 유지 | user-supplied, retry 의도 |
| 692 | streak_gate | soft | Override 유지 | "다른 도구" nudge, `is_error=false` 정당 |
| 755 | readonly_duplicate | soft | Override 유지 | dedup nudge |
| 831 | keeper_deny | **hard** | **Block** | static deny, 즉시 차단 |
| 902 | destructive_guard | **hard** | **Block** | destructive, 즉시 차단 |
| 958 | hard_forbidden | **hard** | **Block** | HITL 무관 무조건 차단 |

soft 3곳의 `[tool_skipped]` content string 분류기 의존(LLM이 거부가 아닌 안내로 해석하는지 typed 보장 아님)은 RFC-0321 범위 밖. 별도 RFC(typed tool-result schema)로 분리.

### 5.5 oas match site 전수 (exhaustiveness)

`hook_decision` variant를 match하는 oas 파일(agent_sdk 0.208.20 실측, 분석 단계):

| 파일 | variant 참조 | 갱신 |
|---|---|---|
| `agent/agent_tools.ml` | 다수 | YES: PreToolUse match에 Block arm(§5.2) |
| `base/hooks.ml` | 다수 | YES: classify_decision, decision_kind_to_string, legal_decisions_for_stage |
| `pipeline/pipeline.ml` | explicit + grouped catch-all 혼재 | 확인: line별 per-variant match는 compiler 강제, grouped catch-all(`Skip | Override _ | ...`)는 Block 포함 여부 점검 |
| `pipeline/pipeline_stage_prepare.ml` | grouped catch-all(`:90`) | 확인: 그룹에 Block 포함 여부 |
| `agent/agent_turn.ml` | 다수 | 확인 |
| `agent/agent_lifecycle.ml` | `decision_to_label`(`:90`) | YES: compiler 강제 |

compiler가 누락을 build error로 보고하므로 silent bug는 아님. 단 migration cost 평가를 위해 전수 열거.

## 6. before / after

| | before | after |
|---|---|---|
| keeper_deny / destructive / hard_forbidden 결과 | `is_error=false` (정상 위장) | `is_error=true`, Non_retryable, Deterministic *(일반적으로 failure 분류 경로로 전환되어 circuit breaker에 반영됨)* |
| LLM 인식 | 거부를 success로 학습 | 거부를 error로 인식 |
| librarian episode 기록 | success로 영구 기록 | error로 기록 |
| circuit breaker | 기존 경로에서는 Plain_text 기반 `inferred_outcome=Success`가 관찰됨 | `is_error=true`를 반환해 failure 경로로 관측이 이동 *(단 경로별 추가 검증 필요)* |
| `[tool_skipped]` content | LLM 자유 해석 | Block reason이 그대로 content (여전히 문자열이나 is_error=true가 의미 보장) |
| soft nudge 3곳 | Override 유지 | 동일 (변경 없음) |

## 7. 불변식 & 검증

### 7.1 단위 테스트

agent_sdk(oas):
1. PreToolUse hook이 `Hooks.Block "test reason"` 반환 시 `tool_result.is_error=true`
2. `failure_kind = Some Non_retryable_tool_error`, `error_class = Some Types.Deterministic`
3. `content = "test reason"` (reason 문자열 verbatim)
4. `legal_decisions_for_stage`: Block이 PreToolUse에서만 legal, 다른 stage에서 illegal(Error)
5. `classify_decision`: `Block _ -> K_Block`
6. `decision_kind_to_string`: `K_Block -> "Block"`

masc:
7. `keeper_deny` list tool → `Hooks.Block` 반환
8. destructive pattern match → `Hooks.Block`
9. hard_forbidden(risk=Critical 또는 runtime_auto_approval_blocked) → `Hooks.Block`
10. `gate_decision_to_string Gate_block -> "block"`
11. `gate_decision_is_rejection Gate_block -> true`
12. `idle_decision_to_label (Hooks.Block _) -> "block"`

### 7.2 regression (기존 경로 보호)

13. `needs_approval`(`keeper_guards.ml:970`) 분기가 여전히 `ApprovalRequired` 반환. callback이 `Approve` 반환 시 도구 실행. Block 전환에 영향 없음.
14. soft nudge 3곳(636/692/755)이 여전히 `Override` → `is_error=false`.
15. 정상 도구 실행 시 `Hooks.Continue` → `find_and_execute_tool`.

### 7.3 런타임 증명

16. risk=Critical 도구 호출 시 keeper LLM이 받는 tool_result `is_error=true` 실측 (`keeper_librarian.ml:42` 로그 `is_error=%b`)
17. `keeper_tool_dispatch_runtime.ml:251` `inferred_outcome`이 Failure/Block 분류, circuit breaker 작동
18. `broadcast_tool_skipped` SSE 카운터 유지 (Block이 `find_and_execute_tool` 우회해도 keeper_guards의 명시적 broadcast 호출 유지)

## 8. 경계

- **agent_sdk는 외부 opam package** (jeong-sik/oas). 단, 본인 소유 repo이므로 외부 대기 없이 type-theoretically 정합한 수정 가능.
- **stale install 주의**: `~/.opam/5.4.0/lib/agent_sdk`(6 variants)와 `~/.opam/5.4.1/lib/agent_sdk`(8 variants, real pin)가 다름. 분석·구현은 반드시 5.4.1 기준.
- **ApprovalRequired callback 경로는 건드리지 않음**: §3.1의 `governance_pipeline.ml:356` Reject 경로는 그대로. Block은 PreToolUse 직접 경로만 추가.
- **soft nudge(636/692/755)는 본 RFC 범위 밖**: content string 분류기 문제는 별도 RFC(typed tool-result schema).
- **post_tool_use_failure hook 우회**: Block arm이 `find_and_execute_tool`을 호출하지 않으므로 post_tool_use_failure hook이 발화하지 않음. `Hooks.HookFailed`(`:845-856`)와 동일 동작. circuit breaker가 `is_error` 필드에 의존하는지, hook에 의존하는지 구현 시 확인(Open question §11).

## 9. 롤아웃

### PR-1: oas (agent_sdk upstream) — Block variant 추가

- `oas/lib/base/hooks.ml`: `Block of string`, `K_Block`, classify/decision_kind_to_string/legal_decisions_for_stage
- `oas/lib/base/hooks.mli`: `Block`/`K_Block` 노출
- `oas/lib/agent/agent_tools.ml`: PreToolUse match에 Block arm
- `oas/lib/agent/agent_lifecycle.ml`: `decision_to_label` Block arm (compiler 강제)
- `oas/lib/agent/agent_turn.ml`, `pipeline/pipeline.ml`, `pipeline/pipeline_stage_prepare.ml`: match site 갱신 (compiler 강제)
- oas test: Block variant `is_error=true` 단언
- `oas/lib/sdk_version.ml`: version bump

oas repo = jeong-sik/oas (본인 소유). 외부 대기 없음.

### PR-2: masc — opam pin 갱신 + keeper_guards 전환 (PR-1 merge 후)

masc의 `agent_sdk` pin을 PR-1의 새 commit으로 이동. 그 후 `keeper_guards.ml` 3 hard-block 사이트(831/902/958)를 `Override → Block`, `gate_decision`에 `Gate_block` 추가, `keeper_hooks_oas.ml` arm 추가, 회귀 테스트.

**pin 갱신과 Block 참조를 단일 PR에 포함** (분할 금지). Block 참조가 pin 갱신 전이면 masc 빌드가 깨지므로. 착지 순서는 RFC-0008 split-brain 교훈(CLAUDE.md `agent_delegation` 근거) 준수: oas PR-1 merge → 새 commit 획득 → masc pin 갱신 + keeper_guards 전환 단일 PR.

## 10. 워크어라운드 거부기준 self-check

CLAUDE.md "워크어라운드 거부 기준" 5종 + 체크리스트 7항에 대한 본 RFC 검증:

| 기준 | 해당 | 근거 |
|---|---|---|
| 텔레메트리-as-fix (counter/alarm만) | 아니오 | is_error 자체를 바꾸는 type-level fix. counter 추가 아님 |
| String/Substring 분류기 | 아니오 | variant 추가. content 문자열 분류 아님 (soft 3곳의 content 문제는 별도 RFC로 명시적 분리) |
| N-of-M 패치 | 아니오 | 6곳 중 hard 3곳을 **일괄** 전환 + 분류 기준(hard/soft) 제시. "일부만" 아님 |
| catch-all `_ ->` 추가 | 아니오 | closed sum type에 variant 추가. exhaustive match 강화 |
| cap/cooldown/dedup/repair | 아니오 | 증상 억제 아님. 근원(variant 부재)을 닫음 |

체크리스트 7항 전부 "아니오". 본 RFC는 워크어라운드 거부 기준을 통과하는 근본 fix.

## 11. Open questions

1. **user custom guard(636)의 hard/soft intent**: 현재 모든 user custom guard는 Override(soft)로 처리. 사용자가 hard-block 의도로 guard를 작성해도 `is_error=false`. user guard callback 반환 type에 typed hard/soft 구분을 추가하는 별도 RFC 필요. RFC-0321은 "현재 user custom guard는 soft-nudge semantic이 보장된다"는 전제로 진행.
2. **soft nudge 3곳(636/692/755)의 content string 분류기**: `is_error=false`가 정당해도 LLM이 content를 올바르게 해석하는지 typed 보장 아님. 별도 RFC(typed tool-result schema)에서 content를 structured JSON(reason_code + reason_text 분리)로 전환. RFC-0042급 안티패턴 잔류.
3. **dual risk evaluation**: `keeper_guards.ml:935` assess_risk(base)와 `governance_pipeline.ml:397-416` callback의 hard_forbidden 재평가가 다름. Block으로 PreToolUse에서 즉시 차단하면 callback 재평가 경로가 dead code가 됨. 제거할지 보조 검증으로 유지할지 설계 결정.
4. **post_tool_use_failure hook 우회**: Block arm이 `find_and_execute_tool` 미호출로 hook 미발화. circuit breaker가 `is_error` 필드로 작동하면 문제없으나, hook에 의존하면 별도 처리 필요.
5. **provider별 error handling**: `is_error=true`가 provider별 error 채널로 분류되지만, content 자체의 reason_code 의미를 LLM이 structured로 소비하는 건 본 PR 범위 밖. provider별 테스트 필요.

## 12. 산출 근거

본 RFC는 10-agent Workflow(분석 3 / 설계 3 / 적대 비판 3 / 통합 1)로 설계. 각 phase가 이전 phase 전체를 입력으로 사용(barrier). Critique가 Candidate A에 HookFailed 재사용 대안을 제기했고, Synthesize가 이를 평가해 `Block` 신규 variant를 선택. 핵심 file:line은 Workflow 이후 별도로 직접 검증(§3, §3.1, §5.3, §5.5 표의 "직접 읽음" 항목). 보조 영향 file:line(§1.1)은 agent 분석 단계 산출로 구현 PR에서 재검증 필요.
