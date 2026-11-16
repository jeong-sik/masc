# Librarian 선언 교체 후 미소비 입력 이어가기

연결: #51278, 병합된 RFC #51317, [Farm 계획](2026-11-12-agent-farm-plan.md)의 E8/TLJ-S02 선행 작업.
최초 기준 소스는 `606e16f5ce8b5c69ad9d18e82f6bf076aaf7f13d`다. 별도 native stack의 네 층을
확인한 로컬 main `4a8a9920776af876caa358d509db39ba7c0a670d` 위로 함께 올렸다.
네 patch는 `git range-diff`에서 같았다. 이후 main에 추가된 floor 회귀의 닫힌 match에도 새 outcome을 반영했다.
아래 고정 head 기록은 rebase 전 각 검토 범위이며, 최종 head·파일 해시는 작업 artifact에 따로 남긴다.

2026-11-16 사용자는 이전 요청을 끝내고 미소비 입력을 새 설정에서 다시 만드는 방식을 선택했다.
읽기 위치를 그대로 두고 다음 pass가 입력을 다시 고른다. 새로 도착한 자료가 함께 포함될 수 있다.
이후 별도 질문에서 사용자는 RFC §9.2의 history `cut`도 종료 증거를 남긴 뒤 새 요청으로 만드는 방식을 선택했다.
모델 요청이 한 번 더 전송될 수 있음을 포함한 결정이며, `raised`와 floor의 불명확한 결과까지 넓히지 않는다.

## 첫 단위: host가 아직 시작하지 않은 요청

- 설정 파일만 바뀐 상태는 `Not_now`다. 설치·package·tool이 같은 새 선언과 정확히 하나의 준비된 worker를 확인한 경우에만 `Declaration_replaced`가 된다.
- Exact의 원본 identity·기존 terminal·실행 proof 복구가 먼저다. 확정된 답과 시작 표시가 있는 요청의 결과는 그대로 보존한다.
- 현재 실행할 시도가 아직 시작되지 않았고 새 선언이 준비됐으면 host가 `Not_allowed`를 저장한다. host 기록에는 `Dispatch_veto_replaced`를 마지막 determining attempt로 남긴다. 그 앞에는 요청을 끝내지 않은 `Deferred` 기록만 올 수 있다.
- 소비자는 `Retained_declaration_replaced`라는 host 전용 사유를 읽는다. worker가 돌려주는 final에는 이 사유를 넣지 않는다. 같은 설명 문자열의 일반 `Not_allowed`는 교체 권한이 아니다.
- worker 응답과 host 복구가 같은 사유를 남긴다. 원본 request·schema·digest에 묶인 host 기록과 소비자 progress의 사유를 확인한다. 그 뒤 worker가 사라지거나 설정이 되돌아가도 일반 입력 실패로 바뀌지 않는다.
- history와 floor는 교체로 끝난 요청의 source·Memory·외부 ACK를 옮기지 않는다. 새 실패 범위를 만들지 않고 다음 pass를 깨운다. 앞서 실제 입력 실패로 좁혀 놓은 범위는 보존한다.
- floor의 교체 step은 기존 정리 경로로 옮긴 뒤 다음 pass를 깨운다. 알 수 없는 결과를 교체 사유로 만들지 않는다.

독립 리뷰에서 발견한 두 항목을 반영했다. `Memory_replaced`를 받는 실제 capacity callback fixture의 닫힌 match를 추가했고,
종결 직후 worker 재조회 실패가 일반 refusal로 바뀌던 경계를 host의 저장된 사유로 바꿨다.

첫 단위 `436c5d39cd99d7d9f59f58446a8b5f9452fe37cd`의 32개 파일을 두 독립 세션이 읽었다.
두 세션은 그 head와 위 범위에서 추가 P0/P1/P2를 찾지 못했다. 정식 GitHub 승인은 아니다.
이 단위는 지금 package가 원래 output과 요청 schema를 계속 허용하는 선언 교체를 다룬다.
현재 package의 capability 철회는 기존 권한 검사에서 일반 `Not_allowed`가 되는 순서를 유지한다.

