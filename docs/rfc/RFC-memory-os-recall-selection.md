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

이 문서의 현행 기준선은 main `86751f610442e4d82992ebc54bf9eb8ba45ef6d2`다. 이 SHA의 `keeper_memory_os_recall.ml`은 ordinary/source 각각의 Absent·Available·Unavailable 상태를 Recall 블록에 표시한다. ordinary가 비었거나 읽히지 않아도 블록을 보내며, Recall을 끈 경우도 disabled 상태 블록을 보낸다. `render_if_enabled`의 반환과 `ordinary_text`/`source_text`를 기준으로 삼는다. source 읽기 실패를 ordinary-only 성공으로 숨기지 않는다. 현재 전량 fact 전송과 `.mli`의 선택·부분 주입 금지는 계속 적용된다.

이 PR head `15706ce9033dce463b8a0ef7e6e5dbdacc545c9d`에 포함된 이전 구현은 ordinary empty/read error에서 블록을 생략하거나 source-only로 내려갔다. 그 구현의 바이트를 위 main 기준선과 섞어 비교하지 않는다. main 기준선이 바뀌면 새 SHA와 입력 cohort를 고정해 평가를 다시 시작한다.

두 구현 모두 `keeper_memory_source_current.ml`의 `Source_io_failed`/`Source_endpoint_unanswered` 경로에서 fact를 보존해 `unverified_paths`에 넣는다. main 기준선의 `source_text`도 그 fact **본문**을 `verified=false`로 렌더한다. 따라서 §2의 검증되지 않은 본문 미전송은 현행 바이트 보존과 동시에 성립하지 않으며, 이 RFC가 제안하는 안전성 변경이다. 저장 사실을 지우지 않고 전송만 바꾼다.

이 RFC는 이 **전송 계약**을 바꾸는 제안이다. 저장된 기억의 삭제나 Librarian의 기억 채택 결정을 바꾸지 않는다.

#36687의 2026-09-15 사례는 `extra_system_context` 전체 237,034 B를 재었다. 2026-09-29에 보고된 같은 UTC 시간대(01:25–05:49Z) 세 Keeper의 조립된 Recall 블록 중앙값은 리더 421,248 B, indie-geek-blue 65,725 B, lane-smith 69,012 B다(Board `p-1ffceadb741b8d2c7eb1cbe716009e77`, indie-geek-blue의 TurnRecord 측정). 이 기록은 위 main SHA 이전의 역사적 관측이다. §5의 같은 입력 평가 기준선으로 재사용하지 않는다. 이는 조립 바이트이며 공급자 전송 토큰이나 캐시 비용을 뜻하지 않는다. 이 RFC의 수치 목표를 정할 때 같은 입력의 전후 측정이 필요하다.

기존 Draft `RFC-memory-os-bounded-context-and-librarian-curator.md` §3.7은 fact 예산을 저장 **커밋 시점**에만 적용하고 주입 시점 선택을 금지한다. 이 제안은 그 조항과 양립하지 않는다. 이미 쌓인 현재 사실을 매 턴 모두 싣는 비용이 확인됐으므로, 그 RFC의 보존·journal 원칙은 유지하고 §3.7과 §6의 “입력 연관 recall은 future scope” 문장은 이 RFC가 채택될 때 명시적으로 개정해야 한다. 두 Draft를 동시에 현행 계약으로 읽지 않는다.

## §2 목표와 불변식

1. 저장소는 모든 current fact를 보존한다. 전송에서 빠진 fact는 저장 사실의 삭제·철회·부정으로 해석하지 않는다. 다만 §3의 명시적 Recall scope 교체 표식은 이전 턴 projection의 현재 적용 권한을 끝낸다. 저장된 사실의 존부와 이번 턴에 근거로 쓸 수 있는 projection은 구별한다.
2. 작은 상시 블록에는 Keeper 정체성, 지속 선호, 권한 경계, 현재 Task/Goal 주소만 들어간다. `category=constraint` 같은 넓은 분류만으로 상시 승격하지 않는다. 상시 여부는 별도 typed `Standing` 연결로 확정한다.
3. 이번 턴의 Task/Goal/자극과 **typed 링크가 있는** 유효 fact만 본문 후보가 된다. 연결이 없는 fact에 최신순·문자열 유사도·강화 카운터 점수를 임의 적용하지 않는다.
4. 조건부 fact는 사실 본문과 함께 typed 유효 조건을 가진다. 예를 들어 `Until_pr_merged (owner, repo, number)`, `Until_hold_released (hold_id)`, `Until_task_terminal (task_id)`다. §4의 조건식 판정에 필요한 사건 증거가 확인됐을 때만 만료한다. 상태를 읽지 못했으면 “유효”나 “만료”로 추정하지 않고 `Validity_unknown`으로 보류한다.
5. source-bound fact는 후보 선택 전에 기존의 정확한 소스 바이트 재검증을 거친다. 변경·불독가·검증 미완료를 ordinary fact와 합쳐 보이지 않게 하지 않는다. 검증되지 않은 claim 본문은 전송하지 않는다.
6. 빈 저장소, 읽기 실패, source 저장 갱신 실패, 선택 실패, projection 예산 초과, 용량 미관측은 서로 다른 typed 결과다. 허용된 projection에서는 모델과 운영자가 그 차이를 볼 수 있어야 한다. §3의 Invalid_policy는 입력 거절이며 fact projection을 보내지 않는다. 대신 이전 held Recall을 무효화하는 고정형 withdrawal control을 같은 블록 identity로 전달하고 운영자 영수증에 기록한다. 선택 실패나 예산 초과가 성공한 일부 fact 주입으로 둔갑하지 않는다.
7. 다음 입력 전체가 같으면 같은 전송 결과가 나온다.

   - ordinary/source snapshot 및 fact metadata bundle의 revision·내용 해시·가용성·갱신 결과와 source 바이트 재검증 결과.
   - 현재 Task/Goal/자극 ID와 각 축의 Known/Unknown 문맥 상태.
   - 사건별 조건 키·소유 저장소·객체 ID·raw 상태·Met/Not_met/Unknown, 영수증 revision·내용 해시·검증 provenance.
   - projection 용량의 known/unobserved/invalid 상태·실효 상한·정책 revision·측정 provenance.
   - 정렬 규약·renderer schema revision, 조회 주소·영수증 참조.

   이 canonical 입력 전체를 결정 영수증에 해시한다. 사건 revision이나 조회 상태가 달라진 재생을 동일 입력으로 세지 않는다. 새 결정 receipt_id는 운영자 원장에만 기록하고 모델의 held Recall 블록 입력에는 넣지 않는다. 아래 stable projection_ref와 본문·표식의 바이트가 동일하면 전체 전송 해시도 동일해야 한다. 시계나 확률은 선택 순서의 입력이 아니다.
8. projection 용량이 미관측이면 §3의 `Capacity_unobserved`로 안전한 전량 fallback을 보낸다. source 재검증과 조건 판정은 용량 관측 여부와 독립적인 전송 안전 조건이다. 검증된 무조건 fact·ordinary/source 상태·invalidation 행은 보존한다. 활성 조건부 본문은 검증된 `Active_condition`과 묶고, Expired·Validity_unknown·unverified source 본문은 ID·typed 상태·이유·조회 주소로 바꾼다. 링크에 따른 부분 선택은 하지 않지만 만료 표식은 전송한다. 이 바이트 변경과 별도 결과 상태 envelope를 기록하며 비용 절감으로 주장하지 않는다.

## §3 입력과 선택 계약

