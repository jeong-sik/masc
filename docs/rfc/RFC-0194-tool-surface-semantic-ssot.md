# RFC-0194: Tool Surface Semantic SSOT — Guiding Principles

**Status**: Draft (Meta-RFC, code = 0)
**Date**: 2026-05-27
**Sub-RFCs**: RFC-0193 (substring classifier sunset, Issue #19032) / RFC-0195 (workflow_rejection descriptor enrichment) / RFC-0196 (dispatch layer clarity)
**Memory anchors**: `feedback-surgical-workaround-rejected-for-tool-surface`, `feedback-cascade-budget-no-hard-gates`

## Context

`masc-mcp` 의 tool surface (Keeper ~38 + Masc ~80+, 총 ~170 `Tool_name` variants) 가 *3개 독립 non-SSOT 메커니즘* 으로 semantic 의미를 누설 중이며, 각 메커니즘이 fleet-observable 실패 모드를 산출:

| Surface | 결함 | Fleet evidence (2026-05-27 8.4h) |
|---|---|---|
| Risk classifier (`lib/governance_pipeline_risk.ml`) | substring matcher 가 primary fallback, `risk_overrides` 8 entry 가 누적 patch | 11 `governance_approval` false-positive |
| `workflow_rejection_error_json` (`agent_tool_task_runtime.ml:23`) | hint / tool_suggestion 시그니처 부재, 6 call site 모두 dead-end | 5 `keeper_memory_write` + 1 `keeper_task_submit_for_verification` empty-arg = 6 LLM dead-end |
| Dispatch layer (`config/keepers/base.toml`) | Claude API / MASC structured / Shell executable taxonomy 부재 | 12 confusion (8 Read-via-Execute, 2 keeper_tasks_list-via-Execute) |

각 fix 를 *surgical patch* 로 진행하면 next contributor 가 같은 workaround 패턴을 재구축. PR #19035 가 그 대표 사례 — `risk_overrides` 에 3 entry 추가 (8th-10th) 로 11 false-positive 해소, 단 substring matcher 자체는 그대로.

본 Meta-RFC 는 **3 sub-RFC 가 공유할 acceptance criteria SSOT** 를 정의. *code = 0*. 모든 후속 PR 은 본 문서의 principle 번호를 cite 하여 어느 principle 을 instantiate 하는지 + 어느 principle 을 not-invoke 하는지 명시해야 한다.

## Research basis (external sources)

- **Anthropic — Code execution with MCP** (<https://www.anthropic.com/engineering/code-execution-with-mcp>): "JSON schemas define structure but **can't express usage patterns**. **Examples > longer descriptions** for parameter accuracy. Tool definitions can be deferred via Tool Search Tool (77K → 8.7K tokens, ~88% 감소)." → *prose hint hardcode* 가 Anthropic 안티패턴.
- **arxiv 2406.19228 — Tools Fail: Detecting Silent Errors** (<https://arxiv.org/pdf/2406.19228>): "Most tool failures are **silent**. Recovery requires LLM active reasoning, not just descriptive metadata." → error message 가 *minimal typed signal* + LLM 의 *descriptor-aided 비결정적 reasoning* 의 조합이 정공법.
- **AWS — Four security principles for agentic AI systems** (<https://aws.amazon.com/blogs/security/four-security-principles-for-agentic-ai-systems/>): "Deterministic pre-execution validation (type / schema / permission) **+** probabilistic intent classification. ROA agent separation: **Explain** (natural language) vs **Policy** (structured typed claim Runtime validates deterministically)." → deterministic + probabilistic 양자 동시, 양자택일 아님.
- **apxml — Handling Tool Errors and Agent Recovery** (<https://apxml.com/courses/langchain-production-llm/chapter-2-sophisticated-agents-tools/agent-error-handling>): "LLM might retry with modified parameters OR use different tool if alternative is available." → alternative tool 의 *typed name list* 가 충분, prose 필요 없음.

## Five Guiding Principles

### §1. Typed SSOT over substring / threshold classifier

Governance, dispatch, scheduler 의 *control-flow* 의사결정에 사용되는 tool property 는 `Tool_name` enum-key 의 typed table 만을 SSOT 로 사용한다. String-pattern fallback 은 *observability only* (log message, metric label) 에 허용, *control flow* 에는 금지.

Rationale: substring matcher 는 false-positive 누적 메커니즘. `risk_overrides` 가 그 증거 — patch 8개가 *분류기 자신의 confusion 의 stack trace*. CLAUDE.md §Workaround §2 (String/Substring 분류기 보강) 의 직접 instantiation.

Anti-pattern example (RFC-0193 의 target):
```ocaml
(* lib/governance_pipeline_risk.ml:101 — REJECTED *)
let high_patterns = [ "create"; "update"; "write"; ... ]
let classify_name name =
  if contains_pattern name high_patterns then High else ...
```

Compliant pattern (RFC-0193 의 target form):
```ocaml
let capability_classification : (Tool_name.t * capability list) list = [
  (Tool_name.Masc Masc.Plan_set_task, [State_modification_self_scoped]);
  ...
]
(* + exhaustive match enforcement via principle §5 *)
```

### §2. Every LLM-blocking gate names an alternative — via descriptor metadata, not per-error prose

Terminal error (workflow_rejection / governance_denied / executable_not_allowlisted / 동등) 는 *typed alternative tool name list* 만 emit. Long prose hint 는 reject.

Alternative 선택의 *guidance* 는 tool descriptor 의 `examples` + `alternatives` field 에 위치 — LLM 이 descriptor 보고 *비결정론적 자율 선택*. 이는 Anthropic 의 "examples > longer descriptions" 권장과 정합.

Anti-pattern example (RFC-0195 의 *원안 v1* 이 회피한 형태):
```ocaml
(* REJECTED — per-error prose hint hardcode *)
workflow_rejection_error_json
  ~hint:"Re-call with result='<one-line summary: shipped/tests/follow-ups>'..."
  ~tool_suggestion:"keeper_task_done"
  "result is required"
```

Compliant pattern (RFC-0195 의 v2 form):
```ocaml
(* error site — minimal typed *)
workflow_rejection_error_json
  ~alternatives:[Tool_name.Keeper Keeper.Task_done]
  "result is required"

(* descriptor — guidance source *)
{ tool_name = Tool_name.Keeper Keeper.Task_done;
  when_to_use = "Mark task complete with a one-line result.";
  examples = [
    "done with result text";
    "done with notes='shipped X, tests green'";
  ];
  alternatives = []; (* terminal *)
  ... }
```

Rationale: prose hint hardcode 는 (a) Anthropic 안티패턴, (b) coding-time decision tree 라 새 case 마다 PR rewrite, (c) deterministic prompt injection — LLM 자율성 침해. Typed `alternatives` list 만 emit 시 LLM 이 catalog descriptor 의 `examples` 로 *contextual 비결정 선택*.

### §3. Dispatch layer is explicit, not inferred

모든 visible tool 이름이 typed `dispatch_layer` tag carry:
```ocaml
type dispatch_layer =
  | Claude_api_native       (* ReadFile, WriteFile, EditFile, ... *)
  | Masc_structured         (* keeper_*, masc_*, tool_* JSON tools *)
  | Shell_executable_argv   (* cat, rg, git, gh, ... via Execute *)
```

System prompt + error hint 가 taxonomy 를 paraphrase 가 아닌 *by-name reference*. 예:
- ❌ "Execute가 노출된 경우 한 번에 하나의 typed argv 명령만 실행"
- ✅ "If a `Shell_executable_argv` layer tool is visible, use one typed argv per call. `Claude_api_native` tools (ReadFile / WriteFile / ...) are called directly via tool_use; they are not shell programs."

`agent_tool_execute_typed_input.ml:371-414` 의 substring heuristic (`String.starts_with ~prefix:"keeper_"`) 은 typed lookup 으로 대체 — argv[0] 이 *`dispatch_layer ≠ Shell_executable_argv` 인 Tool_name* 과 일치하면 layer-specific redirect alternative emit.

Rationale: LLM 학습된 회피 (`Read` 를 Execute 로 보내는 confusion) 의 root = system prompt 의 layer 모호함. Typed tag + explicit prompt language 가 정공법.

### §4. Negation of three rejected workaround shapes (CLAUDE.md §Workaround-Rejection §1 / §2 / §3)

Sub-RFC PR 이 다음 shape 중 하나라도 도입하면 *다른 merit 무관하게 send-back*:

- **§1 Counter-as-fix**: silent failure 를 visible counter 로 *expose* 하되 *fix* 하지 않음
- **§2 String / Substring 분류기 보강**: typed variant 가 가능한 자리에 string match 추가 또는 잠금
- **§3 N-of-M 패치**: "PR #X only fixed M/N sites" 자인하며 나머지를 별도 PR 로 메움 — abstraction 부재 admit

Production-blocking 시 CLAUDE.md Override 3-요건 (`WORKAROUND: <사유>` + `RFC-NNNN` 참조 + `removal target: <date/RFC merge>`) 충족 후에만 머지.

### §5. Exhaustive coverage requirement

Typed table 이 substring matcher 를 대체할 때 *compile-time 또는 test-time exhaustiveness check 강제*. Wildcard (`| _ -> ...`) 금지. Canonical pattern:

```ocaml
let classify_capability : Tool_name.t -> capability list = function
  | Keeper Keeper.Task_claim    -> [Coordination]
  | Keeper Keeper.Task_done     -> [State_modification_task_lifecycle]
  | Masc   Masc.Plan_set_task   -> [State_modification_self_scoped]
  ...
  (* 새 Tool_name variant 추가 시 build fail until classified *)
```

Cluster 화 (RFC-0182 패턴, ~170 → ~12-15 cluster) 로 human-reviewable 표를 짧게 유지하면서도 exhaustiveness 충족.

## ROA Boundary (Probabilistic + Deterministic 동시)

- **Probabilistic layer (LLM)**: tool *selection* (descriptor `when_to_use` + `examples` + `alternatives` 참조), error *interpretation*
- **Deterministic layer (Runtime)**: schema validation, permission gate, `dev_exec_allowlist` enforcement, typed `failure_class` classification

본 RFC 는 deterministic boundary 를 *그대로 유지* — LLM reasoning 에 enforcement 위임하지 않는다. AWS ROA 패턴의 Explain / Policy 분리 그대로.

## Sub-RFC mapping

| Sub-RFC | Instantiates | Status |
|---|---|---|
| RFC-0195 (P0) | §2 (alternatives via descriptor) | Issue 신규 등록 예정 |
| RFC-0193 | §1 (typed SSOT, substring sunset) | [Issue #19032](https://github.com/jeong-sik/masc-mcp/issues/19032) — body update 예정 |
| RFC-0196 | §3 (dispatch layer taxonomy) | Issue 신규 등록 예정 |

3 sub-RFC 간 dependency 없음. RFC-0196 의 `dispatch_layer` field 는 RFC-0195 의 descriptor schema 확장 후 *자연 추가* — 강 dependency 아님, *enabling* 관계.

## Acceptance for Meta-RFC (review-time only)

- 모든 sub-RFC PR body 가 instantiated principle (§N) 명시
- 모든 sub-RFC PR body 가 non-invoked principle 명시
- Anti-pattern example 과 compliant pattern 둘 다 본 문서에서 cite
- Runtime test 없음 — review checklist 가 enforcement

## Out of scope

- Code (lib/ 변경 zero)
- Concrete typed table (sub-RFC 가 정의)
- LLM prompt rewrite (RFC-0196 영역)
- 측정 dashboard (sub-RFC 별 fleet metric 정의)

## References

- CLAUDE.md §워크어라운드 거부 기준 §1 / §2 / §3
- 메모: `feedback-surgical-workaround-rejected-for-tool-surface` (2026-05-27, PR #19035 reframe)
- 메모: `feedback-cascade-budget-no-hard-gates` (2026-05-27, math composition 강제)
- RFC-0182 (descriptor projection cluster taxonomy 패턴 차용)
- RFC-0189 (typed failure_class — workflow_rejection 분류는 이미 typed)
