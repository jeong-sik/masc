---
rfc: "librarian-history-settles-finished-originals"
title: "끝난 Librarian history original 은 scope 밖으로 옮기고, gate 요청은 원본을 digest 로 가리킨다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
related: ["workspace-curator-originals-name-ledger-revisions", "librarian-absorb-gate", "librarian-lifecycle"]
---

# 끝난 Librarian history original 은 scope 밖으로 옮기고, gate 요청은 원본을 digest 로 가리킨다

## 1. 문제

completed-history Librarian 은 `consume_one` 을 돌 때마다 그 Keeper 의 history original 을 전부 다시 읽고 검증한다. 이미 끝난 original 도 마찬가지다. 끝난 original 을 목록에서 빼는 일이 없어서, 한 번 도는 비용이 그때까지 쌓인 original 수를 따라 커진다.

조사와 측정은 [연구 문서](../research/2026-10-26-librarian-history-validation-cost-r1.md)와 [실측 기록](../evidence/research/2026-10-26-librarian-history-validation-cost-r1.md)에 있다. 요점은 이렇다.

- 2026-10-26 22:16 KST 에 기동한 서버(`6a2d8dd6171`)가 1시간 넘게 약 6코어를 썼다. memprof 로 본 할당의 63%가 `Lane_addon_*`·`Keeper_librarian_*` 경로였다.
- 11시간 동안 history original 355개(기록 1,400 MB, 본문 1,376 MB)와 durable gate 기록 349개(본문 1,345 MB)가 쌓였다.
- 같은 요청 본문이 세 군데에 있다. history 본문, gate 본문의 `capture`, history 기록의 `preparation_intended` 이벤트다. Keeper 별 합계가 세 곳 모두 같았다(161 / 161 / 161 MB 등).
- 코드 경로로 센 하한 추정으로, main 은 모든 Keeper 를 한 번씩 도는 데 CPU 약 1,237초, #46143 은 약 72초가 든다.

#46143 은 pass 하나에서 gate scope 를 한 번만 읽게 한다. 그래도 pass 는 그때까지 쌓인 original 과 gate 기록을 전부 읽는다.

## 2. 지금 있는 것

- 설계 문서는 비용을 숨기지 말라고 정한다. `docs/design/addon-original-request-discovery.md` 는 "No new cache, size cap or retry loop hides that cost." 라고 적었다.
- 같은 문서에 `settle` 이 있다. `Lane_addon_tool_request_owner.settle` 은 original 의 기록과 본문을 `tool-request-owners-settled/<scope digest>/<날짜>/` 로 옮긴다(`lane_addon_tool_request_owner.ml` 의 `settle`). 옮긴 기록은 discovery 도, known-ID load 도, 배포 전 저장소 검사도 읽지 않는다. 문서는 "The caller settles only originals no pass needs again and whose body no other record names." 라고 정한다.
- Workspace Curator 가 이 장치를 쓴다(`server_workspace_memory_addon.ml` 의 `settle_chain_with`, `finish_settling`). 체인을 잎부터 옮기고, 끊긴 이동은 다음 discovery 가 마저 끝낸다. 날짜는 체인 root ID 가 만들어진 UTC 날짜다.
- Librarian 은 `settle` 을 부르지 않는다. 호출자는 Curator 하나다.
- `consume_one`(`keeper_librarian_durable_execution.ml`)은 이렇게 돈다.
  1. `Owner.discover` 가 history original 과 본문을 모두 읽는다.
  2. original 마다 `Keeper_librarian_durable_commit.validate` 가 `Unfinished` 나 `Settled` 를 낸다.
  3. `validate_lineage` 가 대체(replacement) 관계를 확인한다. 자식은 부모를 목록에서 찾는다. 부모의 확정된 replacement 는 자식이 목록에 있어야 한다. 대체가 필요한 Conflicted original 을 돌려준다.
  4. 남은 할 일로 다음 작업을 고른다.