## 다음 단위: 접수 전 history 요청

`Captured`·`Admission_wait`는 본문을 읽기 전에 지금 준비된 목적지를 관찰한다.
교체 관계가 확정되고 원래 Exact 기록과 실행 proof가 모두 없을 때만 `Before_dispatch`로 끝낸다.
그 증거는 scope·요청 ID·본문 digest·원래 summary와 당시 두 목적지를 묶는다.
저장된 증거를 읽을 때는 그 값들만 검증하므로 rollback 뒤에도 종결은 유지된다.
worker가 아직 준비되지 않았으면 요청을 그대로 기다리며, 실행 기록을 발견하면 교체를 거부한다.

다른 요청과 연결되지 않고 Gate나 사전 준비 기록도 없는 history 요청은 inventory에서 본문을 읽지 않는다.
이미 끝난 교체 증거를 확인한 다음 전체 lineage 검사와 물리 owner·operator fence·실행 기록 부재를 다시 확인하고
기존 Store의 엄격한 archive 경로로 옮긴다. 새 원본은 그다음에 미소비 source를 다시 읽는다.
이 경로는 본문이 읽히지 않아도 끝내고 정리할 수 있다. 연결된 요청과 floor의 접수 전 처리는 아직 이 범위 밖이다.

실제 Runtime fixture에 두 접수 전 상태의 손상된 본문, 준비 전 대기, 종결·archive 사이 rollback,
새 요청만 한 번 실행되는 경우와 기존 host 실행 기록 때문에 교체를 거부하는 회귀를 추가했다. 실행은 미실행이다.

접수 전 history 단위는 `bd05129f62322f6c001f61c7738b7eef289e5133`으로 고정했다.
두 독립 세션이 그 9개 파일과 관련 Store·Exact·lineage 소스를 읽고 범위 안에서 P0/P1/P2를 찾지 못했다.
8개 OCaml 파일은 문법 검사만 통과했다. 정식 GitHub 승인이나 동작 증거는 아니다.

## 세 번째 단위: 접수 전 floor step

floor의 `Captured`·`Admission_wait`도 같은 목적지·원본·실행 부재 증거를 사용한다.
step owner는 교체 종결을 일반 모델 거절과 다른 반환값으로 전달한다. chain은 이를 입력 크기 실패나
읽지 못한 메시지의 hole로 바꾸지 않고 기존 교체 반환값을 사용한다.
상위 execution은 기존 교체 step 정리 경로를 거쳐 다음 pass를 깨운다. 앞서 실제 크기 실패로 좁힌 범위는 유지한다.

floor step의 본문은 기존 chain 복구가 읽는다. 이 단위는 floor 본문 손상 복구를 약속하지 않는다.
이미 답한 앞 step의 Gate와 Memory 반영은 원래 선언의 권한을 따르므로 별도 범위다.
실제 Runtime fixture에 접수 전 두 상태의 준비 전 대기·교체·rollback과 chain이 hole 없이 교체를 반환하는 회귀를 추가했다.

floor 단위는 `9bda4e4dab8e2e635ccdb0e65397f172cda52159`으로 고정했다.
두 독립 세션이 7개 파일과 관련 경계를 읽고 범위 안에서 P0/P1/P2를 찾지 못했다. 6개 OCaml 파일은 문법만 확인했다.

## 네 번째 단위: 새 선언이 허용한 연결되지 않은 history Cut 해소

연결되지 않은 원본의 `Cut` refusal은 보존한다. 설치·package·tool이 같은 새 선언의 준비된 worker를 관찰하면
별도 `Refusal_settled` fact에 원본 binding·summary·두 목적지와 원래 Cut 증거를 묶어 저장한다.
이는 입력을 버린 capacity settlement와 다른 strict domain kind다. 일반 progress는 후속 처리 사실만 담고,
소비자가 그 뜻과 권한을 검증한다. 이 fact는 Memory·읽기 위치·외부 ACK를 옮기지 않는다.

