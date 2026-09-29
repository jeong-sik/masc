---
rfc: "memory-os-recall-selection"
title: "Memory OS Recall: bounded, task-linked projection with explicit omission"
status: Draft
created: 2026-09-29
author: rondo
related: ["#36687", "#25052", "RFC-memory-os-bounded-context-and-librarian-curator"]
---

# RFC: Memory OS Recall의 선택과 실패 표기

## §1 상태와 결정 범위

현재 `Keeper_memory_os_recall.render_if_enabled`는 ordinary current snapshot의 모든 fact와 재검증된 source-bound fact를 매 턴 렌더한다(`lib/keeper/keeper_memory_os_recall.ml:95`). `lib/keeper/keeper_memory_os_recall.mli:6`은 절단·순위·부분 주입을 명시적으로 금지한다. source snapshot이 없으면 ordinary store가 비어 있거나 읽기에 실패할 때 모델은 Recall 블록을 받지 않는다(`lib/keeper/keeper_memory_os_recall.ml:47-58`). source snapshot이 있으면 ordinary 읽기 실패를 운영자 로그·계측에 남기고 ordinary fact만 비운 뒤, 검증된 source fact와 invalidation 행으로 source-only 블록을 만들 수 있다(`lib/keeper/keeper_memory_os_recall.ml:72-129`). source store 읽기 실패는 ordinary recall로 내려간다(`lib/keeper/keeper_memory_os_recall.ml:65`).

```text
source snapshot absent + ordinary empty/read error -> recall block absent (read error: operator warning)
source snapshot present + ordinary read error      -> source-only block if source rows exist + operator warning
source store read error                            -> ordinary recall only + operator warning
```

이 RFC는 이 **전송 계약**을 바꾸는 제안이다. 저장된 기억의 삭제나 Librarian의 기억 채택 결정을 바꾸지 않는다.

#36687의 2026-09-15 사례는 `extra_system_context` 전체 237,034 B를 재었다. 2026-09-29에 보고된 같은 UTC 시간대(01:25–05:49Z) 세 Keeper의 조립된 Recall 블록 중앙값은 리더 421,248 B, indie-geek-blue 65,725 B, lane-smith 69,012 B다(Board `p-1ffceadb741b8d2c7eb1cbe716009e77`, indie-geek-blue의 TurnRecord 측정). 이는 조립 바이트이며 공급자 전송 토큰이나 캐시 비용을 뜻하지 않는다. 이 RFC의 수치 목표를 정할 때 같은 입력의 전후 측정이 필요하다.

기존 Draft `RFC-memory-os-bounded-context-and-librarian-curator.md` §3.7은 fact 예산을 저장 **커밋 시점**에만 적용하고 주입 시점 선택을 금지한다. 이 제안은 그 조항과 양립하지 않는다. 이미 쌓인 현재 사실을 매 턴 모두 싣는 비용이 확인됐으므로, 그 RFC의 보존·journal 원칙은 유지하고 §3.7과 §6의 “입력 연관 recall은 future scope” 문장은 이 RFC가 채택될 때 명시적으로 개정해야 한다. 두 Draft를 동시에 현행 계약으로 읽지 않는다.

## §2 목표와 불변식

1. 저장소는 모든 current fact를 보존한다. 전송에서 빠진 fact는 삭제·철회·부정으로 해석하지 않는다.
2. 작은 상시 블록에는 Keeper 정체성, 지속 선호, 권한 경계, 현재 Task/Goal 주소만 들어간다. `category=constraint` 같은 넓은 분류만으로 상시 승격하지 않는다. 상시 여부는 별도 typed `Standing` 연결로 확정한다.
3. 이번 턴의 Task/Goal/자극과 **typed 링크가 있는** 유효 fact만 본문 후보가 된다. 연결이 없는 fact에 최신순·문자열 유사도·강화 카운터 점수를 임의 적용하지 않는다.
4. 조건부 fact는 사실 본문과 함께 typed 유효 조건을 가진다. 예를 들어 `Until_pr_merged (owner, repo, number)`, `Until_hold_released (hold_id)`, `Until_task_terminal (task_id)`다. 조건의 모든 의존 사건이 확인됐을 때만 만료한다. 상태를 읽지 못했으면 “유효”나 “만료”로 추정하지 않고 `Validity_unknown`으로 보류한다.
5. source-bound fact는 후보 선택 전에 기존의 정확한 소스 바이트 재검증을 거친다. 변경·불독가·검증 미완료를 ordinary fact와 합쳐 보이지 않게 하지 않는다. 검증되지 않은 claim 본문은 전송하지 않는다.
6. 빈 저장소, 읽기 실패, 선택 실패, 예산 초과는 서로 다른 typed 결과다. 모델과 운영자가 그 차이를 볼 수 있어야 한다. 선택 실패나 예산 초과가 성공한 일부 fact 주입으로 둔갑하지 않는다.
7. 같은 저장 revision, 소스 검증 결과, Task/Goal/자극 ID와 정책 버전이면 같은 전송 결과가 나온다. 시계나 확률은 선택 순서의 입력이 아니다.

