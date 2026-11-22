---
rfc: "librarian-ends-waiting-requests-of-a-replaced-declaration"
title: "선언이 교체되면 그 선언으로 만든 대기 요청을 끝내고 새 선언으로 다시 만든다"
status: Active
created: 2026-11-11
updated: 2026-11-17
author: claude
supersedes: []
superseded_by: null
related: ["0489", "0500", "librarian-history-unknown-resolution", "librarian-history-settles-finished-originals"]
---

# 선언이 교체되면 그 선언으로 만든 대기 요청을 끝내고 새 선언으로 다시 만든다

이슈 #51278 의 설계 문서다. 코드 위치는 main `3c876bd23e9d` 기준이다. 시작 표시를 저장하는 때와 guard 를 부르는 순서(1.3, 3.2, 3.5, 4.1)는 #51269 가 들어간 main `b6fb3b3ee07e` 기준이고, 그 대목은 줄 번호 대신 함수 이름으로 가리킨다.

인용 규칙: 이 문서의 `N행` 표기는 작성 시점 커밋 기준이다. 줄 번호는 그 뒤 커밋에서 밀리므로, 같은 것을 가리키는 심볼 이름(`Module.value`, `type` 생성자)이 함께 적혀 있으면 심볼을 먼저 믿는다. 2026-11-17 main `81cf30f3de` 에서 표본을 다시 열어 보니 3.3 의 두 인용은 어긋나 있었고(고쳤다), `lane_addon_config.ml` 174~180행·`keeper_librarian_durable_edge.ml` 51행도 그 사이 다른 줄을 가리켰다. 남은 행 번호 인용은 같은 rot 를 가질 수 있으므로, 그 자리를 고칠 때 심볼로 바꾸는 것을 함께 한다.

운영자는 2026-11-16에 9절의 네 정책을 선택했다. 이 문서의 정책은 합의됐으며 구현은 진행 중이다.
정책 선택과 소스 변경만으로 회귀 실행·배포·실제 Memory 반영과 ACK가 끝났다고 판정하지 않는다.

## 0. 요약

- keeper-librarian 설치 선언의 revision 이 바뀌면, 그 전에 만든 끝나지 않은 원본은 끝나지 않는다.
  - host 는 그 요청을 실행하지 않는다.
  - Keeper 는 pass 마다 같은 거절을 받고 새 범위를 고르지 않는다.
  - 선언을 예전 값으로 되돌려야만 풀린다.
- 실행을 막는 규칙은 있는데 끝내는 규칙이 없다. 이 문서는 끝내는 규칙을 정한다.
- 다음을 바꾼다.
  1. host 는 결과도 실행 중 표시도 없는 요청의 선언이 교체됐으면 그 요청을 `Not_allowed` 로 끝낸다.
  2. 실행 중인 요청이 CLI slot 을 보내기 직전에 거절되면 `raised` 대신 미뤄진 시도로 남긴다. 다음 cycle 에 1번으로 끝난다.
  3. Keeper 는 worker 에 접수되지 않은 원본의 선언이 교체됐으면 그 원본을 `Refused {stage=Before_dispatch}` 로 끝낸다.
  4. Keeper 는 교체된 선언에서 실행이 끊긴 history 원본에 미소비 종료 증거를 남긴다. 원래 결과 불명은 보존한다.
  5. 교체된 선언의 원본을 끝낸 pass 는 다음 읽기를 좁히지 않고, 자기 Keeper 를 한 번 깨운다.
  6. admission은 전체 묶음의 실행 상태를 확인한 뒤 교체로 끝난 후보와 보류 후보가 섞인 미소비 묶음 전체를 새 요청으로 다시 판단한다(3.9).
  7. 이미 받은 답은 보존한다. 같은 물리 Keeper·Memory epoch·설치·package·tool이면 새 선언에서 미실행 Gate를 이어간다.
- 끝난 원본의 범위는 다음 pass 가 지금 선언으로 다시 고른다. 읽은 위치가 그대로라 입력을 잃지 않는다.
- 새 설정은 없다. 공용 진행 기록과 host 거절 경로를 쓰되, 선언 교체 종료와 일반 거절은 명시적인 타입과 저장 증거로 구분한다.
- 범위는 history, 실행 전 floor step, admission 의 미소비 묶음, 이미 받은 답의 Gate다. floor·admission 의 결과 불명까지 재실행 권한을 넓히지 않는다(5절).
- 요청을 만든 선언의 실행 권한은 유지한다. 답 없는 옛 요청을 새 선언에서 그대로 실행하는 길은 선택하지 않았다(9.1).

## 1. 문제 확인 당시의 코드와 관측

이 절의 코드 위치와 관측은 위에 적은 main 두 버전과 2026-11-11 조사 기준이다. 현재 설치 상태나 회복 완료의 증거로 쓰지 않는다.

### 1.1 선언 revision

- 설치 선언은 `config/lane-addons/` 아래 TOML 파일 하나다.
- 선언 revision 은 `id`, `run_id`, `manifest_path`, package 내용, `binding` 을 묶어 낸 sha256 이다(`lib/lane_addon/lane_addon_config.ml` 174~180행). package 의 `ui_category` 는 뺀다.
- revision 이 바뀌는 때는 넷이다.
  - package 를 새 버전 폴더로 올릴 때. 라이브 선언의 `manifest_path` 는 버전이 들어간 폴더를 가리킨다.
  - `run_id` 를 바꿀 때
  - `tool_hooks`, `exact_outputs`, `binding` 을 바꿀 때
  - 같은 경로의 package manifest 가 바뀔 때
