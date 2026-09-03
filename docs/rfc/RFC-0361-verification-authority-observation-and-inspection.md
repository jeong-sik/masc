---
rfc: "0361"
status: Draft
---

# RFC-0361: 완료 권한의 관측과 조회

Status: Draft
Author: Claude Opus 5 (1M context)
Date: 2026-08-05
Related: #26914, #26915, RFC-0284 (fusion judge observation record), constitution (PR #29140)
Amended: 2026-08-19 — D7 (keeper급 standalone 격상) 추가, Non-goal §2 해석 정정

## Problem

완료 권한(`Completion_authority_agent`)은 Task 완료를 승인/거부하는 LLM이다. 도구가 `report_review_verdict` 하나뿐이라 제출자가 프롬프트에 붙여준 것 밖을 볼 수단이 없다.

```ocaml
(* lib/workspace_metric_hooks.ml:396 *)
~masc_tools:[ report_tool_schema ]
```

프롬프트는 이 경계를 정확히 안다:

> Inspectable proof exists only in the typed `submitted_evidence_access` snapshot inside `completion_notes`.
> An `Evidence_note` is narrative context, not an independently inspected artifact. Do not treat a URL, path, commit, or test claim inside a note as proof that you opened or executed it.

지시는 옳다. 판정자가 그 URL을 열 방법이 없다는 것이 문제다. "직접 확인한 것만 믿어라" + "확인할 도구 없음" = 제출자가 붙인 범위가 판정 가능 범위의 상한.

### 라이브 결과 — task-136

```
verification_id  vrf-24b43c36fc86a9f2e25763affa527f7d
producer         keeper-kidsnote-agent
authority        system_llm_agent / system-llm-agent-473b608e9bc8b621d4ca7c9419a84b34
verdict          approved  →  task-136 = done
```

| | 승인 스냅샷 | 현재 워킹트리 |
|---|---|---|
| `aria-*` 속성 | 14 | 0 |
| 7개 파일 내용 일치 | — | 0/7 |

```
$ git -C .masc/playground/kidsnote/repos/kidsnote_web_inapp \
      log --oneline -S 'aria-label' -- services/benefit-firstcome
(빈 출력)
```

키퍼가 워킹트리를 고침 → 스냅샷 제출 → 승인 → `done` → 같은 샌드박스의 후속 작업이 진행되며 미커밋 편집 소실. **판정자는 틀리지 않았다.** 붙어 있던 7개 파일은 실제로 작업이 되어 있었다. 볼 수 없었던 것은 그게 커밋되지 않은 휘발성 상태라는 사실이고, 그걸 볼 도구가 없었다.

### 실측 (2026-08-05)

| | |
|---|---|
| verdict 이벤트 | 74 (`system_llm_agent` 73 / `human_operator` 1) |
| distinct `authority_actor` | 74 — 2건 이상 판정한 actor 0 |
| 승인 아티팩트 파일 53개 | 커밋됨 44 / tracked·dirty 7 / untracked 2 |
| 승인 레코드 19건 중 내용 드리프트 | 1 (task-136) |
| 라이브 42 레코드의 note 187개 | SHA 형태 23 · URL 9 — 32번 견고한 것을 가리키려 했으나 전부 산문으로 저장 |

44/53이 견고한 것은 키퍼들이 대체로 커밋하기 때문이지 무엇이 강제해서가 아니다. 나머지 9개는 같은 게이트를 같은 방식으로 통과했다.

`authority_actor`는 `Random_id.prefixed ~prefix:"system-llm-agent-" ~bytes:16`(`completion_authority_agent.ml:452`) — CSPRNG 16바이트로, 아무것에서도 파생되지 않고 `verification_id`와도 무관하다. 판정마다 새로 태어나 한 번 판정하고 사라진다. 캘리브레이션·이력·감사를 계산할 모집단이 없다.

관측도 없다. 이 호출은 `?raw_trace`/`?on_event`를 넘기지 않아 최종 verdict 이벤트 한 줄 외에 남는 것이 없다. 키퍼는 `keeper_agent_run.ml:1266`에서 trace를 남기고 웹 대시보드에 볼 곳이 있다.

## Non-goals