`Recall.select`는 effect 없는 함수로 둔다. 입력은 (a) 하나의 authoritative bundle에 결합한 ordinary·source current snapshot, typed fact metadata와 각 revision, (b) source 재검증과 authoritative invalidation 갱신의 닫힌 결과, (c) 이번 턴의 typed `task_id`, `goal_id`, `stimulus_id` 집합, (d) 사건 상태 영수증, (e) 측정·구성된 MASC projection 바이트 상한의 typed 상태와 정책 revision·provenance다. 반환은 아래 receipt-free `selection_result`이며 UUID·시계·영수증 저장 효과를 만들지 않는다. effectful edge가 순수 입력 admission/선택 결과를 받은 뒤 매 시도 새 receipt_id를 할당하고 `decision_receipt`로 감싼다. 같은 선택 입력의 결과는 같고 새 운영자 receipt_id만 다를 수 있으며, 그 ID는 projection/ref/hash 입력에 들어가지 않는다. 이 상한은 MASC가 조립하는 Recall 블록(상태 머리줄·표식·조회 주소 포함)의 바이트 한도이며 provider의 남은 입력 토큰 예산이 아니다. Task/Goal/자극이 읽히지 않으면 그 축은 `Unknown_context`이며 “링크 없음”으로 취급하지 않는다. fact metadata·소스·사건·용량 읽기와 source 갱신은 함수 바깥에서 끝내고, 읽기·검증·쓰기 결과를 각각 닫힌 값으로 넘긴다. edge는 renderer schema가 정하는 고정 길이 projection_ref·조회 주소 **템플릿**으로 capacity 입력 검증을 끝낸 뒤에만 Known 용량을 selector에 넘긴다. 실제 content address는 아직 만들지 않으며, selector 결과와 전송할 본문이 정해진 다음 계산한다.

### Resume에서 유지되는 projection identity

`receipt_id`는 매 결정의 운영자 기록을 구분하며 모델에 자동 주입하는 `Memory_os_recall` 본문·상태 envelope·조회 URL에는 들어가지 않는다. 그 블록에는 `projection_ref`만 쓴다. 이는 fact/metadata 및 사건 증거의 의미 revision·내용 해시, 선택 결과·실패 코드, 렌더/정렬 규약, 용량 정책과 전송 본문을 canonical하게 묶은 content address다. projection_ref 값 자체와 조회 주소 안의 동일 digest 슬롯은 해시 입력에서 제외한다. fresh invocation ID, 관측 wall time, 매 턴 재발급되는 조회 receipt ID는 제외한다. 동일 원천 revision의 사건 영수증은 동일한 content-addressed 참조를 사용한다. 원래 사건 상태나 근거 revision이 바뀌면 새 projection_ref가 생긴다.

주소 형식은 renderer schema에 고정한 prefix와 SHA-256 lowercase hex 64바이트 digest 슬롯이다. 입력 admission에서는 모든 슬롯에 같은 길이의 placeholder를 넣어 직렬화한 템플릿 길이만 검사한다. Admitted 뒤 selector 결과와 안전한 본문을 정하고, 선택 실패나 Budget_overrun을 포함한 **최종** 상태를 렌더한 다음 자기 참조 슬롯을 제외한 canonical 바이트를 해시한다. 그 digest로 모든 슬롯을 동일하게 치환하고 실제 길이가 템플릿 계산과 같은지 검증한 뒤 전송한다. 따라서 정상 후보가 용량을 넘으면 먼저 최소 Budget_overrun 결과로 바꾸고 그 최종 결과의 주소를 계산한다. Invalid_policy에는 selector 결과·projection_ref·실제 projection 조회 객체가 없으며 운영자 admission 영수증·템플릿 해시/길이와 아래 withdrawal control의 전송 결과만 남긴다.

운영자 원장은 매 턴 receipt_id → projection_ref와 실제 전송/보존 여부를 따로 기록한다. `recall_projection(projection_ref)`는 권한 검사 후 그 불변 projection 설명을 조회하며 조회 자체가 held 블록을 다시 조립하지 않는다. fresh receipt 전달이 필요한 도구 응답/운영자 UI는 별도이며 이를 새 Recall 본문으로 붙이지 않는다. 공식 클라이언트의 raw-text hash 기반 carried-block 중복 제거는 그대로 두고, 같은 입력에서 본문과 envelope 전체를 byte-identical하게 유지한다. known/unobserved/Budget_overrun 모두 이 규칙을 따른다. 특히 매 턴 회수한 동일 snapshot·동일 조건에서 두 번 resume할 때 fresh receipt_id는 달라도 Memory_os_recall의 전송 바이트/digest가 같고 두 번째 전체 블록이 append되지 않는 fixture를 요구한다. ordinary/source 내용·가용성, metadata/링크, Task/Goal/자극, 조건/사건 증거, 실패 상태, 용량 정책, renderer 등 §2 determinism key의 의미 입력이나 최종 렌더 projection이 바뀌면 새 블록을 전달한다. 무시하는 변화는 fresh 운영자 receipt_id·invocation ID·wall time뿐이다.

### 이전 Recall의 현재 적용 권한과 withdrawal

모든 정상 projection과 안전 fallback은 고정된 `Recall_scope = Current_projection_only` 선언을 포함한다. 여기서 현재 projection은 이번에 전송한 블록 또는 현재 입력과 정확히 같은 digest로 이미 성공적으로 전달되어 held인 블록이다. 이 선언은 **이전 모든 Recall projection의 본문과 Active_condition은 현재 턴의 근거가 아니며, 현재 projection 또는 이번 턴의 typed lookup으로 다시 검증한 사실만 적용한다**고 명시한다. vendor-owned history에서 예전 텍스트를 삭제했다는 주장이 아니다. 같은 세션의 임의 과거 projection에 남은 fact에도 이 선언이 적용되므로, 최근 held fact ID만 기록해서 더 오래된 본문을 놓치는 방식을 쓰지 않는다. Task A에 연결돼 이전에 Active였던 fact가 Task B로 전환한 뒤 만료되면, 현재 링크에 맞지 않아 개별 Expired 표식이 없어도 새 scope가 이전 Active 주장을 명시적으로 supersede한다. 그 fact를 답에 써야 하면 `recall_fact`에서 현재 Expired/Unknown을 확인해야 한다. 링크 불일치만으로 저장 fact가 만료됐다고 표기하지 않는다.

Invalid_policy에서는 rejected fact projection을 만들지 않으며, 그 잘못된 상한의 바깥에서 고정 renderer schema의 `Recall_withdrawn { reason=Invalid_capacity_policy; scope=No_prior_recall_authority }` control을 `Context_block Memory_os_recall`로 구성한다. fact 본문, fresh receipt_id, 시각 또는 가변 길이 오류를 넣지 않는다. 이는 기존 held block과 같은 identity를 supersede하고 vendor history의 과거 Recall을 현재 근거로 쓰지 말라는 모델 지시를 보낸다. control 바이트·해시는 별도 측정하며 rejected ceiling을 만족한 projection으로 세지 않는다. 새 세션에도 같은 control을 보낸다. 같은 Invalid_policy가 반복되면 control이 byte-identical하여 기존 held-control digest와 일치하고 중복 전송하지 않는다. 다음 유효 projection은 그 control을 정상 scope와 함께 교체한다.

이 규칙은 `Unavailable`·`Budget_overrun`에도 적용한다. 그 고정 최소 envelope의 scope가 이전 본문의 적용을 끝내며, 긴 fact별 철회 목록을 넣어 최소 응답 길이를 늘리지 않는다. 공식 클라이언트의 동일 block identity 교체와 조립한 다음 provider 요청의 control 포함을 검사한 뒤 dispatch를 허용한다. 또는 현재 control과 정확히 같은 digest가 이전에 성공적으로 전달된 held 상태이면 Already_held로 인정한다. 새 digest는 조립만으로 전달 완료라고 기록하지 않으며, 실제 요청 전달/클라이언트 수락이 확인된 뒤에 held 기록과 Delivered를 커밋한다. 조립이 실패하거나 이전 held identity를 교체할 수 없으면 `Recall_control_not_delivered`로 해당 dispatch를 보류한다. 전송 자체가 실패하면 기존 held 기록을 유지하고 미전달 결과를 운영자 영수증에 남기며 같은 미전달 요청으로 모델 실행이 성공했다고 주장하지 않는다. Keeper 전체를 시간·토큰 한도로 중지하는 정책이 아니라, 이전 유효성 주장을 그대로 둔 채 모델을 호출하지 않는 전달 경계다. 다른 블록의 최신 상태로 이 control을 대신했다고 추정하지 않는다.

### Fact identity와 조회 주소

