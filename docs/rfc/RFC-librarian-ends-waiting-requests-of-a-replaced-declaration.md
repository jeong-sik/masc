---
rfc: "librarian-ends-waiting-requests-of-a-replaced-declaration"
title: "선언이 교체되면 그 선언으로 만든 대기 요청을 끝내고 새 선언으로 다시 만든다"
status: Draft
created: 2026-11-11
updated: 2026-11-11
author: claude
supersedes: []
superseded_by: null
related: ["0489", "0500", "librarian-history-unknown-resolution", "librarian-history-settles-finished-originals"]
---

# 선언이 교체되면 그 선언으로 만든 대기 요청을 끝내고 새 선언으로 다시 만든다

이슈 #51278 의 설계 문서다. 코드 위치는 main `3c876bd23e9d` 기준이다. 시작 표시를 저장하는 때와 guard 를 부르는 순서(1.3, 3.2, 3.5, 4.1)는 #51269 가 들어간 main `b6fb3b3ee07e` 기준이고, 그 대목은 줄 번호 대신 함수 이름으로 가리킨다.

## 0. 요약

- keeper-librarian 설치 선언의 revision 이 바뀌면, 그 전에 만든 끝나지 않은 원본은 끝나지 않는다.
  - host 는 그 요청을 실행하지 않는다.
  - Keeper 는 pass 마다 같은 거절을 받고 새 범위를 고르지 않는다.
  - 선언을 예전 값으로 되돌려야만 풀린다.
- 실행을 막는 규칙은 있는데 끝내는 규칙이 없다. 이 문서는 끝내는 규칙을 정한다.
- 다섯을 바꾼다.
  1. host 는 결과도 실행 중 표시도 없는 요청의 선언이 교체됐으면 그 요청을 `Not_allowed` 로 끝낸다.
  2. 실행 중인 요청이 CLI slot 을 보내기 직전에 거절되면 `raised` 대신 미뤄진 시도로 남긴다. 다음 cycle 에 1번으로 끝난다.
  3. Keeper 는 worker 에 접수되지 않은 원본의 선언이 교체됐으면 그 원본을 `Refused {stage=Before_dispatch}` 로 끝낸다.
  4. Keeper 는 교체된 선언에서 실행이 끊긴 원본을 끝난 것으로 읽는다.
  5. 교체된 선언의 원본을 끝낸 pass 는 다음 읽기를 좁히지 않고, 자기 Keeper 를 한 번 깨운다.
- 끝난 원본의 범위는 다음 pass 가 지금 선언으로 다시 고른다. 읽은 위치가 그대로라 입력을 잃지 않는다.
- 새 phase 와 새 설정은 없다. 공용 규약에 있는 사건과 host 에 있는 거절 길을 쓴다. 저장 모양에 더하는 것은 walk receipt 의 갈래 하나다.
- 풀리는 것은 history 원본이다. admission 과, 답을 받고 gate 를 시작하지 못한 원본은 풀지 않는다(5절).
- 먼저 정할 것은 하나다. 교체된 선언의 요청을 끝내고 다시 만들지, 새 선언에서 그대로 실행할지다(9절).

## 1. 지금

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
- 설계 문서는 선언 파일의 바이트만 바뀐 것을 "기존 요청을 옮기거나 다시 쓸 이유가 아니다"라고 적는다(`docs/design/librarian-addon-execution.md` 257~264행). 선언 revision 이 바뀐 때에 옮길지 다시 쓸지는 적혀 있지 않다.

### 1.8 측정

| 무엇 | 값 | 언제, 어떻게 |
|---|---|---|
| 끝나지 않은 history 원본 | 26개. 접수되어 차례 대기 15, 접수 거절 9, worker 에 기록 없음 2 | 2026-11-11 07:44Z, 라이브 기록의 마지막 진행 사건 |
| 기다리는 admission 실행 | 1개 | 같은 조회 |
| 라이브 floor step 기록 | 0개 | 같은 조회 |
| 원본 하나가 담은 범위 | 본문 27개 모두 `all_unread`. 담긴 메시지 중앙값 96개, 최대 7,625개 | 07:39Z, 본문의 범위 필드 |
| 끝나지 않은 원본과 gate 기록이 함께 있던 pass | 4,164번 가운데 0번 | 11-11 00:00~07:40Z, inventory 로그 줄 |
| 이 거절이 로그에 남은 횟수 | 0건 | 11-04~11-11 WARN·ERROR 줄. 라이브 선언 파일은 10-23 이후 바뀌지 않았다 |

- 아직 일어난 적은 없다. 코드로 따라간 결과다.
- 지금 package 를 올리면 대기 15명과 접수 거절 9명, 합쳐 24명의 durable Librarian 이 새로 멈춘다. 기다리는 admission 실행 1개도 멈춘다.

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
  - `Declaration_replaced` 면 `deny` 로 간다. host 기록에 `Not_allowed` 를 저장한다. 같은 cycle 이 그 결과를 worker 에 전달한다.
  - `Not_now` 면 지금처럼 `Error` 다. 아무것도 쓰지 않고 요청은 대기 목록에 남는다.
- 이미 끝난 기록은 guard 를 부르지 않는다(971~972행).
  - 답이 있는 요청은 지금 package 가 그 output 과 schema 를 그대로 선언하는 한, 선언이 교체된 뒤에도 그 답을 전달한다.
  - 선언하지 않으면 지금처럼 전달을 거절한다(940~942행). 그 규칙은 바꾸지 않는다.
