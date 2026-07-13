---
rfc: "0089"
title: "String Classifier to Typed Variant — direct replacement, no lint"
status: Implemented
created: 2026-05-15
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0042"]
implementation_prs:
  - 15520  # G1 tool_help_registry tool_family
  - 15523  # G4 keeper_checkpoint_store ENOENT
  - 15524  # G2 board author_kind + voter_kind
  - 15684  # keeper_path_check_error closed sum + emit-site routing
  - 15699  # shadow-gate parse_outcome_kind
  - 15703  # eval gate destructive-pattern SSOT
  - 15704  # eval_gate evasion_kind
---

# RFC-0089 — String Classifier 박멸: typed variant 직접 교체

## §1 컨텍스트

2026-05-15 bug-hunter audit이 `String.starts_with ~prefix:"..."` 분류 패턴
**215 site (lib/ 기준)** + `String.equal` 1,333 site (대다수 정당, 일부 분류기) 를 식별.
이는 AGENT-LLM-A.md §"워크어라운드 거부 기준 §2 String/Substring 분류기 보강" 정의에
직접 해당한다 — typed variant 가능한 자리에 string match를 두면 컴파일러가 새
prefix 추가 시 reader 누락을 감지 못하고, prefix가 자유롭게 자라 read-side
repair가 누적된다.

대표 caller evidence:

- `lib/audit_log.ml:126` — action kind를 string prefix로 되읽는다.
- `lib/board_core_classify.ml:80` — author prefix가 내부 분류 기준이 된다.
- `lib/tool_help_registry.ml:71` — tool family를 tool name prefix로 추정한다.

```ocaml
if String.starts_with ~prefix:"masc_keeper_" tool_name then
  `Keeper
else if String.starts_with ~prefix:"masc_policy_" tool_name then
  `Policy
else
  `Unknown
