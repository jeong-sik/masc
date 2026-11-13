---
rfc: "librarian-waiting-pass-reads-records-not-bodies"
title: "기다리는 원본의 pass 는 본문을 다시 읽지 않는다"
status: Draft
created: 2026-11-11
updated: 2026-11-13
author: claude
supersedes: []
superseded_by: null
related: ["0500", "librarian-history-unknown-resolution", "librarian-durable-message-floor", "main-domain-scheduler-latency"]
---

# 기다리는 원본의 pass 는 본문을 다시 읽지 않는다

이슈 #51281 의 설계 문서다. 코드 위치는 main `f72bafce9771` 기준이다. 1.6절, 3.9절, 4.7절은 2026-11-13 에 더했고 main `e3c6ea99989e` 기준이다.

## 0. 요약

- Keeper 의 durable Librarian pass 는 끝나지 않은 history 원본의 본문을 pass 마다 처음부터 다시 읽고 검증하고 푼다. worker 에 상태를 물을 때 한 번 더 읽고 검증한다. 원본이 기다리는 동안 본문은 바뀌지 않는다.
- 22.66 MB 본문 하나를 읽고 검증하고 푸는 데 2.8초가 든다(따로 잰 값, 1.2절). 그 Keeper 의 pass 는 로그에서 검증에 중앙값 2.2초를 썼다. 멈춘 원본 둘이 7시간 창의 검증 시간 59% 를 썼다.
- 기다리는 pass 가 본문에서 실제로 쓰는 값은 작다. 주인, 목적지, 앞선 원본, source 의 경로, Exact 요청의 digest 다.
- 2026-11-13 에 다시 재니 검증 시간의 84% 가 운영자 해소로 이어진 원본 쌍을 가진 Keeper 둘에서 나왔다(1.6절). 그 쌍은 pass 마다 부모 본문을 여섯 번, child 요청을 통째로 담은 resolution 기록을 다섯 번 읽는다.
- 바꾸는 것은 넷이다.
  1. 기다리는 길은 본문 없는 기록(`Owner.Record.t`)으로 돈다. 접수 모듈, worker 호출, 진행 기록 저장이 기록을 받는다.
  2. 그 길이 쓰는 값을 기록의 `summary` 에 둔다. 공용 owner 모듈이 그 용도로 둔 칸이고 Curator 가 이미 그렇게 쓴다.
  3. 본문은 쓰는 단계에서 읽고 그때 검증한다. 접수할 때, 답을 확인하고 반영할 때, 거절을 보고할 때다. host 에 실행 증거 파일이 생긴 요청은 그 뒤로 pass 마다 읽는다(3.6절).
  4. 운영자 해소의 계보는 기록과 `summary` 로 확인한다. resolution 기록은 child 요청을 담지 않고 id 와 digest 로 가리킨다(3.9절). 이 층이 첫 층이다(7절).
- 근거는 코드에 이미 적힌 원칙이다. 기록은 요청을 digest 로 가리키고, digest 가 같으면 같은 요청이다.
- history 기록의 모양이 바뀐다. 서버를 멈추고 history 원본과 거기 딸린 기록을 지운 뒤 설치한다(3.7절).
- 본문 파일이 밖에서 바뀐 것을 잡는 때가 달라진다. 지금은 pass 마다 잡고, 바꾸면 본문을 쓸 때 잡는다(9절).

## 1. 지금

### 1.1 pass 가 원본마다 하는 일

시간을 재는 구간은 `lib/keeper/keeper_librarian_durable_execution.ml` 349~389행이다. 그 안과 뒤에서 끝나지 않은 원본 하나마다 아래 일을 한다.

| 일 | 자리 | 다루는 크기 | 잰 구간 |
|---|---|---|---|
| 본문 파일을 읽고 sha256 을 기록의 digest 와 견준다. JSON 으로 풀고, 다시 글자로 만들어 원문과 견준다 | `lib/lane_addon/lane_addon_tool_request_owner.ml` 86~94행 `request_of_body`. 248행 `load_scope` 가 부른다 | 본문 전체 | 안 |
| 본문 안의 `source_text` 를 JSON 으로 풀고, 타입으로 읽고, 다시 글자로 만들어 견준다. 질문을 다시 만들어 저장된 것과 견준다 | `lib/keeper/keeper_librarian_durable_request.ml` 203~221행 `decode` | 본문 전체 | 안 |
| 푼 요청을 다시 JSON 으로 만들어 기록의 요청과 견준다 | 같은 파일 223~231행 `restore_payload` | 본문 전체 | 안 |
| gate 검사가 같은 두 값을 한 번 더 견준다 | `lib/keeper/keeper_librarian_original_gate.ml` 576행. `lib/keeper/keeper_librarian_durable_commit.ml` 264행이 부른다 | 본문 전체 | 안 |
| host 의 Exact 기록을 읽어 요청 전체로 다시 묶는다. canonical 을 네 번 만들고 digest 를 두 번 계산하고 전체 비교를 세 번 한다 | `lib/lane_addon/lane_addon_exact.ml` 862행 `recover_retained`, 460~474행 `bound_record` | host 기록 전체. 기록은 요청 전체를 한 벌 담는다(425~431행) | 밖 |
| worker 를 부르기 전에 Runtime 이 원본을 다시 retain 한다. 요청을 canonical 로 만들고, 글자로 만들어 sha256 을 계산하고, 본문 파일을 다시 읽어 검증한다 | `lib/lane_addon/lane_addon_runtime.ml` 2480~2482행, `lane_addon_tool_request_owner.ml` 288~303행, 107~119행 | 본문 전체 | 밖 |
| worker 에 상태를 묻는다 | `lib/lane_addon/lane_addon_submit_once.ml` 158행, 217행 | 요청 id | 밖 |

- 앞의 셋은 `lib/keeper/keeper_librarian_durable_owner.ml` 46~56행 `discover` 가 원본마다 부른다. 넷째는 검증 구간이 원본마다 부른다(`keeper_librarian_durable_execution.ml` 372행).
- 본문을 읽고 푸는 일은 `Systhread_host` 로 넘긴다(`keeper_librarian_durable_owner.ml` 22행). 전용 domain 하나의 스레드다.
- host 기록을 다시 묶는 일은 `Eio_unix.run_in_systhread` 로 넘긴다(`lane_addon_submit_once.ml` 95행). 부른 쪽 domain 의 스레드다. 한 domain 에서는 한 번에 한 스레드만 OCaml 코드를 돌린다(`lib/core/systhread_host.mli` 1~8행).
- Exact 요청의 digest 는 부를 때마다 요청을 글자로 만들어 계산한다(`lane_addon_exact.ml` 91행).

### 1.2 측정

| 무엇 | 값 | 언제, 어떻게 |
|---|---|---|
| 원본이 없는 pass 의 검증 시간 | 185번, 중앙값 6.4 ms | 2026-11-11 00:00Z~07:01Z, 서버 로그의 inventory 줄 |
| 원본이 하나 있는 pass | 3,586번, 중앙값 388.6 ms | 같은 창 |
| 22.66 MB 본문의 Keeper | 486번, 중앙값 2,204 ms, p90 8,205 ms. 전체 검증 시간의 47.3% | 같은 창 |
| 6.58 MB 본문의 Keeper | 306번, 중앙값 964 ms, p90 2,979 ms. 11.8% | 같은 창 |
| 전체 | pass 3,769번, 검증 시간 합 3,706초, Keeper 29명 | 같은 창. 창은 25,260초다 |
| 끝나지 않은 원본의 본문 | 25개, 합 72.9 MB | 07:01Z |