- 실행 중인 walk 도 slot 마다 보내기 직전에 같은 guard 를 부른다. guard 는 선언 파일을 그때 새로 읽는다(`lane_addon_runtime.ml` 619~629행). 운영자가 파일을 고친 뒤 Runtime 이 앞 worker 를 물리기 전에도 거절이 나온다.
  - guard 를 부르는 자리는 둘이다. `run` 이 실행을 시작하기 전에 한 번 부르고, walk 가 slot 마다 부른다(`run` 안의 `before_dispatch`).
  - 생성 요청(`Generation`) 앞에서는 시작 표시를 먼저 저장하고 그 뒤에 guard 를 부른다(#51269). 계량 요청(`Measurement`) 앞에서는 guard 만 부른다.
  - HTTP slot 에서 거절되면 walk 가 그 자리에서 멈춘다. 끝 저장이 그 시도를 미뤄진 시도(`Deferred`)로 적는다(`lib/server/server_lane_addon_exact.ml` 117~119행, 146~157행). 방금 쓴 시작 표시는 그 저장에서 `Deferred` 로 바뀐다. 다음 cycle 에 위 갈래로 온다.
  - CLI slot 에서 거절되면 예외로 끝나고, 끝 저장이 그 시도를 `raised` 로 적는다(같은 파일 174~177행, 225~229행, `lane_addon_exact.ml` 995행). CLI walker 의 관찰 함수가 값을 돌려주지 못해서다(`lib/keeper/keeper_lane_cli_oneshot.ml` 400행). `raised` 원본은 끝내는 길이 없다.
  - guard 가 거절했다는 것은 그 slot 에 보내지 않았다는 뜻이다. 결과를 모르는 것이 아니다. CLI walker 가 보내기 전의 거절을 값으로 받아 그 자리에서 멈추게 한다. 그 시도는 HTTP 와 같이 `Deferred` 로 남고 다음 cycle 에 위 갈래로 온다(7절의 L1b, #51343).
  - walk 안의 guard 에는 두 결과를 글자로 바꿔 넘긴다. walk 안에서는 어느 쪽이든 멈추기만 한다.
- 실행이 취소되어 끊긴 요청은 3.5 에 있다.
- `authorize_captured_exact_dispatch` 는 3.1 의 조건으로 셋 가운데 하나를 돌려준다. 허가, `Declaration_replaced`, `Not_now` 다.
- Librarian guard 는 셋이다(`lib/server/server_librarian_addon_validation.ml` 43·88·138행).
  - history 와 floor step 의 guard 는 Runtime 의 결과를 그대로 돌려준다. 그 앞의 읽기 실패는 `Not_now` 다.
  - admission 의 guard 는 모두 `Not_now` 로 돌려준다. 지금 동작 그대로다. 이유는 5절에 있다.
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
  - admission 과 Curator 의 확인 함수는 `Replaced` 를 돌려주지 않는다. 그 둘의 동작은 그대로다.
- 이 사건과 전이는 공용 규약에 이미 있다(`lib/lane_addon/lane_addon_request_progress.ml` 의 `Refused` 전이). 지금 `lib` 와 `bin` 어디에도 이 사건을 쓰는 곳이 없다.
- 접수 전 phase 의 요청을 worker 가 들고 있지 않다는 것은 두 사실에서 나온다(2절의 표). Keeper 가 저장하는 순서와, worker 가 접수를 거절할 때 저장하지 않는 것이다. 그래서 조회 없이 끝낸다. 교체된 선언에서는 조회를 보낼 수도 없다.
  - worker 가 그 요청을 들고 있었다면 지금 코드가 오류로 보는 모순이다. 그때는 host 가 3.2 로 그 요청을 끝내고, 그 결과는 아무도 읽지 않는다.
- 증거는 Librarian 의 타입 하나다. 예전 목적지와 지금 목적지를 담는다. 읽을 때 이 타입으로 풀리지 않으면 거절한다.

```ocaml
type replaced = { captured : Lane_addon_captured_destination.t; current : Lane_addon_captured_destination.t }
```

- history 가 읽는 자리는 둘이다.
  - inventory 검사가 이 phase 를 정리된 원본으로 읽는다. 지금은 오류다(`keeper_librarian_durable_commit.ml` 252~253행). 운영자 해소 흐름도 같은 검사 함수를 쓴다.
  - history owner 가 `Settled` 로 돌아온 이 phase 를 받는다. 지금은 오류다(`lib/keeper/keeper_librarian_durable_owner.ml` 216~217행). pass 는 "반영하지 않음"으로 끝나고 이유를 한 줄 남긴다.
- 이 갈래는 거절 갈래(`Refused`)를 지나지 않는다. 다음 읽기를 좁히지 않는다.
  - 새 원본을 만든 바로 그 pass 에서 이 갈래가 나와도 같다. 그 자리는 거절을 `Memory_refused` 로 돌려주고, 그 값은 좁히기 표시를 남긴다(`keeper_librarian_durable_execution.ml` 519~530행, `lib/keeper/keeper_librarian_durable_consumer.ml` 1692~1719행). 이 갈래는 그 값으로 돌려주지 않는다.
- 그다음 pass 는 정리된 원본을 옮기고 같은 범위를 지금 목적지로 새로 만든다. 정리된 거절이 가는 길 그대로다. 그 pass 는 3.6 이 부른다.
- 목적지 확인은 지금 두 벌이다(`keeper_librarian_durable_edge.ml` 51행, `keeper_librarian_admission_dispatch.ml` 38행). 오류 글자만 다르고 하는 일이 같다.
  - 이 층에서 관계를 돌려주는 함수 하나로 합친다. 한쪽만 타입으로 바꾸면 두 벌이 서로 달라진다.
  - admission 은 `Replaced` 와 `Other_owner` 를 모두 지금처럼 거절한다.
- floor step 은 같은 규칙을 따로 옮긴다(7절의 L2b).
  - floor step owner 는 `Settled` 로 돌아온 이 phase 를 지금 오류로 본다(`lib/keeper/keeper_librarian_floor_step_owner.ml` 95행). 결과에 갈래 하나를 더한다. "접수 전에 끝났다"이다.
  - chain 의 결과에도 갈래 하나를 더한다. "교체된 선언에서 멈췄다"이다. 지금 `Stopped` 는 자리와 report 만 담아서 같은 선언의 거절과 가를 수 없다(`lib/keeper/keeper_librarian_floor_chain.ml` 131~145행).
    - chain 은 두 경우에 이 갈래를 돌려준다. step owner 가 "접수 전에 끝났다"를 줬을 때와, host 가 끝낸 `Not_allowed` 를 받았고 step 이 담은 목적지와 지금 목적지의 관계가 `Replaced` 일 때다. chain 은 step 의 목적지를 이미 쓴다(113~114행).
    - 이 갈래는 report 를 만들지 않는다. 읽을 범위를 줄일 근거가 없다.
  - pass 는 그 step 을 `Stopped` 와 같은 길로 정리하고 `wake` 를 부른다(3.6). 다음 pass 가 같은 자리를 새 id 로 묻는다(`keeper_librarian_durable_execution.ml` 550~555행).

### 3.4 교체된 선언에서 실행 없이 끝난 요청은 다음 읽기를 좁히지 않는다

- 지금은 거절이 pass 에 닿으면 다음 읽기가 한 턴으로 좁아진다(`keeper_librarian_durable_execution.ml` 335~343행, `lib/keeper/keeper_librarian_durable_consumer.ml` 1692~1719행). 밀린 것이 다 비워질 때까지 좁은 채다.
- 좁히기는 model 입력을 나누려는 것이다(335~338행의 주석).
- 3.2 가 들어가면 선언을 바꿀 때 기다리던 Keeper 가 모두 `Not_allowed` 를 받는다. 지금 규칙대로면 모두 한 턴씩 읽게 된다.
- 지금 원본은 모두 밀린 범위 전체를 담는다(1.8). 한 턴씩 읽으면 그 범위가 턴 수만큼의 요청으로 나뉜다. 턴 수는 재지 않았다.
- 규칙: 거절이 `Not_allowed` 이고, 그 원본이 담은 목적지와 지금 목적지의 관계가 `Replaced` 면 좁히지 않는다. 그 밖은 지금과 같다.
  - `Not_allowed` 는 host 가 그 요청을 실행하지 않았다는 뜻이다. 입력 크기에 대해 아무것도 말하지 않는다.
  - 교체 전에 실행되어 받은 크기 거절은 호출 결과(`Call_final`)라 이 규칙에 들지 않는다. 지금처럼 좁힌다. provider registry 는 revision 밖이라 그 증거는 새 선언에서도 유효하다.
  - 같은 선언에서 받은 `Not_allowed` 는 지금처럼 좁힌다. 이 문서는 그 동작을 바꾸지 않는다(6절).
  - 지금 목적지를 얻지 못하면 관계를 정할 수 없다. 지금처럼 좁힌다.
- `Not_allowed` 의 이유 글자는 읽지 않는다. 거절의 타입과 두 목적지의 비교로 정한다.

### 3.5 교체된 선언에서 끊긴 원본을 끝난 것으로 읽는다

- 선언을 바꾸는 순간 host 가 실행 중이던 요청은 끊긴다(1.3). Keeper 는 그 원본을 pass 마다 기다리고, 끝내는 길이 없다.
- RFC-0500 은 서버가 멈춰 끊긴 원본(`interrupted`)만 끝난 것으로 읽게 했다. 같은 프로세스 안에서 끊긴 원본(`cut`)을 막은 이유는 되풀이다(RFC-0500 3.6절). 다시 만든 요청이 같은 까닭으로 다시 끊길 수 있고, 그 횟수를 묶는 것이 없다.
- 규칙: 거절 증거가 `cut` 이고, 원본이 담은 목적지와 지금 목적지의 관계가 `Replaced` 면 그 원본을 `interrupted` 와 같게 읽는다.
  - inventory 검사가 정리된 원본으로 읽는다(`keeper_librarian_durable_commit.ml` 246~251행).
  - 그 거절을 받은 pass 가 자기 Keeper 를 깨운다(`keeper_librarian_durable_owner.ml` 195~202행).
  - 다음 읽기를 좁히지 않는다. 끊긴 까닭은 범위 크기와 상관없다(RFC-0500 3.3절).
- 두 자리는 같은 관계 값을 본다. pass 가 지금 목적지를 한 번 얻어 inventory 검사와 owner 에 넘긴다.
  - owner 는 거절을 처음 받은 것인지 다시 받은 것인지 가르지 못한다. 실행에서 거절된 원본은 이어 갈 때마다 같은 거절로 돌아온다(`lib/lane_addon/lane_addon_submit_once.ml` 187~196행). 깨움이 한 번으로 끝나는 것은 다음 pass 의 inventory 검사가 그 원본을 정리된 것으로 읽어 옮기기 때문이다.
  - 두 자리가 다르게 읽으면 그 Keeper 는 다른 신호 없이 pass 를 되풀이한다. 그래서 값 하나를 함께 쓴다.
  - 지금 목적지를 얻지 못하면 둘 다 지금 동작이다. inventory 검사는 끝나지 않은 원본으로 읽고 owner 는 깨우지 않는다.
  - inventory 검사 함수는 지금 목적지를 받지 않는다(`keeper_librarian_durable_commit.ml` 206~207행). 인자 하나를 더한다. 운영자 해소 흐름도 같은 함수를 쓰므로 같은 값을 넘긴다.
- 되풀이는 선언 변경 횟수로 묶인다. 다시 만든 원본은 지금 선언을 담는다. 그 원본이 다시 이 규칙에 들려면 선언이 또 교체돼야 한다. `interrupted` 가 서버 정지 횟수로 묶이는 것과 같은 모양이다.
- 끊긴 까닭이 선언 교체가 아니어도 이 규칙에 든다. 다른 까닭으로 끊긴 원본이 있을 때 운영자가 선언을 바꾸면 그 원본도 풀린다. 설명서는 `run_id` 변경을 새 시도의 허락으로 적는다(1.4).
- 끊긴 시도가 provider 에서 끝났는지는 알 수 없다. 다시 만들면 model 을 한 번 더 부른다. 답은 받은 적이 없으므로 두 번 반영되지 않는다.
- `raised` 는 바꾸지 않는다. 같은 선언에서 끊긴 원본도 그대로다(5절).
  - 선언을 바꿀 때 `raised` 가 생기는 길은 CLI slot 의 guard 거절 하나다. 그 길은 3.2 가 `raised` 를 만들지 않게 고친다. 이미 `raised` 로 끝난 원본은 남는다.
- 이 규칙은 history 원본의 것이다. floor step 은 끊긴 시도를 원인과 상관없이 기다린다(`lib/keeper/keeper_librarian_floor_step_owner.ml` 49~51행). 서버가 멈춰 끊긴 것도 그렇다. 이 문서는 그 동작을 바꾸지 않는다(5절).
- 이 규칙이 푸는 것은 시작 표시가 남은 원본이다. host 는 시작 표시를 첫 생성 요청을 보내기 직전에 저장한다(#51269).
  - 첫 생성 요청의 허가를 기다리다 취소된 실행은 시작 표시가 없다. 그 요청은 host 기록에 결과도 실행 중 표시도 없으므로 다음 cycle 에 3.2 의 갈래로 온다. 선언이 교체됐으면 거기서 `Not_allowed` 로 끝난다.
  - 앞 slot 에 생성 요청을 보낸 뒤 뒤 slot 의 허가를 기다리다 취소된 실행은 시작 표시가 있다. 그 원본은 이 규칙으로 풀린다.

### 3.6 교체된 선언의 원본을 끝낸 pass 는 자기 Keeper 를 깨운다

- 지금은 원본을 정리한 pass 뒤에 그 Keeper 의 다음 pass 를 부르는 것이 없다.
  - `Exact_result_delivered` 는 요청 하나에 한 번 나온다. 그 한 번을 정리하는 pass 가 쓴다.
  - 그 pass 는 "반영하지 않음"으로 끝나고 drain 은 다시 돌지 않는다(`lib/keeper/keeper_librarian_queue_refresh.ml` 326~337행).
  - 쉬는 Keeper 는 다음 턴이 끝나거나 다른 설정 사건이 올 때까지 그 범위를 다시 만들지 않는다.
- 규칙: 교체된 선언의 원본을 끝낸 pass 는 받은 `wake` 를 한 번 부른다. 자리는 셋이다.
  1. host 가 끝낸 `Not_allowed` 를 받았고 관계가 `Replaced` 일 때(3.2)
  2. Keeper 가 접수되지 않은 원본을 끝냈을 때(3.3)
  3. 끊긴 거절을 받았고 관계가 `Replaced` 일 때(3.5)
- 서버가 멈춰 끊긴 거절이 이미 같은 자리에서 같은 일을 한다(`keeper_librarian_durable_owner.ml` 195~202행).
- 되풀이하지 않는다. 깨워진 pass 가 만드는 원본은 지금 선언을 담는다. 그 원본의 관계는 `Same` 이라 이 규칙에 들지 않는다.
  - package 를 올리면서 output 이나 schema 를 뺐다면 한 번 더 돈다. 새 원본도 `Not_allowed` 를 받는다(`lane_addon_exact.ml` 945~951행). 그 거절은 관계가 `Same` 이라 깨우지 않고 거기서 멈춘다.
- 조건 없이 깨우지 않는다. 같은 선언에서 받은 `Not_allowed` 는 원인이 남아 있을 수 있다. 그때 깨우면 만들기, 거절, 정리, 깨움이 다른 신호 없이 돈다.
- floor step 은 chain 의 "교체된 선언에서 멈췄다" 갈래를 받은 pass 가 같은 `wake` 를 부른다(3.3, L2b). `Stopped` 는 깨우지 않는다.

### 3.7 선언을 되돌리면

- 교체된 선언에서 끝난 요청은 끝난 채다. 선언을 되돌려도 살아나지 않는다.
- 새 선언으로 다시 만든 원본은, 선언을 되돌리면 교체된 선언의 원본이 된다. 같은 규칙으로 끝나고 되돌린 선언으로 다시 만들어진다.
- 선언을 한 번 바꿀 때마다 history 원본을 기다리던 Keeper 는 원본 하나를 다시 만든다. 5절의 경우는 지금처럼 남는다.
- 새 worker 가 붙기 전에 되돌리면 아무것도 끝나지 않는다(3.1 의 조건 3).
- host 가 요청을 끝낸 뒤, Keeper 가 그 결과를 읽기 전에 되돌리면 관계가 `Same` 이다. 그 거절은 같은 선언의 `Not_allowed` 로 다뤄진다. 좁히고, 깨우지 않는다. 다음 신호에서 좁은 범위로 다시 만든다.

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
| N+3 | host cycle 이 목록을 돈다 | 선언이 교체됐다. `Not_allowed` 를 저장하고 전달한다. A 가 깬다 | 목록에 없다 | 끊긴 시도를 `outcome_unknown` 으로 끝내고 전달한다. C 가 깬다 |
| N+4 | 각 Keeper 의 pass | host 기록의 `Not_allowed` 로 원본을 끝낸다. 좁히지 않는다. 자기를 깨운다 | 접수되지 않았고 선언이 교체됐다. `Refused {Before_dispatch}`. 자기를 깨운다 | 끊긴 거절을 남긴다. 선언이 교체됐으므로 자기를 깨운다 |
| N+5 | 깨워진 pass | 원본을 옮기고 같은 범위를 새 선언으로 만들어 보낸다 | 같다 | 같다 |

- D 와 E 는 지금처럼 남는다(5절).
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

- 어느 자리에서도 같은 요청이 두 번 반영되지 않는다. 끝난 원본은 답이 없고, 새 원본은 id 가 다르다.

### 4.3 설명서의 `run_id` 절차

- 한 Keeper 의 capacity 거절을 풀려고 `run_id` 를 바꾼다.
- 그 Keeper 는 지금처럼 새 요청을 만든다.
- 다른 Keeper 의 대기 원본은 4.1 의 A, B, C 처럼 끝나고 새 선언으로 다시 만들어진다.

### 4.4 여러 slot 과 여러 계정

- slot 은 host 가 실행할 때 고른다. 3.2 와 3.3 으로 끝난 요청은 답을 받은 적이 없다.
- 다시 만든 요청은 id 가 새것이라 앞 요청의 시도를 이어받지 않는다. 실행될 때의 registry 로 slot 을 처음부터 고른다.
- 선언 revision 은 registry 를 담지 않는다(1.1). context window 가 다른 slot 으로 넘어가는 흐름은 이 규칙과 만나지 않는다.

## 5. 풀지 않는 것

| 무엇 | 지금 동작 | 어디서 다루나 |
|---|---|---|
| 답을 받았고 gate 를 시작하지 못한 원본(`Judged`) | gate 를 시작하려면 목적지 비교를 지나야 한다. 교체된 선언에서는 pass 마다 기다린다. 선언을 되돌리면 이어진다. gate 가 이미 끝난 원본은 그대로 반영된다 | 9절. 공용 규약에 `Judged` 에서 나가는 길은 반영뿐이다. 두 번의 조회(06:39Z, 07:44Z)에서 이 phase 의 history 원본은 0개였다 |
| 답을 받았고 gate 를 시작하지 못한 floor step | 같은 비교에 막혀 chain 이 pass 마다 기다린다(`lib/keeper/keeper_librarian_floor_step_judgment.ml` 65~70행, `keeper_librarian_floor_chain.ml` 113~114행) | 위와 함께 다룬다. 라이브 floor step 기록은 0개다 |
| worker 에 기록이 없는 `Dispatch_pending` 원본 | worker 조회가 목적지 확인에 막혀 pass 마다 오류다. 지금 2개가 이 phase 다 | #50828. 조회만 설치·package·tool 로 허락하면 "없다"는 답을 받아 그쪽 흐름으로 간다. 이 문서의 층이 아니다 |
| 선언의 `id` 를 바꾼 때 | Keeper 는 tool 이름으로 지금 설치를 찾는다(`keeper_librarian_durable_edge.ml` 57~59행). 설치가 달라서 pass 마다 거절한다. worker 저장소는 설치마다 따로라 새 설치의 worker 는 앞 설치의 대기 목록을 받지 않는다. host 는 그 요청을 보지 못한다 | 따로 설계한다. 이 문서의 host 규칙은 대기 목록을 이어받은 worker 가 있어야 선다 |
| admission 요청 | host guard 는 실행을 거절하고 Keeper 는 pass 마다 거절한다. 선언을 바꾸는 순간 실행 중이던 admission 은 끊긴 채 남는다 | 따로 설계한다. admission 은 part 가 목적지를 담는다(`keeper_librarian_admission_owner.ml` 133~134행). `Not_allowed` 를 받은 part 는 기다리기만 한다(같은 파일 `size_refused`). host 가 끝내면 되돌려도 풀리지 않게 된다. 그래서 3.2 에서 뺐다. 그때까지는 선언을 바꾸기 전에 기다리는 admission 실행이 0개인지 본다 |
| 새 worker 가 앞 worker 의 기록을 host 에 주지 못할 때 | worker 는 기록 하나라도 읽지 못하면 멈춘다(`addons/exact_worker.py` 289~292행). 대기 목록이 새 frame 에 들어가지 않으면 목록 호출이 실패한다(433~434행). host 는 대기 목록을 받지 못하고 아무것도 끝나지 않는다 | package 를 바꾸는 쪽이 지킬 조건이다. 새 package 는 저장된 기록을 그대로 읽고 `max_reply_bytes` 를 줄이지 않는다. #51280 의 수리가 이 조건을 지켜야 한다 |
| `ui_category` 만 바꾼 설치 | revision 이 그대로라 교체가 아니다. host 가 그 설치의 요청을 실행하지 않고 Keeper 는 계속 접수한다 | #51300, 수리는 #51308 |
| 같은 선언에서 끊긴 원본, `raised` 로 끝난 원본 | Keeper 가 pass 마다 기다린다 | #50828 |
| 실행 중 끊긴 floor step | step owner 가 끊긴 시도를 원인과 상관없이 기다림으로 돌려준다(`keeper_librarian_floor_step_owner.ml` 49~51행). chain 이 pass 마다 기다리고, 그 Keeper 의 그 범위는 다시 읽히지 않는다. 서버가 멈춰 끊긴 것도 같다 | RFC-0500 3.4절이 floor step 을 뒤로 미뤘다. 그 설계와 함께 다룬다. 라이브 floor step 기록은 0개다 |

## 6. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 새 선언에서 예전 요청을 그대로 실행한다 | 선언 revision 은 새 provider 호출의 권한으로 정해져 있다(1.7). 이 길은 그 계약을 없앤다. 9절의 첫 결정이다. 이 문서는 계약을 두고 끝을 정하는 쪽을 추천한다 |
| 접수되지 않은 원본도 worker 에 보내 host 가 끝내게 한다 | `Admission_wait` 는 대기 목록에 못 들어가서 생긴 phase 다. 다시 보내도 같은 이유로 거절된다(#51280). 끝나지 않는다 |
| Keeper 가 접수된 요청을 스스로 끝낸다 | worker 가 그 요청을 계속 들고 대기 목록의 자리를 차지한다. 선언을 되돌리면 host 가 실행하고 답은 아무도 읽지 않는다. 시작했는지는 host 기록만 안다 |
| worker 에 취소 호출을 더한다 | package 를 바꿔야 한다. 그 배포가 선언 revision 을 바꾼다. 지금 기다리는 원본에는 쓸 수 없다 |
| 거절이 N번 쌓이거나 T시간 지나면 끝낸다 | 근거 없는 숫자다. 선언이 교체됐는지는 비교로 정해진다 |
| `Not_allowed` 에 원인 타입을 넣는다 | host 기록과 worker 가 주고받는 모양이 바뀐다. 저장된 기록을 hard cut 해야 한다. Keeper 는 거절의 타입과 목적지 비교로 같은 것을 안다(3.4) |
| 선언 파일만 보고 교체를 정한다 | 고치는 중간 상태에서 요청이 끝난다. worker 가 붙은 것은 Runtime 이 그 선언을 실제로 적용했다는 사실이다 |
| `Not_allowed` 는 선언과 상관없이 좁히지 않는다 | 근거는 같다. 실행하지 않은 요청은 크기에 대해 말하지 않는다. 다만 같은 선언에서 거절이 되풀이될 때 요청마다 밀린 범위 전체를 다시 쓰게 된다. 선언 교체와 다른 문제라 여기서 바꾸지 않는다 |
| `cut` 을 선언과 상관없이 끝난 것으로 읽는다 | 되풀이를 묶는 것이 없다. RFC-0500 이 막은 이유 그대로다 |

- Curator 는 다른 선택을 했다. 자기 guard 가 없고, 이어 붙일 때 설치·package·tool 만 본다(`lib/server/server_workspace_memory_addon.ml` 120~134행). 이 문서는 Curator 를 바꾸지 않는다.

## 7. 층

| 층 | 바꾸는 것 | 확인 |
|---|---|---|
| L0 | 목적지 관계 타입(3.1). history 의 좁히기 규칙(3.4)과 깨움 규칙의 첫 자리(3.6). 그 계약 문장 | 8절의 좁히기·깨움 시험 |
| L1 | guard 결과 타입, `run` 의 갈래, Runtime 의 판정, history·floor step guard(3.2). 계약 문장 둘(`lane_addon_exact.mli`, `lane_addon_runtime.mli`)과 설명서 982~987행 | 8절의 host 시험 |
| L1b | CLI walker 가 보내기 전의 guard 거절을 값으로 받아 멈춘다. walk receipt 에 "보내기 전에 멈춤"을 더한다(3.2). 구현은 #51343 이다 | 8절의 CLI 시험 |
| L2a | 목적지 확인 두 벌을 하나로, `Submit.resume` 의 접수 전 갈래, 증거 타입, history 가 읽는 자리 둘, 깨움 규칙의 둘째 자리(3.3) | 8절의 Keeper 시험 |
| L2b | 같은 규칙을 floor step 에. step owner 와 chain 의 결과에 갈래 하나씩(3.3) | 8절의 floor 시험 |
| L3 | 교체된 선언에서 끊긴 원본, inventory 검사에 지금 목적지 인자, 깨움 규칙의 셋째 자리(3.5) | 8절의 끊김 시험 |

- L0 이 L1 보다 먼저다. L1 만 들어가면 선언을 바꿀 때 기다리던 Keeper 가 모두 한 턴씩 읽게 되고, 쉬는 Keeper 는 다음 턴까지 그 범위를 다시 만들지 않는다.
- L1b 는 다른 층에 기대지 않는다. L1 없이 들어가도 CLI slot 의 guard 거절이 `raised` 대신 미뤄진 시도로 남는다. 그 요청은 선언을 되돌리면 다시 실행된다.
  - CLI walker 는 Librarian 밖의 소비자도 쓴다. 바꾸는 것은 관찰 함수가 거절을 돌려줄 수 있게 하는 것이고, 거절을 돌려주지 않는 소비자의 동작은 그대로다.
- L3 은 관계 타입만 쓴다. L0 뒤라면 다른 층과 순서를 가리지 않는다.
- L2b 는 라이브 floor step 기록이 0개인 지금 뒤로 미뤄도 1.8 의 원본이 모두 풀린다.
- 모든 층이 서버 코드다. 배포는 서버 재시작이고 선언과 package 는 건드리지 않는다.
- package 를 올리는 일은 L0, L1, L1b, L2a, L3 이 라이브에 올라간 뒤에 한다. `/health` 의 build commit 으로 확인한다. 올리기 전에 볼 것은 둘이다(5절).
  - 기다리는 admission 실행이 0개인가.
  - 새 package 가 저장된 기록을 그대로 읽고 `max_reply_bytes` 를 줄이지 않는가.
- 앞서 저장된 기록은 그대로 읽힌다. host 기록의 `Not_allowed` 와 진행 기록의 `Refused` 는 지금 codec 그대로다. L1b 가 walk receipt 에 갈래 하나를 더한다. 그 모양은 L1b 에서 정한다.

## 8. 시험

화면 배치 시험은 쓰지 않는다. 모두 함수 단위다.

- host
  - guard 가 `Not_now` 면 host 기록이 없다. 다시 허락하면 같은 요청이 실행된다. 지금 시험을 타입만 바꿔 남긴다.
  - guard 가 `Declaration_replaced` 면 결과가 `Not_allowed` 다. host 기록에 그 결과가 있고 runner 는 한 번도 불리지 않는다. 그 뒤 guard 가 허락해도 같은 `Not_allowed` 다.
  - 답이 있는 기록은 guard 를 부르지 않고 답을 전달한다. 지금 시험 그대로다.
  - Runtime 의 판정: 파일만 고친 때는 `Not_now`, 새 worker 가 붙은 뒤는 `Declaration_replaced`, 끈 때와 파일이 깨진 때는 `Not_now` 다.
- CLI
  - CLI slot 을 보내기 직전에 guard 가 거절하면 그 slot 의 runner 는 불리지 않는다. host 기록의 그 시도는 미뤄진 시도이고 결과는 없다. `raised` 가 아니다.
  - 그 뒤 guard 가 `Declaration_replaced` 를 주면 같은 요청이 `Not_allowed` 로 끝난다. guard 가 허락하면 같은 요청이 실행된다.
- Keeper
  - 접수 전 원본에 관계가 `Replaced` 면 `Refused {Before_dispatch}` 사건 하나가 쌓이고 worker 호출은 0번이다.
  - `Dispatch_pending` 원본은 이 비교를 보지 않는다.
  - 한 Keeper 의 두 pass: 접수된 원본에 host 의 `Not_allowed` 가 있으면 첫 pass 가 정리하고 둘째 pass 가 지금 목적지로 새 원본을 만든다. 접수 거절된 원본도 같은 끝에 닿는다.
- floor
  - 접수 전 step 의 선언이 교체되면 chain 이 "교체된 선언에서 멈췄다"를 돌려준다. pass 는 `wake` 를 한 번 부르고, 다음 pass 가 같은 자리를 새 id 로 묻는다.
  - 같은 선언에서 거절된 step 은 지금처럼 `Stopped` 다. `wake` 를 부르지 않는다.
- 좁히기
  - `Not_allowed` 이고 관계가 `Replaced` 면 좁히지 않는다. 다음 원본의 범위가 `all_unread` 다.
  - `Not_allowed` 이고 관계가 `Same` 이면 좁힌다. 지금과 같다.
  - 크기 거절이고 관계가 `Replaced` 면 좁힌다. 지금과 같다.
- 깨움
  - 위 첫 경우의 pass 는 `wake` 를 한 번 부른다. 나머지 둘은 부르지 않는다.
  - 접수 전 원본을 끝낸 pass 는 `wake` 를 한 번 부른다.
- 끊김
  - 증거가 `cut` 이고 관계가 `Replaced` 면 첫 pass 가 `wake` 를 부르고, 둘째 pass 가 원본을 옮기고 새로 만든다.
  - 증거가 `cut` 이고 관계가 `Same` 이면 지금처럼 기다린다. `wake` 를 부르지 않는다.
  - 증거가 `raised` 면 관계와 상관없이 지금처럼 기다린다.
  - 증거가 `cut` 이고 지금 목적지를 얻지 못하면 inventory 검사는 끝나지 않은 원본으로 읽고 owner 는 `wake` 를 부르지 않는다. 두 자리가 같은 값을 본다는 시험이다.
- 변이
  - CLI walker 가 guard 거절을 다시 예외로 던지게 하면 CLI 시험이 `raised` 로 실패한다.
  - inventory 검사만 관계를 `Replaced` 로 고정하면 "지금 목적지를 얻지 못하면" 시험이 실패한다.
  - `Declaration_replaced` 를 `Not_now` 로 바꾸면 host 시험이 실패한다.
  - 3.1 의 조건 3 을 빼면 "파일만 고친 때" 시험이 실패한다.
  - 좁히기 규칙에서 관계 비교를 빼면 "`Same` 이면 좁힌다" 시험이 실패한다.
  - 깨움에서 관계 비교를 빼면 "나머지 둘은 부르지 않는다" 시험이 실패한다.
  - 끊김 규칙에서 관계 비교를 빼면 "`Same` 이면 기다린다" 시험이 실패한다.

## 9. 정할 것

1. **교체된 선언의 요청을 끝내고 다시 만들지, 새 선언에서 그대로 실행할지.** 추천은 끝내고 다시 만드는 쪽이다.
   - 지금 계약: 요청은 만든 선언 안에서만 실행된다. 선언을 되돌리면 이어지고, 되돌리지 않으면 끝나지 않는다(1.7).
   - 추천: 계약을 그대로 두고 끝을 정한다. 교체된 선언의 요청 가운데 답을 받지 못한 것은 끝나고, 그 범위는 새 선언으로 다시 만들어진다.
     - 다시 만든 요청은 지금 서버와 지금 선언이 만든 것이다. 새 package 가 예전 요청을 접수·조회·실행 단계마다 받아 주는지에 기대지 않는다.
     - 대가: 기다리던 Keeper 마다 원본 하나를 다시 쓴다. 지금 원본 본문은 합쳐 72.9 MB 다(#51281). 대기 순서를 잃는다. 선언을 잘못 고쳤다가 되돌려도 그 사이에 끝난 요청은 살아나지 않는다. 5절의 아홉 가지가 남는다.
   - 다른 길: 선언 revision 을 실행 권한에서 뺀다. 설치, package, tool 이 같으면 예전 요청을 새 선언에서 그대로 접수하고 실행하고 반영한다.
     - 얻는 것: 다시 만드는 비용이 없고 대기 순서가 남는다. 5절의 `Judged`, 답을 받은 floor step, 조회, admission 은 모두 같은 비교에 막힌 것이라 생기지 않는다. 이 문서의 L1, L2a, L2b 와 L0 의 좁히기·깨움 규칙이 필요 없다. 관계 타입과 L1b, L3 은 남는다.
     - 대가: "요청은 만든 선언 안에서만 실행된다"는 계약을 없앤다. 계약 문장 둘(1.7), 그 시험 둘, 설계 문서의 문장 하나(`docs/design/librarian-addon-execution.md` 257~260행)를 고친다.
     - 새 package 가 그 output 이나 schema 를 선언하지 않으면 host 가 지금 규칙대로 `Not_allowed` 로 끝낸다(1.6). worker 가 앞 기록을 host 에 주지 못하는 경우는 어느 길에서나 남는다(5절).
     - keeper-librarian 은 prompt 와 schema 를 서버 코드가 만든다(`lib/keeper/keeper_librarian_durable_question.ml` 43~46행, `lib/keeper/keeper_librarian_runtime.ml` 487~495행). 지금 package 만 보면 그대로 실행해도 답이 달라지지 않는다.
     - 실행 중에 끊긴 요청은 이 길에서도 남는다. 3.5 는 어느 쪽에서나 필요하다.
2. **교체된 선언에서 끊긴 원본을 끝난 것으로 읽을지(3.5).** 추천은 넣는 것이다.
   - 넣지 않으면 선언을 바꿀 때마다 그 순간 실행 중이던 요청의 Keeper 가 끊긴 원본으로 남는다. 지금 코드에 그 원본을 끝내는 길이 없다.
   - 대가: `cut` 을 막아 둔 RFC-0500 의 규칙에 예외 하나가 생긴다. 다른 까닭으로 끊긴 원본도 선언을 바꾸면 풀린다.
3. **`Judged` 와 admission.** 이 문서는 그대로 둔다.
   - `Judged` 는 반영 단계가 설치·package·tool 만 보게 하거나, 공용 규약에 반영 없이 끝나는 길을 더해야 풀린다. 앞의 것은 결정 1 의 다른 길과 같은 변화다.
   - admission 은 part 가 목적지를 담는 구조라서 이 문서의 규칙을 그대로 쓸 수 없다. 기다리는 실행이 1개인 지금은, 선언을 바꾸기 전에 0개인지 보는 것으로 넘긴다.

## 10. 관련

- #51278: 이 문서의 이슈다.
- #51280: worker 가 요청을 온 순서로 받지 않는다. 그 수리는 package 를 올려야 해서 이 문서의 층 뒤에 온다.
- #51199, #51272: 한 번에 하나씩 실행해서 대기 목록이 느리게 빈다.
- #50828: 끊긴 원본과 worker 에 기록이 없는 원본.
- #51250, #51269: host 는 시작 표시를 첫 생성 요청을 보내기 직전에 저장한다. 그 허가를 기다리다 끊긴 요청은 표시 없이 남고 다음 cycle 에 다시 실행된다.
- #51326: 기다리는 원본의 pass 가 본문을 다시 읽지 않게 하는 설계다. 그 문서도 `Submit.resume` 의 접수 전 갈래를 바꾼다. 순서는 이 문서의 관계 판정(3.3)이 먼저고 그 문서의 `load` 가 뒤다. 판정은 원본 기록의 목적지와 지금 목적지만 읽는다. 그래서 본문을 읽지 못하는 원본도 선언이 교체됐으면 끝난다. `load` 는 `Same` 일 때만, 접수 의도를 저장하기 전에 부른다. 나중에 들어가는 쪽이 이 순서로 맞춘다.
- #51343: L1b 의 구현이다.
- #51300: `ui_category` 만 바꾸면 host 와 Keeper 의 package 비교가 갈린다.
- RFC-0489 2.5절: Goal 검증도 접수 전 원본을 같은 사건으로 끝내기로 했다. 그쪽은 다음 시도를 잇는 전이를 더 넓힌다. Librarian 은 읽은 위치에서 다시 고르므로 그 전이가 필요 없다. 증거 타입은 소비자마다 자기 것을 쓴다.
- RFC-0500: 서버가 멈춰 끊긴 원본을 정리하고 다시 고르는 길. 이 문서의 3.5 가 같은 길에 조건 하나를 더한다.
