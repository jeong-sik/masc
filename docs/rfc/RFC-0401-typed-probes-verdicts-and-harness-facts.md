---
rfc: "0401"
title: "Task 검증의 typed probe·verdict·harness fact — 제출 경계는 parse 사실만 거절하고, 판정자는 하네스가 잰 사실을 인용한다"
status: Draft
created: 2026-09-02
updated: 2026-09-02
author: claude (codex-mcp-client) + Vincent
supersedes: []
superseded_by: null
related: ["0337", "0387", "0398", "0400"]
---

# RFC-0401: Task 검증의 typed probe·verdict·harness fact

## 0. Summary

지금의 비동기 검증 경로는 그대로 둔다. `submit_for_verification` 이 Task 를
`AwaitingVerification` 으로 옮기고(`lib/workspace/workspace_task_transitions.ml:326`),
keeper 는 그 자리에서 풀려 다른 일을 집으며, 시스템 소유 판정 레인
(`lib/completion_authority_agent.ml`)이 판정하고, 거절은
`Completion_authority_rejected` 스티뮬러스(`lib/keeper_runtime/keeper_event_queue.mli:114`)로
producer keeper 에게 돌아온다. 새 Task 상태는 없다. 타임아웃 게이트도 없다.

이 위에 두 겹만 얹는다.

- **1겹, 제출 경계.** 제출 payload 의 *parse 사실* 만 거절한다. 모르는 probe id,
  중복 id, 선언한 probe 에 verdict 없음, enum 밖 상태, 근거 없는 `holds`/`does_not_hold`,
  빈 참조. 개수 하한은 두지 않는다. "일이 됐는가" 는 판정 레인의 몫이다.
  (RFC-0337 은 철회됐고 파일은 남아 있지 않지만, 그 결정 4 가 코드 주석으로 살아 있다:
  `lib/task/tool_task_completion_review.ml:8`, `lib/keeper/keeper_tool_task_runtime.ml:245`.)
- **2겹, 하네스 사실.** 검증 요청을 만들 때 시스템이 사실 셋을 계산해 요청 스냅샷에
  붙인다. 선언한 명령이 실제로 실행됐는가(`executions_matched`), 가리킨 코드 위치가
  pinned ref 에 존재하는가(`location_exists`), 체크아웃이 pinned ref 에서 얼마나
  벗어났는가(`pinned_ref_drift`). 판정자는 이 표를 받고, 판정문은 인용한 probe id 를
  typed 로 남긴다.

모델이 하는 일과 코드가 하는 일의 경계를 이렇게 긋는다. 문구를 읽고 분류하는 코드는
추가하지 않는다. 판정을 강제하는 프롬프트 문장도 추가하지 않는다.

## 1. 왜 지금인가 — 2026-09-02 실측

`~/me/.masc/verifications/vrf-*.json` 995건(Task 428개)과
`~/me/.masc/verification-runs.jsonl` 을 셌다.

| 항목 | 값 |
|---|---|
| done Task 262건 중 판정 2회 이상 | 94건, 36% (평균 1.93회) |
| 첫 제출이 읽힘 + 계약 있음 (n=116) | 평균 1.34회, 2회 이상 19% |
| 첫 제출이 읽힘 + 계약 없음 (n=120) | 평균 2.21회, 2회 이상 39% |
| 첫 제출이 못 읽힘 + 계약 있음 (n=7) | 평균 3.43회, 2회 이상 86% |
| 첫 제출이 못 읽힘 + 계약 없음 (n=19) | 평균 3.16회, 2회 이상 100% |
| artifact 참조 3,097건 중 판정 시점에 못 읽는 것 | 1,571건, 51% (missing 1,141 · invalid 424) |
| criteria 가 0개인 요청 | 557건, 56% |

기준선 파일은 `~/me/artifacts/evidence/keeper-brief-gates-20260902/` 에 있다
(`measure-baselines.py` 가 만든다).