`fact_id`는 `Ordinary { keeper_id; memory_id } | Source_bound { keeper_id; claim_id }`의 닫힌 식별자다. ordinary의 현행 memory ID에 Keeper namespace를 붙인다. 현행 source-bound `fact`에는 memory ID가 없다(`keeper_memory_source_current.ml`의 `fact` 선언). `claim_id`는 이미 authoritative source current snapshot에 저장된 provenance와 claim 바이트에서 파생하며, 별도 mutable ID 표를 만들지 않는다. 현재 schema에서 ID의 저장 원천은 이 정확한 path·source hash·claim 필드다. 새 source claim을 쓰는 경계와 읽기/조회 경계는 같은 canonical 계산을 쓰고, projection·링크·조회 영수증에는 그 ID와 원천 snapshot revision을 기록한다. ID는 schema tag, Keeper ID, 저장·검증에 쓰는 정확한 source path 바이트, source SHA256, claim UTF-8 바이트 SHA256의 길이 구분 canonical tuple을 SHA256한 값이다. 시각·목록 위치·revision은 ID 입력이 아니다. 같은 claim/source는 재읽기와 순서 변경에서 같은 ID를 가지며, claim 또는 source 바이트가 달라지면 새 ID다. raw path는 ID·모델 상태 줄에 노출하지 않는다.

typed 링크와 조건은 이 ID를 참조하고 snapshot revision에 함께 결합한다. claim을 고친 뒤 옛 ID의 링크를 새 ID로 자동 이전하지 않는다. `recall_fact(fact_id)`와 검색 결과의 조회 주소는 권한을 확인한 뒤 현재 authoritative snapshot에서 그 ID를 정확히 찾고, ID 재계산·요청/반환 ID 일치·source 재검증·조건 영수증을 확인한다. 목록 위치나 텍스트 유사도로 다른 claim을 대신 찾지 않는다. 이 식별자는 저장된 사실의 원천 필드와 영수증으로 재계산할 수 있어야 하며, 읽기나 조회가 current store를 고쳐 ID를 부여하지 않는다. 본문의 F04/F05는 격리 fixture가 선언하는 이 typed ID의 짧은 표기다.

### 링크·조건의 authoritative 저장과 읽기

현행 ordinary/source schema에는 링크와 조건이 없으므로, 구현은 별도 암묵적 side store를 추정해서는 안 된다. 새 `Recall_snapshot_bundle`은 Keeper namespace 아래 ordinary snapshot, source snapshot, metadata snapshot의 불변 객체 참조·각 revision·내용 해시와 `bundle_revision`을 가진다. metadata row는 `{ fact_id; fact_content_hash; links: link list; validity }`이고 `link = Standing | Task of task_id | Goal of goal_id | Stimulus of stimulus_id`, `validity = Unconditional | Conditional of condition`이다. `fact_content_hash`는 해당 authoritative fact 전체의 canonical 저장 바이트 해시이며, source-bound ID의 계산과 별개로 그 메타데이터가 어느 fact 버전에 붙었는지를 확인한다. metadata snapshot 자체에도 revision·schema revision·내용 해시가 있다.

작성 경계는 기존 Keeper memory 쓰기 권한을 확인하고 세 snapshot을 불변 generation에 먼저 기록한 다음, 기대 `bundle_revision`에 대한 CAS로 current manifest 하나를 원자적으로 교체한다. ordinary fact 교체, source invalidation commit, 링크·조건 갱신 모두 같은 manifest 출판 경계를 사용한다. 실패하거나 CAS에서 진 generation은 current가 아니며 권위를 갖지 않는다. reader는 manifest를 한 번 읽고 그 manifest가 지목한 불변 객체와 해시를 모두 확인한다. 서로 다른 generation의 latest 파일을 따로 읽어 조합하지 않는다. 조회 도구도 동일 경계를 사용한다. 원문 source 재검증 결과와 사건 영수증은 이 bundle revision에 결합해 edge에서 selector에 넘긴다.

모든 current fact는 해당 ID·내용 해시에 맞는 metadata row 하나를 요구한다. 명시적 `Unconditional`과 metadata 부재는 다르다. 한 component 안의 불일치·중복·누락은 `Component_inconsistent { component; reason; affected_fact_ids }`이며 그 component 본문만 승인하지 않는다. 다른 component의 bundle 결합·해시·metadata가 독립적으로 확인되면 그 본문은 Selected 후보로 유지한다. bundle 전체의 결합을 확인할 수 없거나 selector 자체의 불변식이 깨진 경우만 전역 `Selection_failed Global_snapshot_inconsistent`로 처리하여 어떤 component 본문도 보내지 않는다. metadata 읽기 자체가 실패하면 `Metadata_read_failed`를 남기고 유효성을 확인할 수 없는 본문을 보류한다. 다른 bundle의 metadata나 텍스트 유사도로 보충하지 않는다. 이 규칙은 unobserved fallback에도 적용한다. 저장 형식과 출판 경계는 이 RFC의 새 구현 계약이며 현행 snapshot이 이미 이를 제공한다는 주장이 아니다.

known projection 용량에서 선택 순서는 `Standing` → 현재 Task 링크 → 현재 Goal 링크 → 현재 자극 링크다. 중복 fact는 fact_id로 한 번만 싣고 동일 우선순위에서는 ID로 안정 정렬한다. `Expired` fact와 검증 실패 source-bound claim은 본문 후보에서 제외한다. `Validity_unknown`은 본문 대신 ID와 보류 이유만 표시한다. 연결이 없는 current fact는 검색 가능한 주소로 남는다.

`Standing` 또는 현재 Task/Goal/자극에 연결된 `Expired` fact는 본문 대신 짧은 typed 만료 표식을 모델에 보낸다: fact_id, 연결된 규칙·사건 키, `Expired` 판정, 조건 충족을 증명하는 사건별 영수증의 조회 주소, **해당 명제의 정확한 조회 키**다. ID와 사건 결합식만으로 명제의 주제를 추정해서는 안 된다. 모델이 그 규칙을 답에 쓰려면 조회 키로 해당 fact 하나를 읽어야 한다. 이 typed 조회는 기존 `keeper_memory_search`와 같은 읽기 권한을 적용하고, 요청 ID와 반환 ID의 일치·현재 snapshot의 fact·source-bound 바이트 재검증·조건 영수증을 확인한 뒤 `fact_id`, fact 본문에서 검증된 짧은 명제 구절과 그 바이트 구간, `Expired`, 근거 주소를 함께 반환한다. 구절은 원문과 바이트 단위로 일치해야 하며 새 요약을 생성하지 않는다. 안전하게 좁힐 구절이 없거나 조회 실패·ID/근거 불일치 때는 명제를 추측하지 않고 기권한다. 원래 fact 본문을 상시 Recall 블록에 재주입하지 않으며, 조회 응답은 요청한 fact 하나로 한정한다.

고정 픽스처에서 C03/F04와 C05/F05의 **모델 입력 표식**은 각각 아래 모양이다. `rule_key`는 주제 라벨이 아니라 조회 키이며, `event_receipts`는 실제 실행에서 조건 키에 결합해 검증한 영수증 주소로 치환한다. All_of는 모든 구성 사건의 Met 영수증 또는 그 영수증들을 모두 조회할 수 있는 검증 bundle을 요구한다. 표식 자체에는 F04가 freeze이고 F05가 label 규칙이라는 명제를 쓰지 않는다.

```text
Expired { fact_id=F04; rule_key=F04; condition=All_of(E-A,E-B); event_receipts=[E-A:Met@<verified-E-A-receipt>, E-B:Met@<verified-E-B-receipt>]; lookup=recall_fact(F04) }
Expired { fact_id=F05; rule_key=F05; condition=Any_of(E-C);     event_receipts=[E-C:Met@<verified-E-C-receipt>]; lookup=recall_fact(F05) }
```