- 위 두 Keeper 의 원본은 worker 에 기록이 없어 멈춰 있다(#50828). 풀릴 때까지 pass 마다 같은 일을 한다.
- 검증 시간은 벽시계 시간이다. 다른 작업을 기다린 시간이 섞여 있다.
- 이 값은 1.1절 표의 "안" 줄만 잰 것이다. host 기록을 묶는 일과 worker 호출 앞의 retain 은 들어 있지 않다.

단계별 시간은 따로 쟀다. 22.66 MB 본문 하나와 3.58 MB host 기록 하나를 읽기만 했다.

| 단계 | 흉내 낸 자리 | 시간 |
|---|---|---:|
| 파일 읽기 | `request_of_body` | 6.0 ms |
| sha256 | 같은 함수 | 371.8 ms |
| JSON 으로 풀기 | 같은 함수 | 693.1 ms |
| 다시 글자로 만들어 원문과 견주기 | 같은 함수 | 728.9 ms |
| `source_text` 를 JSON 으로 풀기 | `decode` | 586.6 ms |
| 다시 글자로 만들어 견주기 | 같은 함수 | 404.6 ms |
| 본문 합 | | 2,791.0 ms |
| host 기록 파일 읽기 | `recover_retained` | 1.0 ms |
| host 기록을 풀기 | `bound_record` | 132.0 ms |
| 요청을 글자로 만들고 sha256, 두 번 | 같은 함수 | 157.0 ms |
| host 기록 합 | | 290.0 ms |

- 조건: 2026-11-11 08:22Z, OCaml 5.5.2, Yojson 과 Digestif 만으로 흉내 낸 실행 파일, 3번의 중앙값이다.
- 그때 load average 가 225.9 였다. 절대값은 부풀어 있다. 단계 사이의 비율을 보려고 쟀다.
- 원본과 질문을 타입으로 풀고 다시 만드는 단계와 gate 검사의 비교는 넣지 못했다. 실제 비용은 이 합보다 크다.
- worker 호출 앞의 retain 은 본문 표의 앞 네 단계를 한 번 더 하는 것과 같은 모양이다. 따로 재지 않았다.
- 파일을 읽어 검증하는 앞의 네 단계가 1,799.8 ms 로 64% 다. 원본으로 푸는 두 단계가 991.2 ms 로 36% 다.

### 1.3 기다리는 pass 가 본문에서 쓰는 값

접수된 원본(`Dispatch_pending`)이 차례를 기다리는 pass 다.

| 쓰는 값 | 어디에 쓰나 | 자리 |
|---|---|---|
| 주인(경로 셋, Keeper id, Memory epoch) | 지금 주인과 같은지 본다 | `keeper_librarian_durable_owner.ml` 117~122행, `keeper_librarian_durable_request.ml` 282~289행 |
| 목적지 | worker 를 부르기 전에 지금 목적지와 견준다 | `keeper_librarian_durable_owner.ml` 131~134행, `lib/keeper/keeper_librarian_durable_edge.ml` 46~49행 |
| 앞선 원본의 id 와 digest | 이어진 원본의 순서를 확인한다 | `keeper_librarian_durable_owner.ml` 127행, `keeper_librarian_durable_execution.ml` 133~142행 |
| 본문 digest | 기록이 같은 요청을 가리키는지 본다 | `keeper_librarian_durable_request.ml` 235~242행 `confirm_record` |
| source 의 runtime 경로 | 그 경로가 주인의 runtime 과 같은 곳인지 본다 | 같은 파일 187~191행 |
| 요청 id | gate 기록과 fence 를 찾는다 | `keeper_librarian_original_gate.ml` 586행, `lib/keeper/keeper_librarian_history_resolution_state.ml` 119~122행 |
| Exact 요청의 id 와 digest | host 기록과 실행 증거를 찾고 묶는다 | `lane_addon_exact.ml` 862행, 592~594행 |

- 이 phase 의 inventory 검사는 위 값과 기록의 진행 기록을 쓴다(`keeper_librarian_durable_commit.ml` 208~217행). gate 검사가 본문 전체를 견주는 576행은 `restore_payload` 가 같은 pass 에서 이미 한 비교다.
- 운영자가 세운 fence 는 작은 파일 하나를 읽는다. fence 가 있을 때만 source 전체의 digest 를 계산한다(`keeper_librarian_history_resolution_state.ml` 112~124행).
- 진행 기록 저장은 기록만 읽고 쓴다. 요청은 digest 로 견준다(`lane_addon_tool_request_owner.ml` 314~342행).
- worker 호출 앞의 retain 이 확인하는 것은 "이 id 의 기록이 같은 요청을 가리키는가"다(같은 파일 298~303행). 기록의 digest 로 답할 수 있다.
- pass 마다 도는 검사가 둘 더 있다. 원본에 output schema 가 있는지(`keeper_librarian_durable_owner.ml` 128~130행), 그 schema 가 lane 의 선언과 맞는지(`lane_addon_exact.ml` 865행, 477~485행)다. 둘 다 요청 전체에서 읽는다. schema 를 실제로 쓰는 것은 결과를 풀 때다(487~490행).
- 모두 경로, id, digest 다. 본문 크기와 무관하다.

본문 전체가 필요한 단계는 따로 있다.

| 단계 | 쓰는 것 | 자리 |
|---|---|---|
| 접수 | 요청 전체를 worker 에 보낸다 | `lane_addon_submit_once.ml` 162~182행 |
| 답 확인 | host 결과나 worker 의 끝난 답을 원본의 질문과 맞춘다 | `keeper_librarian_durable_owner.ml` 142~150행, `lane_addon_submit_once.ml` 116~141행 |
| 반영 | source 의 범위와 읽은 위치 | `keeper_librarian_durable_commit.ml` 63·83·99·164행 |
| 거절 보고 | source 의 범위와 상대 | `lib/keeper/keeper_librarian_durable_refusal.ml` 20·72·93·109행 |
| 계보 확인 | 앞선 원본, 뒤따르는 원본, 교체 의도를 source 와 견준다 | `lib/keeper/keeper_librarian_history_resolution_lineage.ml` 45~48행, `keeper_librarian_durable_execution.ml` 144~185행 |

### 1.4 이미 있는 것

- 공용 owner 모듈의 기록은 `summary` 칸을 갖는다. 계약 문장은 "The consumer's canonical index of the request, fixed at retain. The store does not read it; the consumer checks it against the request."다(`lib/lane_addon/lane_addon_tool_request_owner.mli` 26~28행).
- 같은 모듈은 기록만 읽는 함수를 따로 둔다. `discover` 는 본문 없는 `Record.t` 를 주고 `load_listed` 가 그 기록의 본문을 읽는다(`lane_addon_tool_request_owner.ml` 120행, 223행).
- Curator 가 그 모양대로 쓴다. 기록과 `summary` 만 읽어 원본을 훑고, 손댈 원본만 본문을 읽는다(`lib/server/server_workspace_memory_addon.ml` 478~491행의 주석과 코드).
- Goal verifier 도 `summary` 를 채우고(`lib/keeper/goal_verifier_worker.ml` 163~165행) 기록만 읽어 훑는다(221~224행). 가르는 기준은 요청 id 다(211~219행). 본문은 필요한 기록만 읽는다(232~239행).
- admission closure(`lib/keeper/keeper_librarian_admission_closure.ml` 186행)와 기동 정리(`lib/server/server_settled_archive_sweep.ml` 82~85행)도 기록만 읽는 길을 쓴다.
- history 는 `summary` 를 비워 두고(`keeper_librarian_durable_owner.ml` 40행) `load_scope` 로 본문까지 읽는다(48행).
- 원칙이 두 곳에 적혀 있다.
  - "A record names its request by digest, so equal digests are equal requests; comparing them never walks the request itself."(`lane_addon_tool_request_owner.ml` 95~96행)
  - "Equal digests are equal requests, so a re-check of the same record compares this instead of decoding the body again."(`keeper_librarian_durable_request.ml` 135~138행)
- pass 안에서는 이 원칙을 이미 쓴다. `reload` 는 기록만 다시 읽고 digest 가 같으면 앞서 푼 요청을 그대로 쓴다(`lane_addon_tool_request_owner.ml` 229~240행).
- pass 사이에는 남기는 것이 없다. 다음 pass 는 처음부터 다시 한다.
- 결과가 전달될 때 Keeper 를 찾는 코드도 본문을 읽는다. 요청 하나의 기록과 본문을 읽고(`lib/server/server_librarian_addon_wake.ml` 109행), history 는 원본 전체를 푼다(38~41행). floor step 은 본문의 header 칸만 푼다(44~47행, `lib/keeper/keeper_librarian_floor_step_request.ml` 198~201행).
- 선언을 다시 관찰하거나 export 목록이 바뀌면 모든 scope 의 원본을 본문까지 읽어 Keeper 를 찾는다(같은 파일 71~104행, 128행의 `Owner.fold_all`).
- 본문 없는 원본을 나르는 타입은 `Record.t` 하나다. `retained` 는 `request` 칸이 꼭 있어야 한다(`lane_addon_tool_request_owner.mli` 31~41행). 접수 모듈, worker 호출, 진행 기록 저장은 지금 `retained` 를 받는다(`lane_addon_submit_once.ml` 84행, `lane_addon_runtime.ml` 2467행, `lane_addon_tool_request_owner.ml` 314행).

### 1.5 pass 가 잦은 이유

- 결과 하나가 전달될 때마다 capacity 대기자가 모두 깬다(`server_librarian_addon_wake.ml` 152~156행, #51280).
- 접수를 거절당한 원본은 pass 마다 본문 전체를 다시 보낸다(#51280).
- 멈춘 원본은 풀릴 때까지 pass 마다 같은 검증을 받는다(#50828).
- 이 문서는 pass 의 수를 줄이지 않는다. 기다리는 pass 하나의 값을 줄인다.

### 1.6 운영자 해소로 이어진 원본 (2026-11-13)

운영자가 멈춘 원본을 해소하면 그 원본에 fence 가 서고, 같은 source 로 child 원본이 새로 만들어진다. child 는 fence 가 선 원본을 앞선 원본으로 가리킨다. 이 문서는 그 둘을 "해소 쌍"이라 부른다.

| 무엇 | 값 | 언제, 어떻게 |
|---|---|---|
| 본문 22.66 MB 인 쌍의 Keeper | pass 63번, 검증 시간 합 558.2초, 최장 33.8초 | 2026-11-13 15:30~17:07 KST, build `aa1ff9233691`, 서버 로그의 inventory 줄 |
| 본문 6.58 MB 인 쌍의 Keeper | pass 56번, 합 206.5초, 최장 17.0초 | 같은 창 |
| 나머지 Keeper 27명 | pass 410번, 합 146.4초 | 같은 창 |
| 두 쌍의 몫 | 911.1초 가운데 764.7초, 84% | 계산값 |
| child 원본의 진행 기록 | 1,944 사건과 1,856 사건. 모두 접수 의도와 `capacity_wait` 거절의 짝이다(972번, 928번) | 17:08 KST, 기록 파일 |
| child 원본의 기록 파일 | 247 KB, 236 KB. pass 마다 다시 쓴다 | 같은 때 |
| resolution 기록 파일 | 22.66 MB, 6.58 MB | 같은 때 |
| fence 파일 | 154 KB, 77 KB | 같은 때 |
| 살아 있는 history 기록의 교체 의도(`replacement_intended`) | 0개 | 같은 때, 기록 628개의 진행 기록 |

- 두 child 는 2026-11-12 19:13 KST 에 만들어졌고 그 뒤로 접수되지 못했다(#51280).
- 1.2절의 두 Keeper 와 같은 Keeper 다. 그때는 원본이 worker 에 기록이 없어 멈춰 있었고(#50828), 지금은 그 원본에 fence 가 서고 child 가 기다린다.
- resolution 기록이 본문만큼 큰 것은 child 요청 전체를 `child_payload` 칸에 담기 때문이다(`lib/keeper/keeper_librarian_history_resolution_intent.ml` 52~53행, 311행).
- 서버의 major heap 할당 상위 30자리 146 GB 가운데 약 34 GB 가 `history_resolution_lineage`·`history_resolution_intent`·`history_resolution_state` 아래였다. 가동 32분, 표본 누락 72만 건이라 몫은 어림이다(#51281 의 2026-11-13 댓글).

해소 쌍 하나(fence 가 선 부모 P, child C, resolution 기록 R)에 pass 한 번이 본문 크기의 파일을 읽는 자리를 코드에서 셌다. 계측해서 센 값이 아니다.

| 자리 | P 본문 | C 본문 | R |
|---|---:|---:|---:|
| `Resolution_work.run_serialized` 가 scope 의 resolution 기록을 모두 푼다(`keeper_librarian_history_resolution_intent.ml` 241~249행). 풀 때마다 child 요청을 타입으로 풀고 digest 를 계산한다(147~148행) | | | 1 |
| `recover_child` 가 부모를 읽고(`keeper_librarian_history_resolution_work.ml` 81행), child 를 읽고(87행), 계보를 확인한다(100행) | 2 | 1 | 1 |
| `retain_completion` 이 child 를 읽고 계보를 확인한 뒤에 phase 를 본다(105~122행) | 1 | 1 | 1 |
| `discover` 가 scope 의 원본을 본문까지 읽는다(`keeper_librarian_durable_owner.ml` 46~56행) | 1 | 1 | |
| `validate_lineage` 가 child 의 계보를 확인한다(`keeper_librarian_durable_execution.ml` 150행) | 1 | | 1 |
| 끝나지 않은 child 를 `resume` 이 이어 갈 때 계보를 한 번 더 확인한다(`keeper_librarian_durable_owner.ml` 127행, 33행) | 1 | | 1 |
| 합 | 6 | 3 | 5 |

- 로그의 검증 시간이 재는 구간은 이 가운데 `discover` 줄 하나와 fence 확인, inventory 검사다. 타이머는 `run_serialized` 가 끝난 뒤에 시작하고(`keeper_librarian_durable_execution.ml` 344행, 349행) `validate_lineage` 앞에서 적힌다(383~390행). 위 표의 84% 는 그 구간의 값이다. 나머지 다섯 줄의 시간은 어느 로그에도 없다. 할당 표본에만 보인다.

- 계보 확인 한 번은 부모 본문을 읽어 검증하고 풀고, fence 와 견주려고 부모 source 의 digest 를 계산하고, resolution 기록을 읽어 child 요청을 풀고, 부모 source 에 child 의 현재 Memory 를 얹어 child source 와 글자로 견준다(`lib/keeper/keeper_librarian_history_resolution_lineage.ml` 13~52행).
- 표 밖에도 source 의 digest 를 계산하는 자리가 있다. fence 가 선 원본은 fence 를 볼 때마다 source 전체를 글자로 만들어 digest 를 계산한다(`keeper_librarian_history_resolution_state.ml` 112~118행). pass 한 번에 그 원본을 훑을 때 한 번(`keeper_librarian_durable_execution.ml` 368행), child 의 계보를 볼 때 한 번(148행) 더 돈다.
- worker 를 부르기 전의 retain 이 child 본문을 한 번 더 읽는다(1.1절 여섯째 줄). 위 표에 넣지 않았다. child 가 접수를 기다리는 동안에는 요청 전체를 worker 에 다시 보낸다(#51280).

## 2. 무엇이 문제인가

- 기다리는 동안 원본에서 달라지는 것은 진행 기록뿐이다. 본문은 retain 때 정해지고 그 뒤로 바뀌지 않는다.
- pass 는 달라지지 않는 것을 매번 다시 증명한다. 그 값이 본문 크기에 비례한다.
- 큰 본문일수록 오래 기다린다. model 이 받지 못할 만큼 크거나, 대기 목록에 못 들어가거나, 실행이 오래 걸린다. 그래서 큰 값이 가장 여러 번 되풀이된다.
- 본문을 읽고 푸는 일은 `Systhread_host` 의 domain 하나를 쓴다. 그 domain 은 다른 파일 작업도 받는다(RFC main-domain-scheduler-latency 7절이 더 옮기는 중이다).
  - 검증 시간 합 3,706초를 창 25,260초로 나누면 0.147 이다. 평균으로 pass 0.147개가 늘 이 구간 안에 있었다.
- Curator 는 기록의 `summary` 로 훑는다. history 는 그 칸을 비우고 본문으로 훑는다.
- 해소 쌍의 관계는 child 를 만들 때 한 번 정해진다. `intend_child` 가 두 본문으로 그 관계를 확인하고 resolution 기록에 적는다(`keeper_librarian_history_resolution_intent.ml` 292~313행). pass 는 그 관계를 두 본문과 child 요청의 사본으로 매번 다시 증명한다.
- child 요청은 디스크에 두 벌 있다. child 의 본문 파일과 resolution 기록 안이다.

## 3. 제안

### 3.1 원칙

- 본문은 쓰는 단계에서 읽고, 그때 digest 로 검증한다.
- 기다리는 길은 기록으로 돈다. 그 길이 쓰는 값은 기록의 `summary` 에서 읽는다. 본문을 읽은 자리에서는 그 값이 본문과 같은지 확인한다.
- 기록은 pass 마다 읽는다. 진행 기록은 pass 마다 달라질 수 있다.

### 3.2 기다리는 길은 기록으로 돈다

기다리는 길에 있는 세 자리가 `Record.t` 를 받게 한다.

| 자리 | 지금 | 바꾼 뒤 |
|---|---|---|
| 진행 기록 저장 | `Owner.advance` 는 `expected : retained` 를 받는다. 읽고 쓰는 것은 기록뿐이고 요청은 들고만 다닌다(`lane_addon_tool_request_owner.ml` 326~342행) | 기록을 받는 함수가 그 일을 한다. `retained` 를 받는 `advance` 는 그 함수를 부르고 결과 기록을 가진 요청과 다시 묶는다 |
| `Submit.resume` 과 그 결과 타입 | `original : retained` | `original : Record.t`. 본문은 부른 쪽이 준 함수로 얻는다(3.5절) |
| `Runtime.call_captured_tool_request` | 호출마다 `Owner.retain` 을 부른다. 요청을 다시 만들어 sha256 을 계산하고 본문 파일을 다시 읽는다 | 기록만 다시 읽어 같은 id 가 같은 설치·package·tool·digest·`summary` 를 가리키는지 확인한다 |

- `Owner.advance` 와 `advance_events` 를 부르는 곳은 접수 모듈 말고 아홉 파일이다. 그 호출처들은 바뀌지 않는다. `retained` 를 받는 함수가 남기 때문이다.
- owner 모듈에 함수 하나를 더한다. 가진 `retained` 와 돌려받은 기록을 다시 묶는다. scope, 요청 id, digest 가 같을 때만 값을 준다.
  - `reload` 가 안에서 이미 하는 일이다(229~240행). digest 가 같으면 같은 요청이라는 원칙 그대로다.
  - 본문을 가진 소비자는 접수 모듈이 돌려준 기록을 이 함수로 자기 `retained` 에 묶는다. admission 이 지금 record 를 갈아 끼우는 자리가 그렇다(`lib/keeper/keeper_librarian_admission_owner.ml` 292행, 301행, 304행).
- `call_captured_tool_request` 를 부르는 곳은 둘이다. history 와 floor step 의 edge(`keeper_librarian_durable_edge.ml` 46행), admission(`keeper_librarian_admission_owner.ml` 144행)이다.
  - admission 은 원본을 먼저 만든 뒤에 부른다(129행). 호출 때의 retain 이 원본을 처음 쓰는 호출처는 없다.
  - 지금 retain 은 기록이 없으면 본문과 기록을 `Captured` 로 새로 쓴다(`lane_addon_tool_request_owner.ml` 304~311행). 기록으로는 그렇게 쓸 수 없다. 기록이 없거나 다른 것을 가리키면 `Unavailable` 로 돌려준다. 그 pass 는 worker 에 닿지 못한 대기(`Worker_unreachable`)로 끝난다. 지금 retain 이 실패할 때와 같은 결과다(`lane_addon_runtime.ml` 2482~2483행).
- Curator 는 이 함수를 쓰지 않는다. 호출마다 원본을 본문까지 읽고 `capture_tool_request_owner` 로 다시 retain 한다(`lib/server/server_workspace_memory_addon.ml` 120~141행). 이 문서는 그 길을 바꾸지 않는다(5절).
- fence 읽기와 gate 목록 찾기는 scope 와 요청 id 만 쓴다(`keeper_librarian_history_resolution_state.ml` 119~120행, `keeper_librarian_original_gate.ml` 586행). history 가 기록으로 부른다(fence 는 L0, gate 는 L2).
- 본문을 가진 값에서 기록은 지금도 얻는다(`Owner.listed`, `lane_addon_tool_request_owner.mli` 185~186행).

### 3.3 `summary` 에 두는 값

- 1.3절 첫 표의 값을 타입 하나로 묶는다.

```ocaml
(* keeper_librarian_durable_request *)
type index = private {
  owner : owner;
  destination : destination;
  predecessor : predecessor option;
  runtime_keepers_dir : string;   (* confirm_source_root 이 보는 경로 *)
  exact_digest : string;          (* Lane_addon_exact.digest (request t) *)
  source_digest : string;         (* fence 의 source_sha256 과 같은 계산. 3.9절 *)
  source_basis_digest : string;   (* 읽을 때의 Memory 를 뺀 source 의 digest. 3.9절 *)
}
val index : t -> (index, string) result   (* Exact 요청을 만드는 일이 실패할 수 있다 *)
val index_to_json : index -> Yojson.Safe.t
val index_of_summary : Owner.Record.t -> (index, string) result
```

- `index` 는 검증을 마친 `t` 에서만 만든다. 기록에서 읽은 것은 `index_of_summary` 로만 나온다.
- 요청 id 와 본문 digest 는 기록에 이미 있다. `summary` 에 다시 넣지 않는다.
- `retain` 은 `summary` 에 `index_to_json (index request)` 를 넣는다(`keeper_librarian_durable_owner.ml` 39~41행).
- 기록의 다른 칸이 묶어 주는 값과 아닌 값이 있다.
  - 주인의 경로 셋과 Keeper id 는 scope 로 묶인다. scope 는 그 주소의 sha256 이고(`keeper_librarian_durable_request.ml` 51~59행), 요청 id 가 그 scope 를 담는다(103~112행). `index_of_summary` 는 `summary` 의 주인으로 계산한 scope 가 기록의 scope 와 같은지 확인한다.
  - 목적지의 설치 id, package id, tool 은 기록의 칸과 견준다(235~240행).
  - Memory epoch, 목적지의 revision 둘, 앞선 원본, runtime 경로, Exact digest, source 의 digest 둘은 `summary` 에만 있다. retain 이 검증한 `t` 에서 한 번 쓰고, 본문을 읽는 자리에서 `load` 가 본문과 견준다(3.4절).
- 지금 `t` 를 받는 확인 함수 가운데 기다리는 길이 쓰는 것은 기록과 `index` 를 받게 한다. `confirm_record`, `confirm_source_root`, 주인 확인, 앞선 원본 확인이다.
- 본문을 쓰는 함수는 그대로 `t` 를 받는다. `request`, `validate_proposal`, `confirm_final`, `source` 다.

### 3.4 pass

- `discover` 는 `Owner.discover` 로 기록만 읽고, 기록마다 `index_of_summary` 를 부른다.
- 원본 하나가 아래를 모두 만족하면 기록과 `index` 만으로 간다. 하나라도 아니면 그 자리에서 `load` 로 본문을 읽어 지금 길로 간다.

| 조건 | 어디서 아나 |
|---|---|
| phase 가 `Dispatch_pending` 이다 | 기록의 진행 기록 |
| gate 준비와 gate 기록이 없다 | 기록의 진행 기록, 요청 id 로 찾은 gate 목록 |
| 교체 계보에 들어 있지 않다. 진행 기록에 교체 의도가 없고, 앞선 원본이 있으면 그 원본에 fence 가 서 있다 | 이 원본과 다른 원본들의 `index`, 기록의 진행 기록, 요청 id 로 읽는 fence 파일 |
| host 기록에 결과도 실행 증거도 없다 | 3.6절의 `observe_open` |

- 조건은 모두 타입으로 읽은 값이다. 크기나 시간으로 가르지 않는다.

```ocaml
(* keeper_librarian_durable_owner *)
val discover : ... -> ((Owner.Record.t * Request.index) list, error) result
val load : store:Lane_addon_store.t -> Owner.Record.t -> Request.index ->
  (Owner.retained * Request.t, error) result
```

- `load` 는 `load_listed` 로 본문을 읽어 지금처럼 검증하고 푼다. 그리고 푼 요청의 `index` 가 기록에서 읽은 `index` 와 같은지 확인한다. 다르면 오류다.
- 접수할 원본(`Captured`, `Admission_wait`)은 접수 모듈이 접수 의도를 저장하기 전에 본문을 읽는다(3.5절). 본문을 읽지 못한 채 접수 의도를 저장하는 일이 없다.
- gate 검사는 본문을 읽은 원본에만 576행의 비교를 한다. 기록만으로 가는 원본은 gate 기록이 없다는 것을 요청 id 로 확인한다.

본문을 읽는 자리를 원본의 상태로 적으면 이렇다.

| 원본 | pass 가 하는 일 | 본문 |
|---|---|---|
| 위 조건을 모두 만족하고 worker 가 대기나 없음으로 답한다 | host 기록을 보고 worker 에 묻는다 | 안 읽는다 |
| `Dispatch_pending` 이고 host 기록에 결과나 실행 증거가 있다 | 답을 확인하고 반영하거나 거절을 보고한다 | 읽는다 |
| `Dispatch_pending` 이고 worker 가 끝났다고 답한다 | 그 답을 풀어 확인한다 | 읽는다 |
| `Captured`, `Admission_wait` | 접수한다 | 읽는다. 지금과 같다 |
| `Judged`, `Committing`, `Commit_unknown` | 반영을 잇는다 | 읽는다. 지금과 같다 |
| 정리된 원본 | 거절 규칙, floor 후보, 보관 | 읽는다. 지금과 같다 |
| fence 가 선 원본. 앞선 원본이 없거나 앞선 원본에도 fence 가 서 있다 | fence 와 `index` 를 견준다(3.9절). pass 는 이 원본을 더 다루지 않는다 | 안 읽는다 |
| 해소 쌍의 child | 계보를 기록과 `index` 로 확인한다(3.9절). 그 밖에는 자기 phase 의 줄을 따른다 | 계보 때문에는 안 읽는다 |
| 교체 계보에 든 원본(충돌한 원본과 그 교체 원본) | source 를 견준다 | 읽는다. 지금과 같다 |

- 달라지는 것은 첫 줄과 fence·해소 쌍의 두 줄이다.
- 2026-11-11 08:07Z 에 끝나지 않은 history 원본 26개 가운데 19개가 `Dispatch_pending` 이었다. 마지막 진행 기록이 대기 15, 접수 의도 2, worker 에 기록 없음 2 다. 나머지 7개는 접수 거절이다. 19개가 나머지 조건도 만족하는지는 재지 않았다.
- 1.2절의 멈춘 원본 둘은 worker 에 기록 없음 2 다.

### 3.5 접수 모듈은 본문을 필요한 갈래에서 읽는다

- `Submit.resume` 은 요청 전체를 두 곳에 쓴다. host 기록을 볼 때와 접수할 때다(`lane_addon_submit_once.ml` 96행, 170행). schema 도 두 곳에 쓴다(96행, 195행).
- 부른 쪽이 준 답 해석 함수 둘(`decode_final`, `terminal`)도 요청을 쓴다. 지금은 부른 쪽이 요청을 미리 쥔 채 함수를 만든다.
- 그 함수가 안에서 본문을 읽게 하면 읽기 실패가 엉뚱하게 분류된다.
  - worker 의 끝난 답은 답을 푸는 도중에 `decode_final` 을 부른다(53행). 거기서 난 실패는 "worker 의 답을 알 수 없다"가 된다(155~157행). 진행 기록에 관찰 한 줄이 붙고 pass 는 기다린다(113~115행, 223행).
  - 접수 앞의 실패가 `prepare` 쪽에서 나면 worker 에 닿지 못한 대기가 된다(160~164행).
- 그래서 본문을 읽는 일을 접수 모듈이 직접 한다. 부른 쪽은 읽는 함수를 주고, 답 해석 함수는 읽은 값을 인자로 받는다.

```ocaml
(* lane_addon_submit_once *)
type 'body source = {
  identity : Exact.identity;                    (* 요청 id 와 digest. 3.6절 *)
  load : unit -> ('body, error) result;         (* 본문을 읽고 검증한다 *)
  request : 'body -> Exact.request;
  schema : 'body -> Yojson.Safe.t;
}
val resume : store:Lane_addon_store.t -> label:string ->
  original:Owner.Record.t -> source:'body source ->
  decode_final:('body -> Yojson.Safe.t -> (Exact.final, string) result) ->
  prepare:(unit -> (unit, error) result) -> call:call ->
  terminal:('body -> Owner.Record.t -> Exact.final -> ('final, error) result) ->
  ('final result, error) result
```

- `decode_final` 과 `terminal` 은 읽은 본문 없이는 부를 수 없다. 타입이 막는다.
- 접수 모듈은 본문이 필요한 갈래에 들어설 때 `load` 를 한 번 부른다. 그 실패는 `resume` 의 오류로 그대로 나간다. 진행 기록에 아무것도 쓰지 않는다.

| 갈래 | 자리 | 순서 |
|---|---|---|
| 접수(`Captured`, `Admission_wait` 에서 worker 가 없다고 답함) | 162~182행 | 접수 의도를 저장하기(166행) 전에 읽는다 |
| 답이 저장된 원본(`Judged`) | 184~187행 | 저장된 답을 풀기 전에 |
| 실행에서 거절된 원본 | 192~201행 | 거절 증거를 풀기 전에 |
| host 기록이 `Needs_request` 다 | 213행 | `observe_open` 뒤, `recover_retained` 전에 |
| worker 가 끝났다고 답한다 | 150행 | 답의 상태를 먼저 읽고, 끝난 답이면 결과를 풀기 전에 |

- 마지막 갈래 때문에 worker 답을 푸는 일을 둘로 나눈다. 상태를 먼저 읽고(47~55행), 끝난 답의 결과는 본문을 읽은 뒤에 푼다.
- 나머지 갈래는 본문을 읽지 않는다. host 기록이 열려 있거나 없고 worker 가 대기나 없음으로 답한 `Dispatch_pending`, 반영을 잇는 phase, 정리된 phase 다.
- 소비자는 넷이다. history(`keeper_librarian_durable_owner.ml` 191행), floor step(`lib/keeper/keeper_librarian_floor_step_owner.ml` 86행), admission(`lib/keeper/keeper_librarian_admission_dispatch.ml` 92행), Curator(`lib/server/server_workspace_memory_addon.ml` 109행)다.
  - floor step, admission, Curator 는 이미 가진 본문을 돌려주는 `load` 를 넘긴다. 저장하는 것은 그대로다.
  - history 는 `index.exact_digest` 로 `identity` 를 만들고, `load` 가 3.4절의 `load` 를 부른다.

### 3.6 Keeper 는 열린 host 기록을 digest 로 묶는다

```ocaml
(* lane_addon_exact *)
type identity = private { request_id : string; digest : string }
val identity : request -> identity
val identity_of_digest : request_id:string -> digest:string -> identity

type open_observation =
  | No_record        (* host 기록도 실행 증거 파일도 없다 *)
  | Open             (* host 기록이 있고 결과도 실행 증거 파일도 없다 *)
  | Needs_request    (* 결과나 실행 증거 파일이 있다. 요청 전체로 다시 읽는다 *)
val observe_open : store:Lane_addon_store.t -> declaration_id:string -> identity ->
  (open_observation, recovery_error) result
```

- `observe_open` 은 읽기만 한다. 쓰지 않으므로 실행 중 표시(claim, 869행)를 잡지 않는다. `recover_retained` 가 하는 검사에서 "부른 쪽의 요청을 다시 만들어 견주기"만 뺀다.
  - host 기록이 스스로 맞는지는 지금처럼 본다. 칸과 모르는 칸, canonical 모양, 저장된 요청이 타입으로 풀려 다시 만든 모양과 같은지, 그 요청의 digest 가 `digest` 칸과 같은지, 시도의 순서다(`lane_addon_exact.ml` 460~467행, 470~472행, 491~514행). 어긋나면 `Recovery_invalid` 다.
  - 부른 쪽과는 `digest` 칸과 `identity.digest` 로 견준다. 다르면 `Recovery_invalid` 다.
  - 실행 증거 파일은 요청 id 와 digest 로 찾는다(592~594행, 686~688행). 파일이 있기만 하면 `Needs_request` 다. 증거를 풀고 시도와 묶는 일은 요청 전체가 있어야 하고(`decode_proofs`, `bind_proofs`), 그 검사를 건너뛰지 않는다.
  - host 기록이 없고 증거 파일도 없으면 `No_record`, 기록의 `final` 이 없고 증거 파일도 없으면 `Open`, `final` 이 있으면 `Needs_request` 다.
  - 파일을 읽지 못하면 `Recovery_unavailable` 이다(549~551행의 구분 그대로).
- `Needs_request` 면 지금 길로 간다. 본문을 읽어 요청 전체를 만들고 `recover_retained` 를 부른다. 결과를 풀고, 실행 증거를 검증하고, 증거로 기록을 마무리하는 일은 그 길에만 있다.
- host 는 실행하기 전에 저장된 기록을 요청 전체로 스스로 다시 검증한다(949~959행). 원본 본문에서 만든 요청과 받은 요청의 digest 도 견준다(`lib/server/server_librarian_addon_validation.ml` 38~39행). 그 검증은 바꾸지 않는다.
- 줄어드는 것과 남는 것이 있다.
  - 줄어드는 것: Keeper 가 host 기록을 보려고 요청 전체를 만들 필요가 없다. history 는 그 요청을 본문에서 만든다.
  - 남는 것: host 기록 파일은 요청 전체를 담고 있어서, 읽으면 그 크기만큼 풀고 digest 를 한 번 계산한다. 1.2절의 3.58 MB 기록이면 290.0 ms 가운데 읽기 1.0, 풀기 132.0, digest 한 번 78.5 ms 가 남는다. 측정한 단계를 더한 값이고 바꾼 코드로 잰 값이 아니다. canonical 비교는 재지 않았다. 그 비용은 host 기록의 모양을 바꿔야 준다(5절).
  - 실행 증거 파일이 생긴 요청은 그 뒤로 pass 마다 본문을 읽는다. provider 가 거절해 미뤄진 요청이 그렇다(859~860행의 `Call_refused`). 몇 개인지는 재지 않았다.
- pass 마다 돌던 schema 검사 둘(1.3절)은 본문을 읽는 자리로 옮겨 간다. 그 검사는 요청 자신의 schema 를 lane 선언과 견주는 것이라, 늦게 해도 닿는 상태가 달라지지 않는다.

### 3.7 설치

- L0 부터 `summary` 가 빈 history 기록과 `child_payload` 칸이 있는 resolution 기록은 읽지 않는다. 서버를 멈추고 아래를 지우고 설치한다. `index` 는 L0 에서 마지막 모양으로 넣는다. 뒤 층은 지우지 않고 설치한다.

| 지울 것 | 왜 |
|---|---|
| history 원본의 scope(`keeper-librarian-history-execution-*`), 기록과 본문 두 곳 | 기록 모양이 바뀐다 |
| 그 gate 의 scope, 기록과 본문 두 곳 | gate 는 부모 원본을 id 와 digest 로 가리킨다 |
| floor step 의 scope(`keeper-librarian-floor-step-*`)와 그 gate(`keeper-librarian-floor-step-gate/`), 기록과 본문 두 곳 | floor step 은 history 원본을 id 와 digest 로 가리킨다(`lib/keeper/keeper_librarian_floor_step_request.ml` 97행, 109~111행) |
| history fence(`keeper-librarian-history-fences`)와 resolution 기록(`keeper-librarian-history-resolutions`) | resolution 기록의 모양이 바뀐다(3.9절). 둘 다 원본을 요청 id 로 가리킨다. 원본이 없으면 그 Keeper 의 pass 가 "Resolution original is absent" 로 끝난다(`lib/keeper/keeper_librarian_history_resolution_work.ml` 31~34행, `keeper_librarian_durable_execution.ml` 344~345행) |

- 같은 원본과 gate 묶음을 비운 앞선 hard cut 이 있다(#46247). 그때처럼 반영 중인 원본(`Committing`, `Commit_unknown`)이 없을 때 한다. 2026-11-11 07:44Z 와 08:07Z 에 그 phase 의 history 원본은 0개였고 라이브 floor step 기록도 0개였다.
- 읽은 위치는 원본 밖에 있다. Memory 의 range receipt(`keeper_librarian_durable_commit.ml` 62~81행)와 외부 읽기 cursor 다. 지운 범위는 다음 pass 가 다시 고른다. 요청 id 는 원본마다 새로 만든다(`keeper_librarian_durable_execution.ml` 104행).
- 잃는 것은 넷이다.
  - worker 대기 목록의 순서. 다시 접수한 요청은 뒤에 선다.
  - 받았지만 아직 반영하지 않은 답. 같은 범위를 model 에 한 번 더 묻는다.
  - 정리된 거절이 좁혀 둔 범위. 같은 범위가 한 번 더 거절된 뒤 다시 좁혀진다.
  - 운영자가 세운 fence 와 진행 중인 resolution. 멈춘 원본에 세운 것이면 그 원본과 함께 없어지고, 범위는 다시 고른다.
- 남는 것이 있다.
  - worker 는 지운 원본의 요청을 계속 들고 있다. host 는 원본이 없는 요청에 `Not_allowed` 결과를 저장하고 끝낸다(`server_librarian_addon_validation.ml` 11~16행, `lane_addon_exact.ml` 1007~1008행). worker 가 그 결과를 받아 대기 목록에서 빼는지는 package 쪽이라 확인하지 못했다.
  - host 의 Exact 기록과 실행 증거 파일은 지운 요청의 것도 남는다. 요청 id 가 새로 만들어져 다시 읽히지 않는다. 치우는 길이 있는지는 확인하지 못했다.
- `index_of_summary` 는 살아 있는 scope 의 기록에만 부른다. 보관된 기록은 지금처럼 store 의 기록 모양으로 읽는다.

### 3.8 결과가 전달될 때 Keeper 를 찾기

- 지금은 요청 하나의 기록과 본문을 읽고, history 는 원본 전체를 푼다(1.4절).
- history 는 그 scope 의 기록만 읽어 요청 id 가 같은 기록의 `summary` 에서 주인을 읽는다. 설치 id 는 기록에 있다. 본문을 읽지 않는다.
- 선언을 다시 관찰하거나 export 목록이 바뀔 때의 전체 순회는 기록만 먼저 읽는다. history 원본은 `summary` 로 Keeper 를 찾고, admission 과 floor step 원본만 `load_listed` 로 본문을 읽는다.
  - 모든 scope 를 기록만으로 도는 함수가 owner 층에 없다. `fold_all` 과 `discover_all` 은 기록마다 본문을 읽는다(`lane_addon_tool_request_owner.ml` 256~274행). store 층의 `fold_tool_request_owner_inventory_all` 과 `Owner.decode_published` 로 owner 층에 하나를 더한다.
- floor step 과 admission 이 Keeper 를 찾는 길은 지금 그대로다.

### 3.9 운영자 해소의 계보는 기록과 `index` 로 확인한다

규칙은 하나다. 원본을 가리키는 것은 요청 id 와 digest 로 가리킨다. 요청의 글자는 그 digest 로 이름 붙은 본문 파일 한 곳에만 둔다. 두 원본의 관계는 두 `index` 의 값으로 견주고, `index` 가 본문과 같은지는 본문을 읽는 자리의 `load` 가 확인한다(3.4절). 3.1절의 원칙을 원본 둘 사이로 넓힌 것이다.

**`index` 에 더하는 값 둘**

- `source_digest` 는 `Source.to_json` 을 canonical 로 만든 글자의 sha256 이다. fence 가 `source_sha256` 칸에 적는 값과 같은 계산이다(`keeper_librarian_history_resolution_state.ml` 98행).
- `source_basis_digest` 는 source 에서 Memory revision 과 input 의 `current` 를 비운 값의 digest 다.
  - 해소가 child 의 source 를 만드는 함수 `Source.with_current` 는 그 두 칸만 바꾼다(`lib/keeper/keeper_librarian_durable_capture.ml` 522~525행).
  - 그래서 "child 의 source 는 부모 source 에 child 의 Memory 를 얹은 것과 같다"는 지금의 비교(`keeper_librarian_history_resolution_lineage.ml` 45~48행)는 "두 source 의 basis 가 같다"와 같은 말이다.
  - `with_current` 는 얹은 결과를 `validate_record` 로 검사한다. child 의 source 는 자기 본문을 풀 때 같은 검사를 받는다(`keeper_librarian_durable_capture.ml` 560행).
- 두 값은 retain 이 검증한 원본에서 한 번 계산한다.
- `load` 는 두 값을 쓰는 원본에서만 본문으로 다시 계산해 견준다. 앞선 원본이 있거나 fence 가 선 원본이다. 다른 원본의 두 값은 어디에도 쓰이지 않는다.
  - 다시 계산하는 값은 source 를 글자로 만들어 sha256 을 내는 일 두 번이다. 22.66 MB 본문에서 글자로 만들기 404.6 ms, sha256 371.8 ms 였다(1.2절, 부풀어 있는 값).
  - 해소 쌍이 아닌 원본의 `load` 에 더해지는 것은 `exact_digest` 하나다. Exact 요청의 digest 이고, 그 요청은 본문에서 질문 부분만 담는다. 1.6절의 두 child 에서 질문은 38 KB 였다(본문 20.2 MB, 5.6 MB 가운데).
- host 와 배포 검사는 해소 쌍의 두 원본에서 두 값을 본문으로 계산한다. 지금 그 자리에서 하는 source digest 계산과 source 를 글자로 만들어 견주는 일 두 번을 갈음한다.

**resolution 기록은 child 를 digest 로 가리킨다**

- `child_payload` 칸을 없앤다. phase 의 `child`(`request_id`, `request_digest`)가 child 를 가리킨다.
- `intend_child` 는 지금처럼 두 본문으로 관계를 확인한다. 그 뒤 `Owner.prepare_successor` 로 child 요청을 본문 파일로 먼저 저장하고, 그 id 와 digest 를 phase 에 적는다.
  - 공용 owner 모듈에 이미 있는 길이다. 실행 거절의 successor 가 본문을 먼저 저장하고 digest 만 든 의도를 남긴다(`lib/lane_addon/lane_addon_tool_request_owner.ml` 301~313행, `lib/lane_addon/lane_addon_request_progress.mli` 10행의 `successor`).
  - 본문 파일의 이름은 digest 다(`lib/lane_addon/lane_addon_store.ml` 843~844행). 원본을 retain 할 때 쓰는 파일과 같은 파일이다.
- child 기록이 아직 없는 `Child_intended` 에서는 `Owner.load_successor_request` 로 그 본문을 읽어 child 를 만든다. 본문이 없거나 digest 가 다르면 오류다. 다시 만들지 않는다.
- resolution 기록을 풀 때는 지금 child 요청 전체를 타입으로 풀고, canonical 로 만든 digest 를 phase 의 digest 와 견준다(`keeper_librarian_history_resolution_intent.ml` 147~150행). 요청이 기록에 없으면 그 둘은 child 를 retain 하는 자리의 일이 된다. `load_successor_request` 가 본문을 digest 로 검증하고 `retain` 이 타입으로 푼다. `child_payload` 와 phase 가 함께 있는지 보던 검사(155~156행)는 칸이 없어져 없어진다. 나머지 검사 셋은 자리를 옮긴다.

| 검사 | 지금 | 바꾼 뒤 |
|---|---|---|
| child 가 같은 scope 에 있고 부모와 다른 요청이다 | 풀 때마다 child 요청을 타입으로 푼다(`keeper_librarian_history_resolution_intent.ml` 147~151행) | 풀 때마다 child 의 요청 id 에서 scope 를 읽는다. 요청 id 가 scope 를 담는다 |
| child 의 앞선 원본이 이 원본이다 | 풀 때마다(152~154행) | `intend_child` 가 쓸 때 한 번, 계보 확인이 child 의 `index` 로 pass 마다 |
| Memory 반영 영수증이 child 의 범위와 맞다 | 풀 때마다(159~163행) | `observe_memory_commit` 이 쓸 때 한 번. 끝난 원본의 source 로 견준다 |

- 셋째 줄은 읽을 때의 검사가 하나 빠진다. 밖에서 바뀐 resolution 기록의 영수증이 child 의 범위와 다른 것을 pass 가 잡지 않는다. 영수증이 든 intent 를 읽는 곳은 둘이다. pass 는 그런 intent 를 건너뛰고(253~254행), 운영자 화면은 "Memory 에 반영됨"으로 보여 준다(`keeper_librarian_history_resolution_work.ml` 221~226행). 영수증으로 Memory 를 쓰거나 원본을 움직이는 곳은 없다.

**계보 확인**

`Resolution_lineage.validate` 가 child 하나에 하는 검사를 값으로 옮긴다.

| 검사 | 지금 읽는 것 | 바꾼 뒤 읽는 것 |
|---|---|---|
| 부모 기록이 있고 그 digest 가 child 가 가리킨 digest 다 | 부모 기록과 본문 | 부모 기록, child `index.predecessor` |
| fence 가 부모를 가리킨다 | fence 파일, 부모 기록 | 같다 |
| fence 의 source 와 주인이 부모의 것이다 | 부모 본문에서 푼 source 의 digest 와 주인 | 부모 `index.source_digest`, `index.owner` |
| 이 child 를 가리키는 intent 가 있고 phase 가 맞다 | resolution 기록 | 같다. 기록이 작아진다 |
| intent 가 fence 를 세운 그 관찰·사람·이유다 | resolution 기록, fence | 같다 |
| child 가 intent 가 적은 요청이다 | intent 안의 child 요청을 canonical 로 만든 digest 와 child 본문 digest | intent 의 `child.request_digest` 와 child 기록의 digest |
| child 의 source 가 부모 source 에 Memory 만 얹은 것이다 | 두 본문에서 푼 source | 두 `index.source_basis_digest` |
| 주인이 같다 | 두 본문에서 푼 주인 | 두 `index.owner` |
| 조상에 순환이 없다 | 요청 id | 같다 |

- 함수는 하나다. `index` 를 주는 reader 를 받는다. Keeper 의 pass 는 `index_of_summary` 로 읽은 값을 넘긴다. host 가 실행 앞에서 하는 확인(`lib/server/server_librarian_addon_validation.ml` 32행, 55행)과 배포 검사(`lib/keeper/keeper_librarian_store_preflight.ml` 46~49행)는 지금처럼 본문을 읽고, 푼 원본에서 `Request.index` 로 만든 값을 넘긴다. host 가 본문으로 확인하는 것은 바꾸지 않는다(3.6절).
- fence 가 없는 부모는 교체 계보다. 지금 함수(`Request.validate_predecessor_link_payload`)를 그대로 부른다. 그 함수는 child 요청 전체를 부모의 교체 의도와 견주므로 child 와 부모의 본문이 있어야 한다(5절). 그래서 계보 함수는 reader 를 둘 받는다. `index` 를 주는 것과, 교체 계보에서만 부르는 "본문까지 읽은 원본"을 주는 것이다.
- fence 가 선 원본도 교체 원본일 수 있다. fence 는 worker 에 기록이 없다고 관찰된 원본에 서고, 그 원본이 충돌한 원본의 교체 원본이어도 선다(`lib/keeper/keeper_librarian_history_resolution.ml` 55~64행). 그런 원본은 자기 앞선 원본과의 교체 계보를 본문으로 확인받는다(`keeper_librarian_durable_execution.ml` 153~185행, `keeper_librarian_history_resolution_lineage.ml` 28행·51행).
- `fenced_original` 과 `confirmed_resolution_child` 도 같은 값을 받는다. fence 가 있는지 볼 때 source 의 digest 를 다시 계산하지 않는다.

**pass**

- `discover` 는 기록만 읽고 `index_of_summary` 를 부른다(3.4절).
- fence 가 선 원본 가운데 앞선 원본이 없거나 앞선 원본에도 fence 가 선 것은 `load` 를 부르지 않는다. pass 는 지금도 그 원본을 더 다루지 않는다(`keeper_librarian_durable_execution.ml` 368~370행). 앞선 원본에 fence 가 없는 것은 교체 계보라 `load` 를 부른다.
- 계보를 확인하는 호출처는 pass 에 여섯이다. `recover_child`, `find_completed`, `record_completed_serialized`(`keeper_librarian_history_resolution_work.ml` 100행, 120행, 193행), `validate_lineage`(`keeper_librarian_durable_execution.ml` 150행), `Durable_owner.retain` 과 `resume`(`keeper_librarian_durable_owner.ml` 36행, 127행)이다. 모두 `index` 를 넘긴다.
- `Resolution_work` 의 pass 마다 도는 길도 기록으로 돈다.
  - `recover_child` 는 child 기록이 있으면 그 id 와 digest 를 intent 와 견주고 계보를 확인한다. 부모 본문을 읽지 않는다.
  - `find_completed` 는 child 기록과 `index` 로 fence 를 먼저 본다. fence 가 서 있으면 지금처럼 그 child 의 해소 child 로 내려간다(`keeper_librarian_history_resolution_work.ml` 113~117행). fence 가 없으면 phase 를 본다. `Finished` 나 `Conflicted` 가 아니면 거기서 끝난다. 지금은 본문을 읽고 계보를 확인한 뒤에 phase 를 본다(105~130행).
  - `record_completed_serialized` 는 끝난 원본이 어느 해소에 속하는지 조상을 따라 올라가며 찾는다. 지금은 조상마다 본문을 읽는다(184~187행). 조상의 기록과 `index.predecessor` 로 올라간다.
  - `observe_memory_commit` 은 지금 해소 child 를 `child_payload` 에서 풀어, 끝난 원본의 source 가 그 child 의 source 에 Memory 만 얹은 것인지 본다(`keeper_librarian_history_resolution_intent.ml` 325~332행). 끝난 원본은 해소 child 자신이거나 그 교체 후손이다. 해소 child 의 `index.source_basis_digest` 와 끝난 원본의 것을 견준다. 영수증은 끝난 원본의 source 와 견준다. 끝난 원본은 그 자리에서 이미 본문까지 읽은 값이다.
- 본문을 읽는 자리는 셋이다. child 를 만들 때(`prepare_child` 가 부모 본문을, `intend_child` 가 두 본문을), child 기록이 없어 다시 만들 때, 그리고 원본 자신의 phase 가 본문을 쓸 때(3.4절의 표)다.
- 기동 때의 본문 목록 관찰은 살아 있는 기록과 진행 기록의 의도가 가리키는 digest 만 "가리키는 것이 있다"고 센다(`lib/lane_addon/lane_addon_original_body_inventory.ml` 23~41행). resolution 기록이 가리키는 child digest 도 세게 한다. 그러지 않으면 `Child_intended` 동안 저장해 둔 child 본문이 "가리키는 것이 없는 파일"로 세어진다. 그 관찰은 파일을 지우지 않는다.

## 4. 순서 따라가기

### 4.1 원본 하나의 일생

| 틱 | 일 | 본문 |
|---|---|---|
| N | Keeper A 가 범위를 고르고 원본을 만든다. 본문과, `summary` 를 채운 기록을 쓴다. 접수한다 | 쓴다. 접수하며 보낸다 |
| N+1 ~ N+k | 기록만 읽는다. `summary` 로 확인한다. host 기록을 digest 로 본다. worker 에 묻는다. 대기다. worker 의 답이 앞과 다르면 진행 기록에 한 줄 붙인다 | 안 읽는다 |
| N+k+1 | host 기록에 답이 있다. 접수 모듈이 `load` 를 한 번 부른다. 답을 원본의 질문과 맞추고 반영한다 | 한 번 읽는다 |
| N+k+2 | 원본이 정리된다. 보관 단계가 본문을 읽는다 | 지금과 같다 |

- 서버가 다시 떠도 N+1~N+k 는 같다. 값이 기록에 있어서 본문을 읽지 않는다.
- host 가 실행을 미루고 실행 증거 파일을 남긴 뒤의 틱은 본문을 읽는다(3.6절).

### 4.2 기다리는 동안 본문 파일이 바뀐다

| 때 | 지금 | 바꾼 뒤 |
|---|---|---|
| 바뀐 직후의 pass | 본문 digest 가 달라 pass 가 오류로 끝난다 | 기록만 읽으므로 worker 에 묻고 대기로 끝난다. worker 의 답이 앞과 다르면 진행 기록에 한 줄 붙는다 |
| host 가 그 요청을 실행하려 할 때 | host 가 원본을 읽다 오류로 끝난다. 실행하지 않는다 | 같다 |
| host 가 이미 답을 받은 뒤 | 다음 pass 가 오류로 끝난다 | 답을 확인하려고 본문을 읽을 때 같은 오류로 끝난다 |

- 바뀐 본문으로 접수하거나 반영하는 일은 어느 쪽에서도 없다.
- 달라지는 것은 둘이다. Keeper 쪽에서 오류가 보이는 때가 늦어진다. 그 사이에 worker 관찰이 진행 기록에 붙을 수 있다(`lane_addon_submit_once.ml` 103~112행). 그 줄은 worker 가 대기나 없음으로 한 답의 기록이고 본문의 내용에 기대지 않는다. worker 가 끝났다고 답한 pass 는 본문을 먼저 읽으므로 그 실패는 오류로 끝나고 아무 줄도 붙지 않는다(3.5절).
- worker 에 기록이 없다는 관찰은 운영자가 fence 를 세울 수 있는 조건이다(`keeper_librarian_history_resolution_state.ml` 87~91행). fence 를 세우는 길은 본문을 읽는다.
- 그 사이에 본문이 바뀐 사실이 보이는 곳은 host cycle 의 실패 기록이다. worker 가 그 요청을 들고 있을 때만 그렇다. worker 에 기록이 없는 원본은 host 가 본문을 읽지 않으므로, 본문을 쓰는 단계가 올 때까지 어디에도 드러나지 않는다.

### 4.3 기록의 `summary` 가 본문과 다르다

- retain 은 검증한 원본에서 `summary` 를 만든다. 둘이 다르려면 기록 파일이 밖에서 바뀌어야 한다. 기록의 다른 칸(설치 id, digest)과 같은 처지다.
- `summary` 의 주인이 기록의 scope 와 맞지 않으면 `discover` 가 오류로 끝난다. Memory epoch 는 scope 에 없어서 여기서 잡히지 않는다.
- 기다리는 pass 는 `summary` 의 값으로 확인한다. 주인이나 목적지가 지금과 다르면 지금과 같은 오류로 끝난다.
- `summary` 가 지금 값과는 맞고 본문과 다르면, 기다리는 pass 는 worker 에 묻고 진행 기록에 관찰을 붙일 수 있다. 지금은 `discover` 가 먼저 거절한다.
- 접수와 반영 앞에서는 `load` 가 둘을 견준다. 다르면 오류로 끝나고 아무것도 접수하거나 반영하지 않는다.
- `summary` 의 Exact digest 가 틀린 경우는 둘로 갈린다.
  - host 기록이 있으면 `observe_open` 이 `Recovery_invalid` 를 준다. pass 는 오류로 끝난다. 문구는 host 기록을 가리킨다.
  - host 기록이 없으면 `No_record` 다. worker 에 묻고 기다린다. 본문을 읽는 자리에서 `load` 가 `index` 를 본문과 견줘 오류로 끝낸다.
- host 는 `summary` 를 쓰지 않는다. 실행 전에 본문을 읽어 검증한다.

### 4.4 Memory epoch 가 바뀐다

- 주인 확인은 지금 `discover` 가 한다(`keeper_librarian_durable_owner.ml` 52행). 바꾼 뒤에도 `discover` 가 한다. 본문의 주인 대신 `summary` 의 주인을 지금 관찰한 주인과 견준다. 같은 오류로 끝난다.

### 4.5 Keeper 여럿

- 원본은 Keeper 마다 자기 scope 에 있다. 서로의 기록을 읽지 않는다.
- 결과 하나가 전달되면 capacity 대기자가 모두 깬다. 접수를 거절당한 원본은 본문을 읽어 다시 접수한다. 접수된 원본은 기록만 읽는다.

### 4.6 slot 과 계정

- `summary` 와 `identity` 는 provider, slot, 계정을 담지 않는다. host 가 slot 을 고르고 넘어가는 흐름은 바뀌지 않는다.
- 요청이 다른 slot 으로 넘어가 오래 걸릴수록 Keeper 는 더 여러 번 기다린다. 실행 증거 파일이 생기기 전까지 그 pass 들이 가벼워진다.
- 넘어간 slot 이 입력을 받지 못해 호출이 `Input_refused` 로 끝나면 host 기록에 결과가 생긴다. 그 pass 는 본문을 읽어 거절을 보고한다. 지금과 같다.

### 4.7 운영자가 멈춘 원본을 해소한다

| 틱 | 일 | 부모 본문 | child 본문 | resolution 기록 |
|---|---|---|---|---|
| N | 운영자가 해소를 요청한다. fence 가 선다. `prepare_child` 가 부모 본문을 읽어 child 의 source 를 만든다. `intend_child` 가 두 본문으로 관계를 확인하고 child 본문을 저장한 뒤 id 와 digest 를 적는다. 같은 pass 가 이어서 저장한 본문을 읽어 child 를 retain 하고 확인을 적는다 | 읽는다 | 쓰고, 읽고, retain 이 같은 글자를 한 번 더 쓴다 | 세 번 쓴다. child 요청을 담지 않는다 |
| N+1 ~ N+k | 부모: 기록, `index`, fence. child: 계보를 기록과 `index` 로 확인하고 자기 phase 의 줄을 따른다 | 안 읽는다 | phase 에 따른다 | 읽는다. 크기가 본문과 무관하다 |
| N+k+1 | child 가 끝난다. `observe_memory_commit` 이 두 `index` 로 관계를 보고, 끝난 원본의 source 로 영수증을 견줘 적는다 | 안 읽는다 | 반영하는 길이 이미 읽었다 | 읽고 쓴다 |

- 틱 N 의 일은 한 pass 안에서 이어진다(`keeper_librarian_history_resolution_work.ml` 159~162행). 지금도 그 pass 는 child 요청을 resolution 기록에 한 번, 본문 파일에 한 번 쓴다. 바꾼 뒤에는 본문 파일에 두 번 쓴다. 같은 이름, 같은 글자다.
- `Child_intended` 를 쓴 뒤 child 를 retain 하기 전에 서버가 죽으면 child 본문 파일과 intent 가 남는다. 다음 pass 가 본문을 읽어 retain 한다.
- `intend_child` 가 본문을 저장한 뒤 intent 를 쓰기 전에 죽으면 가리키는 것이 없는 본문 파일이 남는다. 다음 pass 가 child 를 다시 만들면 요청 id 가 새로 만들어져 다른 파일이 된다. 남은 파일은 기동 때의 본문 목록 관찰이 세고, 지우지는 않는다.
- `Child_intended` 에서 저장해 둔 본문이 없어지면 그 Keeper 의 pass 는 오류로 끝난다. child 를 다시 만들지 않고, 그 phase 에서는 해소를 거절로 돌릴 수도 없다(`keeper_librarian_history_resolution_intent.ml` 273~284행). 살아 있는 원본의 본문이 없어졌을 때와 같은 처지다. 그때도 `discover` 가 오류로 끝나고 pass 가 멈춘다. 본문 파일을 지우는 코드는 원본을 정리할 때뿐이다(`lib/lane_addon/lane_addon_store.ml` 939행).
- child 가 접수를 기다리는 틱은 child 본문을 읽는다. 접수 모듈이 요청 전체를 worker 에 다시 보내기 때문이다(5절, #51280).
- 기다리는 동안 부모 본문 파일이 밖에서 바뀌면 pass 는 잡지 않는다. 부모 본문을 다시 쓰는 곳은 없다. host 가 child 를 실행하기 전에 부모 본문까지 읽어 계보를 확인하고, 거기서 오류로 끝난다.

## 5. 풀지 않는 것

| 무엇 | 지금 | 어디서 다루나 |
|---|---|---|
| 접수를 거절당한 원본 | pass 마다 본문을 읽고 요청 전체를 worker 에 다시 보낸다. 1.6절의 두 child 가 지금 이 상태다. 3.9절을 설치해도 그런 child 는 pass 마다 자기 본문을 읽는다. 1.6절의 표에서 P 6·R 5 가 0 이 되고 C 3 이 1 이 된다. 표 밖의 retain 한 번은 L1 까지 남는다. 로그의 검증 시간은 그 구간에 있던 부모 본문 읽기만큼만 준다 | #51280. worker 가 바뀌어야 한다 |
| host 기록이 요청 전체를 담는다 | Keeper 가 읽을 때마다 그 크기만큼 푼다. 시도가 붙을 때마다 요청째로 다시 쓴다. host 는 요청을 시도할 때마다 통째로 다시 묶는다 | #50762 |
| host 가 시도마다 원본 본문을 읽는다 | lane 이 받지 않아 미뤄지는 동안 cycle 마다 되풀이된다(`server_librarian_addon_validation.ml` 27~40행) | #50762 와 함께 본다. host 는 실행 권한을 본문으로 확인한다. Keeper 의 pass 와 다른 판단이다 |
| 실행 증거 파일이 있는 열린 요청 | 증거를 풀려면 요청 전체가 있어야 해서 pass 마다 본문을 읽는다 | 증거의 모양을 바꿔야 한다. 재지 않았다 |
| 교체 계보에 든 원본 | 충돌한 원본의 교체 원본은 앞선 원본을 가리키고, 부모의 진행 기록이 교체 요청 전체를 담는다(`Replacement_intended`). 계보 확인이 본문을 쓰므로 pass 마다 본문을 읽는다(3.4절) | 3.9절과 같은 모양으로 풀린다. 교체 의도를 digest 만 든 `successor` 로 바꾸면 된다. 2026-11-13 에 살아 있는 history 기록의 교체 의도는 0개였다(1.6절). 생기면 재고 그때 옮긴다 |
| 끝난 해소 쌍 | fence 가 선 원본은 끝나지 않은 원본에도 정리된 원본에도 들지 않는다(`keeper_librarian_durable_execution.ml` 369~370행). 끝난 chain 을 보관하는 함수는 조상이 모두 정리된 원본이고 교체 확인을 가졌을 때만 chain 으로 본다(239~244행). 그래서 child 가 끝나도 쌍이 보관되지 않고, 정리된 child 는 pass 마다 본문을 읽는 것으로 보인다 | 확인 필요. 그 두 함수만 읽었고 floor 정리와 거절 정리 쪽은 읽지 않았다. L0 을 구현하기 전에 시험으로 확인하고, 맞으면 이슈로 적는다 |
| Curator 의 worker 호출 | 호출마다 원본을 본문까지 읽고 다시 retain 한다(`server_workspace_memory_addon.ml` 120~141행) | Curator 는 `summary` 로 훑고 손댈 원본만 읽는다. 그 본문의 크기는 재지 않았다 |
| 정리된 거절 원본 | 그 범위가 아직 유효한 동안 pass 마다 본문을 읽는다 | 이 문서 뒤. `summary` 에 범위를 넣으면 같은 모양으로 풀린다. 재지 않았다 |
| floor step, admission 의 pass | 같은 모양으로 본문을 읽는다 | L1 의 기록 길은 함께 쓴다. `summary` 는 재지 않아서 넣지 않는다 |
| gate 기록 | pass 마다 gate scope 의 본문을 읽는다(`keeper_librarian_original_gate.ml` 556행) | 재지 않았다. 기다리는 원본에는 gate 기록이 없다 |
| 본문이 JSON 안에 JSON 글자를 담는다 | 바깥을 풀고 다시 만드는 두 단계가 1,422.0 ms 다(1.2절) | 저장 모양을 바꿔야 한다. 이 문서는 읽는 횟수를 줄인다 |

## 6. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 값을 프로세스 안의 표에 둔다 | 저장 모양이 그대로라 지우고 설치할 일이 없다. 대신 `summary` 와 같은 일을 하는 것이 하나 더 생긴다. 서버가 다시 뜰 때마다 원본마다 본문을 한 번 읽는다. 9절의 첫 결정이다 |
| `summary` 가 빈 원본은 본문에서 값을 만든다 | 옛 모양을 읽는 코드가 남는다 |
| 푼 원본 전체를 프로세스 안에 둔다 | 본문 합이 72.9 MB 이고 푼 값은 그보다 크다. 기다리는 pass 는 그 값을 쓰지 않는다 |
| 값만 `summary` 에서 읽고 파일 검증은 pass 마다 한다 | 1.2절의 64% 가 남는다 |
| pass 마다 본문의 sha256 만 확인한다 | 22.66 MB 에 371.8 ms 가 남는다. 지키는 것은 4.2절의 "오류가 보이는 때" 하나다 |
| 실행 증거 파일이 있어도 마지막 시도의 증거만 본다 | 앞선 시도의 증거가 무효인 기록을 지금은 거절한다. 그 검사가 빠진다 |
| host 기록의 `digest` 칸만 믿는다 | 저장된 요청이 그 digest 와 다른 기록을 지금은 거절한다. 그 검사가 빠지면 host 는 cycle 마다 오류를 내고 Keeper 는 끝없이 기다린다 |
| 본문 파일의 수정 시각이나 크기로 바뀐 것을 잡는다 | 내용을 증명하지 않는다 |
| N번에 한 번만 검증한다 | 근거 없는 숫자다 |
| 해소 쌍을 pass 안에서 한 번만 읽는다 | 1.6절의 P 6·C 3·R 5 가 1·1·1 이 된다. 읽는 양은 여전히 본문 크기에 비례하고 pass 마다 되풀이된다. #51667 이 gate chain 에 한 일이다 |
| resolution 기록은 그대로 두고 계보만 `index` 로 확인한다 | resolution 기록이 child 요청을 담고 있어서 읽을 때마다 본문 크기만큼 푼다. 같은 요청이 디스크에 두 벌 남는다 |
| child 요청의 사본을 resolution 기록 옆 다른 파일로 뺀다 | 본문 파일이 이미 digest 로 이름 붙은 그 요청이다. 같은 것을 두는 곳이 하나 더 생긴다 |
| 교체 의도도 지금 digest 로 바꾼다 | 살아 있는 것이 0개라 잰 값이 없다(1.6절). 공용 진행 기록의 사건 모양을 바꾸는 일이라 따로 한다 |

## 7. 층

| 층 | 바꾸는 것 | 확인 |
|---|---|---|
| L0 | `index` 타입과 codec, `retain` 이 `summary` 를 채우기, history 의 `discover` 와 `load`(3.3절). resolution 기록이 child 를 digest 로 가리키기, 계보 확인과 fence 확인을 기록과 `index` 로, `Resolution_work` 의 pass 길(3.9절). 본문 목록 관찰이 resolution 기록의 child digest 를 세기. fence 가 선 원본은 3.9절의 조건에서 `load` 를 부르지 않고, 나머지 원본은 이 층에서는 모두 `load` 를 부른다. 설치는 3.7절대로다 | 8절의 계보 시험 |
| L1 | 기다리는 길을 기록으로(3.2절): 기록을 받는 진행 기록 저장과 다시 묶는 함수, `Submit.resume` 과 결과 타입, `Runtime.call_captured_tool_request`. 접수 모듈이 본문을 읽는 갈래와 worker 답을 두 번에 푸는 일(3.5절). `Lane_addon_exact.identity` 와 `observe_open`(3.6절). 접수 모듈의 소비자 넷과 worker 호출의 호출처 둘을 함께 옮긴다 | 8절의 접수 모듈·host 기록 시험 |
| L2 | 3.4절의 조건을 만족하는 원본은 `load` 를 부르지 않기, gate 를 기록으로 찾기 | 8절의 pass 시험 |
| L3 | 기록만으로 모든 scope 를 도는 owner 함수, 결과가 전달될 때 Keeper 를 찾는 길(3.8절) | 8절의 wake 시험 |

- L0 이 첫 층이다. 2026-11-13 에 잰 검증 시간의 84% 가 해소 쌍의 Keeper 에서 나왔고, 로그에 잡히지 않는 계보 읽기가 그 밖에 pass 마다 부모 본문 다섯 번, resolution 기록 다섯 번이기 때문이다(1.6절). L0 뒤에 로그의 검증 시간에서 빠지는 것은 부모 본문 읽기다. child 본문 읽기는 L2 와 #51280 이 줄인다.
- 3.7절의 설치가 지금의 두 쌍을 지운다. L0 의 효과는 그 뒤에 운영자가 새로 해소한 쌍에서 잰다. L0 은 접수 모듈, worker 호출, `lane_addon_exact.ml` 을 고치지 않는다. L1 에 기대지 않는다.
- L0 이 history 원본과 resolution 기록의 모양을 바꾼다. 지우고 설치하는 층은 L0 하나다(3.7절).
- L1 은 저장된 것을 바꾸지 않는다. L1 만으로 worker 호출 앞의 본문 읽기(1.1절 여섯째 줄)가 history, floor step, admission 에서 없어진다. Curator 는 다른 길로 부르므로 남는다(5절).
- L1 은 `lane_addon_exact.ml` 을 고친다. RFC exact-request-skips-a-slot-that-refused-its-input 의 L2b 가 같은 파일을 고치는 중이라 그 뒤에 쌓는다.
- L2 는 L0 과 L1 뒤에 온다. `summary` 가 채워져 있어야 하고, 접수 모듈과 worker 호출이 본문을 가진 값을 받는 동안에는 기다리는 pass 가 본문을 읽어야 한다.
- L3 은 L0 뒤에 온다. `summary` 가 채워져 있어야 한다.
- 네 층 모두 서버 코드다. 선언과 package 는 건드리지 않는다.

## 8. 시험

화면 배치 시험은 쓰지 않는다. 모두 함수 단위다.

- 접수 모듈과 worker 호출
  - host 기록이 열려 있거나 없고 worker 가 대기나 없음으로 답하면 `load` 는 0번 불린다. 반영을 잇는 phase 와 정리된 phase 도 0번이다.
  - 3.5절 표의 다섯 갈래는 각각 `load` 를 한 번 부른다.
  - 접수에서 `load` 가 실패하면 `resume` 이 그 오류로 끝나고 접수 의도가 저장되지 않는다.
  - worker 가 끝났다고 답했는데 `load` 가 실패하면 `resume` 이 그 오류로 끝나고 진행 기록에 아무것도 붙지 않는다.
  - worker 호출은 기록이 없거나 다른 digest 를 가리키면 `Unavailable` 이고, 그 `resume` 은 `Worker_unreachable` 대기로 끝난다. worker 는 불리지 않는다.
  - 다시 묶는 함수는 digest 가 다른 기록에 값을 주지 않는다.
- host 기록
  - 스스로 맞고 digest 가 같은 열린 host 기록은 `Open` 이다.
  - `digest` 칸은 같고 저장된 요청이 다른 기록은 `Recovery_invalid` 다.
  - `identity.digest` 가 다른 기록은 `Recovery_invalid` 다.
  - 결과가 있는 기록은 `Needs_request` 다. 실행 증거 파일이 있으면 시도 번호와 상관없이 `Needs_request` 다.
  - host 기록 없이 증거 파일만 있으면 `Needs_request` 이고, 그 길은 지금과 같은 `Recovery_invalid` 로 끝난다.
- pass
  - 접수된 원본의 본문 파일을 지운다. 다음 pass 는 worker 를 한 번 부르고 worker 대기(`Worker_pending`)로 끝난다. worker 에 닿지 못한 대기(`Worker_unreachable`)가 아니어야 본문을 읽지 않았다는 증명이 된다.
  - 같은 상태에서 host 기록에 답을 넣는다. 그 pass 는 본문이 없다는 오류로 끝나고 아무것도 반영하지 않는다.
  - 같은 상태에서 worker 가 끝났다고 답하게 한다. 같은 오류로 끝나고 진행 기록은 그대로다.
  - 본문 파일을 다른 내용으로 바꾼 경우도 같다. digest 오류로 끝난다.
  - 기록의 `summary` 를 다른 주인으로 바꾼다. `discover` 가 scope 오류로 끝난다.
  - `summary` 의 목적지 revision 만 바꾸고 host 기록에 답을 넣는다. 본문을 읽은 자리에서 둘이 다르다는 오류로 끝난다.
  - `summary` 가 빈 기록은 `discover` 가 오류로 끝낸다.
  - Memory epoch 를 바꾸면 기다리는 pass 가 지금과 같은 오류로 끝난다.
  - 교체 계보에 든 원본은 본문 파일을 지우면 오류로 끝난다. 본문을 읽는 길로 갔다는 증명이다.
- 계보(L0)
  - 해소 쌍에서 부모의 본문 파일을 지운다. 다음 pass 의 inventory 검증과 계보 확인이 지금과 같은 결과로 끝난다. 부모 본문을 읽지 않았다는 증명이다.
  - 같은 상태에서 child 가 `Dispatch_pending` 이면 `Resolution_work` 의 pass 길이 child 본문도 읽지 않는다. child 본문 파일을 지워도 그 길은 같은 결과로 끝난다.
  - 부모 `summary` 의 `source_digest` 를 바꾸면 fence 와 다르다는 오류로 끝난다.
  - child `summary` 의 `source_basis_digest` 를 바꾸면 계보 오류로 끝난다.
  - child 기록의 digest 가 intent 의 `child.request_digest` 와 다르면 계보 오류로 끝난다.
  - child `summary` 의 앞선 원본이 다른 요청이면 계보 오류로 끝난다.
  - resolution 기록에 `child_payload` 칸이 있으면 모르는 칸 오류로 끝난다.
  - `Child_intended` 에서 child 기록이 없고 저장한 본문이 있으면 child 가 retain 되고 그 digest 가 intent 와 같다.
  - 같은 상태에서 저장한 본문을 지우거나 다른 내용으로 바꾸면 오류로 끝나고 child 가 만들어지지 않는다.
  - Memory 만 다른 두 source 는 `source_basis_digest` 가 같다. 범위, 읽은 위치, counterpart, 바깥 관찰 가운데 하나라도 다르면 다르다.
  - host 의 실행 앞 확인은 부모 본문 파일을 지우면 오류로 끝난다. host 는 본문을 읽는다는 증명이다.
  - fence 가 선 원본이 충돌한 원본의 교체 원본이면 그 본문 파일을 지운 pass 가 오류로 끝난다. 교체 계보는 본문을 읽는다는 증명이다.
  - fence 가 선 child 에 해소 child 가 또 있으면 `find_completed` 가 그 아래로 내려가 끝난 원본을 찾는다.
  - 끝난 원본이 해소 child 의 교체 후손이어도 `observe_memory_commit` 이 영수증을 적는다. basis 가 다른 원본이면 적지 않는다.
  - 본문 목록 관찰은 `Child_intended` 가 가리키는 본문을 가리키는 것이 있는 파일로 센다.
  - `Resolution_intent.intended_child` 를 읽던 시험 둘(`test/test_keeper_librarian_durable_execution.ml` 2093행, 2113행)은 phase 의 child 와 본문 파일을 읽게 고친다.
- wake
  - history 원본의 본문 파일이 없어도 Keeper 를 찾는다.
- 변이
  - 계보 확인이 부모를 본문까지 읽게 하면 "부모의 본문 파일을 지운다" 시험이 실패한다.
  - 계보 확인에서 `source_basis_digest` 비교를 빼면 그 값을 바꾼 시험이 실패한다.
  - `load` 에서 `source_digest` 비교를 빼면, 본문과 다른 `source_digest` 를 가진 원본을 접수하는 시험이 실패한다.
  - `find_completed` 가 phase 를 보기 전에 본문을 읽게 하면 "child 본문 파일을 지워도" 시험이 실패한다.
  - `find_completed` 가 fence 보다 phase 를 먼저 보게 하면 "해소 child 가 또 있으면" 시험이 실패한다.
  - fence 가 선 교체 원본의 `load` 를 건너뛰게 하면 그 원본의 본문을 지운 시험이 통과해 버린다.
  - `discover` 가 늘 본문을 읽게 하면 "본문 파일을 지운다" 시험이 실패한다.
  - worker 호출이 다시 본문을 retain 하게 하면 같은 시험이 `Worker_unreachable` 로 실패한다.
  - `load` 에서 digest 검증을 빼면 "본문을 바꾼다" 시험이 실패한다.
  - worker 의 끝난 답을 본문을 읽기 전에 풀게 하면 "진행 기록은 그대로다" 시험이 실패한다.
  - `load` 에서 `index` 비교를 빼면 "`summary` 의 목적지 revision 만 바꾼다" 시험이 실패한다.
  - `observe_open` 에서 저장된 요청의 digest 검사를 빼면 host 기록 시험이 실패한다.

## 9. 정한 것

운영자가 2026-11-13 에 정했다.

1. **값을 두는 곳은 기록의 `summary` 다.** 서버를 멈추고 history 원본과 gate, floor step, fence, resolution 기록을 지운 뒤 설치한다. 잃는 것 넷과 남는 것 둘은 3.7절에 있다.
   - 고르지 않은 길은 프로세스 안의 표다. 저장 모양이 그대로라 지울 것이 없다. 대신 `summary` 와 같은 일을 하는 것이 둘이 되고, 서버가 다시 뜰 때마다 원본마다 본문을 한 번 읽고, 3.8절은 pass 와 다른 모듈이라 그 표를 쓰지 못한다.
2. **운영자 해소의 계보를 첫 층으로 옮긴다(L0, 3.9절).** 이 문서의 처음 판은 그것을 풀지 않는 것으로 두었다. 2026-11-13 에 재니 검증 시간의 84% 가 그런 쌍을 가진 Keeper 둘에서 나왔다(1.6절).

아래 둘은 운영자가 맡겼고 이 문서가 정했다.

3. **본문 파일이 밖에서 바뀐 것은 본문을 쓸 때 잡는다.** 접수, 답 확인, 반영, 거절 보고, child 를 만들 때와 끝낼 때다. host 에 실행 증거 파일이 있는 요청과 교체 계보에 든 원본은 지금처럼 pass 마다 잡는다.
   - 이유: pass 마다 잡으려면 pass 마다 본문 전체의 sha256 을 계산해야 한다. 22.66 MB 에 371.8 ms 다(1.2절). 그러면 기다리는 pass 가 본문 크기에 다시 비례한다. 이 문서가 없애려는 것이 그것이다.
   - 대가: 4.2절, 4.3절, 4.7절이다. 그 사이에 worker 관찰이 진행 기록에 붙을 수 있고, 본문이 바뀐 사실은 host 쪽 기록으로만 보인다. output schema 검사 둘도 본문을 읽는 자리로 옮겨 간다. resolution 기록의 영수증 검사 하나는 쓸 때만 한다(3.9절).
4. **L1 은 접수 모듈의 소비자 넷과 worker 호출의 호출처 둘을 한 번에 옮긴다.**
   - 이유: `Submit.resume` 의 인자와 결과 타입이 바뀐다. history 만 옮기려면 옛 타입을 받는 `resume` 을 하나 더 남겨야 하고, 같은 일을 하는 함수가 둘이 된다. 나머지 셋은 이미 가진 본문을 돌려주는 `load` 를 넘기면 되고 저장하는 것은 그대로다(3.5절).
   - 대가: 네 소비자를 한 PR 에서 함께 고친다. 진행 기록 저장의 호출처 아홉 파일은 그대로다(3.2절).
   - 범위 밖으로 둔 것: 교체 의도를 digest 로 바꾸는 일, floor step 과 admission 의 `summary`, Curator 의 worker 호출이다. 잰 값이 없거나 0 이다(5절).

## 10. 관련

- #51281: 이 문서의 이슈다. 측정과 코드 추적이 댓글에 있다.
- #50828: worker 에 기록이 없어 멈춘 원본. 그 원본이 풀려도 큰 원본이 다시 오래 기다리면 같은 비용이 생긴다.
- #51280: 접수 거절이 되풀이되어 pass 가 는다. 1.6절의 두 child 가 22시간 동안 972번, 928번 거절됐다.
- #51655: 서버 전체의 GC 정지와 이 pass 의 할당을 이은 측정이다.
- RFC exact-request-skips-a-slot-that-refused-its-input: L2b 가 `lane_addon_exact.ml` 을 고친다. 이 문서의 L1 은 그 뒤에 쌓는다.
- #50762: host 기록에 시도가 쌓이고 그때마다 요청 전체를 다시 쓴다.
- #51199, #51272: 원본이 오래 기다리는 원인과 그 설계다.
- #51278: 선언이 교체된 원본을 끝내는 설계다. 그 문서도 접수 모듈의 접수 전 갈래를 바꾼다. 두 문서의 층은 서로 기대지 않는다.
- #51263(병합됨): host 기록을 읽지 못한 것과 무효인 것을 가른다. `observe_open` 은 그 구분을 그대로 쓴다.
- #46359(닫힘): 기록 하나에 같은 대화가 네 번 들어가던 것을 줄였다. 이 문서는 남은 한 벌을 다시 읽는 횟수를 줄인다.
- RFC main-domain-scheduler-latency 7절: 파일 작업의 스레드를 `Systhread_host` 로 옮긴다. 그 domain 이 받는 일이 늘수록 이 문서가 줄이는 값이 더 중요해진다.