- `brief-pinned-ref.json`: open Task 518개 중 38개가 제목·설명·노트에 커밋 해시를 글로 들고 있다
  (`git cat-file -t` 가 commit 이라 답한 것만 셌다).
- `tool-family-declared.json`: 지연 로딩 도구 30개 중 30개가 family 미선언.
- `judge-lane-readable-weekly.json`: 최근 7일 완료 판정 64건 중 47건에서 판정자의
  sandbox 읽기가 전부 실패했다. 이건 레인 가용성이고 이 RFC 범위 밖이다(Goal 0b).

**기대 효과는 상한이다.** 계약이 있고 증거가 읽히는 코호트의 2회 이상 비율이 19% 이므로,
전체 36% 가 그 근처로 내려가는 것이 이 설계가 줄 수 있는 최대치다. 상관이지 인과가
아니다. 실제 효과는 `goal-probe-tasks-live-20260902`(probe 가 있는 Task 의 승인 수)와
캠페인 점수판(Goal 0a, verification 밴드 k-of-3)으로만 잰다.

## 2. 타입

전부 닫힌 variant 다. `_ ->` 갈래를 두지 않는다.

### 2.1 Task contract — `pinned_ref` 와 `probes`

`lib/types/types_core.ml:462` 의 `task_contract` 는 지금
`strict; completion_contract; required_evidence; inspect_gate_evidence; verify_gate_evidence`
다. 두 필드를 더한다.

```ocaml
type pinned_ref = {
  repo_relative_path : string;  (* playground 안 체크아웃 경로 *)
  sha : string;                 (* 40자 commit *)
}

type location = { path : string; symbol : string option }

type probe = {
  id : string;
  where : location option;
  command : string list option;  (* argv, 셸 문자열 아님 *)
  question : string;
}

type task_contract = {
  ...기존 다섯 필드...
  pinned_ref : pinned_ref option; [@default None]
  probes : probe list;            [@default []]
}
```

`masc_add_task` 는 `pinned_ref` 가 오면 그 체크아웃에서
`git rev-parse --verify <sha>^{commit}` 을 돌려 존재를 확인하고, 없으면 typed error 로
거절한다. 제목·설명에 해시를 글로 적는 건 막지 않는다. 다만 브리프는 typed 한 것만
그리고, `goal-brief-pinned-ref-20260902` 가 글 속 해시 건수를 0 으로 내린다.

노출 위치는 `config/tools/masc_add_task.toml:52` 의 `contract` 블록이다.
`additional_properties = false` 라서 키를 더하지 않으면 파서가 버린다.

### 2.2 제출 — `verdict`

```ocaml
type verdict_state = Holds | Does_not_hold | Not_checked

type verdict = {
  probe_id : string;
  state : verdict_state;
  evidence : string list;  (* 기존 evidence_refs 와 같은 형식 *)
  note : string;
}
```

`submit_for_verification` 과 `keeper_task_done` 의 `handoff_context` 에 `verdicts` 를
싣는다. 제출 경계(1겹)가 거절하는 것은 다음뿐이다.

| 거절 | 이유 |
|---|---|
| 선언에 없는 `probe_id` | 참조 불가 |
| 같은 `probe_id` 둘 | 중복 |
| 선언한 probe 에 verdict 없음 | 빠짐 (`Not_checked` 로 채우면 통과) |
| enum 밖 `state` | parse 실패 |
| `Holds`/`Does_not_hold` 인데 `evidence` 비어 있음 | 근거 없는 단정 |
| 빈 참조, 해석 불가 참조 | 기존 `blank_evidence_ref`·`unresolvable_evidence_ref` (`lib/task/tool_task_completion_review.ml:13-36`) 그대로 |

`Not_checked` 는 언제나 받는다. 개수 하한은 없다. 내용은 보지 않는다. 지금
`parse_keeper_task_done_evidence_refs`(`lib/keeper/keeper_tool_task_runtime.ml:251`)가
하는 일과 같은 종류의 검사만 한다.