저장 전과 복구 때 모두 원래 Exact request·schema·digest로 host 기록과 완료 proof를 복구하고,
여전히 `Cut`일 때만 이 결정을 인정한다. 검증된 `Rejected Execution`은 닫힌 전이상 `Judged`나 Commit에
도달한 적이 없다. owner와 inventory는 같은 저장 증거를 검증하므로 rollback 뒤에도 정리 여부가 갈리지 않는다.
잘못된 증거, 읽기 오류나 다른 host 결과를 일반 거절로 낮추지 않는다.

다음 pass는 기존 strict archive를 거쳐 미소비 입력을 새 ID로 다시 고른다. `cut`이 선언 교체 때문에 생겼다고
단정하지 않는다. 운영자가 새 선언을 준비한 사건을 새 시도의 허락으로 기록한 것이다.
같은 선언, 준비되지 않은 새 선언, `raised`와 floor Cut는 보류한다. 새 원본을 또 해소하려면 선언이 다시 교체돼야 한다.
이는 Farm TLJ-S02 전체의 실행 중단 원인·종료 추적을 구현한 것은 아니다.

실제 로컬 HTTP provider를 기다리던 호출을 취소해 Cut을 만드는 fixture에 준비 전 대기, 별도 종료 증거,
잘못된 저장 증거 거부, rollback 뒤 archive와 새 원본 한 번 실행을 추가했다. Raised 대조 fixture도 추가했다.
모든 회귀는 작성 상태이며 실행하지 않았다.

독립 리뷰에서 Exact 복구가 다른 claim을 만나면 record만 관찰하는 경로를 찾았다.
Cut 해소는 복구 뒤에도 claim과 관계없이 원본 완료 proof를 따로 읽고 binding을 검증하도록 보강했다.
실제 claim을 보유한 채 proof 파일을 읽지 못하게 만드는 대조 회귀를 추가했다.
또한 접수 전 linked history가 bodyless archive의 범위를 벗어나는데도 종결될 수 있던 틈을 막았다.
predecessor가 있는 접수 전 요청은 기존 publication 절차를 유지한다. 아래층만 단독으로 넣지 않고 전체 native stack을 검토한다.
연결된 Cut도 현재 operator resolution의 완료 추적이 새 root를 잇지 못하므로 이번 producer에서 제외했다.
원본 index를 검증하는 proof helper도 연결된 Cut 증거를 거부한다. 그 요청은 기존 대기를 유지하며 후속 lineage 작업이 남는다.

## 다섯 번째 단위: 연결된 요청과 운영자 해소의 완료 추적

연결된 history의 접수 전 상태와 Cut도 같은 종료 증거를 사용한다. 종료된 원본은 그대로 두고,
기존 full replacement intent에 새 요청의 ID와 전체 내용을 저장한 뒤 게시한다. 부모가 정확히 그 요청을
다시 읽고 ACK하기 전에는 실행하지 않는다. 중간에 끊기면 같은 intent를 복구하며 새 ID를 더 만들지 않는다.

이 연결은 일반 refusal이나 `Settled`라는 판정만으로 허용하지 않는다. 접수 전의 strict 선언 교체 증거,
typed host 선언 교체 결과, 별도 해소 증거를 가진 Cut만 허용한다. payload 검증은 원본 binding과 종료 증거를
검사하고, 소비자와 host의 실제 lineage 검증은 원래 Exact 기록과 실행 proof까지 확인한다.
이 순수 검증을 preflight도 공유한다. generic progress는 Rejected에서도 불변 게시 intent와 ACK만 담으며,
한 거절에 subdivision과 replacement를 함께 남기거나 게시 뒤 종료 근거를 덧붙이는 것은 거부한다.

연결된 새 요청은 원래 source·읽기 위치·외부 ACK 대상을 유지하고 current Memory만 다시 캡처한다.
종료만 저장된 leaf를 다음 연결 대상으로 고르므로 일반 fresh root로 빠져 운영자 해소와 분리되지 않는다.
당시 종료 증거의 A→B는 역사적 권한이다. 새 intent를 만들기 전 rollback하면 지금 준비된 A로 새 ID를
만들 수 있고, intent를 만든 뒤에는 그 목적지를 바꾸지 않는다.