C03/C05의 모델은 답하기 전에 `recall_fact(F04)`/`recall_fact(F05)`를 호출해 반환된 명제를 각각 ‘ORCHID freeze remains active’/‘temporary label rule ends’라는 본문 구절 및 ID와 대조하고, 같은 응답의 만료 판정·영수증을 확인해야 한다. 이는 픽스처의 기존 본문 구절을 식별하는 예시이며 원문 전체가 모델에 자동 전송된다는 뜻은 아니다. 영수증이 없거나 불독가면 만료로 단정하지 않고 `Validity_unknown`으로 보류한다. known projection 용량에서 표식도 위 선택 순서의 원자적 항목으로 용량에 넣으며, 필요한 표식이 넘치면 조용히 버리지 않고 `Budget_overrun`과 대상 ID를 남긴다. 따라서 만료를 확인한 경우와 근거가 처음부터 없는 경우가 모델 입력에서 구별된다.

known projection 용량에서 `Standing` 또는 현재 Task/Goal/자극에 연결돼 본문을 선택한 **활성 조건부 fact**에는 조건을 판정할 때 사용한 사건 상태도 함께 보낸다. 사건별 typed 영수증은 조건 키·소유 저장소·객체 ID·관측 revision·원래 도메인 상태·조건별 `Met`/`Not_met`/`Unknown` 판정과 조회 주소를 fact ID에 결합한다. `Not_met`은 종결 영수증이 없다는 추측이 아니라, 권위 저장소의 현재 상태를 읽고 그 조건이 충족되지 않았음을 판정한 영수증이다. PR closed-unmerged는 종결이지만 Until_pr_merged의 `Not_met`이다. 그 뒤 상태가 바뀌었거나 같은 snapshot에 묶을 수 없으면 `Validity_unknown`으로 보류한다. 모델에 보이는 짧은 `Active_condition` 표식은 그 fact의 조건식과 판정에 사용한 사건 키·상태·영수증 주소를 담는다. 본문과 표식은 한 원자적 항목으로 예산에 넣고, 둘 중 하나만 싣지 않는다. 영수증 불독가·객체 불일치·상태 미확인은 `Not_met`으로 바꾸지 않고 `Validity_unknown`으로 보류한다. 모델은 사건 상태를 질문의 산문이나 fact 본문에서 추측하지 않는다.

고정 픽스처의 C02/C04에서 아래는 **모델 입력**에 함께 도착해야 하는 활성 본문과 표식의 예다. `event_receipts`의 각 주소는 실행 시 검증된 해당 사건의 조건 영수증 주소로 치환한다. F04/F05의 본문은 픽스처의 실제 fact에서 선택된 원문이며, 여기 적은 줄은 그 내용의 새 요약을 생성하라는 지시가 아니다.

```text
C02: F04 body=<selected verified F04 text>
     Active_condition { fact_id=F04; condition=All_of(E-A,E-B); events=[E-A:Met@<verified-E-A-receipt>, E-B:Not_met@<verified-E-B-receipt>]; validity=Active }
C04: F05 body=<selected verified F05 text>
     Active_condition { fact_id=F05; condition=Any_of(E-C); events=[E-C:Not_met@<verified-E-C-receipt>]; validity=Active }
```

이 fixture의 사건은 task-terminal 조건이며 영수증의 raw 상태도 E-A Terminal, E-B/E-C Nonterminal로 고정한다. 따라서 C02는 E-A Met만으로 만료하지 않고 E-B Not_met 영수증을 확인한 뒤 `No; E-B remains nonterminal.`을, C04는 E-C Not_met 영수증(raw 상태 Nonterminal)을 확인한 뒤 `Yes; E-C nonterminal.`을 답할 수 있다. 이 표식은 현재 구현의 출력 주장이 아니라 제안된 전송 계약이다.

용량 입력은 `Projection_capacity_known { ceiling_bytes; policy_revision; provenance }` 또는 `Projection_capacity_unobserved { reason: capacity_unobserved_reason; policy_revision; provenance }`다. known 상한값은 동일 입력의 MASC projection 바이트 실측에 근거해 구성하고, provenance는 측정 영수증과 설정 출처를 가리킨다. 값이 미구성되었거나 필요한 측정이 없으면 unobserved이며, 0·무한대·추정 `available_bytes`를 만들지 않는다. 공식 클라이언트 start/resume에도 같은 계약을 적용한다. `keeper_official_client_host.mli:23-37`의 client 소유 native conversation/tool history는 snapshot에 없고 누적 history는 관측할 수 없다. :299-309의 canonical MASC bytes는 lane window ceiling이 아니며, :573-579의 provider context window 초과는 별도 typed lane terminal이다. 따라서 known projection 상한도 provider remaining을 관측했다거나 실제 요청이 window에 들어간다는 보증이 아니다.

구성된 ceiling은 입력 경계에서 먼저 검증한다. renderer schema가 정하는 최소 `Budget_overrun` 응답(고정 상태 머리줄과 Recall_scope 선언, 고정 길이 projection_ref 슬롯과 조회 주소 템플릿)을 UTF-8로 직렬화해 그 **전체 바이트 길이**를 `minimum_ceiling_bytes`로 계산한다. 고정 숫자나 provider remaining 추정으로 하한을 정하지 않는다. 조회 주소나 provenance·renderer schema가 바뀌면 같은 검증을 다시 한다. 모든 실패 코드·건수·긴 진단·제외 ID·required_bytes 상세는 운영자 영수증에 남기고 주소로 읽는다. selector가 뒤에 추가한 Selection_failed도 이 영수증에 보존하며 최소 응답 바이트를 늘리지 않는다. 정상 body/상태도 envelope를 포함해 실제 바이트를 계산하며, 들어가지 않으면 이 검증된 최소 응답으로 Budget_overrun을 보낸다.

구성값이 최소 응답보다 작거나 capacity 선언을 디코드할 수 없으면 receipt-free `Invalid_policy { reason; issues; projection=None }`를 입력 거절로 반환하고 edge가 운영자 영수증을 붙인다. reason은 `Ceiling_below_minimum { configured_bytes; minimum_ceiling_bytes } | Invalid_capacity_declaration`의 닫힌 분류다. Known이나 Capacity_unobserved로 바꾸지 않으며 selector를 실행하지 않고 **fact projection을 전송하지 않는다**. 대신 위 고정 withdrawal control의 전달을 확인해야 한다. 운영자는 구성 출처·최소 응답 템플릿 직렬화 해시·길이·조회 주소 schema·선행 issues를 확인한다. 이 경우 fact projection/선택 성공으로 세지 않고 실제 withdrawal control 전달 여부만 모델 입력 증거로 기록한다. 정책 상세와 선행 issues는 운영자 보고에 남긴다. 이 거절은 Recall projection 설정에 대한 결과다. 시간·토큰 실행 상한을 만들지 않지만, 위 Recall control 전달 경계가 충족되지 않은 모델 dispatch는 진행하지 않는다.

unobserved이면 `Capacity_unobserved`를 반환한다. 이는 §1의 main SHA에서 전량 블록을 조립하는 **제안된 안전 fallback**이다. 검증된 무조건 ordinary/source fact 행, 가용성 상태와 invalidation 행은 그 기준선의 동일 바이트·순서를 보존한다. 모든 조건부 fact에 §4의 동일한 판정을 적용한다. Active 본문에는 판정에 사용한 `Active_condition`을 원자적으로 붙이고, Expired 본문은 `Expired { fact_id; condition; event_receipts; lookup }` 표식으로, Validity_unknown 본문은 ID·보류 이유·조회 주소로 바꾼다. unverified source fact 행은 `Source_revalidation_failed { fact_id; reason; lookup }`로 바꾸고 본문을 보내지 않는다. metadata를 확인할 수 없는 component의 fact 본문도 보류하고 `Metadata_read_failed` 또는 `Component_inconsistent`와 해당 ID를 남긴다. 원래 기준선과 fallback의 해시, 치환 ID·행 범위·이유를 영수증에 남긴다. source redaction·조건 표식·metadata 보류가 모두 없을 때만 baseline payload는 정확히 동일하다. `Capacity_unobserved` 결과를 알리는 상태 envelope는 stable projection_ref만 담고 baseline payload와 분리해 길이·해시를 기록하므로 전체 모델 입력이 원래 입력과 같다고 주장하지 않는다.