### 2.3 하네스 — `fact`

```ocaml
type drift = Keeper_sandbox_control.checkout_freshness  (* lib/keeper/keeper_sandbox_control.ml:259 *)

type fact = {
  probe_id : string;
  executions_matched : int;
  location_exists : bool option;   (* where 가 없으면 None *)
  pinned_ref_drift : drift option; (* pinned_ref 가 없으면 None *)
}
```

- `executions_matched`: probe 에 `command` 가 있으면, producer keeper 의
  `~/me/.masc/keepers/<k>/raw-traces/turn-*.jsonl` 에서 `Execute` tool_use 블록의
  `input.argv` 를 읽어 probe 의 argv 와 같은 것을 센다. 경로 파생은
  `lib/keeper/keeper_agent_run.ml:254`, 턴 기록과의 조인은
  `lib/types/turn_record.ml:84`(`execution_ids`) 와 `:104`(`raw_trace_run_ref`) 다.
  같음은 각 항목을 trim 한 뒤의 리스트 동등이다. 부분 일치·유사도는 없다.
  `keeper_chat` 은 operator 대화라 자율 턴의 인자가 없다. 그래서 쓰지 않는다.
- `location_exists`: `where.symbol` 이 있으면 pinned 체크아웃에서
  `rg -n --fixed-strings <symbol> <path>` 의 exit code, 없으면 `path` 존재 여부.
- `pinned_ref_drift`: 기존 `freshness_row`(`lib/keeper/keeper_sandbox_control.ml:463`)를
  `pinned_ref.sha` 기준으로 다시 계산한 값.

사실은 검증 요청(`lib/verification.mli:26` 의 `verification_request`)을 만드는
시점에 시스템이 계산해 요청 스냅샷에 저장한다. keeper 는 계산하지도 제출하지도 않는다.

`confidence` 와 `severity` 는 두지 않는다. 일곱 하네스 조사에서 Codex·Claude Code·
Antigravity 가 자가 보고 confidence 를 모으지만 게이트로 쓰는 곳은 없었다.

## 3. 판정 쪽

- `config/prompts/verification.md` 에 템플릿 변수 `{{harness_facts_section}}` 를 더한다.
  지금 변수 목록은 파일 5행의 `template_variables` 에 있다. 프롬프트 자산은 세 자리에
  등록해야 부팅 sync 가 돈다: md 파일, 프롬프트 이름 목록, managed-assets manifest
  (`lib/managed_asset_sync.ml:16`). `test/test_prompt_templates_render.ml` 이 새 변수를
  검증한다.
- 표에는 probe 마다 `executions_matched`·`location_exists`·`pinned_ref_drift` 를 그린다.
  "이 사실을 인용하라" 는 문장은 여기 한 곳에만 적는다. 강제는 아래 스키마가 한다.
- `report_review_verdict` 의 JSON 스키마(`lib/task/anti_rationalization.ml:206`, 정확히
  한 번 호출은 `lib/workspace_metric_hooks.ml:348`)에 `cited_facts : string list`
  (probe id)를 더한다. 사실 표가 비어 있지 않은데 `cited_facts` 가 비면 그 호출은
  verdict 가 아니다. 요청은 열린 채로 남고 판정 레인의 기존 재시도가 다시 돈다.
  새 상태는 없다.
- `completion_authority_rejection`(`lib/keeper_runtime/keeper_event_queue.mli:271`)은
  지금 `car_task_id; car_verification_id; car_reason; car_authority` 다. 여기에
  `car_cited_facts : string list` 를 더해 producer keeper 가 어떤 사실이 걸렸는지
  글이 아니라 id 로 받는다.

## 4. 스필 — 잘린 증거 대신 파일

지금 `truncated=true` artifact 는 쓸 수 없는 증거다(`lib/verification_protocol.ml:104`,
`Workspace_verification_store.truncated_snapshot_items`,
`lib/workspace/workspace_verification_store.mli:66`). `keeper_task_done` 경계의
총 바이트 사전 검사(`lib/keeper/keeper_tool_task_runtime.ml:293`, task-540)가 큰
artifact 를 거절한다.