- `Settled` original 이 pass 에 쓰이는 곳은 `validate_lineage` 뿐이다. 대체 관계의 부모로 쓰인다.
- gate 기록은 Keeper 마다 gate scope 하나에 모인다(`keeper_librarian_durable_gate.ml` 의 `gate_scope`). `read_chain` 과 #46143 의 `Inventory.read` 는 다른 execution 의 gate 기록까지 header 와 owner 를 검사한다. 그래서 끝난 original 의 gate 기록도 매 pass 읽힌다.
- gate 요청(`keeper_librarian_original_gate.ml` 의 `gate_request`)은 `execution_id`, `execution_digest` 와 함께 `capture` 를 담는다. `capture` 는 부모 history 요청 전체다. `execution_digest` 는 부모 기록의 `request_digest` 라서 같은 본문을 이미 가리킨다.
- `capture` 필드를 읽는 곳은 같은지 비교뿐이다. gate 평가(`Keeper_librarian_absorb_gate.continue_captured`)는 history 기록에서 복원한 요청으로 입력을 계산한다. worker 에 보내는 인자에도 들어가지 않는다.
- history 기록의 `preparation_intended` 는 gate 요청 전체를 담는다. 그래서 `capture` 가 기록 안에 또 들어간다.

## 3. 결정

### 3.1 끝난 history original 과 그 gate 기록을 옮긴다

`consume_one` 은 `validate_lineage` 뒤, 다음 작업을 고르기 전에 옮길 수 있는 original 을 `settle` 한다.

옮길 수 있는 단위는 대체 체인 하나다.

- 체인의 잎 L 은 이번 pass 에서 `Settled` 이고, Conflicted 가 아니다. Finished 이거나 실행 단계의 종단 거절이다.
- L 의 조상은 모두 Conflicted 이고, 확정된 replacement 가 바로 아래 original 을 가리킨다. `validate_lineage` 가 이미 이 관계를 확인했다.
- 체인의 어느 original 도 대체가 필요한 목록이나 replacement 게시 대기(`Preparation_pending`)에 있지 않다.

체인은 잎부터 옮긴다. original 하나는 history 기록을 먼저 옮기고, 그 execution 의 gate 기록을 뒤에 옮긴다. 순서는 `settle` 이 정한 대로 기록이 먼저, 본문이 나중이다.

날짜는 Curator 와 같이 체인 root 의 history 요청 ID 가 만들어진 UTC 날짜다(ID 마지막 칸의 uuid v7). 체인의 history 기록과 gate 기록이 모두 이 날짜 아래로 가서, 체인 하나가 보관 위치의 한 날짜 안에 모인다.

본문은 자기 요청 ID 를 담는다(history 요청과 gate 요청 모두 `request_id` 필드). 그래서 옮기는 본문을 다른 기록이 가리키지 않는다.

옮겨도 되는 까닭은 이렇다.

- Finished 는 읽기 위치 정리(`settle_positions`)가 끝난 뒤에만 기록된다(`Commit_observed`). 끝난 original 이 없어도 같은 범위를 다시 읽지 않는다.
- 실행 단계 거절은 읽기 위치를 건드리지 않는다. 다음 pass 가 같은 범위를 새 original 로 다시 잡는다. 거절 보고에는 지난 original 에서 가져오는 근거가 없다(`refusal_report`).
- wake discovery(`server_librarian_addon_wake.ml`)는 scope 를 읽을 때 같은 scope 잠금을 쓴다. 옮긴 original 에 결과 알림(`Exact_result_delivered`)이 늦게 오면 "no original owner" 경고 한 줄로 끝난다. 끝난 original 은 깨울 필요가 없다.

옮긴 original 은 다음 pass 의 discovery 에 나오지 않는다. 그 gate 기록도 gate scope 에 없다. 그래서 pass 비용은 끝나지 않은 original 수를 따른다.

### 3.2 끊긴 이동은 다음 pass 가 마저 끝낸다

이동은 여러 파일을 하나씩 옮긴다. 그 사이에 프로세스가 멈출 수 있다. 다음 pass 는 검증 전에 두 가지를 본다.

