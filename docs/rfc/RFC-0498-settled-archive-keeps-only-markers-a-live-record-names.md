---
rfc: "0498"
title: "settled 보관 위치는 살아 있는 기록이 가리키는 표시만 남기고, 본문과 원본 없는 Exact 기록은 지운다"
status: Draft
created: 2026-11-06
updated: 2026-11-10
author: claude
supersedes: []
superseded_by: null
related: ["librarian-history-settles-finished-originals", "workspace-curator-originals-name-ledger-revisions", "0497"]
---

# RFC-0498: settled 보관 위치는 살아 있는 기록이 가리키는 표시만 남기고, 본문과 원본 없는 Exact 기록은 지운다

- 상태: 초안
- 이슈: #48946
- 근거: §2 의 수치는 2026-11-06 04시(KST) 운영 workspace 에서 쟀다. 보관 위치는 파일 이름과 크기만 셌다. 살아 있는 기록은 문자열 값 중 요청 ID 모양인 것만 뽑아 digest 를 비교했다. 요청 본문은 열지 않았다. §3 의 코드는 `origin/main` `f2d98655513` 이다.
- 앞선 문서: RFC "librarian-history-settles-finished-originals" 는 보관 위치를 만들고 정리 규칙을 Q3 으로 미뤘다. RFC "workspace-curator-originals-name-ledger-revisions" 의 Q1 도 같은 결정을 기다렸다. D7 이 두 질문에 답한다.
- 짝 문서: RFC-0497 은 Lane instance 의 binding 과 관측을 다룬다. 이 문서와 독자도, 잘못 지웠을 때의 비용도 다르다.

## 0. 요약

끝난 original 은 `settle` 로 `tool-request-owners-settled/<scope digest>/<날짜>/` 에 옮겨진다. 옮겨진 뒤 지우는 코드가 없다. 지금 19.7GB 이고 하루 0.5~0.9GB 씩 는다.

이 보관 위치를 읽는 코드는 하나뿐이다. `Lane_addon_store.tool_request_settled` 가 기록 파일이 있는지 `lstat` 으로 본다. 묻는 쪽은 "살아 있는 부모가 가리키는 자식이 보관됐나"만 묻는다. 멈춘 settle 을 마저 끝내려고 묻는 것이다.

- 보관된 본문 14.05GB 는 아무도 읽지 않는다.
- 보관된 기록 5.64GB 도 내용은 아무도 읽지 않는다. 파일이 있는지만 쓴다.
- 지금 살아 있는 기록 420개가 담은 요청 ID 457개 중, 보관된 기록 12,456개를 가리키는 것은 0개다.

같은 원본 ID 로 남는 기록이 두 곳 더 있다. Exact 요청 기록(`exact-requests`)과 원본 실행 증명(`host-results`)이다. 둘 다 살아 있는 원본을 처리할 때만 읽힌다. 원본이 settle 되면 Librarian·Curator 의 권한 검사가 그 ID 를 `Unowned` 로 영구히 거절한다. 그래서 다시 쓰이지 않는다. 지금 이 두 곳에 4.78GB 가 그렇게 남아 있다.

이 RFC 는 세 가지를 정한다. `settle` 은 본문을 보관하지 않고 지운다. 보관된 기록은 살아 있는 기록이 그 ID 를 가리키지 않으면 지운다. 살아 있는 원본이 없는 ID 의 Exact 기록과 실행 증명은 지운다.

## 1. 결정

- D1. `settle` 은 기록을 보관 위치로 옮긴 뒤, 본문을 보관 위치로 옮기지 않고 지운다. 순서는 지금처럼 기록이 먼저다. 다시 부른 `settle` 은 남은 본문을 지운다.
- D2. 보관된 기록은 살아 있는 기록이 그 요청 ID 를 가리키지 않으면 지운다. "가리킨다"는 settle 을 부르는 세 곳이 마저 끝내기에서 묻는 ID 와 같다(§3.2). 살아 있는 기록을 두는 owner 마다 타입으로 답한다(§4.2).
- D3. 지우기는 settlement barrier 와 workspace process lease 안에서 한다. 그 안에서는 settle 이 돌지 않는다. 그래서 그 순간 살아 있는 기록이 가리키는 ID 집합이 정확하다.
- D4. 이미 쌓인 12,456개도 같은 규칙으로 지운다. 먼저 대상만 세는 층을 내고, 운영자가 수치를 확인한 뒤 지우는 층을 낸다(§6).
- D5. 표시를 두 단계("표시 → 다음 주기 재확인 → 삭제")로 지우지 않는다. 이유는 §4.3 에 있다.
- D6. Librarian·Curator declaration 의 Exact 요청 기록과 원본 실행 증명은 그 요청 ID 를 가진 살아 있는 원본이 없으면 지운다(§4.4). 다른 declaration 의 기록은 건드리지 않는다.
- D7. 보관 위치를 디버깅용으로 남기지 않는다. 끝난 Librarian·Curator 일의 결과는 workspace memory 원장과 Keeper 기록에 남는다. 운영 문서 중 보관 위치를 읽으라고 하는 것은 Curator hard cut 절차 하나다. 그 절차는 보관 위치를 다른 곳으로 옮겨 두라고 한다. 운영자가 2026-11-06 에 정했다.

