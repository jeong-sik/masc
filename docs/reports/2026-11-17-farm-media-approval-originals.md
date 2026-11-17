# Farm 미디어 원본과 승인 기록 연결

미디어 원본을 보관한 뒤 Gate가 승인을 만들었지만 승인 ID 저장에 실패할
수 있다. 이때 Gate를 다시 호출하는 것은 조회가 아니다. 기존 제출 경로는
대기 중이거나 아직 소비하지 않은 승인만 재사용한다. 이미 거절되거나 소비된
요청에는 새 승인을 만들 수 있다.

이번 변경은 이 경계를 연결할 저장·조회 기능을 추가한다. 실제 미디어 reader,
승인 replay와 외부 호출은 아직 활성화하지 않는다.

## 원본에 남기는 사실

기존 request progress에 두 사실을 추가했다. `Approval_intended`는 원본 ID와
본문 digest, 완전한 Gate 요청을 묶는다. `Approval_wait_retained`는 그 intent의
digest와 input hash에 실제 관측한 승인 ID를 연결한다. 둘 다 `Captured`에서만
한 번 기록할 수 있으며, 이후 실행·판정·정산 상태로 넘어가도 보존한다.

기존 phase와 다른 producer의 dispatch 규칙은 유지한다. intent나 대기 링크는
승인 또는 실행 허가가 아니다. 최초 자동 허용에는 가짜 승인 ID를 만들지 않는다.
미디어 원본을 복원할 때는 승인 intent를 그 원본에서 다시 계산해 비교하고,
dispatch 사실 앞에 해당 intent가 있는지 확인한다. 다른 도메인의 의미를 이
검사로 대신 판정하지 않는다. Librarian의 실행 transcript는 이 새 승인 사건을
자신의 실행 사건으로 받아들이지 않는다.

Gate 입력은 원본 ID·본문 digest·예약된 실행 ID를 가진 내용 주소 참조다. 완전한
입력 바이트, reader 선언과 준비된 실행 요청은 그 digest가 가리키는 기존 원본에
있다. 현재 설정이나 새 turn으로 입력을 다시 만들거나 큰 data URI를 승인 큐에
복제하지 않는다. 예약된 실행 ID는 프로세스가 시작됐다는 증거가 아니다.

정확한 요청 codec은 workspace, Keeper, operation, canonical input과 hash,
origin, task, goal, continuation channel을 보관한다. 큐와 비교할 때는 기존
논리적 origin 정책을 유지하고, 보관 값에는 물리 turn 증인도 남긴다. 생성 시
중첩된 origin/channel을 실제 디코더로 검증하므로 저장한 값이 복원되지 않는
상태를 반환하지 않는다. 기존 fingerprint 함수의 scalar 규칙은 바꾸지 않았다.
공용 경로 함수도 실제 `~/` 입력에만 HOME을 읽어 절대 경로 codec의 환경 조회를
없앴다. 파일시스템 정규화기를 새로 만들지는 않았다.

## 같은 승인을 정확히 찾고 보존하기

새 조회는 설치가 완료되고 읽기 상태가 정상인 workspace의 큐를 한 lock에서
읽는다. pending, rejection, unconsumed approval, consumed approval과 저장된
replay 결과를 구분한다. 여러 일치 항목은 ambiguity로 반환하며 하나를 고르지
않는다. 알고 있던 ID가 없거나 다른 요청을 가리키면 그 상태와 다른 일치 ID들을
함께 반환한다. missing은 retirement의 증명이나 새 승인 생성 허가가 아니다.
소비됐지만 결과가 없는 승인도 재실행 허가가 아니다.

설치 시 완료된 승인 기록을 정리하는 경로는 이제 live original의 intent와
승인 ID도 참조자로 본다. ID 저장 전 intent가 정확히 일치하는 결정도 보존한다.
Keeper metadata가 없어도 live original의 참조가 먼저다. 원본 metadata를 읽지
못하면 미참조로 판단하지 않고 후보를 보존하면서 retirement 오류를 보고한다.

원본 metadata는 해당 설치 관측에서 한 번 읽어 공유한다. 결정이 없으면 이
읽기도 생략한다. 이 검사는 generic Owner metadata와 progress만 사용한다.
미디어 본문 복원이나 효과 허가가 아니며, Gate와 Media Owner 사이에 순환
의존성을 만들지 않는다. 새 journal, cache 또는 만료 규칙은 없다. 실행 시간이나
전체 설치 비용이 줄었다는 실측은 하지 않았다.

## 검증 범위와 남은 연결

다섯 suite에 17개 사례를 추가했다. strict codec과 중첩 origin 거부, 실제 원본
저장·복원, phase 전이 뒤 승인 기록 보존, Librarian transcript의 다른 사건 거부,
실제 승인 큐의 모든 상태·중복·known-ID 불일치, 재설치 시 intent/link 보존을
다룬다. 승인 큐 사례는 실제 queue와 generic Owner 저장소를 사용한다. 이것을
미디어 reader가 실행됐다는 증거로 해석하지 않는다.

전체 파일 구문 파싱과 독립 소스 검토는 타입·링크·테스트 실행 증거와 구분해
기록한다. 이번 사례의 실행 결과는 아직 없다. `media_read` 식별자는 추가했지만
실제 producer가 없는 동안 host replay 가능 작업으로 광고하지 않는다.

다음 연결에는 원본과 intent를 저장한 뒤 정확한 기존 승인을 조회하는 producer,
실제 one-shot grant 확인, dispatch 전 저장, 완전한 SDK 반환값의 보관, 실제
replay가 필요하다. 그 다음 최종 선택된 history와 정확한 outbox snapshot에만
외부 실행을 연결한다. reader 선택·memo·cache보다 이전 원본을 먼저 확인하고,
여러 원본의 승인 대기와 unknown 상태를 각각 보존해야 한다. 실제 DOCX의
SSH/Guest 변환과 재시작 후 중복 실행 방지는 별도 실행 증거가 필요하다.