```

RFC-0042 (Draft, `keeper_turn_terminal.t.code` closed sum) 가 동일 안티패턴을 한
도메인에서 닫는다. 본 RFC는 RFC-0042의 **잔존 사이트 mop-up** 으로 위치하며,
하나의 typed boundary가 아니라 다중 도메인의 classifier-as-string 패턴을
일괄적으로 typed variant로 옮기는 작업 계약을 정한다.

## §2 Non-goals

본 RFC는 다음을 다루지 않는다:

- **Lint / hardcoded phrase list / regex guard 추가 금지.**
  string classifier를 잡기 위한 string classifier는 워크어라운드 #2에 자기참조로
  해당한다 (참조: `memory/feedback_lint_string_classifier_is_workaround_not_fundamental.md`).
  본 RFC는 *직접 교체*만 다룬다 — 컴파일러가 exhaustive match를 강제하면 lint는
  잉여이고, 강제하지 못하면 lint는 워크어라운드다.
- **외부 protocol / storage boundary string은 scope 제외.**
  CLI argv parsing, git porcelain output, HTTP path routing, diff format parsing,
  JSON envelope key matching은 *boundary*에서 string으로 들어오는 입력이며,
  string match는 boundary의 일부다. 본 RFC가 닫는 것은 *내부 상태/결정/이벤트*를
  string으로 표현하고 다시 분류하는 사이트뿐이다.
- **RFC-0042 재작성.** RFC-0042가 닫는 `keeper_turn_terminal.t.code` 도메인은
  본 RFC 인벤토리에서 제외한다.
- **string normalize / repair / dropped counter 도입.** 본 RFC는 read-side
  workaround를 추가하지 않는다. typed variant 도입 PR이 같은 머지에서 legacy
  string 경로를 함께 삭제한다 (참조: `memory/feedback_hardcoding_and_legacy_zero_tolerance.md`).

## §3 Audit 결과 (sample)

전체 인벤토리는 `docs/rfc/inventory/RFC-0089-string-classifier-sites.md` 참조.
본 절은 결정에 영향을 준 sample만 inline.

### §3.1 Scope-in (typed variant 교체 대상)

| Domain | File:Line | 현재 패턴 (요약) | Typed variant 후보 | Variant 이미 존재? |
|---|---|---|---|---|
| Audit action kind | `lib/audit_log.ml:126` | serialized action prefix를 substring으로 다시 분류 | 기존 `action_kind` variant (`ToolCall of string` 등) 가 이미 정의 — 문제는 *string 직렬화 후 재분류 경로*가 존재한다는 것 | 부분 (직렬화 round-trip만 미정의) |
| Anti-rationalization decision | `lib/anti_rationalization.ml:409` | `starts_with ~prefix:"APPROVE" / "REJECT"` upper-case prefix + word-boundary 검사 후 `Approve / Reject` 변형 생성 | LLM 응답 파싱 boundary이므로 typed parser 결과(`type decision = Approve \| Reject \| Abstain`)로 산출. 내부 caller는 string을 다시 보지 않음 | 변형은 존재, parser 경로만 string 통과 |
| Board author classification | `lib/board_core_classify.ml:80` | `starts_with ~prefix:"auto-" / "qa-"` + substring(`researcher / harness / smoke / probe`) | `type author_kind = Human \| Automation_prefixed of automation_label \| System_actor of system_actor \| External_observer of observer_label` | 없음 — 신규 type 필요 |
| Tool name family | `lib/tool_help_registry.ml:71-83` | 14 site의 `starts_with ~prefix:"masc_operation_" / "masc_dispatch_" / "masc_unit_" / "masc_policy_" / "masc_observe_" / "masc_detachment_" / "masc_keeper_"` | tool registry가 이미 tool descriptor 보유 — `tool_family` 필드를 descriptor에 추가하면 prefix 분류 자체가 사라짐 | 없음 — descriptor 확장 |
| Skill routing line marker | `lib/keeper_skill_routing/keeper_skill_routing.ml:137-148` | `starts_with ~prefix:"skill:" / "skill_reason:" / "SKILL:" / "SKILL_REASON:"` mixed case | skill output protocol parser를 typed (`type skill_line = Skill of skill_name \| Reason of string \| Other of string`) 로 분리. RFC §3.2 boundary가 아닌 이유: 마커는 우리가 *직접 정의*한 내부 protocol | 없음 — 신규 |
| Checkpoint store ENOENT 분류 | `lib/keeper/keeper_checkpoint_store.ml:367-370` | `starts_with ~prefix:"no_such_file" / "no such file" / "unix_error (enoent" / "eio.io fs not_found"` 4-way string match | OCaml stdlib + Eio exception 종류를 직접 `match` (`Unix_error (ENOENT, _, _)` / `Eio.Io (Fs (Not_found _), _)`) — exception을 string화한 뒤 prefix 비교하는 것 자체가 변환 손실 | 없음 — exception pattern match로 직행 |

### §3.1.1 Implementation status (2026-05-17)

§3.1 6 도메인 + 본 RFC 채택 이후 발견된 추가 도메인의 현재 상태:

| Domain | Status | PR |
|---|---|---|
| Tool name family (`tool_help_registry`) | Implemented | #15520 |
| Checkpoint store ENOENT | Implemented | #15523 |
| Board author classification | Implemented | #15524 |
| Audit action kind (`audit_log.ml`) | Pending | — |
| Anti-rationalization decision (`anti_rationalization.ml`) | Pending | — |
| Skill routing line marker (`keeper_skill_routing.ml`) | Pending | — |
| Keeper path-check error (post-RFC discovery) | Implemented | #15684 |
| Shadow-gate parse outcome (post-RFC discovery) | Implemented | #15699 |
| Eval gate destructive-pattern SSOT (post-RFC discovery) | Implemented | #15703 |
| Eval gate evasion kind (post-RFC discovery) | Implemented | #15704 |

§4 Top 3 우선순위 도메인 (tool_help_registry / checkpoint / board author)
은 모두 Implemented. §3.1 의 나머지 3 도메인 (audit action, anti-rationalization,
skill routing) 은 후속 PR 대상으로 남았다.

### §3.2 Scope-out (boundary site, 정당)

다음은 prefix match가 *boundary 정의의 일부*다. 본 RFC 작업 범위 밖.

| File:Line | 패턴 | 정당화 |
|---|---|---|
| `lib/keeper/agent_tool_execute_command_parse.ml:401, 414, 595, 602` | `"-" / "--repo=" / ";"` | CLI argv tokenizer — 외부 입력 string의 lexer |
| `lib/exec/output_parse.ml:166, 212-224` | `"total" / "test " / "src/" / "test/"` | OCaml test runner stdout porcelain |
| `lib/server/server_routes_http_routes_workspace.ml:428, 487, 523` | `"author " / "@@ -" / "+++"` | git blame / diff format parser |
| `lib/server/server_auth.ml:683-685` | `"/dashboard/" / "/static/" / "/graphiql/"` | HTTP path routing (URL은 external string) |

### §3.3 정량 요약

- `String.starts_with ~prefix:"..."` lib/ 합계 (2026-05-15 audit): **215 site**
- `String.starts_with ~prefix:"..."` lib/ 합계 (2026-05-17 재측정): **301 site (+86)**
  - +86 의 의미: RFC 가 Draft 상태로 enforce 되지 않은 2 일 (2026-05-15 → 2026-05-17)
    동안 신규 코드가 string classifier 를 추가로 도입했음. 2 일 +86 누적은
    enforce 부재의 직접적 비용이며 status 승격 (Accepted) 의 motivation.
- 10-site sample triage 결과: scope-in 6 / scope-out 4 (60% / 40%)
- 단순 외삽 시 scope-in 추정 ~130 site (검증 안 됨, full inventory에서 정정).
  외삽치는 본 RFC §4 우선순위 결정에만 사용, 본문 acceptance에 포함하지 않음.
- 가장 큰 단일 도메인 caller blast: Board_core_classify 7 caller (lib 5 + test 2)
- 2026-05-17 top hotspots (file:occurrence):
  `retired_worker_shell_facade:19`, `exec/output_parse.ml:15`,
  `server/server_routes_http_routes_workspace.ml:11`,
  `server/server_dashboard_http_link_preview.ml:9`,
  sandbox Execute runner, `keeper/agent_tool_execute_command_parse.ml:9`.
  대부분 boundary parser (§3.2 scope-out) 후보지만, 사이트별 재분류 필요.

## §4 우선순위 (Top 3)

caller delta가 작고 typed variant 도입 효과가 큰 순:

1. **Tool name family → tool descriptor 확장.**
   `tool_help_registry.ml` 14 prefix site 모두 한 descriptor 필드로 흡수.
   caller 동선이 *registry → consumer*로 단방향이라 reverse search 없음.
   기대 효과 = prefix-as-classifier 14 site 즉시 0.

2. **Checkpoint store ENOENT 분류 → exception pattern match.**
   4 string match를 exception variant match로 교체. ocaml stdlib + Eio 직접 사용.
   PR 1개 (~20 LOC).

3. **Board author classification → `author_kind` variant.**
   신규 type 도입 + 7 caller 동시 갱신.
   `auto-` / `qa-` prefix가 string으로 board에 들어오는 *external write boundary*는
   별도 typed boundary (post.author는 외부에서 들어오는 string)이므로, classifier
   교체만으로 충분 — write 경로는 그대로 두되 read 경로에서 한 번 parse하여
   typed로 흐른다 (Alexis King: Parse, don't validate).

## §5 Migration 전략

각 도메인은 다음 4-step 패턴 한 PR로 처리:

1. **신규 typed variant 정의** (또는 기존 변형 확장).
2. **`<domain>_of_string : string -> <variant>` 1회 parser** (boundary 진입점에만 둠).
   classifier가 *내부 코드 안에서* 다시 등장하지 않아야 함.
3. **caller delta**: 모든 caller가 string 대신 variant로 전환. exhaustive `match`
   강제 (catch-all `_ -> ...` 금지, 신규 변형 추가 시 컴파일 에러 발생).
4. **legacy string 경로 동일 머지에서 삭제** — `*_to_string` 보존은 직렬화/로그
   필요 시에만, parser 역방향은 금지 (round-trip 차단으로 read-side workaround
   방지).

도메인 간 의존성이 없으므로 PR은 *도메인 단위로 독립 진행* 가능하다.
RFC-0042 도메인 (keeper turn terminal code) 과 본 RFC 도메인은 서로 disjoint이며
병행 머지에 충돌 없다.

## §6 Codemod feasibility

자동화 가능한 부분과 수동인 부분을 분리한다 (검증된 측정 없음, 추정):

- **자동화 가능**: 단순 `String.starts_with ~prefix:"X" s` → `match parse s with Some V -> ... | None -> ...` 골격 치환. AST 도구 (`ocamlformat` + `ppx`) 또는 sed 수준.
- **수동 필수**: prefix 매치 후 substring 분리로 payload를 뽑는 사이트
  (`audit_log.ml:126-131` 처럼 `String.sub s 10 (...)` 가 따라오는 경우). caller가
  payload를 어떻게 쓰는지에 따라 variant 인자 형태가 달라짐.
- 본 RFC는 *자동화 ratio를 약속하지 않는다* — Phase 1 첫 PR에서 실측 후
  Implementation summary에 기록한다.

## §7 Acceptance

본 RFC 의 acceptance 모델은 **도메인별 독립 도달** 이다. RFC 전체가 한 번에
Implemented 로 가는 것이 아니라, 각 §3.1 도메인이 완료될 때마다 점진적으로
누적된다.

도메인별로 다음이 동시 성립할 때 해당 도메인을 Implemented 로 표시:

- [ ] §3.1 scope-in 도메인의 `String.starts_with ~prefix:"..."` 사이트 **0건**
      (단, §3.2 scope-out boundary 사이트는 제외).
- [ ] 각 scope-in 도메인의 `String.equal` enum match 사이트 0건.
- [ ] caller delta 100% — 새 variant를 받지 않는 caller 잔존 없음.
- [ ] legacy string 경로 (`*_of_string` parser는 boundary 1곳만, 역방향 round-trip
      불가) 가 *같은 머지 PR*에서 삭제됨. 별도 cleanup PR 약속 금지.
- [ ] catch-all `| _ -> ...` 0건 — 신규 변형 추가 시 컴파일 에러.

본 RFC는 lint나 grep guard로 acceptance를 측정하지 않는다 — acceptance는
컴파일러 강제 + `rg` 직접 count로 검증한다.

### §7.1 RFC-level status 전이

| Status | 조건 |
|---|---|
| Draft | 합의 형성 중 |
| Accepted (현재) | §4 Top 3 도메인 중 최소 1개 Implemented + spec 합의 입증 |
| Implemented | §3.1 모든 도메인 Implemented + RFC 채택 이후 발견된 모든 도메인 Implemented |

**현재 상태 (2026-05-17)**: §4 Top 3 도메인 3/3 Implemented + RFC 후 발견 도메인
4 건 Implemented (PR #15684/#15699/#15703/#15704). §3.1 잔여 도메인 3 건 (audit
action, anti-rationalization, skill routing) 이 후속 PR 대기. Accepted 상태로
승격되어 reviewer 가 새 PR 의 string classifier 도입을 reject 할 근거가 명시화됨.

## §8 위험

- **외부 입력 정의 변경**: anti-rationalization LLM 응답이 `APPROVE/REJECT` 외
  새 단어를 내면 `Other of string` fallback이 필요하다. fallback variant를
  허용하되 catch-all 분기에서 typed로 즉시 격리한다 (string으로 전파 금지).
- **테스트 fixture**: 기존 string 기반 fixture는 typed builder로 함께 갱신.
  fixture가 string을 기대하면 boundary parser를 호출하도록 변경.
- **Caller blast radius**: tool_help_registry는 14 prefix × N caller — 한 PR
  scope를 넘으면 도메인 sub-분할. 분할 시에도 cleanup PR은 별도 약속 금지,
  매 PR이 자기 도메인 legacy를 동시 삭제.

## §9 References

- RFC-0042 (`keeper_turn_terminal.t.code` closed sum, Draft 2026-05-08) — 동일
  안티패턴의 한 도메인.
- AGENT-LLM-A.md §"워크어라운드 거부 기준 §2 String 분류기 보강".
- `instructions/software-development.md` §"AI 코드 생성 안티패턴 §2 Unknown →
  Permissive Default" — string classifier가 unknown 입력을 silent default로
  흡수하는 vector.
- `memory/feedback_lint_string_classifier_is_workaround_not_fundamental.md`
  (2026-05-09 PR #14308 closed) — lint 도입이 워크어라운드 #2에 자기참조로
  해당함을 사용자가 명시 거부.
- `memory/feedback_hardcoding_and_legacy_zero_tolerance.md` — root-fix PR이 같은
  머지에서 legacy 동시 삭제, 별도 cleanup PR 금지.
- Bug-hunter audit 2026-05-15 (215 sites, lib/).

## §10 Open questions

1. `tool_help_registry` 14 prefix를 tool descriptor 필드로 옮길 때 descriptor
   타입의 caller blast가 본 RFC 추정치를 초과하면 도메인을 별도 RFC로 분리할지.
2. `keeper_checkpoint_store` ENOENT 분류는 stdlib `Unix.error` 변형과 Eio
   variant를 union typing으로 묶을지, 각각 별도 match로 둘지 — OCaml exception
   match의 cross-library 패턴 결정 필요.
3. `anti_rationalization` LLM 응답 parser를 본 RFC scope에 포함할지, 별도
   `boundary parser` RFC로 분리할지 — boundary는 §2 scope-out인데 *우리가 정의한*
   prompt 응답 형식이라 internal/external 경계 모호.