**결정론적 evidence floor를 복원하지 않는다.** RFC-0199 / 0222 / 0311 / 0337은 2026-07-13 일괄 Withdrawn이고 결정은 명시적이다:

> Evidence shape is not a universal truth about whether arbitrary work is complete... The configured LLM judges the Task against its context and evidence.

이 RFC는 그 결정을 유지한다. 완료 기준은 그대로 LLM 판단이 갖는다. 바꾸는 것은 그 판단자가 무엇을 볼 수 있고 무엇이 기록되는가다.

**판정자를 키퍼로 만들지 않는다.** 커밋 `6df3c383`(2026-07-30)이 `config/keepers/verifier.toml`을 삭제하며 키퍼 verifier를 의도적으로 제거했다("A Keeper is not a verifier"). 키퍼 레지스트리 등록·자기 샌드박스·task action·라이프사이클/heartbeat·페르소나 toml 중 무엇도 추가하지 않는다.

**(2026-08-19 개정)** 위 금지 다섯 가지는 그대로 유지된다. 바뀌는 것은 해석이다: "키퍼가 아니다"를 "프로세스 경계가 없는 무관리 in-process fiber다"로 읽었던 현 상태를 정정한다. constitution (PR #29140 — main 미머지, 해당 PR의 `docs/constitution.xml`)은 Verifier를 "내부 Standalone LLM Agent"로 정의하고 keeper급 실행체를 요구한다. "키퍼 등록 금지"와 "실행체 격상"은 양립한다 — 레지스트리·샌드박스·페르소나 없이 lane·identity·lifecycle·관측만 격상하는 것이 D7의 목표다.

**Task FSM과 verdict 타입을 바꾸지 않는다.** `completion_verdict = Verdict_approved | Verdict_rejected of { reason }` 에 새 variant를 넣지 않는다. 거부 시 `AwaitingVerification → InProgress` 복귀도 유지한다 — 루프가 작동하는 모습이다.

## Decisions

### D1 — 판정 권한 전용 조회 표면 (읽기 전용)

새 모듈 `lib/verification_authority_tools.ml{,i}`. `Tool_shard.all_keeper_tool_schemas`를 재사용하지 **않는다.**

재사용이 오답인 이유는 취향이 아니라 배선이다. `tool_read_file` / `tool_search_files`는 `Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome`를 통해서만 도달 가능하고, 그것은 `~meta:keeper_meta`(약 30필드)를 요구한다. 판정자가 `keeper_meta`를 위조하면 — 기존 키퍼의 `.name`을 쓰는 순간 그 키퍼의 실제 playground에 대한 읽기·쓰기가 조용히 열린다. `meta`는 신뢰 입력이고 보통 키퍼 턴 루프만 공급한다. 이 경로를 타는 것이 곧 "판정자가 키퍼가 된다"이다.

대신 봉쇄 primitive를 직접 쓴다. 스냅샷을 뜰 때 쓰는 바로 그 코드다:

```
Fs_compat.load_owned_regular_file_range  ~ownership_root   (fs_compat.mli:274)
          owned_directory_paths          ~ownership_root   (:180)
          inspect_owned_directory_chain  ~ownership_root   (:165)
  거부 → Outside_ownership_root / Ownership_boundary_rejected
```

`ownership_root = Keeper_sandbox_config.host_root_abs_of_agent ~agent_name:producer` — `workspace_verification_store.ml:534`가 쓰는 것과 같은 값. 생산자별로 계산되어 판정마다 다르다. 새 격리 로직을 만들지 않는다(두 번째 진실을 만들지 않는다).

| 도구 | 기반 |
|---|---|
| `verification_read_file` | `Fs_compat.load_owned_regular_file_range` |
| `verification_list_dir` | `Fs_compat.owned_directory_paths` |
| `verification_search` | 같은 ownership_root 하위 순회 |
| `verification_git_log` / `verification_git_status` | `Repo_git` (인자 화이트리스트) |
| `verification_task_history` | 기존 task/event 조회 |

git은 기존 스키마가 없다 — `tool_read_file`/`tool_search_files`의 설명이 *"To list a directory, read a file, run find, or view git status/log/diff, use the Execute tool"* 라고 명시하고, `tool_execute`는 `mutating_tool`로 분류된다(`tool_catalog.ml:443-446`). 따라서 `tool_execute`를 경유하지 않고 `Repo_git`(`run_git`, `status_summary`, `get_recent_commits`) 위에 읽기 전용으로 새로 만든다. 허용 서브커맨드는 `log|status|show|diff|rev-parse|rev-list|cat-file`. 쓰기 서브커맨드는 파싱 단계에서 `Error` — 무시가 아니라 거부다(Silent Failure 금지).

쓰기·실행 도구는 넣지 않는다. 판정자가 고칠 수 있으면 거부 대신 수리를 택하고, 그 수리는 아무도 검증하지 않는다.

배선은 한 줄이다. `run_named_with_masc_tools`는 이미 `~masc_tools : tool_schema list`를 받고 `Tool_bridge.oas_tool_of_masc`로 임의 도구를 일반 변환한다(`keeper_turn_driver_wrappers.ml:172-181`). `anti_rationalization_reviewer_provider_config = without_response_format`이므로 structured output이 다중 턴 도구 사용을 막지 않는다.

### D2 — 스냅샷 유지, 라이브 조회 추가, 불일치는 판정 재료

제출 시점 materialization을 그대로 둔다. 스냅샷이 지키는 것은 감사다 — 승인 후 파일을 고쳐놓고 "판정자가 이걸 보고 승인했다"고 주장할 수 없게 한다. task-136에서 그 스냅샷은 승인 당시 내용의 유일한 사본이기도 하다.

라이브 조회는 *추가*다. 두 출처를 프롬프트에서 명시적으로 구분해 제시하고, **둘의 불일치 자체를 판정 재료로 삼는다.**

`config/prompts/verification.anti_rationalization.md`의 *"Inspectable proof exists only in the typed snapshot"* 는 도구가 생기면 거짓이 되므로 같은 변경에서 고친다. 새 지시의 골자: 스냅샷 = 제출 시점 사실, 라이브 = 현재 사실, 둘 다 증거. 스냅샷의 변경이 커밋되지 않았거나 현재 워킹트리에 없으면 그 사실을 판정에 반영한다.

### D3 — 판정 주체에 집계 가능한 축을 준다

`authority_actor`는 판정마다 새로 만들어진다 — durable verdict 이벤트 144건에 distinct actor 144개, 2건 이상 판정한 actor 0개. run은 식별하지만 아무것도 묶지 못한다.

**측정으로 축소된 결정.** 이 RFC의 초안은 `System_llm_agent`에 `profile` 필드를 추가하자고 썼다. 착수 전 verdict 이벤트의 필드를 열거해보니 축은 **이미 계산되고 있었고 투영에서만 버려지고 있었다** — `review_notes`가 `evaluator_runtime`을 만들지만 `authority_fields`가 싣지 않아 `task_activity` payload와 durable `task_completion_verdict` 양쪽에서 사라졌다.

그래서 하는 일은 투영 한 줄이다:

```ocaml
(* workspace_task_transitions.ml — authority_fields *)
@ (match evaluator_runtime with
   | None -> []
   | Some runtime -> [ "evaluator_runtime", `String runtime ])