fallback은 선행 `issues`를 모두 보존하며 링크 기반 부분 선택을 수행하지 않는다. 조건 판정과 만료·보류 표식은 모든 fact에 적용하며 Standing 여부나 현재 링크 일치 여부로 생략하지 않는다. main 기준선에서는 empty/absent/unavailable도 상태 블록을 보내므로 블록 생략으로 실패를 빈 저장소로 바꾸지 않는다. `Baseline_absent`는 renderer가 실제로 블록을 만들지 않은 경우만 표현하며 이 main SHA의 정상 결과가 아니다. Recall disabled 상태는 selector를 호출하지 않고 main의 disabled 블록을 유지한다. 이 결과를 `Selected`나 비용 절감 표본으로 세지 않는다. source-only란 source 본문만 실제로 전송된 경우를 뜻하며, ordinary 상태 행을 없앤다는 뜻은 아니다.

known 상한에 대해서만 다음 원자적 선택 규칙을 적용한다. 필수 상시 본문이나 한 우선순위의 원자적 묶음이 용량을 넘으면 그 묶음의 일부를 조용히 싣지 않는다. `Budget_overrun`을 반환하고 대상 ID·필요 projection 바이트·구성된 `ceiling_bytes` 및 정책 revision·provenance를 운영자 영수증에 남긴다. 여기서 초과는 projection 한도 초과이며 native provider context overflow와 별개다. 모델에는 작은 고정형 상태 머리줄과 조회 도구 주소를 전달한다. 긴 제외 목록은 프롬프트에 모두 쓰지 않고 별도 결정 영수증에 보존한다. 주소 목록도 예산을 넘으면 첫 페이지와 다음 페이지 토큰만 보인다. 주소를 눌러 원문을 읽을 때는 기존 `keeper_memory_search`/읽기 권한과 source 재검증을 다시 적용한다.

순수 선택 결과와 effectful 영수증 wrapper를 분리한다. 아래 선택 variant에는 receipt_id가 없다.

```text
selection_result = Selected of { body; included_ids; omitted_count; issues }
                 | Empty_store of { issues: issue list }
                 | Unavailable of { issues }
                 | Budget_overrun of { required_bytes; ceiling_bytes; policy_revision; provenance; issues }
                 | Capacity_unobserved of { reason: capacity_unobserved_reason; policy_revision; provenance; baseline; issues }

baseline = Baseline_block of { body; verified_ids; redacted_ids; block_hash; baseline_head; original_block_hash; mode: Full | Ordinary_only | Source_only | Status_only }
         | Baseline_absent

capacity_unobserved_reason = Policy_not_configured | Measurement_unavailable

issues : issue list

issue = Ordinary_read_failed
       | Metadata_read_failed
       | Component_inconsistent of { component: Ordinary | Source; reason: component_inconsistency; affected_fact_ids: fact_id list }
       | Source_store_read_failed
       | Source_store_update_failed of { affected_fact_ids; stage: Invalidation_commit }
       | Source_revalidation_failed of fact_id list
       | Unknown_context of { task: bool; goal: bool; stimulus: bool }
       | Selection_failed of selection_failure
       | Validity_unknown of fact_id list

component_inconsistency = Metadata_missing | Metadata_duplicate | Fact_hash_mismatch

selection_failure = Global_snapshot_inconsistent | Fact_identity_conflict
                  | Invalid_link | Invalid_event_receipt | Invalid_selector_policy

capacity_admission = Admitted of projection_capacity
                   | Invalid_policy of { reason: capacity_rejection; issues: issue list; projection=None }
capacity_rejection = Ceiling_below_minimum of { configured_bytes; minimum_ceiling_bytes }
                   | Invalid_capacity_declaration

decision_receipt = { receipt_id; determinism_key; admission: capacity_admission;
                     selection: selection_result option; projection_ref: projection_ref option;
                     control_hash; delivery: Delivered | Already_held | Recall_control_not_delivered }
```

baseline mode는 실제 전송된 fact 본문 component를 뜻한다. Full은 ordinary와 source 본문이 모두 있고, Ordinary_only/Source_only는 해당 component 본문만 있고, Status_only는 본문 없이 상태·만료·보류 표식만 있는 경우다. 어느 mode도 다른 component의 가용성 상태 행을 숨기지 않는다. `Policy_not_configured`는 projection 설정이 없음을, `Measurement_unavailable`은 설정이 참조하는 필수 측정 영수증을 얻거나 검증할 수 없음을 뜻한다. input과 Capacity_unobserved receipt는 이 동일한 닫힌 reason 타입을 사용한다.

capacity_admission은 selector를 호출하기 전 입력 경계의 결과다. Admitted에서만 selector 결과를 만들며, 입력 거절을 Selected나 Capacity_unobserved로 바꾸지 않는다.

known 용량에서 선택할 때 독립적으로 읽고 검증한 fact는 다른 축이 실패해도 살린다. unobserved 용량은 위 `Capacity_unobserved` 기준선 fallback을 적용한다. `Source_store_read_failed`는 source 저장소의 목록·snapshot 자체를 못 읽어 source ID를 모르는 경우다. 특정 ID를 이미 읽었지만 그 claim의 원문 바이트 검증이 실패한 `Source_revalidation_failed of fact_id list`와 구분한다. known 용량에서 source store 읽기 실패에도 ordinary snapshot을 독립적으로 읽었다면 검증된 ordinary 본문을 `Selected`로 보낼 수 있으며, 모델 상태 줄은 `issues=[Source_store_read_failed]; source_included=0; ordinary_included=<count>; projection=<projection_ref>`로 표시한다. 운영자 영수증은 source 읽기 실패 단계·오류 부류·ordinary snapshot revision·살아남은 ordinary ID와 source ID를 열거할 수 없음을 기록한다. 원문 경로나 예외 전문은 모델 상태 줄에 싣지 않는다. ordinary 읽기 실패·source store 읽기 실패·source 재검증 실패·Task/Goal/자극 조회 실패가 함께 일어나면 `issues`에 **모두** 기록한다. known 용량에서 안전하게 보낼 본문이 있으면 `Selected`에 그 본문과 실패 코드를 함께 싣고, 없으면 `Unavailable`에 실패 코드들을 싣는다. `Empty_store { issues=[] }`는 known 용량에서 모든 저장소 읽기와 문맥 조회가 성공했고 사실이 실제로 0건일 때만 쓴다. 빈 결과도 snapshot·정책·블록 해시를 가진 영수증을 반드시 남긴다. issues는 모든 결과에서 issue list이며 서로 다른 실패를 동시에 담는다. Selection_failed의 reason은 위 닫힌 분류다. 예외 전문은 운영자 진단에만 두고 이 분류로 명시적으로 바꾸며, 분류하지 못한 실패를 성공으로 처리하지 않는다. `Component_inconsistent`는 component-scoped 입력 문제이며 전역 `Selection_failed`가 아니다. 예를 들어 source metadata hash만 불일치하고 ordinary bundle/metadata가 검증됐으면 Selected ordinary + Component_inconsistent Source다. 전역 선택 계산 자체가 실패하면 `Unavailable`에 `Selection_failed`와 선행 실패를 모두 남기며, 부분 선택을 성공으로 보내지 않는다. 예산 초과도 부분 묶음을 보내지 않는 `Budget_overrun`에 선행 `issues`를 보존한다. 서로 다른 실패 사이에 한 가지 원인만 남기는 우선순위는 두지 않는다.

source 원문을 성공적으로 읽고 hash 변경을 확인했지만 invalidation/current snapshot의 영속화가 실패하는 경로는 `Source_store_update_failed { affected_fact_ids; stage=Invalidation_commit }`다. 원문을 읽지 못한 Source_revalidation_failed나 source store 목록을 못 읽은 Source_store_read_failed로 바꾸지 않는다. `keeper_memory_source_current.revalidate`는 읽기와 갱신을 함께 수행하므로 구현 시 effect 경계에서 이 단계들을 닫힌 결과로 구분해야 한다. selector 내부에서 쓰기를 재시도하거나 복구 snapshot을 authoritative로 승인하지 않는다.