## 2. 무슨 일이 났나

### 2.1 크기

| 위치 | scope | 기록 | 본문 |
|---|---|---|---|
| `tool-request-owners-settled` | 123 | 12,456개, 5.64GB | 12,456개, 14.05GB |
| `tool-request-owners` (살아 있음) | 115 | 420개, 19MB | `tool-request-bodies` 202MB |

날짜별 보관 기록 수(체인 root 가 만들어진 UTC 날짜):

| 10-26 | 10-27 | 10-28 | 10-29 | 10-30 | 10-31 | 11-01 | 11-02 | 11-03 | 11-04 | 11-05 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1,168 | 1,962 | 381 | 82 | 43 | 289 | 520 | 2,789 | 4,381 | 561 | 280 |

기록 하나가 평균 453KB 다. 앞선 RFC 의 실측대로 같은 요청이 기록의 이벤트에도 들어 있어서다.

### 2.2 살아 있는 기록이 가리키는 보관 기록

살아 있는 기록 420개의 모든 문자열 값 중 UUIDv7 을 담은 것(요청 ID 모양) 457개를 뽑았다. 각 문자열의 SHA-256 을 보관 기록 파일 이름(`digest request_id`)과 맞대었다.

- 맞는 보관 기록: 0개
- 방법 확인: 살아 있는 기록 420개 모두 자기 `request_id` 의 SHA-256 이 파일 이름과 같다. 그래서 ID 문자열을 digest 해서 비교하는 방법이 맞다.

즉 지금 보관된 기록 12,456개는 모두 D2 의 대상이다.

### 2.3 Exact 요청 기록과 원본 실행 증명

같은 시각에 쟀다. Exact 요청 기록은 `request_id` 를, 실행 증명은 `executions[].request_id` 를 읽어 그 SHA-256 을 살아 있는 원본 파일 이름과 맞대었다. 요청 메시지와 답은 열지 않았다.

| declaration | Exact 요청 기록: 원본 없음 | 원본 있음 | 실행 증명: 원본 없음 | 원본 있음 |
|---|---|---|---|---|
| `keeper-librarian` | 6,392개, 1,331.6MB | 90개, 15.7MB | 6,342개, 1,355.9MB | 61개, 16.3MB |
| `workspace-curator` | 580개, 864.6MB | 8개, 20.6MB | 526개, 1,224.1MB | 8개, 55.3MB |

- 원본 없는 Exact 기록은 모두 final 이 있다. Librarian 은 `answered` 6,341, `outcome_unknown` 34, `not_allowed` 17 이다. Curator 는 `answered` 409, `outcome_unknown` 89, `input_refused` 67, `invalid_output` 12, `not_allowed` 2 다. 진행 중(final 없음)인 것은 0개다.
- Librarian 의 원본 없는 Exact 기록 중 5,865개, Curator 의 552개는 원본이 settled 보관 위치에 있다. 나머지는 어느 쪽에도 없다.
- 다른 declaration(`operator-quiz` 19·18개, `browser-stagehand` 2개, `candle-appraiser` 1·1개)은 요청 ID 가 원본 ID 가 아니다. D6 의 대상이 아니다.

## 3. 지금 코드

### 3.1 보관 위치를 읽는 곳

- `Lane_addon_store.tool_request_settled` 가 유일하다. 기록 경로를 `lstat` 해서, 이 프로세스가 가진 일반 파일이면 `true`, 없으면 `false` 다(`lane_addon_store.ml` 803). 내용은 읽지 않는다.
- 보관된 본문 경로(`tool_request_archive_body_path`)는 `settle` 이 쓸 때만 쓴다. 읽는 곳이 없다.
- 시작할 때 도는 본문 inventory(`Lane_addon_original_body_inventory`)는 보관 위치를 보지 않는다. 그 `.mli` 가 "Settled records are not read" 라고 적는다.
- 설계 문서 `addon-original-request-discovery.md` 도 같은 말을 한다. "the Curator's discovery only asks whether a child's record is there, to finish a stopped settle, and `settled` answers only that."

`lane_addon_store.mli` 의 `tool_request_archive_body_path` 주석은 "Startup cleanup inventories the records" 라고 적는다. 지금 코드와 맞지 않는다. 구현 층에서 이 주석을 고친다.

### 3.2 `settled` 를 묻는 곳

settle 을 부르는 곳은 셋이다. 셋 모두 살아 있는 기록이 가리키는 자식이 살아 있는 목록에 없을 때만 묻는다.