## §3 입력과 선택 계약

`Recall.select`는 effect 없는 함수로 둔다. 입력은 (a) ordinary·source current snapshot과 revision, (b) source 재검증 결과, (c) 이번 턴의 typed `task_id`, `goal_id`, `stimulus_id` 집합, (d) 사건 상태 영수증, (e) 전송 가능한 바이트 용량과 정책 버전이다. Task/Goal이 읽히지 않으면 그 축은 `Unknown_context`이며 “링크 없음”으로 취급하지 않는다. 소스·사건·용량 읽기는 함수 바깥에서 끝낸다.

선택 순서는 `Standing` → 현재 Task 링크 → 현재 Goal 링크 → 현재 자극 링크다. 중복 fact는 memory identity로 한 번만 싣고 동일 우선순위에서는 ID로 안정 정렬한다. `Expired` fact와 검증 실패 source-bound claim은 본문 후보에서 제외한다. `Validity_unknown`은 본문 대신 ID와 보류 이유만 표시한다. 연결이 없는 current fact는 검색 가능한 주소로 남는다.

현재 Task/Goal/자극에 연결된 `Expired` fact는 본문 대신 짧은 typed 만료 표식을 모델에 보낸다: memory ID, 연결된 규칙·사건 키, `Expired` 판정, terminal 사건 영수증의 조회 주소다. 표식은 검증된 사건 영수증에서만 만들고, 원래 fact 본문이나 기밀 경로를 복원하지 않는다. 영수증이 없거나 불독가면 만료로 단정하지 않고 `Validity_unknown`으로 보류한다. 표식도 위 선택 순서의 원자적 항목으로 용량에 넣으며, 필요한 표식이 넘치면 조용히 버리지 않고 `Budget_overrun`과 대상 ID를 남긴다. 따라서 만료를 확인한 경우와 근거가 처음부터 없는 경우가 모델 입력에서 구별된다.

용량은 구성된 provider 요청의 남은 입력 예산에서 산출하며 상한값 자체는 동일 입력 실측 후 설정한다. 필수 상시 본문이나 한 우선순위의 원자적 묶음이 용량을 넘으면 그 묶음의 일부를 조용히 싣지 않는다. `Budget_overrun`을 반환하고 대상 ID·필요 바이트·가용 바이트를 운영자 영수증에 남긴다. 모델에는 작은 고정형 상태 머리줄과 조회 도구 주소를 전달한다. 긴 제외 목록은 프롬프트에 모두 쓰지 않고 별도 결정 영수증에 보존한다. 주소 목록도 예산을 넘으면 첫 페이지와 다음 페이지 토큰만 보인다. 주소를 눌러 원문을 읽을 때는 기존 `keeper_memory_search`/읽기 권한과 source 재검증을 다시 적용한다.

제안 결과 타입은 다음처럼 닫는다.

```text
Selected { body; included_ids; omitted_count; issues; receipt_id }
Empty_store
Unavailable { issues; receipt_id }
Budget_overrun { required_bytes; available_bytes; issues; receipt_id }

issues = Ordinary_read_failed
       | Source_revalidation_failed of source_ids
       | Unknown_context of { task: bool; goal: bool }
       | Selection_failed of reason
       | Validity_unknown of memory_ids
```

독립적으로 읽고 검증한 fact는 다른 축이 실패해도 살린다. ordinary 읽기 실패·source 재검증 실패·Task/Goal 조회 실패가 함께 일어나면 `issues`에 **모두** 기록한다. 안전하게 보낼 본문이 있으면 `Selected`에 그 본문과 실패 코드를 함께 싣고, 없으면 `Unavailable`에 실패 코드들을 싣는다. `Empty_store`는 모든 저장소 읽기와 문맥 조회가 성공했고 사실이 실제로 0건일 때만 쓴다. 선택 계산 자체가 실패하면 `Unavailable`에 `Selection_failed`와 선행 실패를 모두 남기며, 부분 선택을 성공으로 보내지 않는다. 예산 초과도 부분 묶음을 보내지 않는 `Budget_overrun`에 선행 `issues`를 보존한다. 서로 다른 실패 사이에 한 가지 원인만 남기는 우선순위는 두지 않는다.

Task/Goal 조회가 실패하면 해당 링크 후보는 보류하고 검증된 `Standing`과 다른 정상 링크만 보낸다. 모델에는 `issues`의 코드·건수와 조회 수단을 표시하고, 운영자 영수증에는 실패한 축·ID와 살아남은 fact ID를 함께 남긴다. source-bound 본문은 그 claim의 소스가 재검증된 경우에만 보낸다. 기밀 경로나 원문은 상태 머리줄에 넣지 않는다.