이 실패에서는 그 턴의 source component를 Unavailable로 닫고 source claim 본문을 하나도 보내지 않는다. 바뀐 소스를 보았다는 관측 영수증은 남기되 invalidation이 저장됐다고 기록하지 않으며, 이전 current claim 본문을 대신 싣지 않는다. 실패 반환만으로 저장이 없었다거나 이전 snapshot으로 되돌아갔다고 추정하지 않는다. 저장 여부를 확인하지 못하면 운영자 영수증에 미확인으로 남긴다. ordinary snapshot은 독립적으로 읽어 검증된 Standing/정상 링크 후보를 유지한다. known 용량에서 ordinary 본문을 보낼 수 있으면 Selected와 Source_store_update_failed를 함께 표시하고, 없으면 Unavailable과 모든 선행 issues를 보낸다. unobserved fallback은 §1 main의 source Unavailable 상태·독립 ordinary 결과를 기준으로 조립하고 갱신 실패 코드를 별도 envelope에 남긴다. Invalid_policy에서는 이 실패도 운영자 영수증에 보존하지만 모델 projection은 보내지 않는다. 다음 정상 revalidation·commit이 성공한 새 영수증에서만 source component를 다시 Available로 표시한다.

known 용량의 선택에서 Task/Goal/자극 조회가 실패하면 해당 링크 후보는 보류하고 검증된 `Standing`과 다른 정상 링크만 보낸다. 모델에는 `issues`의 코드·건수와 조회 수단을 표시하고, 운영자 영수증에는 실패한 축·ID와 살아남은 fact ID를 함께 남긴다. source-bound 본문은 그 claim의 소스가 재검증된 경우에만 보낸다. 기밀 경로나 원문은 상태 머리줄에 넣지 않는다.

## §4 유효 조건과 저장 경계

유효 조건은 free text가 아닌 사건 키와 `All_of`/`Any_of`로 저장한다. 도메인의 Terminal/Nonterminal과 만료 조건 충족은 별개다. 각 사건은 자신의 조건에 대해 `Met | Not_met | Unknown`으로 판정한다.

| 조건 | Met | Not_met | Unknown |
| --- | --- | --- | --- |
| Until_pr_merged(owner, repo, number) | 정확한 PR의 merged=true와 merge commit을 권위 응답으로 확인 | open 또는 closed-unmerged를 권위 응답으로 확인 | 읽기 실패·객체/영수증 불일치·revision 불일치 |
| Until_hold_released(hold_id) | 정확한 HOLD의 명시적 release 영수증 | 해당 HOLD가 release되지 않은 현재 상태 영수증 | 상태·release 증거 미확인 |
| Until_task_terminal(task_id) | 정확한 Task의 Done 또는 Cancelled 상태 영수증 | Todo·Claimed·InProgress·AwaitingVerification 상태 영수증 | 상태·객체·revision 미확인 |

`Until_hold_released`의 권위 원천은 이 RFC가 새로 정의하는 Keeper별 `Recall_hold_store`다. `hold_id = { keeper_id; hold_uuid }`이고 이름이나 산문 문구로 매칭하지 않는다. 불변 hold row는 `{ hold_id; revision; state; actor; evidence_refs }`, `state = Held | Released of { release_receipt_id; released_by }`다. 기존 Keeper memory 쓰기 권한을 확인한 명시적 Create가 새 UUID의 Held를 만들고, 같은 권한을 확인한 Release가 기대 revision에 대한 CAS로 Held → Released를 출판한다. Released는 종단이며 재개는 새로운 hold_id로 Create한다. 생성·해제 영수증은 ID·이전/새 revision·actor·증거 참조·내용 해시를 가진 append-only 기록이다. 시각 경과는 상태를 바꾸지 않는다.

읽기는 hold store의 current manifest가 가리키는 immutable row와 그 생성/해제 영수증을 함께 검증한다. Held의 현재 revision을 확인하면 Not_met, Released와 결합된 release 영수증을 확인하면 Met이다. 객체 없음·읽기 실패·해시/ID/revision 불일치는 Unknown이며 release로 추정하지 않는다. 이 store를 구현하기 전 Until_hold_released를 지원 완료로 표시하지 않는다. 격리 평가의 HOLD fixture는 실제 Create → Release 저장 경계를 실행하고 각 revision의 검증 영수증으로 판정한다. 외부 PR 댓글의 “HOLD” 문구는 이 저장소의 상태가 아니다.

`All_of`는 모든 사건이 Met이면 Expired, 하나라도 Not_met이면 Active, 그 밖은 Validity_unknown이다. `Any_of`는 하나라도 Met이면 Expired, 전부 Not_met이면 Active, 그 밖은 Validity_unknown이다. 빈 결합식은 유효 조건으로 받아들이지 않는다. 영수증은 조건 키·소유 저장소·객체 ID·raw 도메인 상태·조건 판정·관측 revision을 포함한다. All_of 만료 증명에는 모든 구성 사건의 Met 영수증과 조회 주소를 실으며 하나의 주소로 묶을 때도 bundle을 열어 모든 구성 영수증을 검증할 수 있어야 한다. Any_of 만료는 Met인 구성 사건 하나 이상의 검증 영수증과 전체 조건식을 실어 판정 경로를 고정한다. 조회 실패는 해당 사건의 Unknown이고, 시간만 경과했다고 HOLD release나 PR merge를 추정하지 않는다.

Unknown 사건이 있어도 확인된 다른 사건만으로 결합식의 판정이 증명되면 그 판정을 사용한다. 예를 들어 All_of(Unknown, Not_met)는 Active이고 Any_of(Met, Unknown)는 Expired다. Unknown 항목에는 실패 이유를 기록하며 확인 영수증을 만들어 채우지 않는다. §3의 영수증 불독가에 따른 보류는 그 결합식 판정을 증명할 확인 영수증이 부족하거나 그 영수증의 객체·revision 검증이 실패한 경우에 적용한다.

`recall_fact`와 일반 `keeper_memory_search`는 동일한 source 재검증과 조건 판정을 적용한다. 검색은 결과마다 typed `Active | Expired | Validity_unknown` 및 fact_id·조건식·근거 영수증을 반환한다. Expired 본문을 상태 없는 현재 사실처럼 반환하지 않는다. 필요한 본문 구절은 해당 typed 결과에 결합한 검증 원문으로만 읽는다. Validity_unknown이나 source 재검증 실패에는 claim 본문을 보내지 않고 ID·이유·조회 주소를 반환한다. 검색과 Recall이 같은 snapshot·영수증에서 다른 유효성을 주장하면 오류로 기록하고 기권한다.

기존 사실은 조건이 없다는 이유로 자동 만료하지 않는다. Librarian 또는 Keeper가 근거를 확인해 조건과 연결 ID를 붙인 새 claim으로 교체하거나, 검증된 명시적 메타데이터 갱신을 거친다. source-bound claim의 조건과 링크도 소스 바이트에 매여 재검증 뒤 적용된다. “Skill로 옮김”, “PR 닫힘” 같은 산문 문자열을 파싱해 상태 전이를 만들지 않는다.

## §5 관측과 평가 게이트