```

`commit_verdict_r`가 `?evaluator_runtime`을 받고, 완료 권한은 판정된 verdict에 `Some`, 증거 계약 사전 거부에 `None`을 넘긴다 — 그 자리는 필수 라벨 `string option`이라 "판정자가 안 돌았다"가 침묵으로 흘러가지 않는다.

초안 대비 하지 않게 된 것: variant 확장, `keeper_event_queue` decode 경로 갱신, 과거 이벤트 마이그레이션 고민, 그리고 `profile`이라는 새 이름. `evaluator_runtime`은 이미 config `[runtime].cross_verifier`가 바인딩한 provider+model 키(`runtime.ml:1227`)이므로, 같은 문자열에 두 번째 이름을 붙이면 정보는 안 늘고 개념만 는다.

구현: #26964.

### D4 — 관측 record (실행 추상 아님)

RFC-0284 §2의 원칙을 그대로 계승한다: 실행 추상을 새로 만들지 않고, 판정이 끝난 뒤의 *사실*을 emit하고, 프론트엔드는 shape만 보고 렌더한다.

새 모듈 `lib/verification_run_registry.ml{,i}` — `Fusion_run_registry`와 동형. 영속도 같은 모양으로 `<base-path>/.masc/verification-runs.jsonl` 단일 append log + compaction(fusion은 `.masc/fusion-runs.jsonl`).

```
register_running ~verification_id ~task_id ~producer ~authority ~evaluator_runtime
mark_completed   ~verification_id ~outcome ~usage ~elapsed_s ~tool_calls
list_runs / get / run_to_yojson / replay / max_completed_retained
```

**거부·실패·defer도 기록한다** (RFC-0284 §E: 실패한 심판도 토큰을 태웠으면 관측 record에 비용을 남긴다). 기록 지점은 `commit_verdict`가 아니라 `process_task_once` — committed / deferred / contract-invalid 모든 종료 경로를 덮는다.

도구 호출 원본은 `Keeper_tool_call_log`(`.masc/tool_calls/YYYY-MM/DD.jsonl`)에 넣는다. 이름만 `Keeper_*`일 뿐 저장은 fleet 공용이고(`keeper_tool_call_log.ml:116`) `agent_name`은 귀속 문자열이므로 키퍼성이 필요 없다. blob 처리·절단·보존 정책을 그대로 쓴다. registry의 `tool_calls`는 요약만 갖고 원본은 이 로그를 가리킨다.

`?raw_trace`는 그냥 넘기지 않는다 — 그 경로는 `.masc/keepers/<keeper_name>/raw-traces/`로 키퍼 스코프다. 판정자는 키퍼 디렉토리가 없다. 도구 호출은 어차피 이 RFC가 만드는 `dispatch` 클로저를 통과하므로 거기서 기록한다. `?on_event`는 원시 provider SSE(`Agent_sdk.Types.sse_event`)이지 도메인 이벤트가 아니므로 관측 목적에 쓰지 않는다.

### D5 — 라이브러리안: 기존 journal 확장

라이브러리안은 판정자와 **다른 LLM 호출 경로**다. `Keeper_librarian_runtime`은 `Agent_sdk.Exact_output`이고 `Runtime_agent.run` 계열을 거치지 않는다 — `raw_trace`/`on_event`/`Turn_record`/`Trajectory`가 하나도 없다. D4의 배선을 재사용할 수 없다.

이미 있는 것: `.masc/keepers/<id>.memory-journal.jsonl` — `{recorded_at, revision, source:{kind; trace_id; generation}, change, dropped}`. 즉 **성공한 스냅샷 변경**의 출처는 기록된다.

없는 것: 실패 시 디스크 기록이 0이다(in-memory 카운터 + 로그 한 줄). 성공 기록에도 판단 입력이 없다.

새 저장소를 만들지 않고 그 journal을 확장한다:
1. 실패 경로에도 라인을 쓴다 — `change` 없이 `outcome=failed` + 실패 코드.
2. `source`에 판단 입력 요약을 추가 — Keeper instruction digest, 입력 message 수, 후보/유지/폐기 건수.

근거: #26729(librarian constraint가 운영자 지시를 덮음) 진단 시 결과 스냅샷만으로는 "왜 이 constraint가 생겼나"를 역추적할 수 없었다.

### D6 — 대시보드

`fusion-runs-panel` / `fusion-surface.ts` / `fusion-judge-format.ts` 구조를 따라 verification run 목록 + 상세를 추가한다. 기존 `verification-requests-panel.ts`가 *요청*을 보여주므로 그 옆에 *판정 실행*을 둔다.

`session-trace`를 재사용하지 않는다: `loadSessionTrace(agentName, isKeeper)`가 가져오는 3개 소스 중 `trajectory`와 `tool-calls`는 키퍼 전용 라우트이고 키가 **agent name**이다(`trace_id`는 서버가 키퍼의 현재 trace로 해석). 판정자는 키퍼가 아니고 이름도 매 판정마다 바뀐다. fusion-runs는 run id로 키잉하므로 맞는다.

라이브러리안은 웹 대시보드에 표면이 **아예 없다**. `dashboard.ml:115 format_librarian_status`는 CLI/MCP `masc_dashboard` 텍스트 렌더러이고, 노출하는 것은 `ON|OFF|INVALID` + fleet 전체 실패 카운터(재시작 시 리셋)뿐이다. D5의 journal을 읽는 read-only 뷰를 추가한다.

### D7 — Verifier의 keeper급 standalone 격상 (2026-08-19 개정)

**동기.** Constitution (PR #29140)은 Verifier를 "내부 Standalone LLM Agent"로 정의하고 keeper급 실행체를 요구한다. 현행 구현(`lib/completion_authority_agent.ml` — application-owned LLM agent, verdict는 LLM이 `lib/task/anti_rationalization.ml` 경유로 내림, evaluator runtime은 `[runtime].cross_verifier`)은 세 가지 점에서 그에 미달한다:

- **랜덤 actor.** `authority_actor`는 판정마다 `Random_id.prefixed ~prefix:"system-llm-agent-" ~bytes:16`으로 새로 태어난다(`completion_authority_agent.ml:461`). D3이 `evaluator_runtime` 투영으로 provider+model 축을 복구했지만 actor 축은 여전히 1회용이다 — 캘리브레이션·이력·감사를 계산할 모집단이 없다. D3의 관측 쿼리가 모을 "판정 주체" 집계가 영원히 74/74로 흩어진다.
- **무관리 fiber.** 판정 fiber는 keeper lifecycle 없이 돌고, 재시도는 fixed-interval maintenance pulse(`schedule_retry` / `retry_interval_sec`)다. 프로세스 restart 시 in-flight review의 fiber는 증발하고 남는 것은 `verification_run_registry`의 `running` 레코드뿐인데, 그것을 재개하는 주체가 없다. 완료 판정 — task 전이의 최종 게이트 — 의 증거가 restart 경계에서 단절된다.
- **관측 범위의 task 한정.** `verification_run_registry`는 task 전용이다. constitution이 요구하는 Goal Verifier가 판정을 시작하면 그 verdict는 registry 밖이다.

**"키퍼"와 "keeper급 standalone"의 구별.** Non-goal §2의 금지 다섯 가지(레지스트리 등록·자기 샌드박스·task action·heartbeat·페르소나 toml)는 전부 유지한다. keeper급 standalone은 그 다섯 가지 없이 실행체 특성만 갖는다: 전용 lane, 고정 identity, supervised lifecycle, 관측 레코드. 선례는 이미 repo에 있다 — `lib/exact_lane_run_registry.ml`의 Librarian·Hitl_auto_judge·Board_attention이 키퍼 등록 없이 `[runtime.exact_output_lanes.*]`의 frozen-order slot lane 위에서 실행된다.

결정 넷:

(a) **전용 exact-output lane `verifier_exact` 등록과 frozen-order slot failover.** `[runtime.exact_output_lanes.verifier_exact]`에 slots를 선언하고 판정 호출은 lane을 거쳐 선언 순서대로 failover한다. `[runtime].cross_verifier`의 단일 runtime 바인딩(`runtime.toml:17`)은 lane의 첫 슬롯으로 흡수하거나 lane이 참조하는 이름으로 남긴다 — 어느 쪽이든 provider 선택의 SSOT는 하나여야 하며, 구현 슬라이스에서 택한다. 고정 순서 failover는 Librarian과 같은 계약이다.

(b) **고정 authority identity.** `authority_actor`를 판정마다 랜덤이 아닌 고정 문자열(예: lane id와 같은 `verifier_exact`)로 바꾼다. run 식별은 기존 `verification_id`가 계속 맡고, actor는 집계·캘리브레이션·감사의 축이 된다.

(c) **Supervised lifecycle + restart 시 in-flight review 복구.** 판정 fiber를 supervisor 아래에 두고, 기동 시 `verification_run_registry`의 `running` 레코드를 스캔해 재개한다. 재개는 재실행이다 — 판정은 멱등(같은 스냅샷 + 라이브 조회를 다시 판정) — 하되 `verification_id`를 유지해 레코드의 연속성을 지킨다. fixed-interval retry는 유지하되 supervisor의 재시작 정책 아래로 통합한다.

(d) **관측 레코드의 goal verdict 확장 — 의존 명시.** Constitution의 Verifier는 task와 goal 양쪽을 판정한다. `verification_run_registry`를 goal verdict까지 커버하도록 확장할지는 **B1-B3 Goal Verifier 게이트 구현 결과에 따라 결정한다**: goal 판정이 `Completion_authority_agent` 경로를 타면 registry 확장, 별도 게이트면 별도 registry 또는 공통 스키마. 이 개정은 의존만 고정하고 선택은 미결로 남긴다.

**하지 않는 것 (Non-goal 재확인).** (a)–(d) 어디에도 키퍼 레지스트리 등록, `config/keepers/verifier.toml` 부활, heartbeat, 전용 샌드박스, task action이 없다. 커밋 `6df3c383`의 "A Keeper is not a verifier"는 유지된다.

## Sequencing

| # | 내용 | 상태 |
|---|---|---|
| 1 | D4 관측 record + registry (**도구 없이 먼저**) | #26931 |
| 2 | D6 대시보드 (verification run) | #26944 (머지, #26931 로 흡수) |
| 3 | D3 집계 축 — 투영 한 줄로 축소 | #26964 |
| 4 | D1 + D2 도구 표면 + 프롬프트 | 미착수 |
| 5 | D5 + D6 라이브러리안 journal + 뷰 | 미착수 |
| 6 | D7 (a) `verifier_exact` lane 등록 + frozen-order failover | 미착수 (B7 1단계) |
| 7 | D7 (b)(c) 고정 identity + supervised lifecycle + restart 복구 | 미착수 (B7 2단계) |
| 8 | D7 (d) goal verdict 관측 확장 | B1-B3 Goal Verifier 게이트 결과 대기 |

도구를 먼저 주면 관측 없이 감사 불가능한 판정자가 된다. record → 화면 → 축 → 도구 순으로, 도구가 켜지는 시점에는 이미 볼 수 있는 상태여야 한다. 6·7 단계는 이 순서와 무관하다 — lane과 lifecycle은 판정 표면이 아니라 실행체 배선이며, 기존 1·3단계의 관측(record + `evaluator_runtime` 축)이 이미 머지되어 있으므로 격상 후에도 record-first 원칙을 위반하지 않는다.

4·5 단계는 이 문서가 머지되는 시점에 착수하지 않았다. 특히 4 단계는 D2 의 미결 사항(스냅샷과 라이브 조회를 함께 줄 때 "제출 시점 immutable" 불변식을 어떻게 표현할지)을 먼저 정해야 한다.

## Verification

### 회귀 방지 (4단계 수용 기준)

task-136을 fixture로 고정한다. 레코드가 보존되어 있다:

```
.masc/verifications/vrf-24b43c36fc86a9f2e25763affa527f7d.json
  스냅샷 aria-* ×14 / 현재 워킹트리 ×0 / git log -S aria-label 빈 출력