운영자 해소 조회는 종료된 부모의 확인된 replacement를 따라간다. 새 descendant가 실제로 Finished에
도달한 뒤 기존 range receipt를 해소 intent에 저장해야 완료다. 종료 사실이나 child 게시만으로 완료하지 않는다.
operator fence 아래의 연결 기록은 기존처럼 보존한다. 별도의 suffix archive는 이번 범위에 넣지 않았다.
일반 replacement chain의 중단된 archive 복구도 새 Rejected 부모의 종료 권한과 전체 source 파생을 다시 확인한다.

Runtime·Exact·operator resolution fixture에 접수 전/Cut 각각의 종료 직후 rollback, intent만 저장된 중단,
child 저장 후 부모 ACK 전 중단을 다루는 여섯 시나리오를 작성했다. 같은 ID 복구, ACK 전 host 실행 거부,
source 보존, 실제 새 요청의 Memory receipt와 원래 해소 완료 연결을 확인하도록 했다.
linked Raised에 대한 순수 검증 거부와 서로 다른 후속 게시의 상호 배제도 추가했다. **실행은 미실행이다.**

## 여섯 번째 단위: 설치 전 검사도 종료 증거를 확인

실제 consumer는 접수 전 종료를 정리하기 전에 원래 Exact 기록과 실행 proof가 모두 없는지 확인한다.
기존 preflight는 `Before_dispatch`면 Exact를 읽지 않아, 유효한 실행 중 기록이 있어도 그 consumer 검사를
통과한 것으로 볼 수 있었다. Cut의 별도 종료 증거도 일반 `Outcome_unknown` 확인만으로는 typed 원인을 구분하지 못했다.

공통 `ended_with`가 순수 종료 증거와 명시적인 읽기 port를 함께 검증한다. 실제 저장소 reader와 preflight가
같은 규칙을 쓴다. 접수 전에는 기록·proof가 없어야 하고, host 종결은 원래 typed 사유와 독립적으로 읽은
최신 proof를 모두 확인한다. Exact 검사가 제거할 기록을 ‘보낸 적 없음’의 근거로 쓰지 않는다.
검사는 읽기뿐이며 Runtime·모델·Memory·큐 ACK를 호출하지 않는다.

Runtime fixture에 strict 접수 전 종결, 남아 있는 유효한 host 기록, Exact가 제거할 손상 기록, record 없는
손상 proof, 증거 복원 후 정상 재개를 추가했다. 실제 Cut fixture에는 같은 delivered outcome을 가진 Raised
host 기록과 잘못된 별도 종료 증거를 preflight·inventory가 함께 거부하는 대조를 더했다. 실행은 미실행이다.

## admission의 추가 정책 결정

사용자는 미소비 후보 묶음에 이미 보류 판정된 후보와 선언 교체로 끝난 후보가 함께 있으면,
**미소비 묶음 전체를 새 요청으로 다시 판단**하도록 선택했다. 추가 모델 호출이 생길 수 있음을 포함한다.
기존 committed candidate receipt와 ACK로 완료된 후보는 제외한다. 저장된 종료 후 rollback한 혼합 묶음도
그 종료 사실을 새 frontier의 한 번의 재생성 근거로 쓰며, 새 root의 소유권이 옛 근거의 반복 사용을 막아야 한다.
실행 결과가 불명확하거나 Memory 반영이 끝나지 않은 후보의 권한으로 넓히지 않는다.
이 결정은 다음 일곱 번째 소스 단위에 반영했다. 동작 검증은 남아 있다.

## 일곱 번째 단위: admission 전체 미소비 묶음 이어가기

접수 전 admission도 원래 host 기록·proof가 모두 없는지 확인한 뒤 두 선언을 묶은 종료 증거를 남긴다.
이미 접수됐지만 provider를 시작하지 않은 요청은 서버 guard의 typed 선언 교체 사유를 보존한다.
일반 거절이나 admission Cut·Raised, 아직 Memory에 반영하지 않은 Accepted 답은 새 root 권한이 아니다.
종료를 새로 저장했을 때만 기존 큐를 깨운다. 종료 자체는 Memory 반영이나 후보 ACK가 아니다.