- `enabled`, `ui_category`, 주석, 파일 이름은 revision 을 바꾸지 않는다. `ui_category` 만 바꾼 때는 따로 결함이 있다(#51300, 5절).
- provider registry, 계정, slot 순서도 revision 밖이다.
- Runtime 은 revision 이 달라진 선언의 worker 를 물린다(`lib/lane_addon/lane_addon_runtime.ml` 4514~4520행). 다음 beat 에 새 revision 으로 다시 붙인다(4521~4537행).
- keeper-librarian 의 worker 저장소는 persistent 이고(`addons/keeper-librarian/lane.toml` 의 `[world.state]`) 설치 id 와 package id 로 묶인다(`lane_addon_runtime.ml` 319~327행). revision 은 그 재료가 아니다. 그래서 새 worker 가 앞 worker 의 대기 요청을 이어받는다.

### 1.2 원본은 만든 때의 선언을 담는다

- Keeper 가 만드는 원본은 목적지를 담는다. 설치, package, tool, 선언 파일 바이트의 revision, 선언 revision 다섯이다(`lib/lane_addon/lane_addon_captured_destination.ml` 1~7행).
- `same_semantic` 은 파일 바이트의 revision 을 뺀 넷이 같아야 참이다(같은 파일 20~24행).
- 요청을 보내거나 실행하기 직전에 이 비교를 하는 곳은 셋이다.

| 누가 | 언제 | 다르면 |
|---|---|---|
| Keeper `confirm_destination` (`lib/keeper/keeper_librarian_durable_edge.ml` 51행) | worker 를 부르기 전마다. 접수도 조회도 같다 | `Rejected` 오류로 pass 가 끝난다 |
| Runtime `call_captured_tool_request` (`lane_addon_runtime.ml` 2466행) | worker 호출 직전 | 호출을 보내지 않는다 |
| host `authorize_captured_exact_dispatch` (`lane_addon_runtime.ml` 612행) | 모델 호출 직전마다. 선언 id, package id, 선언 revision 을 견준다(628행) | 글자뿐인 `Error`. 요청은 worker 대기 목록에 남는다 |

- 같은 비교가 다른 자리에도 있다. gate 를 시작하기 전의 권한 확인(`keeper_librarian_durable_edge.ml` 38~40행), 정리된 거절이 새 원본을 막는지(`lib/keeper/keeper_librarian_durable_refusal.ml` 181~183행), admission 의 part 와 접수(`lib/keeper/keeper_librarian_admission_owner.ml` 133~134행, `lib/keeper/keeper_librarian_admission_dispatch.ml` 55~56행)다.
- 모두 "지금 하지 않는다"만 정한다. 그 요청을 어떻게 끝낼지는 어디에도 없다.

### 1.3 phase 마다 일어나는 일

선언이 교체된 뒤의 history 원본이다.

| 원본의 phase | 지금 | 자리 |
|---|---|---|
| `Captured`, `Admission_wait` (worker 에 접수되지 않음) | worker 에 묻기 전에 목적지 확인에서 거절된다. pass 마다 오류다 | `lib/lane_addon/lane_addon_submit_once.ml` 200~206행 |
| `Dispatch_pending`, host 기록에 결과가 없고 실행 중이 아님 | Keeper 는 host 기록을 먼저 읽는다. 열려 있으면 worker 에 물으려다 같은 거절을 받는다. host 는 cycle 마다 원본 본문을 다시 읽어 확인한 뒤 거절한다 | 같은 파일 207~218행, `lib/lane_addon/lane_addon_exact.ml` 976행 |
| `Dispatch_pending`, host 가 실행 중이었음 | Runtime 이 worker 를 물릴 때 실행을 취소한다. 첫 생성 요청을 보내기 직전까지 간 실행은 시작 표시가 남는다(`lane_addon_exact.ml` 의 `mark_started`). 다음 cycle 이 그 시도를 `outcome_unknown` 으로 끝내고 원인을 `cut` 으로 남긴다. Keeper 는 그 원본을 pass 마다 기다린다. 끝내는 길이 없다. 첫 생성 요청의 허가를 기다리다 취소된 실행은 시작 표시가 없다(#51269). 그 요청은 윗줄과 같다 | `lane_addon_runtime.ml` 213행·1180~1186행, `lane_addon_exact.ml` 919~926행·994행, `lib/keeper/keeper_librarian_durable_commit.ml` 246행 |
| `Dispatch_pending`, host 기록이 끝남 | Keeper 가 host 기록의 결과로 원본을 끝낸다. worker 를 부르지 않고 목적지도 확인하지 않는다 | `lane_addon_submit_once.ml` 208~210행 |
| `Judged`, 반영이 남음 | gate 가 이미 끝났으면 목적지를 보지 않고 반영한다. gate 를 시작하거나 이어서 실행해야 하면 목적지 비교에 막혀 기다린다 | `keeper_librarian_durable_commit.ml` 312~317행, 350~352행 |

- 끝나지 않은 원본이 하나 있는 동안 그 Keeper 는 새 범위를 고르지 않는다(`lib/keeper/keeper_librarian_durable_execution.ml` 479행).
- host cycle 은 요청마다 따로 판정한다. 거절된 요청이 같은 cycle 의 다른 요청을 막지는 않는다(`lane_addon_runtime.ml` 1335~1340행).
- 접수된 요청은 끝날 때까지 worker 대기 목록에서 frame 자리를 차지한다. 새 요청은 대기 목록과 함께 frame 에 들어갈 때만 접수된다(`addons/exact_worker.py` 410~412행).
  - 교체된 선언의 요청은 끝나지 않으니 그 자리가 비지 않는다.
  - 원본이 없던 Keeper 가 새 선언으로 만든 요청도 그 자리만큼 덜 접수된다.

### 1.4 설명서의 절차가 이 상태를 만든다

- `docs/KEEPER-USER-MANUAL.md` 982~987행은 capacity 거절 뒤에 다시 시도하려면 선언의 `run_id` 를 바꾸라고 안내한다.
- keeper-librarian 설치 하나가 모든 Keeper 의 요청을 받는다.
- 한 Keeper 의 거절을 풀려고 `run_id` 를 바꾸면, 그때 끝나지 않은 원본을 든 다른 Keeper 가 모두 1.3 의 상태가 된다.

### 1.5 정리된 거절에는 규칙이 있다

- 정리된 capacity 거절은 자기 목적지만 막는다. `Refusal.blocked` 는 거절의 목적지가 지금 목적지와 `same_semantic` 일 때 새 원본을 막는다(`keeper_librarian_durable_refusal.ml` 181~189행). 지금 목적지를 읽지 못할 때도 막는다(189행).
- 계약 문장도 있다. "A different configured semantic destination permits a fresh attempt while retaining the earlier refusal"(`lib/keeper/keeper_librarian_durable_execution.mli`).
- 끝나지 않은 원본에는 같은 규칙이 없다.

### 1.6 host 는 이미 세 경우에 요청을 실행 없이 끝낸다

- `Lane_addon_exact.run` 안의 `deny` 가 host 기록에 `Not_allowed` 를 저장한다(`lane_addon_exact.ml` 935~944행). 같은 host cycle 이 그 결과를 worker 에 전달한다(`lane_addon_runtime.ml` 1322~1323행).
- 지금 `deny` 로 가는 경우는 셋이다(945~954행).
  - 지금 package 가 그 output 을 선언하지 않는다.
  - 지금 package 가 그 요청의 schema 를 허용하지 않는다.
  - 그 요청의 원본이 host 에 없다.
- Keeper 쪽은 이 결과를 받는 길이 이미 있다.
  - 다음 pass 가 host 기록에서 `Not_allowed` 를 읽는다(`lane_addon_submit_once.ml` 208~210행).
  - host 기록과 맞는지 확인한다(`lib/keeper/keeper_librarian_original_final.ml` 47~72행).
  - 원본은 정리된 것으로 읽힌다(`keeper_librarian_durable_commit.ml` 251행).
  - 정리된 `Not_allowed` 는 새 원본을 막지 않는다(`keeper_librarian_durable_refusal.ml` 147행).
  - 그다음 pass 가 같은 범위를 지금 목적지로 새로 만든다. 그 pass 를 부르는 것은 없다. 다른 신호가 올 때 돈다(3.6).
- 선언이 바뀌어도 output 과 schema 가 그대로면 이 길로 가지 않는다. 실행 직전 guard 가 `Error` 를 돌려주고 끝난다(976행).

### 1.7 지금 계약

- Runtime 의 계약 문장은 이 확인을 새 provider 호출 전의 권한으로 적는다. 이미 받은 답은 다시 확인하지도 버리지도 않는다고 적는다(`lib/lane_addon/lane_addon_runtime.mli` 34~41행).
- 기존 시험 둘이 그 계약을 고정한다.
  - `test/test_lane_addon_exact.ml` 의 `test_execution_guard_is_not_retained_delivery_authority`. guard 가 거절하면 host 기록을 남기지 않는다. guard 가 다시 허락하면 같은 요청이 실행된다.
  - `test/test_lane_addon_host_cycle.ml` 의 `test_original_exact_semantic_dispatch_authority`. 새 revision 에서는 예전 요청을 실행하지 않는다. `enabled` 를 껐다 켜면 같은 요청이 실행된다.
- 지금 계약은 "요청은 만든 선언 안에서만 실행된다. 선언을 되돌리면 그대로 이어진다"이다.
- 되돌리지 않을 때의 끝은 정해져 있지 않다.
- 기존 설계는 선언 파일의 바이트만 바뀐 것을 "기존 요청을 옮기거나 다시 쓸 이유가 아니다"라고 적었다. 선언 revision 이 바뀐 때에 옮길지 다시 쓸지는 적혀 있지 않다.

### 1.8 측정

| 무엇 | 값 | 언제, 어떻게 |
|---|---|---|
| 끝나지 않은 history 원본 | 26개. 접수되어 차례 대기 15, 접수 거절 9, worker 에 기록 없음 2 | 2026-11-11 07:44Z, 라이브 기록의 마지막 진행 사건 |
| 기다리는 admission 실행 | 1개 | 같은 조회 |
| 라이브 floor step 기록 | 0개 | 같은 조회 |
| 원본 하나가 담은 범위 | 본문 27개 모두 `all_unread`. 담긴 메시지 중앙값 96개, 최대 7,625개 | 07:39Z, 본문의 범위 필드 |
| 끝나지 않은 원본과 gate 기록이 함께 있던 pass | 4,164번 가운데 0번 | 11-11 00:00~07:40Z, inventory 로그 줄 |
| 이 거절이 로그에 남은 횟수 | 0건 | 11-04~11-11 WARN·ERROR 줄. 라이브 선언 파일은 10-23 이후 바뀌지 않았다 |

- 그 조사에서는 선언 교체로 생긴 실제 장애를 관측하지 않았다. 코드로 따라간 결과다.
- 당시 상태에서 package 를 올리면 대기 15명과 접수 거절 9명, 합쳐 24명의 durable Librarian 이 새로 멈출 수 있었다. 기다리는 admission 실행 1개도 같은 영향권이었다. 현재 수량은 배포 전에 다시 읽는다.

## 2. 무엇이 문제인가

- 운영자가 선언을 바꾸는 것은 앞으로 가려는 것이다. package 를 올리거나 설명서대로 `run_id` 를 바꾼다. 지금 계약은 되돌릴 때만 풀린다.
- worker 를 고치는 수리(#51280)는 package 를 올려야 한다. 그 배포가 곧 선언 revision 변경이다. 이 문서의 층이 먼저 들어가야 한다.
- 요청을 끝낼 수 있는 곳은 그 요청의 사실을 가진 곳이다.

| 요청의 상태 | 그 사실을 가진 곳 | 근거 |
|---|---|---|
| worker 에 접수되지 않음 | Keeper 의 진행 기록 | Keeper 는 `Dispatch_intended` 를 저장한 뒤에만 접수 호출을 보낸다(`lane_addon_submit_once.ml` 157~166행). worker 는 접수를 거절할 때 아무것도 저장하지 않는다(`addons/exact_worker.py` 410~412행) |
| 접수됨, 결과가 없고 실행 중이 아님 | host 의 Exact 기록 | 시작 표시(`Started`)와 결과(`final`)는 host 기록에만 있다(`lane_addon_exact.ml` 983행, 1007행) |
| 접수됨, 실행이 끊김 | host 의 Exact 기록과 Keeper 가 받은 거절 증거 | 끊긴 시도는 host 기록에 `cut` 으로 남는다(`lane_addon_exact.ml` 923~926행). Keeper 의 진행 기록이 그 증거를 싣는다 |

- 지금은 세 곳 모두 "지금 하지 않는다" 또는 "기다린다"만 돌려준다.

## 3. 제안

### 3.1 "선언이 교체됐다"의 뜻

요청이 담은 목적지와 지금 설치를 견줘 아래가 모두 참일 때다.

1. 선언 폴더를 새로 읽은 결과가 완전하다.
2. 그 id 의 선언이 정확히 하나이고 켜져 있다.
3. 그 선언의 revision 으로 붙은 살아 있는 worker 가 정확히 하나다.
4. 설치, package, tool 은 요청이 담은 것과 같다.
5. 선언 revision 은 요청이 담은 것과 다르다.

- 1~3 가운데 하나라도 아니면 "지금은 정하지 못한다"이다. 요청은 그대로 남고 다음에 다시 본다.
  - 선언을 끈 것, 파일이 깨진 것, 파일만 고치고 worker 가 아직 붙지 않은 것이 여기에 든다.
  - 새 worker 가 앞 worker 의 기록을 읽지 못해 멈춘 것도 여기에 든다(5절).
- 4 가 아니면 지금처럼 거절 오류다. 다른 설치의 요청이다. 선언의 `id` 를 바꾼 것이 여기에 든다(5절).
- 시간, 횟수, 글자 비교는 쓰지 않는다. 다섯 조건은 선언 읽기와 Runtime 의 entry 표에서 정해진다.
- Keeper 쪽은 지금 목적지를 얻을 때 이미 1~3 을 본다. 선언 읽기가 완전하고, 붙어 있는 worker 의 선언이 켜져 있고 그 revision 그대로여야 목적지가 나온다(`lane_addon_runtime.ml` 2310~2352행). Keeper 쪽에 더할 것은 4·5 를 타입으로 나누는 비교 하나다.

```ocaml
(* lane_addon_captured_destination *)
type relation =
  | Same            (* same_semantic *)
  | Replaced        (* 설치·package·tool 은 같고 선언 revision 만 다르다 *)
  | Other_owner     (* 그 밖 *)
val relation : captured:t -> current:t -> relation
```

- host 쪽은 `authorize_captured_exact_dispatch` 가 1~5 를 한 번에 보고 글자를 돌려준다. 이 결과를 타입으로 나눈다(3.2).

### 3.2 host: 결과가 없고 실행 중이 아닌 요청을 끝낸다

- 실행 직전 guard 의 결과를 타입으로 나눈다.

```ocaml
(* lane_addon_exact *)
type dispatch_veto =
  | Not_now of { detail : string }   (* 지금은 정하지 못한다. 아무것도 쓰지 않는다 *)
  | Declaration_replaced             (* 3.1 의 다섯 조건이 참이다 *)
type dispatch_guard = unit -> (unit, dispatch_veto) result
```

- `run` 은 실행을 시작하려는 갈래에서만 이 결과를 본다(`lane_addon_exact.ml` 974~976행의 `None, None`).
  - 이 갈래에 오는 요청은 host 기록에 결과가 없고 실행 중 표시(`Started`)도 없다.
  - provider 가 받지 않아 미뤄진 시도(`Deferred`)만 남은 요청도 여기에 온다. 답을 받은 적은 없다.
  - `Declaration_replaced` 면 host 기록에 `Not_allowed {reason=Replaced_declaration}` 을 저장한다. 같은 cycle 이 그 결과를 worker 에 전달한다.
    - `Not_allowed` 의 사유는 타입 둘이다. 권한·소유 거절(`Permission_refused {detail}`)과 선언 교체(`Replaced_declaration`)다.
    - worker 로 가는 모양도 둘이다. 앞의 것은 `reason` 글자를 싣고, 뒤의 것은 `"cause":"declaration_replaced"` 를 싣는다. 모르는 `cause` 와, `cause` 와 `reason` 을 함께 실은 값은 host 도 worker 도 거절한다.
    - 사유는 host 기록, worker 기록, Keeper 의 진행 기록에 그대로 남는다. 뒤에 선언을 되돌려도, 지금 선언을 읽지 못해도 바뀌지 않는다.
    - worker 가 이 사유를 돌려주면 `Submit.resume` 이 host 기록에서 같은 사유를 확인한다. host 기록이 없거나, 열려 있거나, 다른 결과면 거절한다.
    - 이 모양을 받는 worker 는 keeper-librarian 0.2.5 부터다(7절).
    - 소비자는 현재 목적지 비교로 저장된 사유를 다시 추정하지 않는다.
  - `Not_now` 면 지금처럼 `Error` 다. 아무것도 쓰지 않고 요청은 대기 목록에 남는다.
- 이미 끝난 기록은 guard 를 부르지 않는다(971~972행).
  - 답이 있는 요청은 지금 package 가 그 output 과 schema 를 그대로 선언하는 한, 선언이 교체된 뒤에도 그 답을 전달한다.
  - 선언하지 않으면 지금처럼 전달을 거절한다(940~942행). 그 규칙은 바꾸지 않는다.
- 실행 중인 walk 도 slot 마다 보내기 직전에 같은 guard 를 부른다. guard 는 선언 파일을 그때 새로 읽는다(`lane_addon_runtime.ml` 619~629행). 운영자가 파일을 고친 뒤 Runtime 이 앞 worker 를 물리기 전에도 거절이 나온다.
  - guard 를 부르는 자리는 둘이다. `run` 이 실행을 시작하기 전에 한 번 부르고, walk 가 slot 마다 부른다(`run` 안의 `before_dispatch`).
  - 생성 요청(`Generation`) 앞에서는 시작 표시를 먼저 저장하고 그 뒤에 guard 를 부른다(#51269). 계량 요청(`Measurement`) 앞에서는 guard 만 부른다.
  - HTTP slot 에서 거절되면 walk 가 그 자리에서 멈춘다. 끝 저장이 그 시도를 미뤄진 시도(`Deferred`)로 적는다(`lib/server/server_lane_addon_exact.ml` 117~119행, 146~157행). 방금 쓴 시작 표시는 그 저장에서 `Deferred` 로 바뀐다. 다음 cycle 에 위 갈래로 온다.
  - L1b 이전에는 CLI slot에서 거절되면 예외로 끝나고, 끝 저장이 그 시도를 `raised`로 적었다(같은 파일 174~177행, 225~229행, `lane_addon_exact.ml` 995행). CLI walker의 관찰 함수가 값을 돌려주지 못해서였다(`lib/keeper/keeper_lane_cli_oneshot.ml` 400행). 이 정책은 이미 남은 `raised` 원본의 종료 권한을 더하지 않는다.
  - guard 가 거절했다는 것은 그 slot 에 보내지 않았다는 뜻이다. 결과를 모르는 것이 아니다. CLI walker 가 보내기 전의 거절을 값으로 받아 그 자리에서 멈추게 한다. 그 시도는 HTTP 와 같이 `Deferred` 로 남고 다음 cycle 에 위 갈래로 온다(7절의 L1b, #51343).
  - walk 안의 guard 에는 두 결과를 글자로 바꿔 넘긴다. walk 안에서는 어느 쪽이든 멈추기만 한다.
- 실행이 취소되어 끊긴 요청은 3.5 에 있다.
- `authorize_captured_exact_dispatch` 는 3.1 의 조건으로 셋 가운데 하나를 돌려준다. 허가, `Declaration_replaced`, `Not_now` 다.
- Librarian guard 는 셋이다(`lib/server/server_librarian_addon_validation.ml` 43·88·138행).
  - history 와 floor step 의 guard 는 Runtime 의 결과를 그대로 돌려준다. 그 앞의 읽기 실패는 `Not_now` 다.
  - admission 도 실행 전 선언 교체를 명시적인 사유로 전달한다. 미소비 묶음을 다시 만드는 조건은 3.9절을 따른다.
- Curator 의 guard 는 `Ok ()` 뿐이라 바뀌지 않는다(`lib/server/server_lane_addon_exact.ml` 268행).
- worker 가 전달된 결과를 받으면 Runtime 이 `Exact_result_delivered` 를 낸다(`lane_addon_runtime.ml` 1290~1293행). Librarian 이 그 요청의 Keeper 를 깨운다(`lib/server/server_librarian_addon_wake.ml` 105행).
- Keeper 는 1.6 의 길로 그 결과를 받는다. 더할 것은 둘이다. 좁히지 않는 것(3.4)과 다음 pass 를 부르는 것(3.6)이다.
- 이 규칙은 새 worker 가 앞 worker 의 대기 목록을 host 에 줄 때만 선다. 주지 못하는 경우는 5절에 있다.

### 3.3 Keeper: 접수되지 않은 원본을 끝낸다

- host 는 worker 에 접수되지 않은 요청을 볼 수 없다. Keeper 가 끝낸다.
- `Submit.resume` 의 접수 전 갈래(`Captured`, `Admission_wait`)가 worker 에 묻기 전에 3.1 의 비교를 본다.
  - `Replaced` 면 `Refused {stage=Before_dispatch; evidence}` 를 저장하고 `Settled` 를 돌려준다. worker 를 부르지 않는다.
  - `Same` 이면 지금처럼 조회하고 접수한다.
  - `Other_owner` 면 지금처럼 거절 오류다.
- `Submit.resume` 은 소비자 넷이 함께 쓴다. history, floor step, admission, Curator 다. 관계는 소비자가 넘기는 확인 함수의 결과로 받는다.
  - admission 도 관계를 구분하되 part 하나의 종료를 묶음 소비로 보지 않는다(3.9). Curator 의 확인 함수는 `Replaced` 를 돌려주지 않는다.
- 이 사건은 공용 규약의 `Refused` 전이를 쓴다(`lib/lane_addon/lane_addon_request_progress.ml`).
- 접수 전 판정은 정본 owner journal의 사건을 복원해 얻은 phase를 쓴다.
  - `Captured`에는 확정된 전송 의도가 없으며 submit RPC를 보내지 않았다.
  - `Admission_wait`에는 전송 의도를 거절한 기록이 있다. 이 원본의 producer는 submit RPC 전 `Not_sent` 거절이나 worker의 명시적인 `capacity_wait` 응답일 때만 그 기록을 쓴다.
  - `capacity_wait`는 RPC를 받지 않았다는 뜻이 아니다. worker가 submit RPC를 받았지만 요청을 접수·저장하지 않았다는 뜻이다. 같은 ID가 이미 저장돼 있으면 worker는 먼저 pending·finished를 돌려준다.
- `Submit.resume`는 `Dispatch_intended`를 새로 확정 저장한 `Fresh`일 때만 submit RPC를 보낸다. 같은 의도가 이미 저장됐거나 저장 결과가 불확실하면 보내지 않는다.
  - 전송 뒤 응답 유실·해석 실패·취소로 접수 결과를 확정하지 못하면 `Dispatch_pending`에 남는다. worker의 후속 부재 응답도 접수 전 phase로 돌리지 않는다.
  - `Refused {Before_dispatch}`는 `Captured`·`Admission_wait`에서만 저장할 수 있다. `Dispatch_pending`의 원본을 접수 전 종료로 바꾸지 않는다.
- 종료 증거는 원래 owner·요청 ID·본문 digest·목적지와 정본 journal에 결속한다. 두 목적지만 있는 외부 값은 원본의 종료 권한이 아니다. 복원한 원본과 증거가 결속되지 않거나 journal을 읽지 못하면 끝내지 않는다.
- 위 순서와 전이는 이 원본의 미접수를 증명한다. 같은 부재를 확인하기 위한 추가 Exact inventory·proof 조회는 필요하지 않다.
- 이 보장은 기존 Keeper Memory lane의 Keeper별 직렬화와 workspace lease 안에서 성립한다. owner 갱신은 전체 expected record와 progress를 다시 비교하며 다른 tail을 거절한다.

- history 가 읽는 자리는 둘이다.
  - inventory 검사가 이 phase 를 정리된 원본으로 읽는다. 문제 확인 당시에는 오류였다. 지금은 `keeper_librarian_durable_commit.ml` 의 `frontier` 가 `Unfinished | Settled` 두 값이고, 접수 전 종료(`Rejected {stage=Progress.Before_dispatch}`)인지는 `Keeper_librarian_declaration_replacement.ended` 가 정한다. 끝났으면 `Settled`, 아니면 `Error "Original history has no declaration replacement ending"` 로 거절한다. 운영자 해소 흐름도 같은 검사 함수를 쓴다.
  - history owner 가 `Settled` 로 돌아온 이 phase 를 받는다. 문제 확인 당시에는 오류였다. 지금은 `lib/keeper/keeper_librarian_durable_owner.ml` 이 `Submit.End_replaced` 로 끝낸다. pass 는 "반영하지 않음"으로 끝나고 이유를 한 줄 남긴다.
- 이 갈래는 거절 갈래(`Refused`)를 지나지 않는다. 다음 읽기를 좁히지 않는다.
  - 새 원본을 만든 바로 그 pass 에서 이 갈래가 나와도 같다. 그 자리는 거절을 `Memory_refused` 로 돌려주고, 그 값은 좁히기 표시를 남긴다(`keeper_librarian_durable_execution.ml` 519~530행, `lib/keeper/keeper_librarian_durable_consumer.ml` 1692~1719행). 이 갈래는 그 값으로 돌려주지 않는다.
- 그다음 pass 는 정리된 원본을 옮기고 같은 범위를 지금 목적지로 새로 만든다. 정리된 거절이 가는 길 그대로다. 그 pass 는 3.6 이 부른다.
- main `8e78ac5f9e10`의 L2a(#52674)는 위 순서를 따른다. `Captured`·`Admission_wait`에서 관계와 live owner를 확인하고, 두 목적지를 담는 `Request.replaced`를 원본 record·본문·owner와 결속해 저장한다. 이 절은 그 소스 경로를 설명하며 동작 시험 완료를 뜻하지 않는다.

- 문제 확인 당시 목적지 확인 코드는 두 벌이었다(`keeper_librarian_durable_edge.ml` 51행, `keeper_librarian_admission_dispatch.ml` 38행). 오류 글자만 다르고 하는 일이 같았다.
  - 현재 L2a는 관계를 돌려주는 함수 하나를 쓴다. 한쪽만 타입으로 바꾸면 두 벌이 서로 달라진다.
  - admission 은 `Other_owner` 를 거절하며 `Replaced` 는 3.9절의 묶음 교체로 처리한다.
- floor step 은 같은 규칙을 따로 옮긴다(7절의 L2b).
  - floor step owner 는 `Settled` 로 돌아온 이 phase 를 지금 오류로 본다(`lib/keeper/keeper_librarian_floor_step_owner.ml` 95행). 결과에 갈래 하나를 더한다. "접수 전에 끝났다"이다.
  - chain 의 결과에도 갈래 하나를 더한다. "교체된 선언에서 멈췄다"이다. 지금 `Stopped` 는 자리와 report 만 담아서 같은 선언의 거절과 가를 수 없다(`keeper_librarian_floor_chain.ml` 의 `type outcome`, `Stopped of {position; report}`).
  - chain 의 `outcome` 은 지금 `Finished`·`Pending`·`Stopped`·`Superseded` 넷이다. 교체 종료를 새 갈래로 세우면 나머지 셋의 뜻은 그대로다. `Stopped`(같은 선언의 거절), `Pending`(다음 pass 가 이어감), `Superseded`(다른 후보가 대신함)는 교체 종료와 갈리고, `Finished` 는 정상 종료다.
    - chain 은 두 경우에 이 갈래를 돌려준다. step owner 가 검증된 "접수 전에 끝났다"를 줬을 때와, host 가 남긴 `Not_allowed {reason=Replaced_declaration}` 를 복원했을 때다. 일반 `Not_allowed`와 현재 목적지 비교만으로 이 갈래를 만들지 않는다.
    - 이 갈래는 report 를 만들지 않는다. 읽을 범위를 줄일 근거가 없다.
  - pass 는 그 step 을 `Stopped` 와 같은 길로 정리하고 `wake` 를 부른다(3.6). 다음 pass 가 같은 자리를 새 id 로 묻는다(`keeper_librarian_durable_execution.ml` 의 `Floor_chain.Stopped {position;report}` 갈래 — `Floor_cleanup.settle_step` 을 거쳐 `Consumer.Memory_refused [report]` 로 돌려준다).

### 3.4 선언 교체 종료는 다음 읽기를 좁히지 않는다

- 선언 교체 종료는 요청을 실행하지 않았거나, 결과를 모르는 옛 요청을 미소비 상태로 끝냈다는 사실이다. 입력이 크다는 판정이 아니다.
- host가 저장한 `Replaced_declaration` 사유 또는 소비자가 검증한 종료 증거가 있을 때만 다음 읽기를 좁히지 않는다.
- 일반 `Not_allowed`와 설명 글자가 같다는 이유로 교체 종료를 만들지 않는다. 지금 목적지와의 비교만으로 사유를 추정하지도 않는다.
  3.3의 접수 전 종료는 이 금지에 해당하지 않는다. 그 비교는 사유를 추정하지 않고, 종료를 만들기 전에 교체를 확인하는 조건이다.
- 교체 전에 실제로 받은 입력 크기 거절과 이미 좁힌 범위는 보존한다. 새 선언은 그 증거를 없애지 않는다.
- 종료 증거를 저장한 뒤에는 현재 worker나 목적지를 읽지 못해도 같은 종료로 읽는다. 선언을 되돌렸다고 일반 거절로 바뀌지 않는다.
- 다음 pass는 읽은 위치에서 미소비 입력을 다시 고른다. 그 사이 도착한 입력이 함께 포함될 수 있다.
- `Permission_refused {detail}`는 권한·소유 거절이다. 설명에 교체를 가리키는 글자가 있어도 교체 종료가 아니다. 다음 읽기는 기존처럼 좁힌다.

### 3.5 교체된 선언에서 끊긴 history 원본은 미소비 종료 증거를 남긴다

- 실행 중이던 요청은 선언 교체 때 취소되어 host에 `cut`이 남을 수 있다. provider에서 실제로 끝났는지는 여전히 알 수 없다.
- 운영자는 이 경우도 종료 증거를 남긴 뒤 미소비 입력으로 새 요청을 만드는 쪽을 선택했다(9.2).
- 허용 조건은 실행 단계의 history 원본, 엄격하게 결속된 원래 Exact request·schema·digest·attempt·proof, 그리고 3.1의 `Replaced`다.
- 저장 전과 복구 때 원래 Exact request와 schema로 실제 host Cut를 확인하고 실행 proof를 별도로 읽는다. Cut 해소에는 `No_completed_latest`가 필요하다. 손상·읽기 오류·다른 원본의 proof는 종료 권한이 아니다. 일반 typed 선언 교체의 과거 `Call_refused` 허용을 여기로 넓히지 않는다.
- 원래 거절과 결과 불명은 보존한다. `cut`을 `interrupted`나 성공으로 다시 쓰지 않는다. 별도 종료 증거가 원본 binding과 새로 준비된 목적지를 가리킨다.
- 저장한 종료 증거는 현재 선언을 다시 빌려 권한으로 삼지 않고 검증한다. owner와 inventory는 같은 증거를 읽는다.
- 종료 자체는 Memory 반영, source 소비나 외부 ACK가 아니다. linked 원본은 기존 후속 요청의 durable intent와 부모 확인 절차를 따른다.
- predecessor가 있는 원본은 기존 fence와 해소 intent 아래에서 이어간다. 새 자식의 전체 본문과 ID를 먼저 저장하고, 실제 자식 저장을 확인한 뒤 부모 ACK를 남긴다. 중단 뒤에는 같은 intent의 같은 자식을 복구하며 별도의 fresh root로 빠지지 않는다. 실제 새 자식의 Memory 반영과 원래 source ACK를 확인하기 전에는 해소 완료가 아니다.
- host의 Cut 기록은 provider의 종료나 옛 실행의 배타성을 증명하지 않는다. 후속 반영과 ACK는 원본의 실행 claim과 효과 차단을 실제로 확인하는 경계를 따로 거쳐야 한다.
- 같은 종료 사실로 새 root를 반복해서 만들지 않는다. 새 원본을 이 정책으로 다시 끝내려면 그 원본의 선언이 또 교체돼야 한다.
- 끊긴 원인이 선언 교체였다고 단정하지 않는다. 준비된 새 선언을 적용한 운영자의 선택이 새 시도를 허용한다.
- 다시 만든 요청은 model을 한 번 더 부를 수 있다. 정상 결과·Gate·Memory·ACK 검사는 새 요청에서도 모두 필요하다.
- 이 정책은 같은 선언의 Cut, `raised`, floor Cut, admission Cut를 허용하지 않는다. 같은 선언에서의 복구 계약은 #50828에서 따로 다룬다.
- 첫 생성 요청의 허가를 기다리다 취소되어 시작 표시가 없는 원본은 3.2의 실행 전 경로를 따른다. 시작 표시를 가진 Cut과 섞지 않는다.
- 첫 생성 요청 전에 guard가 선언 교체로 거절한 요청은 typed `Replaced_declaration` 종료를 따른다. 앞서 완료된 deferral의 실제 bound proof가 남을 수 있으며, 이를 Cut 결과와 혼동하지 않는다.

main `cd28f2ac4174`의 L3(#52695)는 다음 경로로 Cut 원본을 정리한다.

- inventory 검사는 원래 host의 `Cut`을 확인하고 `frontier`를 돌려준다. 그 `Cut`의 교체가 released 이면 `Settled`, 아니면 `Unfinished` 다. pass가 현재 목적지와 비교해 정리할지 정한다. `Cut`을 `Interrupted`나 답으로 바꾸지 않는다.
- 현재 목적지는 그 pass가 첫 Cut 원본을 만났을 때 한 번 읽는다. inventory 판정과 owner의 깨움은 그 값을 함께 쓴다. 새 원본을 만들거나 접수 전을 확인하는 다른 자리는 따로 읽는다.
- inventory 검사는 `io`에서 돌고 목적지는 pass의 fiber에서 읽는다. 목적지를 읽지 못하면 기다리고 까닭을 로그에 남긴다. `Finished`·`Conflicted`만 묻는 운영자 해소 흐름은 이 판정을 쓰지 않는다.
- 정상 Exact 경로는 요청별 claim을 잡은 채 실행한다. 이미 terminal이 있으면 다시 실행하지 않는다. proof로 답을 복원하는 경로도 terminal이 없는 `Started`에만 열린다.
- Memory 반영은 살아 있는 원본을 다시 읽고 실제 `Answered` judgment와 host 답을 요구한다. 원래 Cut은 그 검사를 통과하지 못한다. provider가 원격에서 끝났는지는 여전히 모른다.
- 현재 L3는 별도 교체 종료를 저장하지 않고 archive 이동을 종료로 삼는다. 별도 종료 기록과 rollback에 관한 위 정책과의 차이는 3.7에 적는다. 기존 효과 차단은 위의 claim·terminal·원본 재확인으로 설명한다.

이 설명은 소스에서 확인한 경로다. 동작 시험·배포·실제 Memory 반영이나 ACK 완료를 뜻하지 않는다.

### 3.6 교체된 선언의 원본을 끝낸 pass 는 자기 Keeper 를 깨운다

- 지금은 원본을 정리한 pass 뒤에 그 Keeper 의 다음 pass 를 부르는 것이 없다.
  - `Exact_result_delivered` 는 요청 하나에 한 번 나온다. 그 한 번을 정리하는 pass 가 쓴다.
  - 그 pass 는 "반영하지 않음"으로 끝나고 drain 은 다시 돌지 않는다(`lib/keeper/keeper_librarian_queue_refresh.ml` 326~337행).
  - 쉬는 Keeper 는 다음 턴이 끝나거나 다른 설정 사건이 올 때까지 그 범위를 다시 만들지 않는다.
- 규칙: 검증된 선언 교체 종료를 저장하거나 복원해 원본을 정리한 pass는 받은 `wake`를 한 번 부른다. 자리는 셋이다.
  1. host가 저장한 `Not_allowed {reason=Replaced_declaration}`를 복원했을 때(3.2)
  2. Keeper가 접수되지 않은 원본의 종료 증거를 저장하거나 복원했을 때(3.3)
  3. history Cut의 별도 미소비 종료 증거를 저장하거나 복원했을 때(3.5)
- 현재 관계만으로 깨움 권한을 만들지 않는다. 저장 뒤 선언을 되돌리거나 목적지를 읽지 못해도 같은 종료를 복원한다.
- 서버가 멈춰 끊긴 거절이 이미 같은 자리에서 같은 일을 한다(`keeper_librarian_durable_owner.ml` 195~202행).
- 같은 종료를 읽을 때마다 root나 깨움 의무를 새로 만들지 않는다. 저장된 후속 요청이 있으면 그것을 이어간다. 깨워진 pass가 지금 선언으로 만든 새 원본은 새 선언 교체가 없으면 이 규칙에 들지 않는다.
  - package 를 올리면서 output 이나 schema 를 뺐다면 새 원본도 `Not_allowed`를 받을 수 있다(`lane_addon_exact.ml` 945~951행). 그 사유는 `Permission_refused`라 교체 종료가 아니므로 다시 깨우지 않는다.
- 조건 없이 깨우지 않는다. 같은 선언에서 받은 `Not_allowed` 는 원인이 남아 있을 수 있다. 그때 깨우면 만들기, 거절, 정리, 깨움이 다른 신호 없이 돈다.
- floor step 은 chain 의 "교체된 선언에서 멈췄다" 갈래를 받은 pass 가 같은 `wake` 를 부른다(3.3, L2b). `Stopped` 는 깨우지 않는다.
- admission도 3.9의 묶음 교체 의무를 저장한 뒤 같은 원칙으로 다음 pass를 요청한다.

### 3.7 선언을 되돌리면

- 저장된 선언 교체 종료는 유지된다. 선언을 되돌려도 끝난 ID를 다시 실행하지 않는다.
- 다음 읽기는 당시 준비된 선언으로 새 원본을 만든다. 그 원본도 나중에 실제 선언 교체가 확인되면 같은 종료 정책을 따른다.
- 종료만 저장되고 새 자식 intent를 만들기 전에 rollback하면 당시 준비된 목적지로 새 자식을 만들 수 있다. intent가 이미 저장됐다면 목적지와 본문을 바꾸지 않고 같은 자식을 복구한다.
- 새 worker가 준비되기 전에 되돌렸다면 3.1의 교체 조건이 성립하지 않으므로 종료 증거를 만들지 않는다.
- host가 끝낸 뒤 Keeper가 읽기 전에 되돌려도, 저장된 명시적인 종료 사유를 복원한다. 현재 관계가 `Same`이라는 이유로 좁히거나 실행을 재개하지 않는다.

위는 별도 종료 증거를 남기는 정책이다. 현재 main L3(#52695)는 다음처럼 동작한다.

- 별도 교체 종료 사유를 저장하지 않는다. archive로 옮기는 pass 전에 선언을 되돌리면 같은 선언의 Cut으로 읽고 다시 기다린다. Keeper가 Cut을 읽기 전이나 읽고 깨운 뒤에 되돌려도 같다.
- archive로 옮긴 뒤에는 선언을 되돌려도 끝난 상태를 유지한다.
- 해소 흐름이 만든 자식 원본은 archive로 옮겨지지 않을 수 있다(5절, #52659). 교체된 선언에서는 정리된 것으로 읽지만 라이브 기록이 남는다. 선언을 원래 값으로 되돌리면 다시 끝나지 않은 원본으로 읽힌다. 새 원본도 끝나지 않았으면 "끝나지 않은 원본이 둘"이라는 오류가 나고, 새 원본이 끝났으면 옛 원본을 기다린다. 선언을 다시 바꾸면 풀린다.
- 3.2·3.3으로 끝난 자식은 사유가 저장돼 있어 rollback으로 뒤집히지 않는다. 9.1·9.2의 별도 종료 기록과 그 기록을 복원하는 정책은 현재 L3에 들어 있지 않다.

### 3.8 이미 받은 답과 미실행 Gate

- 운영자는 답을 보존하고 Gate를 이어가는 쪽을 선택했다(9.3). history·floor step·admission에 같은 정책을 적용한다.
- 이 절의 Gate 재개는 흡수 판정이나 반영이 남은 답에 적용한다. admission의 `Deferred` 판정은 보존하되 Gate·Memory 반영을 기다리는 답으로 취급하지 않는다. 그 미소비 후보는 3.9의 전체 재판단에 포함한다.
- 원래 답의 host terminal·최신 실행 proof·원본 입력을 먼저 확인한다. 받은 답을 새 Librarian 요청의 결과로 바꾸거나 다시 묻지 않는다.
- 새 Gate 실행 전에는 같은 물리 Keeper·Memory epoch·설치·package·tool이며, 현재 선언으로 준비된 worker인지 확인한다.
- 선언 revision만 달라졌다는 이유로 Gate를 막지 않는다. 다른 owner·설치·package·tool이나 준비되지 않은 worker는 권한을 주지 않는다.
- 이미 저장한 Gate의 질문, 판정 목적지와 원래 답의 결속은 계속 검증한다. 이미 받은 판정은 복원한다.
- 이미 전송한 Gate의 결과와 불확실성은 보존한다. 전송 중이거나 결과가 불명확한 Gate를 미실행으로 바꿔 다시 보내지 않는다.
- 이 권한은 받은 답의 미실행 Gate에만 해당한다. 답 없는 옛 원본의 접수·provider 전송이나 새 admission part의 실행 권한을 넓히지 않는다.

### 3.9 admission의 미소비 묶음

- part나 실행이 명시적인 선언 교체 종료 조건을 충족하면 미소비 묶음 전체를 새 root 요청으로 다시 판단한다(9.4).
- 한 part의 종료가 형제 part나 실행의 권한을 대신하지 않는다. 인계 전에 묶음 전체 frontier와 각 연결 실행을 확인한다.
- Gate·반영이 남은 `Accepted` 답이 있으면 기존 원본의 Gate·Memory·receipt·ACK 경로를 먼저 마친다(3.8). 그 답을 새 root에 넣어 다시 판단하지 않는다. `Deferred` 후보에는 Gate나 소비 receipt를 먼저 요구하지 않고 아래의 인계 대상에 남긴다.
- 접수됐거나 전송 중인 실행, 결과 불명, Cut·Raised가 미해소 상태로 남아 있으면 전체 인계를 보류한다. 다른 part의 교체 종료에 동승해 다시 실행하지 않는다.
- 그 뒤 남은 모든 후보가 `Deferred` 판정이거나 엄격하게 검증된 교체 종료로 인계 가능한지 확인하고, 남은 미소비 묶음 전체를 새 root로 넘긴다.
- 같은 묶음에서 이미 `Deferred`였던 후보도 포함한다. 후보별로 소유권을 쪼개 이어가지 않는다.
- 실제 완료 receipt와 ACK로 소비된 후보는 제외한다. 새 root는 남은 후보를 빠뜨리거나 중복 소유하지 않아야 한다.
- 실행 요청을 아직 만들지 않은 part는 전체 실행 inventory에서 자신을 가리키는 실행이 실제로 없는지 확인한다. 가짜 capture나 실행 부재 증거를 만들지 않는다.
- 새 root의 전체 후보·원본·목적지 결속과 이전 root의 소유권을 저장하고 확인한다. 재시작이나 선언 rollback 뒤에도 같은 새 root를 복구한다.
- 종료 사실 하나를 반복 사용해 새 root를 계속 만들지 않는다. 이전 part와 실행은 실제 후속 완료와 전체 후보 receipt·ACK가 확인된 뒤 정리한다.
- admission Cut·Raised와 Gate·반영이 남은 `Accepted` 답은 새 root를 허용하는 종료 사유가 아니다. 그런 답은 3.8의 Gate 정책을 따른다. `Deferred`와 구분한다.

## 4. 순서 따라가기

### 4.1 package 를 올린다

Keeper 다섯이 서로 다른 phase 에 있다.

- A: 접수되어 차례를 기다린다.
- B: 접수를 거절당했다.
- C: host 가 지금 실행 중이다.
- D: 답을 받았고 gate 를 아직 시작하지 않았다.
- E: worker 에 기록이 없다.

| 틱 | 일 | A | B | C |
|---|---|---|---|---|
| N | 운영자가 선언을 고친다 | 대기 | 대기 | 실행 중 |
| N+1 | Runtime 이 바뀐 선언을 관찰하고 앞 worker 를 물린다 | | | 실행이 취소된다. 첫 생성 요청을 보내기 직전까지 갔으면 시작 표시가 남는다 |
| N+2 | 새 worker 가 붙고 대기 목록을 이어받는다. export 목록이 바뀌어 저장된 Keeper 가 모두 깬다 | | | |
| N+3 | host cycle 이 목록을 돈다 | 선언이 교체됐다. `Not_allowed {reason=Replaced_declaration}` 을 저장하고 전달한다. A 가 깬다 | 목록에 없다 | 끊긴 시도를 `outcome_unknown` 으로 끝내고 전달한다. C 가 깬다 |
| N+4 | 각 Keeper 의 pass | host의 명시적인 교체 종료로 원본을 끝낸다. 좁히지 않는다. 자기를 깨운다 | 실행 부재와 선언 교체를 확인해 `Refused {Before_dispatch}`를 남긴다. 자기를 깨운다 | 엄격하게 결속된 Cut을 확인하고 별도 미소비 종료 증거를 남긴다. 자기를 깨운다 |
| N+5 | 깨워진 pass | 읽은 위치에서 미소비 입력을 새 선언으로 고른다 | 같다 | 원래 Cut은 보존하고, 저장된 후속 요청과 효과 차단 조건을 확인해 이어간다 |

- D는 원래 답을 보존하고 3.8의 조건으로 미실행 Gate를 이어간다. 이미 전송한 Gate는 다시 보내지 않는다.
- E의 worker 부재는 별도 복구 계약을 따른다(5절, #50828). 선언 교체만으로 실행 부재를 만들어내지 않는다.
- 깨움 사건은 N 과 N+2 사이에 세 번 나온다. 바뀐 선언을 관찰할 때, 앞 worker 를 물릴 때, 새 worker 가 붙을 때다(`lane_addon_runtime.ml` 4566행, 3407행, 1394행). 깨는 것은 저장된 Keeper 전부, admission 큐의 Keeper, 원본을 든 Keeper 다(`server_librarian_addon_wake.ml` 71~104행). 앞의 둘은 새 worker 가 붙기 전이라 그 pass 들은 지금처럼 오류로 끝난다.
- N+2 의 신호로 깬 Keeper pass 가 host 의 N+3 보다 먼저 오면 A 는 지금처럼 거절 오류를 한 번 낸다. host 가 끝낸 뒤의 pass 가 정리한다.
- 위 표의 C 는 시작 표시가 남은 경우다. C 가 첫 생성 요청의 허가를 기다리다 취소됐으면 시작 표시가 없다(#51269). 그 C 는 N+3 에 A 와 같은 길로 간다.
- C 가 취소로만 끝나지는 않는다. N 과 N+1 사이에 walk 가 다음 slot 으로 넘어가면 guard 가 고친 파일을 읽고 거절한다(3.2). 그 시도는 미뤄진 시도로 남고 C 는 N+3 에 A 와 같은 길로 간다.
- 앞 worker 가 container 를 기다리는 중이면 Runtime 은 그 worker 를 물리지 않는다(`lane_addon_runtime.ml` 4270~4274행). N+1 이 그만큼 늦어진다.
- 지금은 한 번에 하나를 실행한다. C 는 선언을 바꿀 때마다 많아야 하나다. 함께 실행하는 수를 늘리면(#51272) 그만큼 는다.

### 4.2 중간에 서버가 멈춘다

| 멈춘 자리 | 다시 뜬 뒤 |
|---|---|
| host 가 `Not_allowed` 를 저장한 뒤, 전달하기 전 | 다음 cycle 이 저장된 결과를 전달한다(`lane_addon_exact.ml` 972행). Keeper 는 worker 가 아니라 host 기록을 읽으므로 전달을 기다리지 않는다 |
| host 가 저장하기 전 | 요청은 대기 목록에 그대로 있다. 다음 cycle 이 다시 판정한다 |
| Keeper 가 `Refused` 를 저장한 뒤, 깨우기 전 | 깨움은 프로세스 안의 신호라 사라진다. 기동 뒤 선언을 처음 관찰할 때 저장된 Keeper 가 모두 깬다(`lane_addon_runtime.ml` 4196~4197행, `server_librarian_addon_wake.ml` 71~104행). 그 pass 가 정리된 원본으로 읽고 새로 만든다 |
| Keeper 가 저장하기 전 | 다음 pass 가 같은 비교를 다시 한다 |
| host 가 history 요청을 실행 중일 때 | 그 시도는 `interrupted` 로 끝난다. RFC-0500 의 길이다. floor step 과 admission 은 그 길이 없다(5절) |

- 재시작 뒤에도 원래 결과, 교체 종료, 후속 요청의 결속을 각각 복원해야 한다. 새 ID라는 사실만으로 중복 반영 방지가 증명되지는 않는다. 결과·Gate·Memory receipt·source 소비·ACK 경계의 확인이 모두 필요하다.
- 서버가 살아 있는 채로 깨움이 빠지는 경우가 셋 있다. Keeper 의 `Refused` 저장 결과가 불확실하게 돌아온 때와, 저장과 깨움 사이에서 pass 가 취소된 때다. 그 pass 는 오류로 끝나고 깨우지 않는다. 저장이 됐다면 다음 신호(턴 종료, 설정 사건)의 pass 가 정리된 원본으로 읽고 새로 만든다. 서버가 멈춰 끊긴 거절의 깨움(RFC-0500)도 같은 모양이다. 저장이 안 된 것을 깨움으로 메우면 저장이 계속 실패하는 동안 pass 가 다른 신호 없이 돈다. 셋째는 Cut 거절을 받은 pass가 현재 목적지를 읽지 못한 때다(현재 L3, 3.5). 그 pass는 깨우지 않고 까닭을 로그에 남긴다. 선언이 교체된 채라면 다음 신호의 pass가 inventory에서 정리된 원본으로 읽는다. Add-on이 다시 붙는 것도 그 신호다.

### 4.3 설명서의 `run_id` 절차

- 한 Keeper 의 capacity 거절을 풀려고 `run_id` 를 바꾼다.
- 그 Keeper 는 지금처럼 새 요청을 만든다.
- 다른 Keeper 의 대기 원본은 4.1 의 A, B, C 처럼 끝나고 새 선언으로 다시 만들어진다.

### 4.4 여러 slot 과 여러 계정

- slot 은 host 가 실행할 때 고른다. 3.2 와 3.3 으로 끝난 요청은 답을 받은 적이 없다.
- 다시 만든 요청은 id 가 새것이라 앞 요청의 시도를 이어받지 않는다. 실행될 때의 registry 로 slot 을 처음부터 고른다.
- 선언 revision 은 registry 를 담지 않는다(1.1). context window 가 다른 slot 으로 넘어가는 흐름은 이 규칙과 만나지 않는다.

## 5. 별도 복구 계약을 따르는 경우

이미 받은 답의 Gate와 admission 미소비 묶음은 각각 3.8·3.9에서 다룬다. 아래 경우는 그 권한을 얻지 않는다. 수량은 1.8의 역사적 관측으로 대신하지 않고 실제 배포 대상에서 확인한다.

| 무엇 | 이 정책의 경계 | 어디서 다루나 |
|---|---|---|
| worker 에 기록이 없는 `Dispatch_pending` 원본 | worker 조회가 목적지 확인에 막힐 수 있다 | #50828. 부재를 증명하는 조회와 기존 원본의 후속 요청 계약을 따른다. 이 문서는 부재를 추정해 끝내지 않는다 |
| 선언의 `id` 를 바꾼 때 | Keeper 는 tool 이름으로 지금 설치를 찾는다(`keeper_librarian_durable_edge.ml` 57~59행). 설치가 달라서 pass 마다 거절한다. worker 저장소는 설치마다 따로라 새 설치의 worker 는 앞 설치의 대기 목록을 받지 않는다. host 는 그 요청을 보지 못한다 | 따로 설계한다. 이 문서의 host 규칙은 대기 목록을 이어받은 worker 가 있어야 선다 |
| 새 worker 가 앞 worker 의 기록을 host 에 주지 못할 때 | worker 는 기록 하나라도 읽지 못하면 멈춘다(`addons/exact_worker.py` 289~292행). 대기 목록이 새 frame 에 들어가지 않으면 목록 호출이 실패한다(433~434행). host 는 대기 목록을 받지 못하고 아무것도 끝나지 않는다 | package 를 바꾸는 쪽이 지킬 조건이다. 새 package 는 저장된 기록을 그대로 읽고 `max_reply_bytes` 를 줄이지 않는다. #51280 의 수리가 이 조건을 지켜야 한다 |
| `ui_category` 만 바꾼 설치 | revision 이 그대로라 교체가 아니다. host 가 그 설치의 요청을 실행하지 않고 Keeper 는 계속 접수한다 | #51300, 수리는 #51308 |
| 같은 선언의 history Cut·`raised`로 끝난 원본 | 선언 교체 종료로 해소하지 않는다 | #50828. 실제 원인과 실행 증거를 보존한다 |
| 해소 흐름이 만든 자식 원본(선행 원본이 fence 됨)이 답 없이 정리된 때 | 끝난 자식은 archive 로 옮겨지지 않는다. chain 을 옮기는 규칙은 선행 원본이 정리된 목록에 있을 때만 서고, fence 된 원본은 그 목록에 들지 않는다(`keeper_librarian_durable_execution.ml` 의 `finished_chains`). 해소 intent 는 완료가 관찰되지 않은 채 남는다. pass 는 막히지 않고 새 범위를 고른다. 실행에서 거절된 자식도 같다. 3.3과 현재 L3의 Cut 정리는 이 모양에 닿는 길을 하나씩 더한다. 현재 L3로 정리된 자식은 rollback 뒤 끝나지 않은 원본으로 돌아온다(3.7) | #52659 |
| 실행 중 끊긴 floor step·admission | history의 Cut 교체 정책을 적용하지 않는다. 원래 결과 불명을 보존한다 | 각각의 복구 계약을 따로 설계한다. RFC-0500 3.4절도 floor step을 뒤로 미뤘다 |

## 6. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 새 선언에서 답 없는 예전 요청을 그대로 실행한다 | 운영자는 요청을 만든 선언의 전송 권한을 유지하고 미소비 입력으로 새 요청을 만드는 쪽을 선택했다(9.1). 받은 답의 Gate 권한(3.8)은 원본의 재전송 권한이 아니다 |
| 접수되지 않은 원본도 worker 에 보내 host 가 끝내게 한다 | `Admission_wait` 는 대기 목록에 못 들어가서 생긴 phase 다. 다시 보내도 같은 이유로 거절된다(#51280). 끝나지 않는다 |
| Keeper가 host 증거 없이 접수된 요청을 스스로 끝낸다 | worker가 그 요청을 계속 들고 있을 수 있다. 선언을 되돌리면 host가 실행하고 답은 아무도 읽지 않는다. 실제 원본 실행·종료 증거와 효과 차단을 확인해야 한다 |
| worker 에 취소 호출을 더한다 | package 를 바꿔야 한다. 그 배포가 선언 revision 을 바꾼다. 지금 기다리는 원본에는 쓸 수 없다 |
| 거절이 N번 쌓이거나 T시간 지나면 끝낸다 | 근거 없는 숫자다. 선언이 교체됐는지는 비교로 정해진다 |
| 사유를 저장하지 않고, Keeper 가 읽을 때 원본의 목적지와 지금 목적지를 비교해 정한다 | 얻는 것: worker 가 받는 모양이 그대로라 서버만 올리면 된다. 고르지 않은 이유: host 가 끝낼 때 아는 까닭을 Keeper 가 나중 설정으로 다시 짐작하게 된다. 선언을 되돌린 뒤에 읽으면 같은 선언의 거절로 읽혀 좁아지고 깨우지 않는다. 지금 선언을 읽지 못하면 정하지 못한다. 권한 거절 뒤에 선언이 바뀌면 교체로 읽힌다. host 의 guard 와 Keeper 가 설정을 따로 읽어 둘이 어긋날 수 있다. 사유를 저장하는 쪽의 대가는 worker 가 받는 모양 하나와 package 0.2.5 다(7절). `reason` 글자를 가진 기록은 `Permission_refused` 로 그대로 읽혀서 저장된 기록은 건드리지 않는다 |
| 선언 파일만 보고 교체를 정한다 | 고치는 중간 상태에서 요청이 끝난다. worker 가 붙은 것은 Runtime 이 그 선언을 실제로 적용했다는 사실이다 |
| `Not_allowed` 는 선언과 상관없이 좁히지 않는다 | 근거는 같다. 실행하지 않은 요청은 크기에 대해 말하지 않는다. 다만 같은 선언에서 거절이 되풀이될 때 요청마다 밀린 범위 전체를 다시 쓰게 된다. 선언 교체와 다른 문제라 여기서 바꾸지 않는다 |
| `cut` 을 선언과 상관없이 끝난 것으로 읽는다 | 되풀이를 묶는 것이 없다. RFC-0500 이 막은 이유 그대로다 |

- Curator 는 다른 선택을 했다. 자기 guard 가 없고, 이어 붙일 때 설치·package·tool 만 본다(`lib/server/server_workspace_memory_addon.ml` 120~134행). 이 문서는 Curator 를 바꾸지 않는다.

## 7. 층

아래는 구현을 나누는 단위다. 층 목록은 현재 head의 구현·회귀·배포 판정을 대신하지 않는다.
마지막 칸은 그 층을 main 에 넣은 PR 이다. 병합은 배포나 실제 원본 회복을 뜻하지 않는다.

| 층 | 바꾸는 것 | 확인 | main 반영(2026-11-17) |
|---|---|---|---|
| L0 | 목적지 관계 타입(3.1). `Not_allowed` 사유 타입과 worker wire, 명시적인 교체 종료의 저장·복원, 좁히기(3.4), 깨움(3.6)의 공통 계약 | 8절의 종료 증거·좁히기·깨움 시험 | #52621 |
| L1 | guard 결과 타입, `run`의 갈래, Runtime 판정과 host의 종료 사유(3.2). Exact·Runtime의 계약과 설명서. keeper-librarian package 0.2.5 | 8절의 host 시험 | #52622 |
| L1b | CLI walker가 전송 전 guard 거절을 값으로 받아 멈추고 receipt를 남긴다(3.2). #51343으로 main에 병합됐다 | 8절의 CLI 시험. 이 병합은 다른 층의 완료 증거가 아니다 | #51343 |
| L2a | 목적지 확인 통합, 정본 접수 phase·전송 의도에 결속한 종료, history owner·inventory의 같은 종료 판정(3.3) | 8절의 Keeper 시험 | #52674 |
| L2b | floor step owner·chain의 실행 전 교체 종료와 후속 pass(3.3) | 8절의 floor 시험 | 없음 |
| L3 | history Cut의 별도 미소비 종료, 후속 요청 결속과 옛 실행의 효과 차단(3.5). 현재 archive 방식과 정책 차이는 3.5·3.7에 구분한다 | 8절의 Cut·재시작·Memory·ACK 시험 | #52695 |
| L4 | admission 미소비 묶음 전체의 새 root, Deferred 후보 보존과 소유권 인계(3.9) | 8절의 admission 시험 | 없음 |
| L5 | 받은 답을 보존하고 같은 owner·설치의 미실행 Gate를 이어가는 권한(3.8) | 8절의 Gate 시험 | 없음 |

- L0 이 L1 보다 먼저다. L1 만 들어가면 선언을 바꿀 때 기다리던 Keeper 가 모두 한 턴씩 읽게 되고, 쉬는 Keeper 는 다음 턴까지 그 범위를 다시 만들지 않는다.
- L1b 는 다른 층에 기대지 않는다. L1 없이 들어가도 CLI slot 의 guard 거절이 `raised` 대신 미뤄진 시도로 남는다. 그 요청은 선언을 되돌리면 다시 실행된다.
  - CLI walker 는 Librarian 밖의 소비자도 쓴다. 바꾸는 것은 관찰 함수가 거절을 돌려줄 수 있게 하는 것이고, 거절을 돌려주지 않는 소비자의 동작은 그대로다.
- L3은 관계 타입 외에도 원래 실행 증거, 저장된 후속 요청과 source 효과 차단을 함께 쓴다. L4·L5도 각각 묶음 소유권과 Gate의 원래 답을 검증한다. 공통 관계 타입만 붙였다고 소비자 통합이 끝난 것은 아니다.
- 1.8의 floor·admission 수량을 근거로 구현을 생략하거나 배포를 허용하지 않는다. 실제 대상의 전체 연결 기록을 확인한다.
- 서버 설치, 새 package 적용, 실제 원본의 회복은 별도 단계다. `/health`의 build commit은 실행 중인 바이너리의 근거이며 회복 증거가 아니다.
- package 적용 전에는 대상 후보에서 저장된 원본·owner·Gate·source·receipt·ACK의 연결을 읽고, 새 worker가 기존 대기 목록을 읽어 host에 줄 수 있는지 확인한다(5절).
- 새 종료 증거와 후속 요청의 저장 형식은 각 구현 층에서 엄격하게 정의한다. 기존 codec으로 모두 읽힌다고 미리 가정하지 않는다. 읽기 전용 preflight의 성공은 Memory 반영이나 ACK 완료가 아니다.
- L0 은 worker 코드(`addons/exact_worker.py`)도 바꾼다. 새 모양(`"cause":"declaration_replaced"`)을 받는 image 는 keeper-librarian 0.2.5 다. 나머지는 서버 코드다.
  - 0.2.4 image 의 worker 는 그 전달에 오류로 답하고 요청을 대기 목록에 남긴다. base 의 `exact_worker.py` 에 `addons/tests/test_keeper_librarian.py` 의 재시작 시험을 돌려 확인했다.
  - 그때도 Keeper 는 다음 pass 에 host 기록에서 그 종료를 읽는다(`lane_addon_submit_once.ml` 의 `Dispatch_pending` 갈래). 전달 사건이 없어서 그 pass 는 다른 신호를 기다린다. worker 의 대기 기록은 0.2.5 가 붙을 때까지 남아 목록의 자리를 차지하고, host 는 cycle 마다 전달을 다시 해 본다. 이 문단은 코드를 읽어 적었고 실행으로 확인하지 않았다.
- 순서는 서버가 먼저, package 가 다음이다. L0, L1, L1b, L2a, L3 이 라이브에 올라간 뒤에 package 0.2.5 를 고른다. `/health` 의 build commit 으로 서버를 확인한다.
  - 0.2.5 를 고르는 것이 선언 교체다. 그때 붙는 worker 가 0.2.5 라서 그 종료를 받는다.
  - 서버를 올린 뒤 0.2.4 image 인 채로 선언을 바꾸면(`run_id` 만 바꾸는 절차 포함) 위의 남는 기록이 생긴다. 서버를 올린 뒤 처음 하는 선언 변경을 0.2.5 로 한다.
  - 올리기 전에 볼 것은 둘이다(5절).
  - 기다리는 admission 실행이 0개인가.
  - 새 package 가 저장된 기록을 그대로 읽고 `max_reply_bytes` 를 줄이지 않는가.
- 3.2의 `reason` 글자를 가진 `Not_allowed` 기록은 `Permission_refused`로 읽힌다. 진행 기록의 `Refused`도 기존 codec을 쓴다. 이 사실은 새 Cut 종료·admission 인계 형식을 이미 읽을 수 있다는 증거가 아니다. L1b walk receipt의 갈래는 그 층에서 정한다.

## 8. 시험

host·Runtime·Keeper·Memory·ACK 사이의 실제 권한과 저장 경계를 확인한다. 이 절은 필요한 검증 시나리오이며 실행 결과표가 아니다. 화면 배치 시험은 쓰지 않는다.

- host
  - 실행을 시작하기 전 guard가 `Not_now`면 종료나 새 실행 증거를 만들지 않는다. 다시 허락하면 같은 요청이 실행된다.
  - guard가 `Declaration_replaced`면 `Not_allowed {reason=Replaced_declaration}`를 저장하고 runner를 부르지 않는다. 선언을 되돌린 뒤에도 같은 종료를 복원한다.
  - 답이 있는 기록은 guard 를 부르지 않고 답을 전달한다. 지금 시험 그대로다.
  - Runtime 의 판정: 파일만 고친 때는 `Not_now`, 새 worker 가 붙은 뒤는 `Declaration_replaced`, 끈 때와 파일이 깨진 때는 `Not_now` 다.
- CLI
  - CLI slot 을 보내기 직전에 guard 가 거절하면 그 slot 의 runner 는 불리지 않는다. host 기록의 그 시도는 미뤄진 시도이고 결과는 없다. `raised` 가 아니다.
  - 그 뒤 guard 가 `Declaration_replaced` 를 주면 같은 요청이 `Not_allowed` 로 끝난다. guard 가 허락하면 같은 요청이 실행된다.
- Keeper
  - 정본 journal의 phase가 `Captured`·`Admission_wait`이고 관계가 `Replaced`면 `Refused {Before_dispatch}`를 저장한다. worker에 보내지 않는다.
  - submit RPC는 새 `Fresh` 전송 의도 뒤에만 보낸다. 같은 의도의 재확인·저장 불확실은 다시 보내지 않는다. `capacity_wait`는 RPC 뒤에도 미접수이며, 전송 뒤 Unknown·부재 응답은 `Dispatch_pending`에 남는다.
  - 원본 binding·journal이 맞지 않거나 읽지 못하면 종료를 거절한다. `Dispatch_pending`을 접수 전으로 취급하지 않는다.
  - 한 Keeper 의 두 pass: 접수된 원본에 host 의 `Not_allowed` 가 있으면 첫 pass 가 정리하고 둘째 pass 가 지금 목적지로 새 원본을 만든다. 접수 거절된 원본도 같은 끝에 닿는다.
- floor
  - 접수 전 step 의 선언이 교체되면 chain 이 "교체된 선언에서 멈췄다"를 돌려준다. pass 는 `wake` 를 한 번 부르고, 다음 pass 가 같은 자리를 새 id 로 묻는다.
  - 같은 선언에서 거절된 step 은 지금처럼 `Stopped` 다. `wake` 를 부르지 않는다.
- 좁히기
  - 검증된 교체 종료는 좁히지 않는다. 저장 뒤 rollback되거나 현재 목적지를 읽지 못해도 같다.
  - 일반 `Not_allowed`는 현재 관계가 `Replaced`여도 교체 종료가 되지 않는다. 설명 글자가 같아도 같다. `Permission_refused`의 다음 읽기는 기존처럼 좁힌다.
  - 실제 입력 크기 거절과 이미 좁힌 범위는 교체 후에도 보존된다. 다음 pass는 그 위치에서 미소비 입력을 고른다.
- worker
  - 교체 종료는 worker 를 다시 띄운 뒤에도 그 모양으로 읽히고 대기 목록에서 빠진다.
  - 모르는 `cause` 와, `cause` 와 `reason` 을 함께 실은 종료는 거절하고 요청은 대기로 남는다.
  - worker 가 교체 종료를 돌려줬는데 host 기록이 없거나, 열려 있거나, 다른 결과면 `Submit.resume` 이 거절한다.
- 깨움
  - 검증된 교체 종료를 정리한 pass는 `wake`를 한 번 부른다. 일반 거절만으로 깨우지 않는다.
  - 종료 저장 뒤 깨우기 전에 서버가 멈추면 저장된 종료와 후속 요청을 복원한다. 같은 종료로 root를 반복 생성하지 않는다.
- 끊김
  - 실행 단계 history Cut의 원래 request·schema·digest·attempt·proof와 교체 관계를 확인해야 별도 종료를 저장한다. 원래 Unknown은 보존한다.
  - 같은 선언의 Cut·Raised·floor Cut·admission Cut는 그 종료를 허용하지 않는다. 시작 표시가 없는 원본은 실행 전 경로와 구분한다.
  - 현재 L3의 durable 시험은 HTTP fixture로 Cut 경로를 검사한다. 시작 표시 뒤 host 예외로 끝나는 Raised 시험은 없다. 그 갈래는 L3가 바꾸지 않았고 Cut과 타입으로 구분한다.
  - 종료를 아직 저장하지 않았고 현재 목적지를 얻지 못하면 inventory와 owner 모두 종료를 만들지 않는다. 이미 저장한 종료는 현재 관계를 다시 빌리지 않고 복원한다.
- 후속 요청·Memory·ACK
  - 후속 요청을 저장한 뒤 본문 준비나 전송 전에 멈춰도 같은 결속을 복원한다. 원본과 결속되지 않은 자식, 바뀐 본문·목적지, 중복 root를 거절한다.
  - 옛 실행이 claim을 놓지 않았거나 효과 차단을 확인하지 못하면 후속 Memory 반영·source 소비·ACK를 하지 않는다. 관찰 fiber만 취소한 경우도 포함한다.
  - Memory receipt가 없거나 다른 원본을 가리키면 source를 소비하지 않는다. 일부 ACK 뒤 재시작해도 증명된 부분만 복원한다.
- Gate
  - history·floor step·admission에서 Gate 대상 답과 proof를 먼저 복원하고, 같은 물리 Keeper·Memory epoch·설치·package·tool과 준비된 worker일 때만 미실행 Gate를 보낸다.
  - owner·epoch·설치·package·tool이 다르거나 worker가 준비되지 않으면 새 Gate를 보내지 않는다.
  - 이미 받은 판정은 보존한다. 이미 전송했거나 결과 불명인 Gate를 미실행으로 바꾸어 다시 보내지 않는다. 받은 답을 원본 재전송 권한으로 쓰지 않는다.
- admission
  - 전체 frontier가 인계 가능한지 확인한 뒤 교체로 끝난 후보와 Deferred 후보가 섞인 남은 미소비 묶음 전체를 새 root로 재판단한다. 실제 소비 receipt·ACK가 있는 후보만 제외한다.
  - 한 후보가 교체로 끝났어도 형제 실행이 접수·전송 중이거나 Unknown·Cut·Raised가 미해소 상태면 전체 인계를 보류한다. Gate·반영이 남은 `Accepted` 답을 가진 형제는 기존 Gate·Memory·ACK로 먼저 마치고 새 root에 재포함하지 않는다. `Deferred` 후보는 Gate나 소비 receipt를 먼저 요구하지 않고 새 묶음에 포함한다.
  - 실행을 아직 만들지 않은 part도 전체 inventory에서 연결 실행의 부재를 확인한다. 일부 목록만 읽었거나 연결 실행이 남아 있으면 교체하지 않는다.
  - 새 root 준비 전후·소유권 인계 전후에 멈춰도 같은 묶음을 복원한다. rollback 후에도 후보 누락·중복 소유·반복 root가 없다.
  - admission Cut·Raised·Gate·반영이 남은 `Accepted` 답은 묶음 교체 사유가 아니며 다른 후보의 종료에도 동승하지 않는다. Gate 대상 답은 기존 Gate 경로로 이어간다.
- 변이
  - CLI walker 가 guard 거절을 다시 예외로 던지게 하면 CLI 시험이 `raised` 로 실패한다.
  - `Declaration_replaced` 를 `Not_now` 로 바꾸면 host 시험이 실패한다.
  - 3.1 의 조건 3 을 빼면 "파일만 고친 때" 시험이 실패한다.
  - 저장된 종료 대신 현재 관계만 보면 rollback·목적지 조회 실패 시험이 실패해야 한다. rollback 시험은
    `test_a_declaration_put_back_before_the_end_is_read_preserves_the_ending`(#52622)이다. 목적지 조회 실패 시험은 2026-11-17 main 에 없다.
  - 전송 의도 확정 전에 submit을 보내거나 전송 뒤 Unknown을 접수 전으로 돌리면 대응 경계 시험이 실패해야 한다. Cut claim·Memory receipt 확인을 빼도 해당 시험이 실패해야 한다.
  - Deferred 후보를 빼거나, 미해소 형제를 다른 후보의 종료에 동승시키거나, 전송된 Gate를 미실행으로 취급하면 각각의 묶음 보존·권한·Gate 재전송 방지 시험이 실패해야 한다.
  - 좁히기 규칙이 사유를 가리지 않게 하면 일반 `Permission_refused`의 좁히기 시험이 실패해야 한다.
  - 깨움이 사유를 가리지 않게 하면 일반 거절은 깨우지 않는다는 시험이 실패해야 한다.


## 9. 운영자가 정한 정책

2026-11-16에 네 선택을 확인했다. 아래 정책은 구현·회귀·배포 완료 주장과 구분한다.

### 9.1 답 없는 요청은 끝내고 새 선언으로 다시 만든다

요청은 만든 선언 안에서만 실행한다는 계약을 유지한다. 선언이 교체되면 검증된 종료 증거를 남기고, 읽은 위치를 옮기지 않은 채 다음 pass가 미소비 입력을 새 요청으로 고른다.

종료된 ID는 선언을 되돌려도 살아나지 않는다. 새 원본을 쓰는 비용과 대기 순서 변경은 받아들인다. 새 worker가 준비되기 전이거나 다른 설치인 경우에는 이 권한이 생기지 않는다.

### 9.2 결과가 불명확한 history Cut도 미소비 종료 후 다시 판단한다

3.5의 Cut 조건과 선언 교체가 확인되면 별도 종료 증거를 남긴다. provider 결과의 불명확성은 그대로 보존한다. 추가 model 요청이 전송될 수 있음을 포함한 선택이다.

재판단 한 번이 보낼 수 있는 model 요청 수의 상한은 정하지 않았다. 9.4는 같은 종료로 root를 반복 만들지 않는다고 보장하지만, 전체 호출량은 막지 않는다. 상한을 둘지는 열린 질문이다.

이 선택은 같은 선언의 Cut이나 Raised, floor·admission의 결과 불명까지 일반화하지 않는다. 기존 원본의 Memory 반영이나 ACK를 허락하는 선택도 아니다.

### 9.3 받은 답은 보존하고 미실행 Gate를 이어간다

같은 물리 Keeper·Memory epoch·설치·package·tool과 준비된 worker라면 새 선언에서 미실행 Gate를 이어간다. 이미 받은 판정, 이미 전송한 Gate의 결과와 불확실성은 보존한다. 원래 Librarian 요청을 다시 보내지 않는다. Gate 대상이 아닌 admission `Deferred` 후보는 3.9의 전체 재판단을 따른다.

### 9.4 보류 후보와 종료 후보가 섞인 admission 묶음은 전체를 다시 판단한다

3.9의 전체 frontier 확인을 거친 뒤 남은 미소비 묶음 전체를 새 root 요청으로 판단한다. 기존 보류 후보도 포함하고, 실제 receipt·ACK로 소비된 후보는 제외한다. Gate·반영이 남은 `Accepted` 답은 기존 Gate·Memory·ACK 경로로 먼저 마치며 미해소 실행이 있으면 전체 인계를 보류한다. `Deferred` 후보에는 Gate나 소비 receipt를 먼저 요구하지 않는다. 모델 호출이 더 생길 수 있는 대가를 받아들이되, 같은 종료 증거로 root를 반복 생성하거나 후보를 잃지 않는다.

## 10. 관련

- #51278: 이 문서의 이슈다.
- #51280: worker 가 요청을 온 순서로 받지 않는다. 그 수리는 package 를 올려야 해서 이 문서의 층 뒤에 온다.
- #51199, #51272: 한 번에 하나씩 실행해서 대기 목록이 느리게 빈다.
- #50828: 끊긴 원본과 worker 에 기록이 없는 원본.
- #51250, #51269: host 는 시작 표시를 첫 생성 요청을 보내기 직전에 저장한다. 그 허가를 기다리다 끊긴 요청은 표시 없이 남고 다음 cycle 에 다시 실행된다.
- #51326: 기다리는 원본의 pass 가 본문을 다시 읽지 않게 하는 설계다. 그 문서도 `Submit.resume` 의 접수 전 갈래를 바꾼다. 순서는 이 문서의 관계 판정(3.3)이 먼저고 그 문서의 `load` 가 뒤다. 판정은 원본 기록의 목적지와 지금 목적지만 읽는다. `load` 는 `Same` 일 때만, 접수 의도를 저장하기 전에 부른다. 다만 pass 는 접수 전 원본의 본문을 inventory 에서 먼저 읽는다(`keeper_librarian_durable_execution.ml` 의 `waits` 는 `Dispatch_pending` 만 고른다). 그래서 본문을 읽지 못하는 접수 전 원본은 이 판정에 닿기 전에 pass 가 오류로 끝난다. 나중에 들어가는 쪽이 이 순서로 맞춘다.
  - 교체 판정과 정본 journal의 접수 전 증거 확인(3.3)은 새 전송을 위한 `load`보다 먼저 한다. 본문을 읽지 못한다는 사실 자체를 종료 증거로 삼지는 않는다. 나중에 통합하는 쪽도 이 권한과 순서를 함께 보존한다.
- #51343: L1b 의 구현이다.
- #51300: `ui_category` 만 바꾸면 host 와 Keeper 의 package 비교가 갈린다.
- RFC-0489 2.5절: Goal 검증도 접수 전 원본을 같은 사건으로 끝내기로 했다. 그쪽은 다음 시도를 잇는 전이를 더 넓힌다. Librarian 은 읽은 위치에서 다시 고르므로 그 전이가 필요 없다. 증거 타입은 소비자마다 자기 것을 쓴다.
- RFC-0500: 서버가 멈춰 끊긴 원본을 정리하고 다시 고르는 길. 이 문서의 3.5는 선언 교체의 history Cut을 별도 미소비 종료로 다루며 원래 결과 불명을 보존한다.