매 입력은 projection 여부와 무관하게 `receipt_id`와 §2의 전체 determinism key를 남긴다. Invalid_policy에는 projection=None·fact 전송 없음·운영자 오류와 withdrawal control의 바이트/전달 상태를 기록한다. 실제로 보낸 projection은 입력 snapshot revision/해시, 사건 영수증 revision/해시/provenance, source 갱신 결과, renderer/정렬 규약·조회 상태, 정책 버전, 포함·제외 ID와 이유, 유효 조건 판정, source 검증 결과, projection 용량의 known/unobserved 상태·상한의 정책 revision·provenance, 모델에 실제 보낸 블록 해시를 남긴다. `Capacity_unobserved`는 이유·baseline mode/absence·검증된 ID·선행 issues를 기록하고 모델에도 fallback 상태를 표시한다. 관측되지 않은 provider remaining이나 `available_bytes` 숫자를 영수증에 넣지 않는다. native provider overflow는 selector 결과와 조인 가능한 별도 lane terminal 영수증으로 남긴다. 유효한 capacity 입력으로 실제 projection을 보낼 때 모델에는 상태 코드·포함 건수·생략 건수·조회 수단과 §3의 연결된 만료 표식을 짧게 보인다. Budget_overrun은 §3의 최소 응답에 고정 상태·Recall_scope 선언·stable projection_ref·조회 주소만 넣는다. 이 경우 실패 코드·건수를 모델 상태 줄에 직접 표시하는 의무의 명시적 예외이며 모든 선행·선택 실패와 판정 상세는 영수증에서 읽는다. Invalid_policy에서는 fact projection의 상태 표시 대신 고정 withdrawal control을 보냈거나 dispatch를 보류했다는 사실을 운영자 영수증에 명시한다. 운영자는 영수증에서 개별 제외 이유와 표식의 근거 사건을 읽는다. 정보 누락과 검색 실패를 구별할 수 있도록 실제 `keeper_memory_search` 호출도 센다. C02/C04는 고정 입력·정답을 유지한 채 활성 fact 본문과 `Active_condition`의 실제 전송 바이트, E-A/E-B/E-C 사건 상태 영수증의 소유 저장소·객체 ID·revision 검증 결과, 각 영수증의 모델 도착 여부와 답변을 기록한다. 미종결 영수증 없이 고정 정답을 맞힌 경우는 근거를 전달한 성공으로 세지 않는다. C03/C05는 고정 입력·정답을 유지한 채 모델에 보낸 표식 바이트, `recall_fact`의 실제 호출·반환 ID·검증된 명제 구절·조건 충족 영수증 조회(All_of 구성 사건 전부), 답변을 각각 기록해 만료 확인이 실제 답에 도달했는지 판정한다. `recall_fact`는 이 RFC의 제안 조회 계약이며, 현행 `keeper_memory_search`가 그 응답을 이미 제공한다는 주장은 아니다. 구현 전 shadow가 이 조회를 제공하지 못하면 C03/C05를 통과로 세지 않는다.

평가는 운영 원본 기억을 복제하지 않은 격리 fact 스냅숏과 고정 턴 자극으로 §1의 고정 main SHA 전량 주입, 안전 fallback, 후보 선택을 같은 입력에 shadow 재생한다. 원래 전량과 안전 fallback의 source-redaction·조건 판정·metadata 보류 차이는 안전성 변경으로 별도 계수하고, 선택 절감은 안전 fallback과 후보 선택을 짝 비교한다. `test/test_keeper_memory_os_current.ml`의 `with_temp_keepers`/typed fact/replace가 픽스처 시작점이며, 테스트 파일의 존재 자체를 실행 성공으로 세지 않는다. 필수 질문은 현재 Task 권한, Goal 상태, 뒤집힌 PR 상태, 만료된 HOLD, source 변경·불독가, ordinary 읽기 오류, 선택 오류, 예산 초과, 근거 없을 때 기권을 포함한다.

판정표에는 조립 바이트, 실제 요청 토큰(획득 시), 캐시 적중, 선택 지연, 필수 사실 회수, 옛 상태 오답, 만료 제약 재사용, 기권, 검색 호출률을 분리한다. `Unavailable`의 안전한 기권과 실패 때문에 잃은 검증 가능 정보도 별도 계수한다. 격리 픽스처는 source store 자체 읽기 실패로 ordinary만 살아남는 경우(`Selected`의 모델 상태 줄에 `Source_store_read_failed`, 운영자 영수증에 source ID 불명과 ordinary revision/ID가 기록되는지 검사), ordinary 읽기 실패로 source-bound만 살아남는 경우, Task/Goal/자극 조회 실패, 링크 없는 사실을 실제 `keeper_memory_search`로 찾는 경우, Task/Goal 없이 `Standing`을 회수하는 경우를 포함한다. 공식 클라이언트 start와 resume 각각에서 known projection capacity와 unobserved capacity를 모두 고정 평가 입력에 넣는다. known에서는 원자적 선택과 `Budget_overrun`을, unobserved에서는 main `86751f610442e4d82992ebc54bf9eb8ba45ef6d2` 기준선의 검증된 무조건 행·상태 행의 동일 바이트 보존, source redaction·조건 판정·metadata 보류 각각의 diff·금지 본문 미전송, 별도 상태 envelope 바이트, 선행 issues 보존을 확인한다. empty/unavailable에서도 Status_only 블록이 존재하는지 확인하며 정상 결과를 Baseline_absent로 세지 않는다. 이 네 조합의 fallback 발생률과 검증 가능 정보 보존은 별도 계수하며, unobserved를 선택 성공이나 절감 표본으로 합산하지 않는다. projection 한도 안인 입력도 native provider overflow를 낼 수 있는 별도 lane fixture를 포함해 두 판정이 섞이지 않는지 확인한다. 답변 정확도 짝 비교는 같은 Keeper·턴 종류·snapshot뿐 아니라 동일한 전체 모델 대화·도구 history에서 독립 분기한 세 실행을 요구한다. start는 동일 초기 입력으로 격리 session을 만든다. resume은 client가 export/replay 또는 동등한 immutable history fork를 지원하고 전체 history 해시·client version·resume checkpoint를 영수증으로 검증할 수 있는 fixture에서만 짝 비교한다. 한 session에 세 arm을 연속 실행하지 않는다. native history를 포착/재생할 수 없는 실제 official-client resume은 관측 cohort로 분리하고 입력 바이트·fallback·provider 결과를 보고하되 선택에 따른 정확도/오답 변화의 인과 효과나 짝 비교 통과로 세지 않는다. replayable resume fixture가 없으면 resume 정확도 게이트는 미검증으로 남긴다. 같은 입력의 안전한 전량 fallback 대비 30% 절감은 비용 목표이며(9/28 관측치는 추세 참고로만 사용), **필수 사실 회수 저하나 옛 상태 오답 증가를 허용하는 면제 조건이 아니다**. Shadow 결과와 실제 provider 요청 영수증 없이는 배포 효과나 완료를 선언하지 않는다.

추가 필수 fixture는 (a) 동일한 PR이 open → closed-unmerged → merged로 바뀔 때 Until_pr_merged가 Not_met → Not_met → Met으로 판정되는 경우, (b) All_of 두 사건 중 한 영수증만 있으면 Expired 증명이 거절되는 경우, (c) Recall과 일반 검색이 Expired/Validity_unknown을 같은 typed 결과로 표시하고 source 불독가 본문을 보내지 않는 경우다. source claim은 순서 변경·동일 바이트 재기록에서 같은 fact_id, 변경된 claim/source hash에서 새 ID, 다른 Keeper에서 다른 ID를 갖는지 확인한다. 모든 읽기·조회가 성공한 0-fact 입력은 Empty_store 영수증과 `issues=[]`를 검증한다. 여러 실패가 동시에 발생한 별도 입력은 Selected/Unavailable의 issue list에 모든 실패가 남는지 검증하며 Empty_store를 기대하지 않는다. unobserved 안전성 변환에서 무조건 ordinary/status/invalidation 행의 바이트 diff가 0인지, source redaction과 조건부 fact 표식·metadata 보류의 ID·행 변경이 각각 기록됐는지, envelope 차이가 별도로 기록됐는지 검사한다.

추가 입력 경계 fixture는 (a) 기억 revision·문맥 ID가 같지만 사건 영수증 revision이 달라 Active가 Expired로 바뀌는 경우, (b) source hash 변경을 확인한 뒤 invalidation commit만 실패하는 경우, (c) 실제 최소 UTF-8 응답보다 작은 ceiling과 정확히 같은 ceiling이다. (a)는 다른 determinism key와 판정을, (b)는 Source_store_update_failed·source 본문 없음·ordinary 독립 보존·저장 여부 미확인을 포함한 정직한 영수증을 확인한다. (c)의 작은 값은 Invalid_policy·selector 미실행·fact projection 없음·withdrawal control 전달 또는 dispatch 보류·운영자 영수증을, 정확한 경계는 최소 Budget_overrun 응답이 상한 안에 드는지를 확인한다. 다중 바이트 주소·상태 텍스트와 길이가 바뀐 조회 주소도 같은 직렬화 검증에 포함한다. 입력 검증 뒤 Selection_failed가 추가돼도 최소 Budget_overrun 바이트는 그대로이고 모든 실패가 영수증에 보존되는 경우를 확인한다.

