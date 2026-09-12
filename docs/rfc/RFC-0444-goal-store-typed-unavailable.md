---
rfc: "0444"
title: "goal store 를 못 읽으면 빈 목록이 아니라 typed 상태다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0420", "0352", "0362", "0387", "0044"]
implementation_prs: []
---

# RFC-0444: goal store 를 못 읽으면 빈 목록이 아니라 typed 상태다 (goal-store-typed-unavailable)

## 0. Summary

`goals.json` 을 이 build 가 못 읽으면 지금은 `Goal_store.read_state` 가 `default_state ()` 를 돌려준다. 못 읽는 store 가 "goal 0개" 로 보인다. 2026-09-08 하드컷(#34459) 뒤 97개 goal 이 7시간 29분 동안 모든 화면에서 비어 보였고, 운영자가 손으로 리셋해 G1 goal 이 영구히 사라졌다(B1).

이 RFC 는 세 가지를 정한다.

- goal store 읽기는 하나의 닫힌 합 `Goal_store.source` 로만 나온다. 빈 상태는 파일이 둘 다 없을 때 하나뿐이다.
- 부팅은 계속된다. 못 읽으면 `Unavailable` 값이 생기고, 모든 소비자(MCP tool, dashboard, TUI, keeper 프롬프트, verifier)가 그 값을 그대로 보여준다. goal 쓰기는 전부 거부된다.
- 읽기는 파일을 건드리지 않는다. 리셋은 운영자가 명시적으로 부르는 별도 명령이고, 옮기기만 하고 지우지 않는다. goal 스키마를 하드컷하는 PR 은 이 리셋 단계를 같은 PR 에 싣는다.

기존 RFC 와의 관계.

- **RFC-0420 을 확장한다.** 0420 은 keeper meta·memory current 두 store 에 대해 "못 읽으면 부팅 거부" 다. 이 RFC 는 store 별 부팅 정책을 `Refuse_boot | Degrade_typed` 두 갈래로 나누고, goal store 를 `Degrade_typed` 로 둔다. 어느 store 가 어느 갈래인지는 §2.4 의 표가 정하고, 부팅 코드는 그 표를 읽을 뿐 스스로 판단하지 않는다. 0420 의 examine/quarantine 분리와 `--accept-store-quarantine` 플래그는 그대로다. 그 플래그는 goal store 에 아무 효과가 없다.
- **RFC-0352 를 따른다.** goal 은 1급 엔티티이고 옛 shape 를 읽는 코드는 만들지 않는다. 이 RFC 도 마이그레이션·호환 reader 를 만들지 않는다.
- **RFC-0362 와 겹치지 않는다.** 0362 는 goal 의 owner 와 intake 를 다룬다. store 가 `Unavailable` 이면 intake 도 같은 값을 본다는 것 외에 건드리는 것이 없다.
- **RFC-0387 을 좁힌다.** 0387 의 verifier 는 `list_goals_result` 로 이미 typed 로 읽는다. 이 RFC 는 그 결과가 `Unavailable` 일 때 verifier 가 무엇을 기록하는지(§2.3 항목 7)를 정한다.

## 1. 배경 (실측)

- #34459(12e13e8d34, 2026-09-08T16:20:13Z 머지)가 `goal_of_yojson` 에 `criterion_revision` 필수 필드를 넣었다. 기존 97개 goal 전부가 이 필드가 없어 디코드에 실패했다. `.last-good` 은 같은 shape 의 복사본이라 같이 실패했다.
- 16:41:27Z 부팅부터 `read_state` 가 `Undecodable _ -> default_state ()` 로 접었다. dashboard(`dashboard_goals.ml` 당시 `list_goals` 호출), keeper 프롬프트, TUI, goal verifier 가 전부 goal 0개를 봤다. 대시보드 Work 페이지는 `활성 목표 0 · 정상 순환` 이었다(docs/audits/goal-source-availability-20260909.md).
- 로그에는 `goal_store: both primary and recovery goals.json corrupt (primary: goal_of_yojson: criterion_revision must be a non-blank string, …)` ERROR 가 1,557줄(2026-09-08T16:41:30Z..2026-09-09T00:10:29Z, 중앙 간격 10초). 읽을 때마다 한 줄이라 줄 수가 곧 읽기 횟수다. 운영자 화면에는 아무 신호도 없었다.
- #34485(18:22:38Z)가 `list_goals_result` 를 넣어 `masc_goal_list` 가 오류를 내기 시작했다. 09-09T00:24:16Z internal_error, 00:25:29Z count=97, 00:28:29Z count=41, 01:18:43Z count=0. 운영자가 손으로 고치다 리셋했고 `goal-reliable-change-g1-20260909` 를 포함한 97개가 사라졌다. `goal_events.jsonl` 은 0바이트(mtime 01:17:56Z). task-1478 은 goal 없는 고아가 됐다.
- 리셋 안내(#34614 09-09T01:04:19Z, #34624 02:42:28Z)는 리셋이 끝난 뒤에 머지됐다.
- 지금 main(e763050689)에도 접는 경로가 남아 있다. `lib/goal/goal_store.ml:320-323 read_state` → `default_state ()`, `:438-439 get_goal`, `:551 list_goals`. `lib/workspace_goals.ml:723-725 handle_goal_transition` 이 `get_goal` 을 거쳐 손상된 store 에 `Not_found "goal not found"` 로 답한다(S5). 그 창에서 `goal not found` 는 0줄이라 아직 터지지 않았을 뿐이다.
- 부팅 코드는 `goals.json` 을 읽지 않는다(`server_bootstrap_loops.ml`, `keeper_store_boot_reconcile.ml`, `deployment_preflight_helper.ml validate-stores` 모두 `Goal_store` 호출 0건). 못 읽는 store 는 첫 소비자 읽기에서 처음 드러난다.

## 2. 설계

### 2.1 읽기 결과는 하나의 닫힌 합이다

```ocaml
(* lib/goal/goal_store.ml — 유일한 reader. read_state / get_goal / list_goals / load_state 는 지운다. *)
type source =
  | Uninitialized                       (* goals.json 도 .last-good 도 없다. 유일한 정당한 빈 상태 *)
  | Available of state                  (* goals.json 이 디코드됐다. 미러는 읽기에 관여하지 않는다 *)
  | Unavailable of unavailable

and unavailable =
  { file : string                       (* goals_path config *)
  ; reason : reason
  ; mirror : mirror_status              (* 같은 시점의 .last-good 상태. 서빙하지 않고 보여만 준다 *)
  ; reset_step : reset_step }

and reason =
  | Missing_after_init                  (* primary 없음, .last-good 있음 *)
  | Unreadable of Unix.error            (* open/read 실패. EACCES·EISDIR·EIO 가 각각 남는다 *)
  | Not_json of string                  (* 바이트가 JSON 이 아니다 *)
  | Schema_rejected of { field : string; detail : string }   (* JSON 이지만 이 build 의 디코더가 거절 *)

and mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_decodes of { goal_count : int; updated_at : string }  (* primary 와 어긋난 증거 *)
  | Mirror_rejected of reason

and reset_step =
  | Repair_field of string              (* Schema_rejected: 어느 필드를 채우면 다시 읽히는지 *)
  | Reset_goal_store                    (* masc goals reset --base-path <p> 를 부른다 *)
  | Restore_permission                  (* Unreadable EACCES *)

val load_source : Workspace.config -> source
type lookup = Goal_found of goal | Goal_absent | Store_unavailable of unavailable
val find_goal : Workspace.config -> goal_id:string -> lookup
```

Codex 가 요구한 여섯 조건은 이렇게 갈린다. 미초기화 = `Uninitialized`(두 파일 다 없음). 초기화 뒤 사라짐 = `Missing_after_init`. 스키마 불일치 = `Schema_rejected`(필드 이름 포함). 깨진 바이트 = `Not_json`. 권한 = `Unreadable EACCES`. primary·mirror 불일치 = `Unavailable` 안의 `Mirror_decodes`. 지금 `load_state` 가 하는 "primary 가 깨지면 mirror 로 읽는다" 는 없어진다. mirror 는 `authoritative_read_only` 대로 읽기도 쓰기도 허가하지 않는다.

`load_source` 는 파일을 열고 읽기만 한다. rename·write·삭제를 하지 않고 로그도 찍지 않는다. 로그는 §2.3 의 두 곳만 찍는다.

### 2.2 쓰기

`update_state`·`transact_goal`·`update_goal_if_phase`·`delete_goal`·`with_existing_goals` 는 지금처럼 `with_file_lock` 아래에서 `load_source` 를 부른다. `Unavailable u` 면 `Error (Store_unavailable u)` 로 거부하고 파일을 건드리지 않는다. `Uninitialized` 일 때만 첫 쓰기가 파일을 만든다. 빈 상태를 미리 써 두는 부팅 코드는 없다. 동시 writer 는 같은 lock 을 잡으므로 "한쪽은 Unavailable 을 보고 다른 쪽은 쓴다" 가 생기지 않는다.

### 2.3 producer → store → consumer → caller

| # | consumer (file:function) | 지금 | 이 RFC 뒤 |
|---|---|---|---|
| 1 | `workspace_goals.ml:handle_goal_list` → MCP `masc_goal_list` | `Internal_error` + 문장 | typed code `Unavailable`. 결과 JSON: `ok:false, error_code:"goal_store_unavailable", reason:<생성자 이름>, field, file, mirror:{status,goal_count}, reset_step` |
| 2 | `workspace_goals.ml:723 handle_goal_transition` → `masc_goal_transition` | `get_goal` → `Not_found` | `find_goal` 로. `Store_unavailable` 은 `Unavailable`, `Goal_absent` 만 `Not_found` |
| 3 | `handle_goal_upsert`, `goal_store.ml:497 delete_goal`(소비자 `server_dashboard_http_delete_actions.ml:980`), `server_routes_http_routes_verification.ml:179` proof 커밋, `task_goal_assignment.ml` 의 goal_ids 검증 | upsert·proof·배정은 문장 오류. `delete_goal` 은 못 읽는 store 를 `Persistence_failed (undecodable_store_error …)` 문자열로 접는다(`:501`) | 같은 `Unavailable` 값. `delete_goal_error` 에 `Store_unavailable of unavailable` 팔을 추가하고 `:501` 의 문자열 팔을 지운다. `workspace_task_create.ml:Goal_source_unavailable` 은 이 값을 싣는다 |
| 4 | `dashboard_goals.ml:goal_store_unavailable_json`, `server_dashboard_http.ml:574`, `dashboard_http_keeper.ml:744` | `ok:false, error_code, error` | 1번과 같은 봉투. `dashboard/src/api/dashboard-goals.ts goalStoreUnavailableDetail` 은 문자열이 아니라 `{kind:'unavailable', reason, field, file, mirror, resetStep}` 합으로 파싱. `goal-tree.ts` 는 `role="alert"` 블록에 file·reason·reset step 을 그리고 `goal-create-form` 의 제출을 비활성화한다 |
| 5 | `tui_decode.ml:5307 decode_planning_snapshot`, `:9167 decode_goal_detail_timeline` | 봉투를 `Error detail` 문자열로 접어 `state.planning_error` 한 줄 | `Planning_unavailable of unavailable_view \| Planning of snapshot`. Planning pane 본문에 file·reason·reset step 을 그린다. 헤더 배지는 `refresh failed` 와 다른 글자를 쓴다 |
| 6 | `keeper_world_observation.ml:1527 open_goal_ids`, `keeper_unified_prompt.ml:1259 active_goal_summaries_for_task`, `:1529 Active_goals layer`, `keeper_unified_metrics_decision.ml:184 active_goals_source` | `Error string` → `keeper_world_active_goals_unavailable` fragment | 같은 fragment 에 reason·file 을 싣는다. 이 층은 프롬프트 렌더링이라 문자열이 종착지다. keeper 가 부르는 goal 도구는 1~3번의 typed 거부를 받는다 |
| 7 | `goal_verification_agent.ml:63 collect_pending` | `Error _` 를 그대로 반환, 사이클 종료 | `Scan_skipped of unavailable` 을 verification-runs 표면(`dashboard/src/api/dashboard-goal-verification-runs.ts`)에 durable 행으로 남기고 WARN 한 줄. 줄 수 = 스캔 수 |
| 8 | 부팅 `keeper_store_boot_reconcile.ml:examine` | goal store 를 안 본다 | `Goal_store.load_source` 를 한 번 부른다. `Unavailable` 이면 INFO 한 줄 `goal_store: unavailable reason=<ctor> file=<path> mirror=<status> reset=<step>`. 거부·격리·플래그 없음 |

board 모듈과 스케줄러는 `Goal_store` 를 부르지 않는다(rg 0건). board 에는 새 글이 생기지 않는다.

### 2.4 어느 store 가 거부하고 어느 store 가 degraded 인가

| store | 정책 | 이유 |
|---|---|---|
| keeper meta | `Refuse_boot` (0420) | 없으면 keeper 가 뜨지 않거나 다른 keeper 로 뜬다 |
| memory current | `Refuse_boot` (0420) | 없으면 keeper 가 빈 기억으로 돌면서 새 기억을 써 손실을 덮는다 |
| goal store | `Degrade_typed` (이 RFC) | goal 없이도 task·board·schedule 로 keeper 가 돈다. 쓰기가 전부 거부되므로 덮어쓰기가 없다 |

규칙은 하나다. **읽기 실패를 모든 소비자가 typed 로 보여주고 모든 쓰기를 거부할 수 있는 store 만 `Degrade_typed` 가 된다.** 둘 중 하나라도 못 하면 `Refuse_boot` 다. 정책은 `Keeper_store_boot_reconcile.policy : store -> boot_policy` 의 exhaustive match 한 곳에 적힌다. 새 store 를 넣으면 컴파일러가 이 표를 채우라고 한다.

### 2.5 남는 것과 막히는 것

- **남는다**: keeper 턴 진입, task 생성·claim·전이(goal_ids 없는 것), board, schedule, HITL, task verifier, keeper 시작·중지. Active_goals 층은 unavailable fragment 로 렌더된다. 턴 진입은 goal 을 읽지 않으므로 dispatch 결정에 goal store 가 끼지 않는다.
- **막힌다(typed 거부)**: `masc_goal_upsert`·`masc_goal_transition`·goal 삭제, goal_ids 를 가진 task 생성·배정, goal proof 판정 커밋, goal verifier 스캔(skip 기록), goal 에 연결된 task 완료의 goal 반영(`reconcile_committed_proof`). task 자체의 전이는 막히지 않는다.

### 2.6 리셋

읽기는 파일을 절대 옮기지 않는다. 리셋은 `masc goals reset --base-path <p>` 명령 하나다.

1. lock 을 잡고 `load_source` 를 다시 부른다. `Available` 이면 거부한다(멀쩡한 store 는 리셋하지 않는다).
2. `goals.json`, `goals.json.last-good`, `goal_events.jsonl`, `goal_verifications.json` 네 파일을 `<name>.rejected-<ts>` 로 옮긴다(0420 §8 의 이름 규칙). 지우지 않는다. 옮기기 전후 digest 를 출력한다.
3. backlog 의 task 중 `goal_ids` 가 비어 있지 않은 task 수와 id 를 출력한다. 리셋 뒤 이 링크는 전부 고아다. 링크는 지우지 않고 task detail 과 goal tree 가 `Goal_link_orphaned` 로 그린다. 고아 수는 `masc_goal_list` 의 `Uninitialized` 응답에도 실린다.
4. 끝나면 `load_source` 가 `Uninitialized` 를 돌려준다. 옮긴 파일을 읽는 코드는 없다.

### 2.7 하드컷 PR 의 자격

`goal_of_yojson`·`state_of_yojson` 이 전에 받던 row 를 거절하게 바꾸는 PR 은 같은 PR 에 다음을 싣는다.

- `Schema_rejected` 가 낼 `field` 와 `reset_step` (`Repair_field` 인지 `Reset_goal_store` 인지).
- 운영자 소유 파일 네 개(`goals.json`, `goals.json.last-good`, `goal_events.jsonl`, `goal_verifications.json`) 각각에 대해 이 하드컷이 읽기를 바꾸는지, 바꾸면 어느 생성자로 떨어지는지. 네 파일은 §2.6 의 리셋 범위와 같은 목록이다.
- 하드컷이 닿는 소비자 목록. §2.3 의 여덟 행 중 어느 행의 출력이 달라지는지 적는다.
- CHANGELOG "Fresh state required" 항목(#34624 가 만든 절).
- 하드컷 전 fixture 로 부팅해 §3 의 1·6·7 을 통과하는 테스트. fixture 에는 `Goal_phase.t` 의 모든 생성자에 있는 goal 이 하나 이상 들어간다. 한 phase 에서만 읽히고 다른 phase 에서 거절되는 하드컷도 `Schema_rejected` 로 잡혀야 한다. fixture 는 운영자가 손으로 고친 파일도 포함한다(97→41 사례). 손으로 고친 바이트는 다른 바이트와 똑같이 strict 로 읽고 특별한 경로가 없다.
- 두 번 부팅해도 파일 digest 가 같다는 테스트. 부팅은 goal 파일을 쓰지 않는다.

## 3. 판정 기준

1. `criterion_revision` 없는 97개 goal fixture 를 base path 에 두고 부팅하면 `masc_goal_list` 는 `ok:false, error_code:"goal_store_unavailable", reason:"schema_rejected", field:"criterion_revision"` 을 준다. `goals:[]` 는 어떤 응답에도 없다.
2. `rg -n 'let read_state|let get_goal |let list_goals |let load_state' lib/goal/goal_store.ml` 가 0줄. `rg -n 'default_state ()' lib/goal/goal_store.ml` 는 `Uninitialized` 첫 쓰기 한 곳만.
3. 못 읽는 store 로 1시간 돌리면 `rg -c 'goal_store: both primary and recovery' <system_log>` 가 0. `goal_store: unavailable` 줄 수 = 부팅 수, `goal verifier scan skipped` 줄 수 = 스캔 수.
4. `masc_goal_transition` 은 못 읽는 store 에 code `Unavailable`, 멀쩡한 store 의 없는 id 에 `Not_found`. 두 테스트가 각각 있다.
5. `Unavailable` 상태에서 upsert·transition·delete·goal_ids 있는 task 생성을 부르면 전부 거부되고 `goals.json` 과 `.last-good` 의 sha256 이 호출 전후 같다.
6. `masc goals reset` 뒤 `.rejected-<ts>` 네 파일의 digest 가 원본과 같고, `load_source` 가 `Uninitialized`, 첫 upsert 뒤 `Available` 에 goal 1개. 출력된 고아 task 수 = backlog 에서 goal_ids 가 비어 있지 않은 task 수.
7. 못 읽는 store 로 두 번 부팅하면 `/health` 200 이고 두 부팅 사이 goal 파일 digest 가 같다. `/api/v1/dashboard/planning` 봉투에 reason·file·reset_step 이 있다.
8. TUI PTY 시나리오: Planning pane 본문에 reset step 문구가 있다. 헤더가 아니라 pane 에서 찾는다.
9. `dashboard/src/api/dashboard-goals.test.ts` 가 봉투를 합으로 파싱하고, `goal-tree.test.ts` 가 alert 블록과 비활성화된 create form 을 확인한다.

## 4. 단계

- **PR-1 store**: §2.1 타입, `load_source`·`find_goal`, 접는 reader 4개 삭제, 쓰기 거부 typed. 여섯 조건 + mirror 네 상태 테스트. (판정 2·5)
- **PR-2 MCP**: `Unavailable` code, list·transition·upsert·delete 봉투, task 생성 매핑. (판정 1·4)
- **PR-3 dashboard**: OCaml 봉투 확장 + TS 합 파싱 + alert + form 비활성화. (판정 7·9)
- **PR-4 TUI**: `Planning_unavailable` + pane 렌더 + PTY 시나리오. (판정 8)
- **PR-5 keeper·verifier**: observation·prompt·metrics 에 reason 싣기, verifier `Scan_skipped` durable 행. (판정 3 후반)
- **PR-6 boot**: `policy` 표, examine 에 goal store, INFO 한 줄. (판정 3 전반·7)
- **PR-7 reset**: `masc goals reset`, 고아 보고, `Goal_link_orphaned` 렌더, CONTRIBUTING 하드컷 체크리스트. (판정 6)

## 5. 반론과 답

- **Codex: "list 에만 typed 오류를 두면 다른 소비자는 여전히 빈 상태로 일을 승인한다. 리셋 절차만 두면 증거 파괴가 가장 쉬운 복구가 된다."** reader 가 하나뿐이고 접는 reader 는 지운다. 빈 목록에 닿는 경로가 코드에 없으므로 소비자가 빠지면 컴파일이 실패한다. 리셋은 읽기와 분리된 별도 명령이고 옮기기만 한다. 아무것도 안 하는 것이 가장 쉬운 길이고, 그 길에서는 바이트가 그 자리에 남고 쓰기가 막혀 있어 기다리는 데 비용이 없다.
- **"0420 처럼 부팅을 거부하면 더 단순하다."** goal 이 없어도 keeper 는 돈다. 거부하면 goal 파일 하나 때문에 fleet 전체가 서고, 운영자는 부팅을 위해 리셋을 서두른다. 09-09 의 손실이 그 순서였다. §2.4 의 규칙이 두 정책의 경계다.
- **"mirror 가 읽히면 그걸 서빙하면 되지 않나."** `write_state_result` 는 primary 를 쓴 뒤 mirror 를 쓰고 mirror 실패는 WARN 이다. mirror 는 뒤처질 수 있다. 서빙하면 primary 가 깨진 사실이 사라진다. 보여주되 서빙하지 않는다.
- **헌법 forbidden.** `magic_number`: 숫자 임계 없음. `string_matching`: 분기는 전부 variant, wire 의 생성자 이름은 TS union·`Tui_decode` variant 로 exact 파싱. `budget_gate`: 횟수·시간으로 막는 것 없음. `greedy_shortcut`: 빈 fallback 을 지우는 것이 이 RFC 의 본체. `hardcoded_path`: 경로는 `goals_path config` 하나. `env_var_sprawl`: 새 env 없음, 0420 처럼 플래그도 없음. `legacy_residue`: 옛 shape reader 없음, 옮긴 파일을 읽는 코드 없음.
- **헌법 invariants.** `closed_sum_over_string`: §2.1. `strict_parse_no_default`: `Uninitialized` 는 파일이 둘 다 없을 때만. `failure_keeps_evidence`: 읽기는 파일을 안 건드리고 리셋은 옮긴다. `authoritative_read_only`: mirror 로 읽기·쓰기를 허가하지 않는다.
- **Codex `rfc_must_pin_down` 다섯 항목이 어디에 답해졌는가.** (1) 여섯 조건의 구분 → §2.1 의 `reason`·`mirror_status`·`Uninitialized`. (2) list·lookup·transition·verifier·scheduler·keeper·TUI·dashboard 의 빈 fallback 과 문자열 not-found 제거 → §2.3 의 여덟 행. scheduler 와 board 는 `Goal_store` 를 부르지 않아 행이 없다. (3) 남는 것과 막히는 것 → §2.5. (4) 바이트 보존·리셋 범위·고아 링크·호환 reader 없는 readback → §2.6 과 판정 6. (5) 하드컷 자격, 운영자 파일, phase 별 fixture, 반복 부팅, 동시 writer → §2.7 과 바로 아래 항목.
- **"반복 부팅·동시 writer 는?"** 부팅은 goal 파일을 쓰지 않으므로 N 번 부팅해도 digest 가 같다(판정 7). 쓰기와 리셋은 같은 `with_file_lock` 아래에서 `load_source` 를 다시 보므로 한쪽이 `Unavailable` 을 본 사이 다른 쪽이 쓰는 일이 없다(§2.2).

## 6. 근거

- 손실 창: `goal_store: both primary and recovery goals.json corrupt` ERROR 1,557줄, 2026-09-08T16:41:30Z..2026-09-09T00:10:29Z, 중앙 간격 10초. 영향 goal 97개, 7시간 29분. MCP 로그 count 97 → 41 → 0 (00:25:29Z / 00:28:29Z / 01:18:43Z). `goal_events.jsonl` 0B (01:17:56Z).
- 머지 시각: #34459 12e13e8d34 2026-09-08T16:20:13Z, #34485 86ab85b5e0 18:22:38Z, #34614 278eea6e50 2026-09-09T01:04:19Z, #34624 7f1e095be4 02:42:28Z.
- finding: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/merged.md` B1(714행), S5(277행). 종합: 같은 디렉터리 `synthesis-adversarial.md` §1 첫 행, §3 패턴 2. Codex 검토: `codex-roadmap.json` decision_critiques[3], rfc_order 1번.
- 결정: `~/.claude/projects/-Users-dancer-me-workspace-yousleepwhen-masc/memory/masc-runtime-decisions-2026-09-12.md` 4번.
- 코드(main e763050689): `lib/goal/goal_store.ml` `load_state`(243-316), `read_state`(320-323), `load_primary_state`(392-402), `get_goal`(438), `list_goals`(551), `list_goals_result`(560), `write_state_result`(354). `lib/workspace_goals.ml:723` `handle_goal_transition`. typed 소비자: `dashboard_goals.ml:182,273`, `keeper_unified_prompt.ml:1293,1529`, `keeper_world_observation.ml:1528`, `goal_verification_agent.ml:63`, `keeper_unified_metrics_decision.ml:184`, `tui_decode.ml:5301,9167`, `dashboard/src/api/dashboard-goals.ts:26`. `lib/workspace_goals.ml` 의 `Goal_store.` 호출 43곳.
- 이전 감사: `docs/audits/goal-source-availability-20260909.md` (남은 소비자 목록, 네 가지 source 조건).