- **체인 중간에서 멈춘 경우.** discovery 에 나온 original 의 확정된 replacement 자식이 목록에 없고, 그 자식이 체인 root 날짜 아래 보관 위치에 있으면(`Owner.settled`), 자식이 남긴 gate 기록을 먼저 옮기고 이 original 과 그 조상을 이어서 옮긴다. 잎부터 옮기므로 root 는 아직 목록에 있고, 날짜는 root 에서 구한다. 이 original 과 조상은 앞 pass 에서 이미 옮겨도 된다고 판정된 체인이다. 자식이 보관 위치에도 없으면 지금처럼 `validate_lineage` 가 거절한다.
- **root 의 history 기록만 옮기고 gate 기록을 못 옮긴 경우.** gate scope 의 기록 중 execution 이 discovery 에 없고, 그 execution 의 history 기록이 자기 ID 날짜 아래 보관 위치에 있으면 그 gate 기록을 옮긴다. root 가 아닌 original 에서 멈췄다면 부모가 목록에 남아 앞의 경우가 먼저 처리한다. 그래서 여기 남는 gate 기록의 execution 은 체인 root 이고, 자기 날짜가 곧 체인 날짜다. 이런 gate 기록은 검증 결과를 바꾸지 않는다. `read_chain` 은 header 만 보고 execution 이 다르면 넘어가고, `Inventory` 는 execution 별로 고른다. original 이 하나도 없는 pass 는 gate scope 를 읽지 않으므로, 다음 original 이 생긴 pass 가 옮긴다.

execution 이 discovery 에도 보관 위치에도 없는 gate 기록은 지금과 같이 둔다. 이 RFC 는 그런 기록을 옮기거나 지우지 않는다.

기록은 옮겼는데 그 본문을 옮기기 전에 멈추면, 본문이 scope 옆에 남는다. 보관 위치로 간 기록은 discovery 에 나오지 않으므로 다시 `settle` 하지 않는다. 그 본문을 가리키는 기록도, 읽는 곳도 없어서 검증 결과는 바뀌지 않는다(Q4).

### 3.3 이동이 실패하면 그 pass 는 멈춘다

`settle` 이나 `settled` 가 오류를 내면 `consume_one` 은 `Original_publication_blocked` 로 끝난다. 다음 작업을 고르지 않는다. 다음 pass 가 3.2 를 거쳐 다시 시도한다.

계속 진행할 수도 있다. 옮기지 못한 original 은 목록에 남고 여전히 올바르기 때문이다. 하지만 체인 중간에서 멈춘 채 다음 pass 의 마무리까지 실패하면 `validate_lineage` 가 거절한다. 실패를 그 자리에서 드러내는 쪽을 고른다. 6장 Q1 에 남긴다.

### 3.4 gate 요청은 `capture` 를 담지 않는다

- `gate_request` 에서 `capture` 필드를 뺀다. 부모 요청은 `execution_id` 와 `execution_digest` 가 가리킨다.
- gate 요청의 `version` 을 2로 올린다. 필드 집합을 확인하는 7곳(`parent_execution_id`, `validate_successor_request`, `restore_record`, `read_chain`, `root_preparation`, `Inventory.read` 등)에서 `capture` 를 뺀다.
- 부모 기록 본문과 메모리의 capture 를 맞춰 보는 비교(`load_parent`, `root_preparation`, `Inventory.validate` 의 `equal parent.request (Capture.to_json capture)`)는 그대로 둔다. gate 요청 필드와 상관없이, 복원한 capture 가 그 부모의 본문인지 확인하는 비교다.
- history 기록의 `preparation_intended` 는 gate 요청을 담으므로 함께 작아진다. 진행 기록 타입(`Lane_addon_request_progress`)은 바꾸지 않는다.
- 대체 체인에서 부모의 `Replacement_intended` 가 자식 history 요청 전체를 담는 사본은 남는다. 끊긴 게시를 복구할 때 그 요청으로 같은 자식을 다시 만들기 때문이다.
- reader 는 필드 검사보다 먼저 `version` 을 본다. 다른 버전이면 "Original gate request is not version 2" 로 거절해서, 3.5 단계를 빠뜨렸을 때 로그가 원인을 가리킨다.
- admission gate(`keeper_librarian_admission_gate.ml`)도 같은 functor 를 쓴다. 같이 바뀐다.

라이브 기록 하나에서 `capture` 를 64자 문자열로 바꿔 쟀더니 history 기록이 3,370,525 바이트에서 5,604 바이트가 됐고, 파싱이 23.6 ms 에서 0.043 ms 가 됐다(실측 기록 5절).

### 3.5 하드컷