실행 요청보다 먼저 저장된 part에는 가짜 capture를 만들지 않는다. owner의 실행 scope 전체를 엄격히
복원하고 그 part를 가리키는 실행이 없음을 확인한다. 새 선언 또는 저장된 종료 사실이 있으면
완료 receipt와 ACK로 빠진 후보를 제외한 pending 묶음 전체에 새 root를 저장한다.
기존 보류 후보도 함께 재판단하며, 종료 후 rollback해도 옛 ID를 다시 실행하지 않는다.
새 root가 이전 root 전체를 소유하므로 같은 종료 사실을 반복해서 새 요청의 근거로 쓰지 못한다.

새 root 목적지는 당시 저장된 목적지로 검증한다. part와 execution은 의미 설정을 비교하고 각각의
전체 원본·digest·후보 binding을 보존한다. 주석만 바뀐 source revision으로 정상 실행을 거부하지 않는다.
runtime과 preflight는 같은 전체 frontier·후보 보존·identity·종료 검사를 사용한다.
과거 part와 실행은 새 active leaf가 모두 실제로 Finished에 도달하고 전체 후보 receipt·ACK가 확인된 뒤
기존 forest closure로 함께 정리한다.

Runtime·실제 HTTP fixture에 실행 없는 root의 게시 후 재개, 손상 실행 inventory의 부재 증명 거부,
주석 변경, Captured·Admission_wait의 종료와 rollback, 접수됐지만 provider가 시작되지 않은 host 종료,
Deferred와 종료된 sibling의 전체 묶음 재판단·rollback·closure, admission Cut 보존을 작성했다.
**이 회귀는 실행하지 않았다.** 독립 소스 리뷰에서 발견한 source revision 비교 불일치와 서버 guard의
누락을 수정했다. 기존 preflight가 일부 후보를 잃은 supersession을 넘기던 차이도 순수 검사 공유로 막았다.
정상 root의 후보 묶음·digest를 일관되게 줄인 대조 fixture에서 preflight와 runtime이 같은 후보 보존
검사를 적용하도록 작성했다. 이 대조를 포함한 새 회귀는 아홉 경우이며 모두 미실행이다.

## 여덟 번째 단위: 이미 받은 답의 Gate 이어가기

추가 질문에서 사용자는 **받은 답을 보존하고 Gate를 이어가는 쪽**을 선택했다.
history·floor step·admission은 실제 원래 host 답과 proof를 다시 확인한다. Gate의 새 질문을
실행하기 전에 같은 물리 Keeper·Memory epoch와 원래 설치·package·tool의 준비된 worker를 확인한다.
선언 revision만 달라졌다는 이유로 답을 버리거나 Librarian 요청을 다시 보내지 않는다.

Gate의 판정 목적지와 원본 질문·부모 결속은 기존 journal이 계속 검증한다. 이미 받은 판정은 복원하고,
전송 중이거나 취소로 불명확해진 판정은 그대로 남긴다. 새 Gate 권한을 답 없는 원본의 실행 권한으로
사용하지 않는다. 기존 접수·provider 전송·새 part 실행의 semantic revision 검사는 유지한다.

실제 Runtime fixture에 history의 worker 준비 전 대기와 새 설정 뒤 원래 답 반영, floor의 받은 답 보존,
각 경로의 다른 설치 거부를 작성했다. admission에는 Gate가 없던 경우, 이미 캡처한 미실행 Gate,
실제 HTTP 전송 중 취소된 Gate, 다른 설치의 네 경우를 작성했다. 여덟 회귀 모두 미실행이다.
history 두 경우의 Gate에는 흡수 항목이 없고, floor 두 경우는 실제 원래 응답을 복원한 뒤
`Judgment.judge`와 새 권한 함수의 경계를 직접 다룬다. 이 네 경우를 Gate HTTP 전송이나
전체 floor chain의 동작 증거로 세지 않는다. admission 세 경우는 별도 Gate HTTP fixture를 쓰며,
다른 설치 사례는 전송 0건을 기대한다. 취소 사례는 그 fixture의 취소 원인만 처리한다.
이 단위의 문법·독립 소스 검토 기록은 `artifacts/farm-librarian-answered-gate-20261116/`에 따로 둔다.