| 묻는 곳 | 살아 있는 기록에서 꺼내는 ID |
|---|---|
| `Keeper_librarian_durable_execution` `finish_settling` | `Progress.replacement` 가 `Preparation_confirmed intended` 인 기록의 `intended.request_id` |
| `Keeper_librarian_durable_execution` `settle_orphan_gates` | gate inventory 의 execution ID |
| `Keeper_librarian_floor_cleanup` `settle_orphan_gates` | step gate inventory 의 execution ID |
| `Server_workspace_memory_addon` `finish_settling` | `Progress.Subdivided (_, intent)` 인 기록의 `intent.request_id` |

RFC-0500 1층(#49002)이 넷째 호출처를 더한다. admission `evaluate` 가 서버가 멈춰 끊긴 실행을 옮긴다. 이 호출처는 `settled` 를 묻지 않는다. 옮긴 실행을 가리키는 살아 있는 기록이 생길 수 없기 때문이다(RFC-0500 §3.2).

`true` 면 살아 있는 부모 체인을 마저 옮긴다. `false` 면 그 부모를 그대로 둔다. 그 뒤 lineage 검사(`validate_lineage`)가 그 부모를 거절한다. 그래서 표시를 잘못 지웠을 때의 결과는 재실행이 아니라 그 체인의 정지다. 정지는 저절로 풀리지 않는다.

묻는 쪽은 settlement barrier 를 잡지 않는다. 읽기만 하기 때문이다. barrier 는 settle 의 이동과 §4.2 의 pass 를 서로 막는다. 묻는 쪽이 묻는 ID 는 그 순간 살아 있는 기록이 가리키는 것이라 `N` 에 들어 있다. 그래서 pass 와 같이 돌아도 그 표시는 지워지지 않는다.

### 3.3 Exact 요청 기록과 원본 실행 증명을 읽는 곳

- Exact 요청 기록: `Lane_addon_store.exact_request_path ~declaration_id ~request_id`. `Lane_addon_exact.run` 이 같은 요청을 다시 받을 때 남은 final 을 찾으려고 읽는다. 살아 있는 원본을 처리하는 consumer 도 `observe_retained` 로 읽는다(`keeper_librarian_admission_capture`, `keeper_librarian_original_final`, `lane_addon_submit_once`).
- 원본 실행 증명: `host-results/<digest ["exact-original-execution", declaration_id]>/<digest ["original-request", request_id, digest]>.json`(`lane_addon_exact.ml` `proof_key`). `read_original_execution`, `read_latest_original_execution` 이 읽는다. 호출처는 `keeper_librarian_admission_parts`, `keeper_librarian_admission_capture`, `keeper_librarian_original_final` 이다. 모두 살아 있는 원본의 capture 를 먼저 복원한 뒤 읽는다.
- `run` 은 실행 때마다 권한을 다시 묻는다. Librarian(`server_librarian_addon_validation.ml` `load_original`)과 Curator(`server_workspace_memory_addon_validation.ml` `authorize`)는 살아 있는 원본이 없으면 `Unowned` 로 거절한다. `.mli` 는 `Unowned` 를 "The host has no original request with this ID, so none can grant it later. The request ends as [Not_allowed]." 라고 적는다. 거절은 dispatch 와 delivery 를 모두 막는다. 그래서 원본이 없는 ID 의 남은 final 은 worker 에게 다시 전달되지 않고, provider 도 다시 불리지 않는다.

## 4. 설계

### 4.1 본문

`settle_tool_request` 는 지금 기록과 본문을 차례로 `move_into_archive` 한다. D1 은 두 번째 이동을 지우기로 바꾼다.

- 기록이 먼저 옮겨진다. 그래서 중간에 멈추면 지금처럼 "본문만 scope 옆에 남는다". 기록이 본문 없이 남는 일은 없다.
- 본문이 이미 없으면 성공으로 본다. 지금 `move_into_archive` 는 원래 자리에도 보관 위치에도 없으면 `Error` 다. 지우기는 "이미 없음"이 다시 부른 settle 의 정상 결과다.
- 지운 뒤 부모 디렉터리를 sync 한다(`remove_binding_with` 와 같이 `sync_existing_parent`).
- `settle` 의 호출 계약은 이미 "다른 기록이 가리키지 않는 본문"만 settle 한다고 적는다. 본문은 자기 요청 ID 를 담아서 두 기록이 한 본문을 나누지 않는다.

### 4.2 보관 기록

`tool-request-owners/` 아래에 기록을 두는 owner 를 닫힌 타입 하나로 묶는다. settle 을 부르는 owner 만 적지 않는다. 아래의 "어느 항목에도 속하지 않는 scope 가 있으면 지우지 않는다" 규칙이 살아 있는 scope 모두에 걸리기 때문이다.

2026-11-06 운영 workspace 의 살아 있는 scope 를 (package, tool) 로 세면 다섯 가지다.

| package / tool | scope | 기록 | 항목 |
|---|---|---|---|
| `keeper-librarian` / `admit_memory` | 60 | 282 | `Librarian_admission` |
| `keeper-librarian` / `derive_memory` | 23 | 23 | `Librarian_history`, `Librarian_floor` |
| `workspace-curator` / `curate` | 1 | 8 | `Workspace_curator` |
| `masc.completion-authority.review` / `verifier_review` | 1 | 101 | `Completion_review` |
| `masc.goal-verification.review` / `goal_proof_review` | 1 | 8 | `Goal_proof_review` |

```ocaml
type owner_family =
  | Librarian_admission | Librarian_history | Librarian_floor | Workspace_curator
  | Completion_review | Goal_proof_review
```

- 이 타입은 `Server_tool_request_consumer` 에 있다. 시작 pass 와 설치 전 검사(`deployment_preflight_helper` 의 `validate_tool_request`)가 같은 타입을 와일드카드 없이 match 한다. 그래서 설치 전 검사가 받는 scope 는 pass 도 분류한다.
  - 타입에 없는 owner 가 살아 있는 기록을 남기면 설치 전 검사가 배포를 멈춘다. 타입에 항목을 더하면 두 match 가 그 항목의 답을 적어야 컴파일된다.
  - scope 하나에 기록을 다 두는 owner 는 넷이다. Curator, 두 review, Candle appraiser(`candle-appraisals`)다. Librarian 기록의 종류는 아래처럼 `purpose` 가 정한다.
  - settle 을 부르는 owner 는 Librarian 과 Curator 다. Candle appraiser 는 settle 하지 않고 보관 위치도 읽지 않는다. 그래서 두 review 처럼 progress 이벤트의 ID 만 답한다.
- 두 review 항목은 settle 하지 않는다. 그래서 보관 위치에 그 owner 의 기록이 없고, 답은 빈 집합이다. 구현 층은 그 기록이 다른 owner 의 요청 ID 를 담지 않는지 확인한다(§7).
- 각 항목은 살아 있는 기록 하나가 담은 원본 ID 를 모두 답한다. §3.2 의 표보다 넓다. 마저 끝내기가 묻는 ID 만이 아니라, `Lane_addon_request_progress` 의 이벤트 중 요청 ID 를 담는 것(`Preparation_intended`, `Replacement_intended`, `Successor_intended`, `Subdividing`, `Subdivided` 등)과 gate inventory 의 execution ID 를 모두 넣는다. 모든 phase 와 이벤트를 와일드카드 없이 match 한다. 그래서 새 이벤트가 생기면 컴파일러가 이 답을 고치게 한다.
- 한 항목 안에 기록 종류가 여럿 있다. 11-06 에 Librarian 기록을 아래 종류로 다시 셌다.

  | 종류 | 살아 있음 | 보관 위치 |
  |---|---:|---:|
  | admission 실행 | 66 | 0 |
  | admission gate | 150 | 0 |
  | admission part | 66 | 0 |
  | history 실행 | 25 | 5,907개, 2,576MB |
  | history gate | 0 | 6,053개, 140MB |
  | floor step·floor step gate | 0 | 0 |
  | Curator | 9 | 585개, 3,119MB |
  | 완료 검토·Goal 증명 검토 | 101, 8 | 0 |

  그래서 기록을 항목에 넣는 일은 (package, tool) 이 아니라 기록 종류로 한다. Librarian 기록의 종류는 배포 전 검사가 이미 쓰는 `Keeper_librarian_store_preflight.purpose` 가 정한다. Curator 와 두 review 는 종류가 하나라서 (package, tool) 로 정한다. 종류를 정하지 못한 기록이 하나라도 있으면 pass 는 아무것도 지우지 않는다. 배포 전 검사는 이런 기록을 `Ok ()` 로 넘기지만, 이 pass 는 오류로 본다.
- 종류마다의 답은 두 집합의 합이다. 하나는 그 기록의 progress 이벤트가 담은 요청 ID 전부다. 다른 하나는 gate 기록의 부모 실행 ID 다. 가리키는 기록이 살아 있는지는 묻지 않는다.
  - 부모 실행 ID 는 gate inventory 가 실행 ID 를 모으는 함수(`parent_execution_id`, `keeper_librarian_original_gate.ml:69`)로 꺼낸다. 세 gate 가 이 함수를 같이 쓴다.
  - 다른 구조 ID 는 넣지 않는다. gate 의 `predecessor`, history 실행의 `predecessor`, admission 실행의 `parent_part_id`, part 의 `predecessor` 는 살아 있는 목록에서만 찾고 `settled` 에 넘기지 않는다. 이것까지 꺼내려면 종류마다 capture 를 복원해야 한다. 그러면 복원 하나하나가 pass 를 멈출 수 있는 실패 지점이 된다.
  - 그래서 pass 는 gate 기록만 본문을 읽는다. 나머지 기록은 progress 를 담은 기록 파일만 읽는다(`Owner.discover`).
  - 배포 전 검사의 validator 를 그대로 쓰지 않는 까닭: 그 validator 는 부모가 없으면 오류다. 실행이 먼저 보관되고 gate 가 남은 상태(`settle_orphan_gates` 가 다루는 고아 gate)는 정상인데, validator 로는 그때마다 pass 가 멈춘다. 이 pass 에서는 고아 gate 가 가리키는 실행 ID 가 `N` 에 들어가야 한다. 그래야 `settled` 가 `true` 를 답한다.
  - §3.2 의 네 호출처가 `settled` 에 넘기는 ID 는 progress 이벤트의 ID(history·Curator `finish_settling`)와 gate 의 부모 실행 ID(history·floor `settle_orphan_gates`) 둘뿐이다(`keeper_librarian_durable_execution.ml:265`·`:283`, `keeper_librarian_floor_cleanup.ml:69`, `server_workspace_memory_addon.ml:479`). 둘 다 이 합에 들어 있다. 1층 PR 은 네 호출처마다 그 호출처가 묻는 ID 가 `N` 에 있음을 시험으로 보인다. 새 호출처가 생기면 그 PR 이 같은 시험을 더한다.
  - `purpose` 는 접두사를 차례로 맞대는 분류다. floor step 의 접두사 `keeper-librarian-floor-step-` 는 floor step gate 접두사의 앞부분이라, gate 를 먼저 맞대야 맞는다. 잘못 분류된 기록은 다른 종류의 decoder 를 만나 오류가 되고, pass 는 아무것도 지우지 않는다. 그래서 잘못 지우지는 않는다. scope 이름을 하나의 typed codec 으로 바꾸는 일은 이 RFC 의 범위가 아니다(§5).
- 지우는 pass 는 모든 scope 의 살아 있는 기록을 읽는다. scope 는 Keeper 목록이 아니라 `tool-request-owners/` 아래 디렉터리를 훑어 모은다. 각 기록에 항목의 답을 모아 ID 집합 `N` 을 만든다.
- scope 하나, 기록 하나라도 읽지 못하거나 decode 하지 못하면 그 pass 는 아무것도 지우지 않고 끝난다. 어느 항목에도 속하지 않는 scope 가 있어도 같다.
- §2.2 에서 쓴 "문자열 값 중 ID 모양인 것" 훑기는 쓰지 않는다. 이 측정은 타입 답이 아직 없어서 쓴 근사다. 구현은 위의 타입 답을 쓴다. L1 은 같은 데이터에서 타입 답의 `N` 이 이 측정의 457개를 모두 덮는지 한 번 비교해 PR 에 적는다. 보관 기록 중 `digest request_id` 가 `N` 의 digest 에 없는 것을 지운다. 지울 때는 그 날짜 디렉터리의 본문 파일도 같이 지운다(이미 쌓인 본문).
- 이 pass 는 settlement barrier 와 workspace process lease 안에서 돈다. 시작할 때 본문 inventory 다음에, 그리고 날짜별 store 정리가 도는 24시간 주기에 같이 돈다. 새 주기는 만들지 않는다.

### 4.3 두 단계로 지우지 않는 이유

키퍼 리뷰는 "잘못 지우면 요청이 한 번 더 실행된다"는 이유로 두 단계 지우기를 권했다. 그 위험은 맞다. 살아 있는 부모가 가리키는 자식의 표시를 지우면, 부모는 자식이 없다고 보고 다시 만들 수 있다.

다만 그 경우는 이 규칙에서 생기지 않는다.

1. 부모는 자식을 만들기 전에 자식 ID 를 기록한다. `Lane_addon_request_progress` 의 이벤트 이름이 그 순서다. `Replacement_intended` 가 ID 를 적고(`Preparation_pending`), 자식이 저장된 뒤 `Preparation_confirmed` 가 된다. Curator 는 `Subdividing` 에서 `Subdivided` 로 간다. `.mli` 는 "confirm the retained child before ACK" 라고 적는다.
2. 체인은 잎부터 옮긴다. 부모는 자식보다 늦게 보관 위치로 간다.
3. 그래서 자식 표시가 보관돼 있고 살아 있는 기록이 그 ID 를 가리키지 않으면, 그 부모는 이미 보관 위치에 있다. 보관된 기록은 다시 살아나지 않는다.
4. 새 기록이 가리키는 ID 는 새로 만든 ID 다. ID 마지막 칸이 그때 만든 UUIDv7 이다(`Request.minted_on`).
5. 지우는 pass 가 도는 동안 settle 은 barrier 에 막힌다. 그래서 1~4 가 pass 안에서 바뀌지 않는다.

한 번 확인해서 정확한 조건을 두 번 확인해도 결과가 같다. 두 단계는 표시 상태만 하나 더 만든다. 구현 층은 4 번(자식 ID 를 어디서 만드는지)을 세 곳 모두 코드로 확인한다(§7).

### 4.4 Exact 요청 기록과 원본 실행 증명

`owner_family` 의 settle 하는 항목은 자기 declaration 을 안다. Librarian 세 항목은 `keeper-librarian`, Curator 는 `workspace-curator` 다. 두 review 항목은 이 절의 대상이 아니다.

대상 여부는 declaration 이름이 아니라 권한 검사와 같은 결정으로 정한다. Curator 의 `authorize` 는 그 declaration 에 묶인 package 가 Curator package 일 때만 원본 없는 요청을 `Unowned` 로 거절한다. 다른 package 면 원본 없이 허가한다. 그래서 두 validation 모듈(`server_librarian_addon_validation`, `server_workspace_memory_addon_validation`)이 "이 declaration·package 의 요청은 원본이 있어야 허가된다"를 답하는 함수 하나씩을 내놓는다. `authorize` 와 이 pass 가 그 함수를 같이 쓴다. 지금 그 declaration 에 묶인 package 를 알 수 없으면 그 declaration 의 기록은 건드리지 않는다.

§4.2 의 pass 는 이어서 이렇게 한다.

1. 그 declaration 의 `exact-requests` 와 `host-results` 파일 목록을 먼저 만든다.
2. 그다음 모든 scope 의 살아 있는 원본 목록을 읽는다.
3. 목록 1 의 기록 중 요청 ID 를 가진 살아 있는 원본이 목록 2 에 없는 것을 지운다. Exact 기록은 파일 이름(`digest request_id`)을 살아 있는 원본 파일 이름과 맞대면 되므로 내용을 읽지 않는다. 실행 증명은 파일 이름에 요청 digest 가 섞여 있어서 `executions[].request_id` 를 읽는다.
4. 한 요청 ID 에서는 실행 증명을 먼저, Exact 기록을 나중에 지운다. Exact 기록 없이 증명만 남으면 `read_*_original_execution` 과 `run` 의 `bound_proofs` 가 "proof has no matching started attempt" Error 를 낸다. 그러면 `run` 이 권한 검사에 닿기 전에 멈춘다. 반대로 증명만 지우고 멈추면 `run` 은 권한 검사에서 `Not_allowed` 로 끝난다.

원본은 Exact 실행보다 먼저 저장된다(`retain` 이 dispatch 전에 기록과 본문을 쓴다). 그래서 1 다음에 생긴 Exact 기록은 목록 1 에 없다. 목록 1 에 있는 기록의 원본은 2 에서 보인다. RFC-0497 의 폴더 목록과 같은 순서다.

원본이 없는 ID 는 `Unowned` 계약상 다시 허가되지 않는다. 그래서 두 단계로 지울 까닭이 없다. 이 pass 도 settlement barrier 와 workspace process lease 안에서 돈다.

barrier 는 2·3 동안만 잡는다. 1 은 실행 증명을 통째로 읽어서 오래 걸린다(아래 13초). 그동안 settle 을 막을 까닭이 없다. 1 다음에 settle 된 원본은 2 에서 안 보인다. 그 원본의 ID 도 다시 허가되지 않으니 기록을 지워도 된다.

실행 증명은 내용을 읽어야 요청 ID 를 안다. 11-06 운영 workspace 에서 Librarian·Curator 증명 7,000개(2.67GB)를 Python 으로 읽는 데 13초가 걸렸다. 같은 주 시작 로그에서 checkpoint sweep 은 p50 1.36초, 본문 inventory 는 p50 1.96초다(11-01~11-06, 61·48번). 그래서 이 절의 세기는 시작 단계에 넣지 않는다. 시작 정비(`Server_runtime_startup_maintenance.start_maintenance`)로 worker domain 에서 돌고, 끝나면 로그 한 줄을 남긴다. 세기는 아무것도 지우지 않아서 lease 와 barrier 를 잡지 않는다. L3 의 지우기는 이 절의 규칙대로 barrier 안에서 돈다.

권한 검사와 같은 결정을 쓴다. `Server_workspace_memory_addon_validation.original_required` 와 `Server_librarian_addon_validation.original_required` 가 그 함수다. `authorize` 의 "원본 없음" 갈래가 이 함수를 부른다. Librarian package 는 namespace 밖 요청을 바로 `Unowned` 로 끝내고, namespace 안 요청도 원본이 없으면 `Unowned` 로 끝낸다. 그래서 package 하나로 답할 수 있다. 다른 package 의 namespace 요청은 세지 않는다. 그 기록은 지우지 않는 쪽으로 남는다.

## 5. 이 RFC 가 하지 않는 것

- Lane instance 의 binding 과 관측: RFC-0497.
- content-addressed blob(`evidence/`, `sequences/`)과 Curator 원장 판본 파일: 가리키는 쪽이 여럿이다. 보관 기록이 줄면 가리키는 쪽이 하나 줄 뿐이다.
- 실행 기록(`exact_lane_run_registry` 의 `completed_retention`): 이미 레인마다 최근 2,000개로 정해져 있다.
- 살아 있는 scope 옆에 남은 본문(멈춘 retain·settle 이 남긴 것): 이슈 #45320.
- Librarian scope 이름을 접두사 대신 typed codec 으로 읽는 일. 지금 `purpose` 는 접두사를 순서대로 맞대고, 겹치는 접두사가 있다(§4.2, 이슈 #49021).

## 6. 구현 순서

1. L1 계획: §4.2·§4.4 의 pass 가 지울 대상만 센다. 아무것도 지우지 않는다. §4.2 의 기록 수·바이트, 본문 수·바이트, 남는 수는 시작 로그 한 줄에 싣는다(L1a). §4.4 의 Exact 기록·실행 증명 수와 바이트는 시작 정비의 로그 한 줄에 싣는다(L1b, §4.4 끝). 기록 종류와 종류마다의 답 함수도 이 층에 들어간다.
   - 확인: 배포 뒤 대상 수가 §2.2 와 같은 방법으로 잰 값과 맞는다.
2. L2 본문: D1. `settle` 이 본문을 지운다. 이미 쌓인 본문은 L3 이 지운다.
   - 확인: 배포 뒤 새 날짜 디렉터리에 `bodies/` 가 생기지 않는다.
3. 운영자 확인: L1 수치를 보고 L3 을 병합한다. 설정 스위치는 두지 않는다.
4. L3 지우기: §4.2·§4.4 의 pass 가 지운다. 지운 수와 바이트를 한 줄 info 로그에 남긴다. 세 조각으로 나눈다.
   - L3a: 시작 때 §4.2 의 pass 가 지운다. 1층 census 를 지우는 pass(`Server_settled_archive_sweep`)로 바꾼다. 시작 지점은 `Eio_main.run` 앞, process lease 아래라 settle 이 아직 돌지 못한다. 그래서 barrier 를 따로 잡지 않는다.
   - L3b: §4.4 의 Exact 기록과 실행 증명을 지운다.
   - L3c: 24시간 주기에서 같은 pass 를 settlement barrier 안에서 돌린다.
   - 확인: 첫 pass 뒤 `tool-request-owners-settled` 가 거의 빈다. 이후 하루 크기가 settle 중에 멈춘 체인 수만큼만 남는다.

## 7. 구현 층이 코드로 닫을 것

- 두 review 항목(`verifier_review`, `goal_proof_review`)의 기록이 다른 owner 의 요청 ID 를 담지 않는지 확인한다. 담는다면 그 항목도 답을 낸다(§4.2).
- 세 곳에서 자식 ID 를 언제 만드는지 확인한다(§4.3 의 1·4 번). 부모가 자식 ID 를 기록하기 전에 자식 기록이 생기는 경로가 있으면 D2 는 그 경로를 막는 방법과 같이 다시 쓴다.
- `Progress` 가 자식 ID 를 담는 곳을 모두 찾는다. §3.2 는 마저 끝내기가 묻는 ID 만 적었다. `Preparation_intended`, `Successor_intended` 처럼 ID 를 담는 이벤트가 더 있다. 다른 phase 가 보관된 ID 를 가리키면서 `settled` 를 묻지 않는다면 D2 에 영향이 없다. 다만 그 목록을 PR 에 적는다.
- `lane_addon_store.mli` 의 틀린 주석(§3.1)을 고친다.
- Librarian·Curator 의 권한 함수가 살아 있는 원본이 없을 때 `Undecided` 가 아니라 `Unowned` 를 돌려주는 경로를 모두 확인한다. `Undecided` 경로가 있으면 그 ID 의 기록은 D6 에서 뺀다.
- 살아 있는 child 가 이미 settle 된 parent 의 실행 증명을 읽는 경로가 없는지 확인한다. 체인은 잎부터 settle 되므로 없어야 한다.
- 권한 검사가 `Undecided` 로 답하는 경우(원본을 읽지 못함)는 "못 읽으면 아무것도 지우지 않는다" 규칙에 묶는다. 그 pass 는 D6 의 기록을 하나도 지우지 않는다.
- worker 가 settle 된 ID 를 계속 내면 `run` 의 거절이 그 ID 에 작은 `Not_allowed` 기록을 다시 쓰는지 확인한다. 쓴다면 이 pass 가 날마다 그것을 지우고 다음 거절이 다시 쓴다. 그 반복의 크기를 L1 에서 센다.
- 시험은 바뀌는 계약만 고친다. 지금 보관 본문이 생기는지 보는 시험(`test_workspace_memory_curator_lane.ml`, `test_keeper_librarian_durable_execution.ml`)은 본문이 지워지는지 보게 바꾼다. `test_lane_addon_original_body_inventory.ml`, `test_lane_addon_request_discovery.ml` 도 보관 경로를 쓴다.
- `bench_keeper_librarian_pass.ml` 은 보관 기록과 본문을 읽는다. Librarian Goal 의 측정 도구라서 D1 이 들어가면 그 단계가 실패한다. L2 에서 같이 고친다.

## 8. 리뷰

- 키퍼 리뷰어와 먼저 방향을 맞췄다.
  - 받아들인 것: RFC-0497 과 따로 쓴다. 기간이나 개수가 아니라 가리키는 쪽이 없을 때 지운다. 가리키는 쪽의 범위에 Librarian durable 실행, floor 정리, Curator 가 모두 들어간다. 세기 → 운영자 확인 → 지우기 순서로 낸다.
  - 바꾼 것: 리뷰어는 독자마다 읽은 위치(watermark)를 보자고 했다. 이 보관 위치의 독자는 순서대로 읽지 않는다. 살아 있는 부모가 가리키는 ID 만 묻는다. 그래서 watermark 대신 "살아 있는 기록이 가리키는 ID 집합"을 쓴다(§4.2).
  - 받아들이지 않은 것: 두 단계 지우기. 이유는 §4.3 에 있다.
- 첫 head(`9a05f5e108e`) 리뷰(5791182846)를 이렇게 반영했다.
  - 판단: "가리키는 기록이 없는 보관 기록은 다시 가리켜지지 않는다"는 깨지지 않았다. `N` 이 빠지면 결과는 재실행이 아니라 체인의 정지다(§3.2).
  - P2(`N` 을 만드는 단계가 닫혀 있지 않다): 못 읽은 scope·기록이 있으면 아무것도 지우지 않는다. scope 는 저장소 디렉터리를 훑어 모은다. 답은 이벤트까지 넓힌 타입 답이다(§4.2). 리뷰어가 권한 문자열 훑기 안전망은 넣지 않았다. 문자열 분류를 운영 코드에 두지 않는다는 저장소 규칙 때문이다. 대신 이벤트까지 넓힌 타입 답을 쓰고, L1 에서 이 측정과 한 번 비교한다.
  - P3: 본문이 이미 없으면 성공, 지운 뒤 디렉터리 sync(§4.1). 표 첫 행 이름을 `finish_settling` 으로 고쳤다. barrier 의 역할을 §3.2 에 적었다. bench 와 시험 파일을 §7 에 적었다.
- 셋째 head(`416fe24d07f`) 리뷰(5791260269): §4.4 판단(원본 없는 ID 의 Exact 기록은 지워도 재질의 결과가 같다)은 코드와 맞다고 봤다. 새 P2 두 건을 반영했다.
  - P2-1: 증명을 먼저, Exact 기록을 나중에 지운다(§4.4 의 4).
  - P2-2: 대상 여부를 declaration 이름이 아니라 `authorize` 와 같은 함수로 정한다. package 를 모르면 건드리지 않는다(§4.4).
  - P3: `Undecided` 를 못 읽음 규칙에 묶었다. Exact 기록은 파일 이름만 맞댄다. 거절이 다시 쓰는 작은 기록의 반복을 L1 에서 센다(§7).
- 2026-11-06 둘째 자체 확인: 1층을 짜려고 기록을 종류별로 다시 셌다. `admit_memory` 한 (package, tool) 에 실행·gate·part 세 종류가 있다. 보관 위치의 절반(6,053개)은 history gate 다. 그래서 항목을 기록 종류로 정하고, 답을 종류마다의 decoder 로 꺼내게 §4.2 를 고쳤다. 배포 전 검사의 validator 는 고아 gate 에서 오류가 나서 쓰지 않는다.
- 2026-11-06 자체 확인: §4.2 의 닫힌 타입이 settle 호출처 셋만 적어서, "어느 항목에도 속하지 않는 scope 면 지우지 않는다" 규칙대로라면 pass 가 매번 멈췄다. 살아 있는 scope 에 admission·두 review owner 가 있기 때문이다. 타입을 살아 있는 owner 다섯 종류로 넓혔다. RFC-0500 1층이 admission 을 넷째 settle 호출처로 더하는 것도 같이 적었다.
- 2026-11-10 운영 확인: 11-09 09:57Z 기동부터 열한 번, pass 가 "a live record is in a scope no owner claims" 로 아무것도 지우지 않았다. 살아 있는 `candle-appraisals` 기록 13개가 pass 의 분류표에 없었다. 설치 전 검사는 같은 일을 하는 표를 따로 두었고 그 표에는 Candle 이 있었다(#49635). 두 표를 `Server_tool_request_consumer` 하나로 합치고 §4.2 를 그렇게 고쳤다(#48946).