gate 요청 모양이 바뀐다. 옛 기록을 읽는 코드는 만들지 않는다. 옛 gate 기록은 필드 검사에서 거절되고, 옛 gate 요청을 담은 history 기록의 `preparation_intended` 는 새 `gate_request` 와 같지 않아 거절된다.

3.1 이 먼저 배포돼 끝난 체인과 그 gate 기록이 보관 위치로 옮겨진 뒤에 배포한다. 그러면 옮길 것은 끝나지 않은 history original 과 admission original 뿐이다.

배포 전에 서버를 멈추고, 아래를 `lane-addons/` 밖으로 옮긴다. scope 디렉터리 이름은 scope 문자열의 sha256 이다(`lane_addon_store.ml` 의 `tool_request_owner_path`).

- `tool-request-owners/` 와 `tool-request-bodies/` 의 `keeper-librarian-history-execution-*`, `keeper-librarian-durable-gate/*` scope
- 같은 두 곳의 `keeper-librarian-execution-*`, `keeper-librarian-admission-gate/*`, `keeper-librarian-parts/*`, `keeper-librarian-partitions/*` scope. admission 의 parts 와 partitions 는 admission 실행 기록을 ID 로 가리켜서, 실행 기록만 옮기면 모든 admission discovery 가 "Original parent execution is missing" 으로 멈춘다(`keeper_librarian_admission_parts.ml` 의 `original_capture`). 네 scope 를 함께 옮기면, 다음 admission pass 가 Memory receipt 로 commit 된 후보를 먼저 ACK 하고 남은 후보로 새 root 를 만든다.

보관 위치(`tool-request-owners-settled/`)는 옮기지 않는다. pass 도, 배포 전 저장소 검사도 읽지 않는다.

옮기기 전에, 위 scope 에 `Committing` 이나 `Commit_unknown` 인 original 이 있으면 그 original 이 끝나기를 기다린다. Memory commit 이 적용됐는데 원본만 없어지면, 다음 pass 가 같은 범위를 다시 읽어 같은 사실을 또 제안할 수 있다. 그 밖의 original 은 옮겨도 된다. 아직 commit 하지 않은 범위는 읽기 위치가 나아가지 않았으므로 새 original 로 다시 잡힌다.

### 3.6 관측