추가 안전 fallback fixture는 Standing-only 조건부 fact, source-bound 조건부 fact, 일반 linked 조건부 fact 각각의 Active/Expired/Validity_unknown을 known/unobserved 모두에서 확인한다. unobserved에서도 Expired·Unknown 본문은 전송되지 않고 typed fact_id와 근거/보류 표식이 남아야 한다. stimulus-only 문맥 실패는 `Unknown_context { task=false; goal=false; stimulus=true }`로 구별한다. Ordinary_only/Source_only/Full/Status_only, 두 capacity_unobserved_reason을 각각 구성한다. metadata의 누락·중복·fact hash 불일치와 동시 snapshot 교체는 다른 generation의 링크/조건을 승인하지 않아야 한다. HOLD Create/Release 및 replayable history 검증 없는 resume 표본은 해당 게이트의 성공으로 세지 않는다.

## §6 이행 순서와 열린 결정

1. §1의 main SHA와 안전 fallback의 바이트 차이를 함께 기록하고 전량 경로의 조립 블록·토큰·캐시 기준선을 같은 입력으로 고정하고 격리 픽스처를 만든다.
2. 결과 타입·영수증과 읽기/선택/예산 실패 및 `Capacity_unobserved` fallback의 모델/운영자 표시를 먼저 추가한다. 기존 경로와 새 경로를 shadow로 나란히 계산하고 실제 모델에는 기존 결과만 보낸다.
3. typed 링크·만료 조건·source 재검증을 붙인 선택기를 격리 평가한다. start/resume의 known/unobserved 평가와 정확도 게이트 통과는 전송 전환의 필요 조건이며, 해당 Keeper의 실제 저장본 준비 완료를 대신하지 않는다. projection 상한의 설정값·정책 revision·측정 provenance를 확정하기 전에는 shadow를 유지한다.
4. Keeper별 실제 ordinary/source 저장본을 권위 있게 읽어 revision·내용 해시·전체 fact ID 집합을 고정한다. 기존 memory 쓰기 권한을 가진 주체가 각 fact의 근거를 확인하고 명시적 링크와 `Unconditional | Conditional`을 승인한다. metadata 부재를 Unconditional로 바꾸거나 산문에서 링크·조건을 추출하지 않는다. 승인 주체·fact ID·내용 해시·근거를 기록하고, §3의 불변 bundle과 current manifest CAS로 출판한다. 이것은 새 계약의 최초 채택 절차이며 옛 형식을 읽는 호환 경로나 자동 변환 계층을 새 selector에 추가하지 않는다.
5. 전환 경계는 ordinary/source의 현재 revision·해시·전체 ID 집합과 출판된 bundle을 다시 읽는다. 모든 current fact에 정확히 하나의 승인 metadata가 결합돼 있고 source 재검증·해시·bundle 결합이 성공해야 `Adoption_ready { keeper_id; bundle_revision; ordinary_revision; source_revision; metadata_revision; content_hashes; coverage_fact_ids; approval_refs }` 영수증을 출판한다. 이 영수증은 시간이 아니라 해당 immutable bundle의 권위를 증명한다. 준비 중 fact 추가·교체·invalidation이 있었다면 이전 coverage 영수증으로 전환하지 않고 새 revision 전체를 다시 승인·검증한다. 부분 준비·읽기 실패·CAS 패배·승인 미완료는 `Adoption_pending` 또는 typed 실패이며 기존 전송과 shadow를 유지한다.
6. 실제 전송 전환은 Keeper별 current manifest와 `Adoption_ready`가 같은 bundle을 가리키는지 확인하는 하나의 출판 경계에서만 허용한다. old writer와 새 bundle writer가 동시에 current를 바꿀 수 있게 두지 않는다. 기존 쓰기 경로도 같은 권위 출판 경계에 참여하도록 연결하거나 해당 Keeper의 쓰기 소유권을 명시적으로 새 writer에 이전한 뒤 전환한다. 그 경계에 참여하지 않는 writer의 동시 변경을 배제할 수 없으면 준비 완료를 주장하지 않고 전환하지 않는다. 전환 이후 fact/metadata 변경은 §3의 bundle CAS를 사용한다. 전환 이전 실패 후 재시도는 마지막 authoritative revision부터 재검증하며 저장 성공을 추정하지 않는다. 모든 Keeper를 한 번에 전환하지 않고 미준비 Keeper는 기존 경로를 유지한다.
7. 구 RFC §3.7/§6과 이 문서의 충돌을 해소하고 `keeper_memory_os_recall.mli`의 “never truncates, ranks, or partially injects” 문장을 새 계약으로 교체한다. 문서 병합은 위 준비 영수증·평가 결과·권위 출판 경계의 구현 완료나 실제 전환을 뜻하지 않는다.

전환 admission fixture에는 metadata 없는 실제 형식의 ordinary O1/source S1 저장본, 한 component만 준비된 저장본, 준비 중 ordinary/source fact 추가·내용 교체·source invalidation, manifest CAS 패배, 권한 없는 승인, old writer의 동시 쓰기, 실패 뒤 재시도를 포함한다. 미준비·부분 coverage·다른 revision·배제되지 않은 writer에서는 새 전송이 켜지지 않고 기존 경로의 O1/S1 연속성이 유지되는지 확인한다. 완전한 승인 bundle과 쓰기 출판 경계가 준비되면 Keeper별 전환 영수증이 정확한 ID·해시·revision을 가리키며, 전환 직전 변경에는 옛 영수증을 거절하는지 확인한다. 이 fixture와 실제 Keeper별 준비 영수증을 확인하기 전 rollout 완료로 기록하지 않는다.

열린 결정은 상시 fact 지정 권한, MASC projection 바이트 상한의 설정값·정책 revision·측정 provenance, 링크 없는 fact의 연결 지정 권한, 조회 도구가 오래된 source-bound 내용을 거부하는 정확한 표면, Recall control 경계 밖의 다른 전송 실패를 어떻게 복구할지다. Recall control 미전달 때 dispatch 보류는 위에서 확정한 안전 계약이다. 이 Draft는 이 값들을 확인 없이 확정하지 않으며 runtime 변경이나 배포 효과를 주장하지 않는다.

추가 admission fixture는 selector 호출 계수를 기록한다. 최소 템플릿보다 작은 known ceiling은 호출 0회·projection_ref 없음·fact projection 미전송과 withdrawal control 전달을 요구한다. admitted Selected/Unavailable/Budget_overrun은 결과 확정 뒤 계산한 digest를 같은 길이 슬롯에 채우며, 치환 전후 길이 동일·최종 payload와 주소 재계산 일치·같은 입력 resume의 byte-identical 결과를 검증한다.

추가 resume 안전 fixture는 (1) 같은 deterministic 입력을 두 번 선택하면 receipt-free 결과/본문은 같고 edge가 서로 다른 운영자 receipt_id를 붙이는지, (2) ordinary가 건강하고 source metadata 한 행만 손상되면 Component_inconsistent Source와 Selected ordinary가 함께 남으며 전역 실패는 Unavailable인지, (3) ordinary/링크/Task/Goal/자극/가용성/용량 정책 각각의 단독 변화가 새 projection을 전달하는지 확인한다. (4) Task A에서 Active였던 fact가 링크가 맞지 않는 Task B 전환 뒤 만료된 resume은 이전 body/Active_condition의 적용 권한이 새 scope로 끝나고 typed lookup이 Expired를 반환해야 한다. (5) 유효 projection 뒤 Invalid_policy resume은 같은 Memory_os_recall identity의 withdrawal control이 실제 provider 입력에 포함되고 held digest를 교체하는지, 반복 invalid control은 중복 전송되지 않는지, control 전달 실패는 모델 dispatch 없이 끝나는지 확인한다. 이 fixture를 실행하기 전 held-history 안전성이 검증됐다고 주장하지 않는다.
