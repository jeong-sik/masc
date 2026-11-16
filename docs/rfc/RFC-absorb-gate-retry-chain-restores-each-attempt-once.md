---
rfc: "absorb-gate-retry-chain-restores-each-attempt-once"
title: "흡수 시도 사슬은 한 번 읽는 동안 시도마다 한 번만 복원한다 — 후보 셋의 비교"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
supersedes: []
superseded_by: null
related: ["librarian-absorb-gate", "librarian-history-settles-finished-originals", "0484", "0489", "0498"]
---

# 흡수 시도 사슬은 한 번 읽는 동안 시도마다 한 번만 복원한다 — 후보 셋의 비교

2026-11-15 하루 동안 TypeSafe 는 크레딧이 없다며(HTTP 402) 모든 판정을 거절했다.
그동안 Librarian 은 깨어날 때마다 같은 원본에 흡수 시도를 하나씩 더 남겼다.
시도가 70개 쌓인 Keeper 의 pass 검증 구간은 75초였다. 시도가 0개일 때는 1초가 안 걸렸다.
운영자가 TypeSafe 콘솔에서 크레딧을 넣었고, 11-16T01:34Z 부터 TypeSafe 가 다시 답했다.

이 RFC 는 pass 비용이 시도 수보다 빨리 느는 원인을 적고, 줄이는 후보 셋을 비교한다.
권고는 후보 A 다. 사슬 계약과 저장 상태를 바꾸지 않는다. 코드는 아직 쓰지 않았다.