pass 마다 `durable Librarian inventory validated: originals=… unfinished=… gate_records=… elapsed_ms=…` 를 남긴다(#46143 위 관측 PR). 3.1 이 들어가면 `originals` 와 `gate_records` 가 끝나지 않은 일 수 근처에 머물러야 한다.

옮긴 pass 는 `durable Librarian settled finished history: chain_records=… orphan_gates=…` 를, 끊긴 이동을 마저 끝낸 pass 는 `durable Librarian finished an interrupted settle: records=…` 를 남긴다.

## 4. 다른 방법과 비교

| 방법 | pass 비용 | 좋은 점 | 나쁜 점 |
|---|---|---|---|
| 지금 + #46143 | 쌓인 original 수 × 요청 크기 | 고칠 곳이 없다 | 기록이 쌓일수록 커진다 |
| 파일 stat 이나 digest 로 결과 캐시 | stat 수 + 바뀐 것만 | 저장 형식이 그대로다 | 설계 문서의 "No new cache" 와 부딪친다. 디렉터리 신원·권한, scope 에 새로 생긴 gate 기록, 일시 오류 같은 입력을 키에 빠짐없이 넣어야 한다. 빠뜨리면 틀린 결과를 재사용한다 |
| pass 당 검증 개수 상한, 오래된 기록 건너뛰기 | 상한까지 | 바로 줄어든다 | 헌법 `budget_gate`, `no_wall_clock_death` 와 설계 문서의 "size cap" 금지에 걸린다. 깨진 기록을 못 볼 수 있다 |
| 끝난 original 지우기 | 끝나지 않은 수 | 디스크도 준다 | 증거가 사라진다. 지우는 규칙과 참조 세기가 따로 필요하다 |
| 이 RFC: `settle` + digest 참조 | 끝나지 않은 수 × 작은 기록 | 이미 있는 장치를 쓴다. 증거는 보관 위치에 남는다 | 이동이 여러 파일이라 끊긴 이동을 마무리하는 코드가 필요하다. 저장 형식이 바뀌어 하드컷이 한 번 필요하다 |

## 5. 나눠 올리는 순서

#46143 은 무관한 #46139 위에 쌓여 있어서, 같은 코드를 main 위로 옮긴 #46242 위에 올린다(스택 #46245).

1. #46242: pass 하나가 gate scope 를 한 번 읽는다(#46143 과 같은 코드).
2. #46243: 3.6 의 관측 로그.
3. #46244 — 3.1–3.3: 끝난 체인을 옮기고, 끊긴 이동을 마무리한다. `settle` 은 discovery 의 `Record.t` 만 받으므로, retained 값에서 `Record.t` 를 꺼내는 `Lane_addon_tool_request_owner.listed` 를 mli 에 연다.
4. #46247 — 3.4·3.5: gate 요청에서 `capture` 를 뺀다. 스택 #46245 와 따로 둔다. 둘을 함께 배포하면 옛 gate 기록이 남은 scope 를 `Inventory.read` 가 settle 전에 거절해서, 끝난 기록이 옮겨지지 않은 Keeper 가 모두 멈춘다. #46244 가 배포되고 끝난 기록이 옮겨진 뒤에 배포한다.
5. 남은 비용에 대한 상수배 개선. #46243 로그로 끝나지 않은 original 하나의 pass 비용을 잰 뒤 연구 문서 4.3 에서 고른다. 그 경로의 두 번째 전체 읽기는 #46175 가 다룬다.

## 6. 정할 것

- **Q1. 이동 실패 때 멈출지.** 권고: 멈춘다(3.3). 끝나지 않은 일은 그대로 남고, 오류는 기존 "durable Librarian range not consumed" 경고로 보인다.
- **Q2. admission original.** `keeper-librarian-execution-*` scope 의 explicit admission original(`Keeper_librarian_admission_capture`)도 같은 방식으로 쌓인다(11시간에 45개, 기록 91 MB, 본문 92 MB). 이 RFC 는 3.4 의 형식만 같이 바꾸고, 옮기는 일은 다루지 않는다. 권고: 관측으로 비용을 본 뒤 따로 정한다.
- **Q3. 보관 위치 정리.** 보관 위치는 계속 커진다. 권고: 이 RFC 에서는 지우지 않는다. Curator 보관 위치를 정리하는 규칙과 같이 정한다.
- **Q4. 이동이 남긴 본문.** 기록만 옮기고 멈추면 본문이 scope 옆에 남는다(3.2). 중단된 retain 이 남기는 본문과 같고, 이런 본문을 치우는 곳이 없다는 문제는 이슈 #45320 이 추적한다. 이 RFC 는 따로 다루지 않는다.

## 7. 검증

모델 없이 테스트하는 것:

- Finished original 하나가 끝까지 돈 뒤, 다음 pass 에서 그 history 기록·본문과 gate 기록·본문이 보관 위치로 옮겨지고, 다음 discovery 와 gate scope 에 나오지 않는다.
- 대체 체인(Conflicted 부모 → Finished 자식)은 잎부터 옮겨진다. 자식만 옮기고 멈춘 상태에서 다음 pass 가 부모를 마저 옮기고, `validate_lineage` 가 거절하지 않는다.
- root 의 history 기록만 옮기고 멈춘 상태에서, original 이 없는 pass 는 gate 기록을 그대로 두고 다음 original 의 pass 가 옮긴다.
- 끝나지 않은 original, 대체가 필요한 Conflicted original, replacement 게시 대기인 original 은 옮기지 않는다.
- 옮긴 뒤에도 Memory 읽기 위치와 receipt 는 그대로다. 같은 범위로 새 original 을 만들지 않는다.
- gate 요청과 `preparation_intended` 에 `capture` 가 없다. 검증·복구·재시도가 지금과 같은 결론을 낸다.

라이브에서 재는 것(1장 값과 비교):

- 3.6 로그의 `originals`, `gate_records`, `elapsed_ms`
- 누적 CPU 시간 차이, memprof 에서 `Lane_addon_*`·`Keeper_librarian_*` 비중
- `lane-addons/` 의 scope 별 기록 수와 바이트

## 8. 다루지 않는 것

- 보관 위치를 지우는 규칙(Q3)
- admission original 이동(Q2)
- 본문 외 사본(실행 기록 입력·출력)의 크기
- Curator 쪽 저장 형식