```

도구를 받은 판정자가 이 입력에 REJECT를 내야 한다. **현재 코드로는 APPROVE가 나온다** — 이 테스트는 지금 실패해야 하고 4단계에서 통과해야 한다. 테스트가 실패할 능력을 먼저 증명한 뒤 수정한다.

### 봉쇄 테스트 (필수)

`test/test_verification_authority_tools.ml`:

- 생산자 playground 밖 절대경로 → `Outside_ownership_root`
- `../` traversal → 거부
- symlink 탈출 → 거부 (`Evidence_symbolic_link`와 같은 판정)
- git 쓰기 서브커맨드 → `Error` (silent no-op 아님)
- 다른 키퍼의 playground → 거부

### 관측

```bash
# 1단계: 판정 1건 후 record
tail -2 .masc/verification-runs.jsonl | jq .

# 3단계: profile 축이 모이는가 (현재는 74/74로 흩어짐)
rg -h task_completion_verdict .masc/events/**/*.jsonl \
  | jq -r 'select(.verdict) | .authority_profile // "none"' | sort | uniq -c
```

## Open

- 증거 참조 어휘(`artifact:` / `note:`) 확장은 이 RFC 범위 밖이다. 도구가 생기면 판정자가 note의 URL·SHA를 직접 열 수 있으므로, 타입 확장이 여전히 필요한지는 4단계 이후 실측으로 판단한다.
- 판정자에게 실행(테스트·빌드) 도구를 줄지는 열어둔다. "테스트가 통과한다"는 주장을 직접 확인할 수 있게 되지만 판정 비용·시간과 실행 격리 위치를 따로 결정해야 한다.