바꾼다. 상한을 넘는 증거는 잘린 앞부분 대신 검증 저장소 아래 스필 파일에 통째로
쓰고, 스냅샷은 `{ spilled_path; bytes; sha256 }` 를 든다. 판정자는 `tool_read_file` 로
그 파일의 구간을 읽는다. 판정자에게 주는 도구는 지금 셋이다
(`lib/verification_authority_tools.ml:13-15`: `tool_read_file`, `tool_search_files`,
`masc_web_fetch`). `goal-verification-input-spills-20260902` 가
`truncated_evidence_count` 를 0 으로 잰다.

## 5. 브리프 렌더 — 안정 접두사를 깨지 않는다

`pinned_ref` 와 `probes` 는 휘발 밴드에만 그린다. `Repository_freshness` 레이어
(`lib/keeper/keeper_unified_prompt.ml:1488`)와 같은 자리다. 안정 접두사에는 넣지
않는다. `goal-brief-keeps-prefix-20260902` 가 keeper 별 캐시 적중 중앙값이
도입 전 7일 값 아래로 내려가지 않는지 본다(기준선: rondo .35, sangsu .32,
code-reviewer .39, 캐시를 보고하지 않는 다섯 keeper 는 0).

## 6. 열린 결정 — Vincent 결정 대기

1. **`executions_matched = 0` 인데 `Does_not_hold` 를 어디서 거절하나.**
   기본안은 판정 레인이 사실을 인용해 거절한다(1겹은 parse 만 본다는 위계 유지).
   대안은 제출 경계의 typed 거절이다. 더 빠르지만, 하네스가 "일에 대한 판단" 을
   하는 첫 사례가 된다.
2. **`probes` 를 `masc_add_task` 에서 required 로 둘 것인가.**
   optional 로 시작한다. `goal-probe-tasks-live-20260902` 가 probe 있는 Task 의
   승인 10건에 닿으면 그때 다시 본다.

## 7. 하지 않는 것

- 결정론적 게이트를 프롬프트 문장으로 강제하지 않는다.
- 도구 문구나 verdict 문장을 substring 으로 분류하지 않는다.
- 턴당 예산 상한, cooldown, dedup 을 넣지 않는다.
- 새 Task 상태를 만들지 않는다.
- 타임아웃을 게이트로 쓰지 않는다. keeper 는 판정을 기다리지 않는다.

## 8. 순서와 닫히는 Goal

| 단계 | 내용 | Goal |
|---|---|---|
| 1 | 이 RFC. verdict 스키마 테스트 `test/test_verification_verdict_schema.exe` | `goal-verdict-enum-schema-20260902` |
| 2 | `location_exists` 사실 (읽기만, 제출을 막지 않음) | `goal-verdict-location-exists-20260902` |
| 3 | `executions_matched` 사실 (raw-traces 조인) | `goal-verdict-executed-command-20260902` |
| 4 | 판정 프롬프트 사실 표 + `cited_facts` | `goal-authority-cites-facts-20260902` |
| 5 | 스필 | `goal-verification-input-spills-20260902` |
| 6 | fleet 에 probe Task 하나부터 10건 | `goal-probe-tasks-live-20260902` |
| 병렬 | `pinned_ref` + `masc_add_task` 존재 확인 | `goal-brief-pinned-ref-20260902` |
| 병렬 | 렌더가 휘발 밴드에만 닿는지 테스트 | `goal-brief-keeps-prefix-20260902` |

계획 문서: https://claude.ai/code/artifact/90162b81-3298-473f-824b-9588e49598a3
일곱 하네스 조사: https://claude.ai/code/artifact/ded25623-da52-4d73-8925-9ad982a024d4
masc task-1236 · goal-verdict-enum-schema-20260902