## 아홉 번째 단위: 실행 전 종료와 설치 검사

실행 전 종료가 저장된 뒤 archive 전에 중단하면, 연결과 Gate가 없는 history 원본은
런타임이 본문 없이 정리할 수 있었다. 설치 검사는 소비자에게 묻기 전에 본문을 읽어
같은 원본을 거절했다. 이 차이를 단일 소비자 검사 경로에서 맞춘다.

공통 검사는 먼저 엄격한 record metadata를 넘기고 소비자가 필요할 때 원래 본문을 복원한다.
history의 namespace·index·저장된 선언 교체 증거가 맞고, predecessor·자식 참조·Gate 참조·fence·준비·대체
intent가 모두 없을 때만 본문 없이 검사한다. Exact identity로 기존 파일 판정 경로를 읽어
host record와 proof가 실제로 모두 없음을 확인한다. 검사에서 지울 record는 부재 증거가 아니다.
다른 상태와 namespace, 연결된 원본과 Gate 소비자, Candle과 기본 검사도 본문 검증을 유지한다.

설치 검사는 현재 선언이나 worker를 요구하지 않고 저장된 종료만 판정한다. source·Memory·외부 ACK와
종료 record를 바꾸지 않는다. 실제 정리의 owner·source-root·fence 재확인과 CAS는 기존 runtime이 맡는다.
따라서 worker 비활성화나 설정 되돌림으로 종료된 ID가 다시 실행되지 않는다.

기존 Runtime fixture에 Captured·Admission_wait의 손상·누락 본문, 비활성화·설정 되돌림 뒤 설치 검사,
Gate 참조와 연결된 종료의 본문 요구, 손상 host record와 record 없는 proof의 거절을 추가했다.
**문법 검사만 실행했으며 이 회귀 시나리오는 미실행이다.**

## 확인한 범위

변경 OCaml 파일의 `ocamlc -stop-after parsing -c`와 `git diff --check`를 확인한다.
파일별 해시와 결과는 각 단위의 `artifacts/farm-librarian-*/`에 둔다.
독립 소스 리뷰는 그 리뷰가 지정한 head와 diff에만 적용한다.

회귀 코드를 추가했다. 실제 Runtime·Server Exact fixture의 새 worker 준비 전후, 종결 뒤 worker 비활성화·rollback,
입력·읽기 위치·외부 ACK 보존, 같은 RPC에서 받은 사유, worker final과 host 기록 불일치,
typed marker의 순서와 codec, 이전 입력 실패 유무를 다룬다.
**타입 검사·Dune 빌드·회귀 실행·CI·설치·운영 복구는 미실행이다.** 문법과 소스 검토로 동작 성공을 주장하지 않는다.

## 남은 범위

- 연결된 history의 접수 전 상태·Cut 해소는 위 소스 변경과 작성한 회귀의 범위이며, 실제 타입·회귀·운영 검증은 남는다.
- isolated history의 실행 전 종료는 아홉 번째 소스 단위에서 설치 검사와 맞췄다. 실제 기동 검증과 연결된 요청의 본문 손상 복구는 남는다.
- floor 본문 손상 복구는 남는다. 이미 받은 답의 Gate는 여덟 번째 소스 단위로 이으며 실제 반영 검증은 남는다. CLI가 전송 직전 guard에서 멈추는 L1b는 이미 #51343에 있으므로 중복 구현하지 않는다.
- `raised`·floor Cut·admission Cut는 별도 상태다. history Cut 해소는 위의 별도 운영자 결정과 증거 조건에 한정한다.
- 따라서 #51278 전체, TLJ-S02와 Farm 전체가 끝났다고 판정하지 않는다.
- native stack 발행은 이전 시도에서 GitHub CLI 인증을 얻지 못했다. 연결된 GitHub 읽기 도구의 인증과 CLI/native stack 발행 인증은 다르다.