- 다루는 것: 흡수 시도 사슬을 읽는 비용, 실패가 길어질 때 살아 있는 gate scope 에 남는 시도, 운영자가 풀어야 하는 거절 뒤에 다시 묻는지.
- 다루지 않는 것: 원본 본문을 다시 검증하는 비용(#51655, #51281), 시도 하나의 크기, Board attention 판정이 목적지를 묻는 순서(RFC-0484 §3.2 가 그대로 두기로 했다).
- 근거 기준: 코드는 `origin/main` `f782a8f3268e` 에서 읽었다. 측정은 운영 저장소 `~/me/.masc` 를 읽기만 했다.
- 표시: **[사실]** 코드나 데이터에서 확인한 것, **[추정]** 근거는 있으나 직접 재지 않은 것, **[제안]** 이 RFC 가 내놓는 것, **[확인 필요]** 모르는 것.

## 0. 요약

- **[사실]** 사슬을 한 번 읽을 때 시도마다 처음 시도까지 거슬러 올라가며 다시 복원한다. 앞에서 복원한 결과를 다시 꺼내 쓰지 않는다. 그래서 길이 n 사슬 하나를 읽으면 복원이 n(n+1)/2 번 일어난다(§1.2).
- **[사실]** 11-16T01:38Z 에 durable gate 기록 570개가 사슬 19개에 있었다. 가장 긴 사슬은 71개였다. 거절로 끝난 기록 567개 중 565개가 402 였다(§2).
- **[제안]** 후보 A: 한 번 읽는 동안 이미 복원한 시도는 다시 꺼내 쓴다. 사슬 하나를 읽을 때 복원이 n 번으로 준다. admission gate 의 discover 는 gate 기록마다 새로 읽으므로, 같은 pass 안에서 한 번 읽은 것을 함께 쓰게 한다(§4.1).
- 후보 B(대체된 시도를 보관소로 옮기기)는 고르지 않는다. 지금 사슬 계약과 RFC-0498 의 보관소 정리 규칙과 부딪친다(§4.2).
- 후보 C(402·401·403 뒤에는 자동으로 다시 묻지 않기)도 고르지 않는다. C 였다면 01:34Z 뒤에도 운영자가 masc 에서 따로 조치하기 전까지 흡수가 멈춰 있었다(§4.3).
- 정할 것은 §7 의 1~4 다.

## 1. 지금 동작

### 1.1 실패 뒤 다시 묻는 자리

세 gate 가 같은 모양으로 다시 묻는다. 앞 시도가 실패로 끝났고(`Gate.failure_detail` 이 `Some`) 지금 권한이 있으면, 앞 시도를 `predecessor` 로 가리키는 새 시도를 `Journal.retain` 으로 남기고 `Journal.resume` 으로 보낸다.

| gate | scope 접두어 | 다시 묻는 자리 | 지금 권한 |
|---|---|---|---|
| durable(완료 이력) | `keeper-librarian-durable-gate/` | `lib/keeper/keeper_librarian_durable_commit.ml:355-373` | `lib/keeper/keeper_librarian_durable_edge.ml:32-40` |
| admission | `keeper-librarian-admission-gate/` | `lib/keeper/keeper_librarian_admission_owner.ml:253-269` | `lib/keeper/keeper_librarian_admission_owner.ml:58-61` |
| floor step | `keeper-librarian-floor-step-gate/` | `lib/keeper/keeper_librarian_floor_step_judgment.ml:106-113` | `lib/keeper/keeper_librarian_floor_chain.ml:117-118`(`durable_edge.ml:32` 를 부른다) |

- **[사실]** 세 gate 의 사슬 저장과 검증은 공용 functor `Keeper_librarian_original_gate.Make`(`lib/keeper/keeper_librarian_original_gate.ml`) 하나다. `lib/keeper/keeper_librarian_admission_gate.ml:11`, `lib/keeper/keeper_librarian_durable_gate.ml:3`, `lib/keeper/keeper_librarian_floor_step_gate.ml:4` 가 이 functor 를 쓴다.
- **[사실]** 지금 권한은 Keeper owner 와 Add-on 목적지 설정만 확인한다. 목적지가 무엇으로 거절했는지는 읽지 않는다.
- **[사실]** §2 의 측정은 durable gate 만 셌다.

### 1.2 사슬을 읽는 비용

- **[사실]** `read_chain_with`(`keeper_librarian_original_gate.ml:413-454`)는 같은 원본의 시도마다 `restore_record_with` 를 부른다.
- **[사실]** `restore_record_with`(`:348-399`)는 앞 시도를 불러 `restore_record_with` 로 다시 복원한다(`:359`). 처음 시도까지 이렇게 내려간다. 복원할 때마다 그 시도의 transcript 를 처음부터 다시 맞춰 본다(`:367-399`).
- **[사실]** 한 번 읽는 동안 같은 부모를 다시 확인하지 않게 하는 `confirmed_parents`(`:117-135`)는 있다. 시도 복원에는 같은 장치가 없다.
- 그래서 길이 n 사슬을 한 번 읽으면 복원이 1 + 2 + … + n = n(n+1)/2 번 일어난다. 디스크에서 읽는 `current_reading` 이면 앞 시도를 부를 때마다 기록과 본문을 다시 읽어서, `Owner.load` 가 n(n−1) 번 나간다.
- **[사실]** pass 하나는 사슬을 여러 번 읽는다.
  - 로그의 `elapsed_ms` 구간 안(`keeper_librarian_durable_execution.ml:363` 에서 `:478-484` 까지): `Inventory.validate` 가 사슬을 한 번 읽고(`keeper_librarian_original_gate.ml:620`), 처음 시도 준비를 확인하고(`:638`), 마지막 시도를 처음까지 다시 복원한다(`:641-642`). 합치면 (n+1)(n+2)/2 번이다. 이 구간의 `load` 는 메모리의 Map 조회다.
  - 구간 밖(`keeper_librarian_durable_commit.ml:286-373`): `validate`(`:288`), `recover_root`(`:333`, 처음 시도 준비만 확인한다), `recover_retries`, `root`, `latest`, `restore_latest_result`, `retain`, `resume`(`:371`)이 저마다 `current_reading` 을 새로 만들어 디스크에서 다시 읽는다.
- **[사실]** admission gate 의 discover(`keeper_librarian_admission_owner.ml:84-90`)는 gate 기록마다 `Gate_journal.validate` 를 부른다. 부를 때마다 새 `current_reading` 을 만든다(`keeper_librarian_original_gate.ml:402`). 사슬 하나에 기록이 n 개면 discover 한 번에 복원이 n(n+1)/2 번이다. discover 는 `:449`, `:496`, `:511`, `:515`, `:565`, `:583` 에서 불린다.
- **[사실]** 배포 전 점검은 다른 길을 탄다. `validate_binding_chain`(`keeper_librarian_original_gate.ml:270-284`)도 처음 시도까지 내려가서 n(n+1)/2 번 방문하고, 방문마다 `parent_final` 을 부른다.

### 1.3 기록이 scope 를 떠나는 때

- **[사실]** gate 기록은 원본이 끝날 때 그 원본의 기록과 함께 보관소로 옮긴다(`keeper_librarian_durable_execution.ml:223-239`). 판정이 실패하는 동안의 시도는 모두 살아 있는 scope 에 남는다.
- **[사실]** `Lane_addon_tool_request_owner.settle`(`lib/lane_addon/lane_addon_tool_request_owner.mli:240-246`)은 기록을 날짜별 보관소로 옮기고 본문을 지운다.
- **[사실]** 서버가 뜰 때마다 보관소 정리(`lib/server/server_settled_archive_sweep.ml`, `bin/main_eio.ml:387`)가 돈다. 살아 있는 기록이 요청 ID 를 가리키지 않는 보관 기록은 지운다(RFC-0498 D2).
  - "가리킨다"는 progress event 의 요청 ID 와, gate 기록이면 부모 실행 ID 다(`server_settled_archive_sweep.ml:34-60`). gate 요청 본문의 `predecessor` 는 세지 않는다.

### 1.4 이미 정해 둔 것

- `RFC-librarian-absorb-gate` §2 의 6항: 판정이 실패하면 입력 범위를 남겨 재시도한다. 같은 절 끝: 입력 범위가 남아 판정 서비스 회복 뒤 다시 읽힌다.
- RFC-0484 §3.2: `typesafeai` health 칸은 아무것도 막지 않는다. `Typesafeai_client.destination_outcomes` 는 프로세스 메모리의 투영이고 호출을 정하는 데 쓰지 않는다(`lib/typesafeai/typesafeai_client.mli:119-123`).
- RFC-0489 §2.7: 같은 입력이 같은 실패를 되풀이하는 `Raised` 는 자동 재시도에서 빼고, 명시적 요청으로만 다시 만든다.
- RFC-0498 D2: 보관된 기록은 살아 있는 기록이 그 요청 ID 를 가리키지 않으면 지운다.
- `docs/design/addon-original-request-discovery.md:40-41`: "No new cache, size cap or retry loop hides that cost." `RFC-librarian-history-settles-finished-originals` 는 이 문장을 들어 결과 캐시를 고르지 않았다.
- 헌법 `magic_number`, `budget_gate`(`docs/constitution.xml:446-471`): 반복 횟수나 누적 숫자로 멈추지 않는다.
- 헌법 `failure_keeps_evidence`(`docs/constitution.xml:237-240`): 전달 실패는 증거를 남기고 대상을 소비하지 않는다.
- 헌법 `gates`(`docs/constitution.xml:502-508`): 하드 게이팅을 기본으로 고려하지 않는다.

## 2. 측정

기록 수는 11-16T01:38Z 한 시점에 셌다. 읽은 곳은 `lane-addons/tool-request-owners/` 중 `scope` 가 `keeper-librarian-durable-gate/` 로 시작하는 기록이다.

| 무엇 | 값 |
|---|---:|
| 기록 / scope | 570 / 18 |
| 사슬(처음 시도 기준) / 가장 긴 사슬 | 19 / 71 |
| 처음과 마지막 사이의 시도 | 533 |
| 거절로 끝난 기록 | 567 |
| 그중 402 / HTTP 상태 없음 | 565 / 2 |
| 판정까지 간 기록(`judgment_retained`) | 1 |
| 아직 끝나지 않은 기록 | 2 |

- **[사실]** 사슬 19개 중 하나는 길이가 1이다. 그래서 처음과 마지막 사이는 570 − 19 − 18 = 533 이다.
- **[사실]** 거절로 끝난 기록은 모두 목적지 하나(`https://api.typesafe.ai/v1/systemone`, 모델 `jev-latest`)에 물었고 거절도 하나씩이다. 402 본문은 `billing_error`, "no available TypeSafe API credits" 다.
- **[사실]** 11-16T01:16Z 무렵 기록 574개의 크기는 기록 19.7 MB, 본문 10.2 MB 였다. 시도 하나가 약 52 KB 다.
- **[사실]** Board attention 판정은 11-15T00:00Z 부터 11-16T01:34:48Z 까지 모두 `jev=failed` 였다. 01:34:48Z 부터 `jev=not_relevant`, `jev=relevant` 가 나온다. 11-15T00:00Z 앞은 보지 않았다.
- **[사실]** 01:37Z 에 geek-scout 의 사슬 하나(기록 16개)가 끝나 보관소로 옮겨졌다. 위 570개에는 들지 않는다.

pass 검증 구간 시간. 서버 로그 `durable Librarian inventory validated` 의 `gate_records`, `elapsed_ms` 다. 이 구간은 §1.2 의 첫 묶음만 잰다.

| Keeper | 시각 | gate 기록 | `elapsed_ms` |
|---|---|---:|---:|
| code-reviewer-uncle | 11-15T11:11Z | 0 | 893 |
| code-reviewer-uncle | 11-15T20:32Z | 52 | 34,276 |
| code-reviewer-uncle | 11-16T00:50Z | 70 | 74,590 |
| context-reviewer | 11-16T01:02Z | 52 | 104,737 |
| ocaml-agent-ic | 11-16T00:40Z | 65 | 73,949 |
| you-never-change | 11-16T01:13Z | 44 | 60,612 |

- **[사실]** `gate_records` 는 그 Keeper scope 의 기록 전부다. 사슬 하나의 길이와 같지 않다.
- **[사실]** 같은 52개에서 34,276 ms 와 104,737 ms 가 나왔다. 벽시계 시간이라 그때 기계가 하던 다른 일이 섞인다.
- **[추정]** uncle 은 기록이 52개에서 70개로 늘 때 시간이 2.18배 늘었다. 사슬 하나라면 n² 은 1.81배, (n+1)(n+2)/2 는 1.79배를 예측한다. 관측이 예측보다 크고, 남는 몫은 이 표로 가를 수 없다. 사슬 복원이 구간에서 차지하는 몫은 재지 않았다 **[확인 필요]**.
- **[확인 필요]** 01:34Z 뒤 사슬이 끝나 정리되면 같은 Keeper 의 `elapsed_ms` 가 돌아오는지. 이 RFC 의 PR 댓글로 붙인다.

## 3. 문제

1. **사슬을 읽는 비용이 시도 수의 제곱으로 는다.** 판정이 실패하는 동안 원본마다 깨어날 때마다 시도가 하나 는다. pass 는 사슬을 여러 번 읽고, 한 번 읽을 때마다 n(n+1)/2 번 복원한다. admission gate 는 discover 한 번에 이 읽기를 기록 수만큼 한다.
2. **살아 있는 gate scope 가 시도마다 약 52 KB 씩 커진다.** 원본이 끝나야 보관소로 옮겨진다. 402 가 이어진 동안 570개, 약 30 MB 가 쌓였다.
3. **운영자가 풀어야 하는 거절에도 깨어날 때마다 다시 묻는다.** 402 는 크레딧을 넣어야 풀린다. 그 사이의 시도는 같은 거절을 받는다.

1번은 거절 이유와 상관없이 생긴다. 서버 오류나 응답 없음이 길어져도 같다.

## 4. 후보

### 4.1 후보 A — 한 번 읽는 동안 복원한 시도를 다시 꺼내 쓴다 (권고)

**[제안]**

- A-1. `reading` 에 복원한 시도를 담는 칸을 하나 더 둔다. 요청 ID 를 키로 하는 Map 이다. `restore_record_with` 는 같은 요청 ID 를 이미 끝까지 복원했으면 그 결과를 돌려준다.
- A-2. admission gate 의 discover 가 gate 기록마다 `Gate_journal.validate` 를 따로 부르지 않는다. durable gate 처럼 `Inventory.read` 로 scope 를 한 번 읽고, 원본마다 `Inventory.validate` 를 부른다. `keeper_librarian_durable_gate.mli:121-123` 은 같은 검증 pass 안에서 한 번 읽은 것을 함께 쓰도록 허락한다.
- 결과가 지금과 같은 이유: 한 `reading` 이 살아 있는 동안 그 gate scope 에는 아무것도 쓰지 않는다. `reading` 은 호출 하나 안에서 만들고 버린다. 만드는 곳은 `current_reading`(`keeper_librarian_original_gate.ml:137`, `:402`, `:404`, `:456`, `:477`, `:501-506`, `:553`)과 `Inventory.validate`(`:596-643`)다. 그 사이에 `Owner.retain`, `advance`, `prepare_successor`, `settle` 은 돌지 않는다. 이 전제를 `reading` 타입 주석에 적는다.
- 담는 것은 끝까지 성공한 복원만이다. 오류는 담지 않으므로 처음 나는 오류가 지금과 같다. 고리 검사(`visited`)는 그대로다. 앞 시도는 하나뿐이고 담긴 시도는 처음 시도까지 이어졌으므로, 담긴 결과가 고리 위에 있을 수 없다.
- "No new cache" 문장과의 관계: 그 문장은 Known-ID 읽기의 디렉터리 비용을 캐시로 감추지 말라는 것이다. A 의 칸은 호출 하나가 끝나면 사라지고, 저장소를 읽는 횟수를 감추지 않는다. 같은 모양이 이미 둘 있다. `confirmed_parents`(`keeper_librarian_original_gate.ml:117-135`)와 배포 전 점검의 `forest_proof`(`keeper_librarian_store_preflight.ml:32-45`)다. 운영자가 이 해석을 받아들이지 않으면 그 설계 문장을 이 RFC 에서 고친다(§7 의 2).
- 결과: 사슬 하나를 읽을 때 복원이 n 번이다. `current_reading` 의 `Owner.load` 는 n(n−1) 번에서 2(n−1) 번으로 준다.
- 바뀌지 않는 것: 사슬 계약, 오류 문구, 저장 상태, 다시 묻는 때와 횟수, 목적지 호출. `recover_root`·`retain`·`resume` 처럼 고치거나 보내기 전에 새로 읽는 API 는 지금처럼 저마다 새 `reading` 을 만든다.
- 닿는 곳: `keeper_librarian_original_gate.ml`(A-1)과 `keeper_librarian_admission_owner.ml`(A-2)다. A-1 은 공용 functor 라서 세 gate 가 함께 쓴다.
- 대가: `current_reading` 은 담은 시도를 `read.records` 목록과 따로 쥔다. 살아 있는 `reading` 하나에 약 n × 52 KB 다.
- 남는 것: 배포 전 점검의 `validate_binding_chain` 은 A 가 바꾸지 않는다(§1.2). 구간 밖에서 사슬을 읽을 때마다 `load_scope` 로 gate scope 전체를 다시 읽는 비용도 그대로다. 2번과 3번 문제도 그대로다.

### 4.2 후보 B — 대체된 시도를 보관소로 옮긴다 (고르지 않음)

다음 시도의 ACK 뒤 처음과 마지막 사이의 시도를 `settle` 로 옮기는 안이다. 지금 계약과 다음처럼 부딪친다.

- 처음 시도의 progress 는 다음 시도를 `Subdivided(_, successor)` 로 가리킨다. 그 시도가 scope 에 없으면 `read_chain_with` 가 "Acknowledged original gate successor is missing" 으로 거절한다(`keeper_librarian_original_gate.ml:427-434`). `validate_payload` 도 거절한다(`:296-306`).
- 처음 시도의 `Successor_intended` 는 다음 시도의 본문을 digest 로 가리킨다. `settle` 은 본문을 지운다. `settle` 의 계약은 "다른 기록이 그 본문을 가리키지 않는 것만" 옮긴다고 적는다(`lane_addon_tool_request_owner.mli:244-245`).
- 앞 시도가 scope 에 없으면 `read_chain_with` 는 "Original gate predecessor is outside its execution inventory" 로 거절한다(`:447-449`). `restore_record_with` 도 앞 시도를 scope 에서 불러야 한다(`:356-366`).
- 마지막 시도는 "아무도 가리키지 않는 기록"으로 찾는다(`:451-453`, `:472-475`). 중간이 빠지면 처음 시도도 아무도 가리키지 않게 된다.
- 배포 전 점검(`lib/keeper/keeper_librarian_store_preflight.ml:92-98`)은 `validate_binding_chain` 으로 앞 시도를 scope 에서 읽는다(`keeper_librarian_original_gate.ml:278-279`).
- 서버가 뜰 때 보관소 정리는 `predecessor` 를 세지 않는다(§1.3). 옮긴 중간 시도는 처음 시도가 가리키는 하나를 빼고 다음 기동에 지워진다.

B 를 하려면 공용 사슬 계약과 RFC-0498 D2 를 함께 바꿔야 한다. 얻는 것은 2번 문제(저장 크기)와, 구간 밖 `load_scope` 가 읽는 양이다. 1번의 제곱 비용은 A 가 계약 변경 없이 푼다.

### 4.3 후보 C — 402·401·403 뒤에는 자동으로 다시 묻지 않는다 (고르지 않음)

끝난 시도 자신의 기록에서 거절 종류(`refusal_class`, `lib/typesafeai/typesafeai_client.mli:93-104`)를 읽어 다음 시도를 만들지 않는 안이다.

- **[사실]** 01:34Z 의 회복은 운영자가 TypeSafe 콘솔에서 크레딧을 넣은 결과다(운영자 확인). 통과한 시도의 목적지와 모델은 실패한 시도와 같다.
- **[추정]** 운영자가 masc 설정은 건드리지 않았다. 기록에는 키가 없어서(`destination_id` 는 `destination_uri` 와 `model` 만 담는다, `typesafeai_client.mli:24-31`) 키가 그대로였는지는 기록으로 확인할 수 없다.
- 그래서 "목적지 묶음이 바뀌면 다시 묻는다"는 조건은 이 회복을 보지 못한다. C 를 쓰면 크레딧을 넣은 뒤 운영자가 masc 에서 따로 다시 묻게 해야 한다. 지금은 그 조치 없이 다음 깨어남에 회복된다.
- C 를 고르지 않는 근거:
  - 헌법 `gates` 는 하드 게이팅을 기본으로 두지 않는다.
  - `~/me/AGENTS.md` 의 masc 작업 절은 "`Interrupted`, `Ambiguous`, acknowledgement, dependency 같은 과거 evidence를 scheduling Gate로 쓰지 않는다"고 적는다. 헌법에는 같은 문장이 없다.
- C 쪽 선례도 있다.
  - RFC-0489 §2.7 은 같은 입력이 같은 실패를 되풀이하는 `Raised` 를 자동 재시도에서 빼고, 명시적 요청으로만 다시 만든다.
  - exact lane 은 쉬는 시각을 밝히지 않은 계정 거절을 `Configuration_refused` 로 끝낸다(`lib/server/exact_lane_failure.ml:30-37`).
  - Task 검증은 `Producer_must_act` 에 자동 재시도를 걸지 않는다(`lib/task/anti_rationalization.ml:576-579`).
- 이 선례들과 흡수 관문이 다른 점: 앞의 셋은 한 번 실행하는 비용이 크다. 흡수 관문의 다시 묻기는 거절을 바로 받는 HTTP 호출 하나와 기록 하나다. 그 기록이 쌓여 느려지는 몫은 A 가 줄인다.

### 4.4 그 밖에 고르지 않은 것

| 길 | 고르지 않는 이유 |
|---|---|
| 시도 횟수 상한, backoff, cooldown | `magic_number`, `budget_gate`. RFC-0489 §3 도 Goal 검증에 넣지 않았다. |
| health 투영(`destination_outcomes`)으로 다시 묻기를 막기 | RFC-0484 §3.2. 프로세스 메모리라 재시작하면 빈다. |
| 기록 하나 안에서 다시 보내기 | 기록 하나는 요청 ID 하나다. "The refusal itself remains terminal; neither fact permits redispatch"(`lib/lane_addon/lane_addon_request_progress.mli:78-79`). |
| 오래된 시도를 지우기 | `failure_keeps_evidence`. |
| pass 의 여러 사슬 읽기를 `reading` 하나로 합치기 | 고치거나 보내기 전에는 새로 읽는다는 계약(`keeper_librarian_durable_gate.mli:121-123`)을 바꾼다. A 가 들어가면 읽기 한 번의 비용이 사슬 길이에 비례하므로, 남는 비용은 읽는 횟수에 비례한다. |
| 파일 stat·digest 를 키로 하는 호출 사이 결과 캐시 | "No new cache" 문장과 부딪친다. `RFC-librarian-history-settles-finished-originals` 가 같은 이유로 고르지 않았다. |

## 5. 기대 효과 (계산)

사슬 하나를 한 번 읽을 때의 복원 수와, `elapsed_ms` 구간의 `Inventory.validate` 한 번의 복원 수다.

| 사슬 길이 n | 읽기 한 번: 지금 n(n+1)/2 | 읽기 한 번: A | `Inventory.validate`: 지금 (n+1)(n+2)/2 | `Inventory.validate`: A |
|---:|---:|---:|---:|---:|
| 1 | 1 | 1 | 3 | 1 |
| 19 | 190 | 19 | 210 | 19 |
| 52 | 1,378 | 52 | 1,431 | 52 |
| 71 | 2,556 | 71 | 2,628 | 71 |

- **[추정]** `elapsed_ms` 구간에서 사슬 복원 몫이 같은 비율로 준다. 이 구간의 `load` 는 메모리 조회라서 디스크 읽기는 바뀌지 않는다.
- **[추정]** 구간 밖에서는 복원 몫과 함께 `Owner.load` 가 n(n−1) 번에서 2(n−1) 번으로 준다. `load_scope` 몫은 그대로다.
- admission gate 의 discover 는 A-2 로 기록 수만큼의 사슬 읽기가 원본마다 한 번으로 준다.

## 6. 검증

구현할 때 쓸 시험이다. 숫자 문턱을 검사하지 않는다.

- 같은 결과(공개 API): `retain` 으로 길이 1, 2, 8 사슬을 만든다. `validate_chain`, `root`, `latest`, `restore_latest_result`, `Inventory.validate` 가 지금과 같은 값을 돌려주는지 본다.
- 같은 오류(공개 API): 앞 시도가 없는 사슬, 다른 제안으로 이어진 사슬, 끝나지 않은 앞 시도에 붙은 사슬을 만든다. 같은 함수들이 지금과 같은 오류 문구로 실패하는지 본다. 지금 이 오류 문구를 확인하는 시험은 배포 전 점검 쪽 둘(`test/test_deployment_store_directories.ml:1149-1167`)뿐이라 새로 쓴다.
- 쓰기를 건너지 않음: `advance` 로 시도 하나의 progress 를 바꾼 뒤 부른 API 가 바뀐 progress 를 본다. 칸이 호출 사이에 남지 않는다는 뜻이다.
- admission discover: 같은 사슬에서 A-2 전과 뒤의 discover 결과가 같다.
- 복원 수는 시험으로 세지 않는다. `reading` 과 `restore_record_with` 는 `.mli` 에 없고, 세려고 시험용 진입점을 새로 열지 않는다. 효과는 운영 측정으로 본다.
- 운영 측정: 배포 앞뒤로 같은 로그 줄의 `gate_records`, `elapsed_ms` 를 비교한다.

## 7. 정할 것

1. 후보 A(A-1, A-2)를 구현할지. 이 RFC 는 구현을 권고한다.
2. A 가 "No new cache" 문장과 부딪치지 않는다는 §4.1 의 해석을 받아들일지. 받아들이지 않으면 그 설계 문장을 고친다.
3. 긴 거절 동안 살아 있는 gate scope 가 시도마다 약 52 KB 씩 커지는 것을 그대로 둘지. 줄이려면 B 를 공용 사슬 계약과 RFC-0498 D2 변경까지 포함해 다시 설계해야 한다.
4. C 를 다시 열지. 크레딧을 넣은 뒤 masc 에서 한 번 더 조치하는 것을 받아들일 때만 뜻이 있다.

## 8. 관련

- `RFC-librarian-absorb-gate` §2: 실패 뒤 재시도와 회복 뒤 다시 읽기.
- `RFC-librarian-history-settles-finished-originals`: 끝난 원본을 보관소로 옮기는 일, 결과 캐시를 고르지 않은 이유.
- `docs/design/addon-original-request-discovery.md`: "No new cache" 문장.
- RFC-0484 §3.2: `typesafeai` health 칸.
- RFC-0489 §2.7, §3: 새 시도를 만드는 때와 상한을 두지 않는 이유.
- RFC-0498: 보관소에서 살아 있는 기록이 가리키지 않는 것을 지우는 규칙.
- 이슈: #51655(pass 의 본문 재검증 비용), #52304(TypeSafe 402, 닫힘), #51281.