## §4 유효 조건과 저장 경계

유효 조건은 free text가 아닌 사건 키와 정해진 결합(`All_of`, `Any_of`)으로 저장한다. `All_of`는 전부 종결이면 만료, 하나라도 확실히 미종결이면 유효, 나머지 미확인 조합은 `Validity_unknown`이다. `Any_of`는 하나라도 종결이면 만료, 전부 미종결이면 유효, 나머지 미확인 조합은 `Validity_unknown`이다. 사건 영수증에 소유 저장소·객체 ID·최종 상태·관측 revision을 포함한다. 시간만 경과했다고 HOLD나 PR 상태를 추정하지 않는다.

기존 사실은 조건이 없다는 이유로 자동 만료하지 않는다. Librarian 또는 Keeper가 근거를 확인해 조건과 연결 ID를 붙인 새 claim으로 교체하거나, 검증된 명시적 메타데이터 갱신을 거친다. source-bound claim의 조건과 링크도 소스 바이트에 매여 재검증 뒤 적용된다. “Skill로 옮김”, “PR 닫힘” 같은 산문 문자열을 파싱해 상태 전이를 만들지 않는다.

## §5 관측과 평가 게이트

매 projection은 `receipt_id`, 입력 snapshot revision/해시, 정책 버전, 포함·제외 ID와 이유, 유효 조건 판정, source 검증 결과, 예산, 모델에 실제 보낸 블록 해시를 남긴다. 모델에는 상태 코드·포함 건수·생략 건수·조회 수단과 §3의 연결된 만료 표식을 짧게 보인다. 운영자는 영수증에서 개별 제외 이유와 표식의 근거 사건을 읽는다. 정보 누락과 검색 실패를 구별할 수 있도록 실제 `keeper_memory_search` 호출도 센다. C03/C05는 고정 입력·정답을 유지한 채 모델에 보낸 표식 바이트, terminal 영수증 조회, 답변을 각각 기록해 만료 확인이 실제 답에 도달했는지 판정한다.

평가는 운영 원본 기억을 복제하지 않은 격리 fact 스냅숏과 고정 턴 자극으로 현재 전량 주입과 후보 선택을 같은 입력에 shadow 재생한다. `test/test_keeper_memory_os_current.ml`의 `with_temp_keepers`/typed fact/replace가 픽스처 시작점이며, 테스트 파일의 존재 자체를 실행 성공으로 세지 않는다. 필수 질문은 현재 Task 권한, Goal 상태, 뒤집힌 PR 상태, 만료된 HOLD, source 변경·불독가, ordinary 읽기 오류, 선택 오류, 예산 초과, 근거 없을 때 기권을 포함한다.

판정표에는 조립 바이트, 실제 요청 토큰(획득 시), 캐시 적중, 선택 지연, 필수 사실 회수, 옛 상태 오답, 만료 제약 재사용, 기권, 검색 호출률을 분리한다. `Unavailable`의 안전한 기권과 실패 때문에 잃은 검증 가능 정보도 별도 계수한다. 격리 픽스처는 ordinary만 살아남는 경우, source-bound만 살아남는 경우, Task/Goal 조회 실패, 링크 없는 사실을 실제 `keeper_memory_search`로 찾는 경우, Task/Goal 없이 `Standing`을 회수하는 경우를 포함한다. 같은 Keeper·같은 턴 종류·같은 snapshot으로 짝 비교한다. 같은 입력의 전량 기준선 대비 30% 절감은 비용 목표이며(9/28 관측치는 추세 참고로만 사용), **필수 사실 회수 저하나 옛 상태 오답 증가를 허용하는 면제 조건이 아니다**. Shadow 결과와 실제 provider 요청 영수증 없이는 배포 효과나 완료를 선언하지 않는다.

## §6 이행 순서와 열린 결정

1. 현재 전량 경로의 조립 블록·토큰·캐시 기준선을 같은 입력으로 고정하고 격리 픽스처를 만든다.
2. 결과 타입·영수증과 네 실패의 모델/운영자 표시를 먼저 추가한다. 기존 경로와 새 경로를 shadow로 나란히 계산하고 실제 모델에는 기존 결과만 보낸다.
3. typed 링크·만료 조건·source 재검증을 붙인 선택기를 격리 평가한다. 정확도 게이트를 통과한 뒤에만 전송 경로를 전환한다.
4. 구 RFC §3.7/§6과 이 문서의 충돌을 해소하고 `keeper_memory_os_recall.mli`의 “never truncates, ranks, or partially injects” 문장을 새 계약으로 교체한다.

열린 결정은 상시 fact 지정 권한, 예산 설정값, 링크 없는 레거시 fact의 전환 책임, 조회 도구가 오래된 source-bound 내용을 거부하는 정확한 표면, 전송 실패 시 턴을 계속할지 보류할지다. 이 Draft는 이 값들을 확인 없이 확정하지 않는다.
