# 입력 주변: 진행줄·준비 미리보기·준비 상세·응답 활동

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 입력 주변 — 진행줄·준비 미리보기·준비 상세·응답 활동

- 현재 대화의 진행 상태는 한 줄로 표시한다. 현재 호출·응답 상태만 남긴다.
  진행 타이머(요청·호출 경과 시간, 무응답 시간)와 누적 도구 목록·런타임 ID는 상세 레이아웃에 둔다.
- 서버 준비 미리보기는 원래 operation의 실행 ID(배치 binding 포함)나 자율 실행의
  정확한 turn reference로만 진행줄에 연결한다. 조회 시점의 상태는 `최근 확인`으로
  표시한다. provider·Tool 활동이 관측된 뒤에는 늦은 준비 조회가 이를 대체하지 않는다.
  Keeper 이름이나 시각만으로 다른 실행의 상태를 빌리지 않는다.
- 자율 journal이 아직 없을 때의 준비는 실제 Owner 슬롯의 `현재 작업` 관측으로
  표시한다. 대기 중인 요청의 접수·실행으로 바꾸지 않는다. 같은 원래 턴의 provider
  관측이 들어오면 journal 이전에 읽은 snapshot도 이 별도 줄로 다시 그리지 않는다.
- `작업 맥락 조회`는 실제 Lane·workspace memory·wiki 조회의 바깥 scope다.
  병렬 분기가 모두 끝났다는 사실과 각 출처가 정상이라는 판정은 구분한다.
- 첫 공통 프롬프트 조립은 원래 writer의 Prompt 준비 관측이다. 후속 Tools별
  재투영을 새 실행 시작이나 이전 준비 상태의 재개로 표시하지 않는다.
- 준비 단계 기록은 같은 writer가 보관한 scope ID와 원래 operation·turn reference로
  상세에 연결한다. provider 활동 뒤 완료된 준비 기록도 현재 진행줄을 되돌리지 않는다.
  중첩된 단계의 시간은 겹치므로 합산해 전체 대기 시간으로 표시하지 않는다.
  scope ID는 writer 안에서만 의미가 있다. 다른 실행의 같은 숫자를 이어 붙이지 않는다.
  live timeline은 실행 중 관측이며 저장된 과거 턴 기록이나 재시작 복구 증거가 아니다.
  펼친 대화 상세의 Keeper만 이력을 요청한다. 미요청 `null`은 확인한 빈 이력과
  구분하고, 전체 Keeper 상태 조회에 이력을 일괄 첨부하지 않는다.
- 선택된 종료 작업의 상세를 펼치면 기존 runtime trace에서 저장된 준비 보고서를
  읽는다. 자율 journal의 원래 turn reference, 직접 요청의 기록된 reply 또는 정확한
  종단 operation의 outcome reference와 실제 batch execution ID로 연결한다. reply와
  operation의 연결이 다르면 어느 쪽도 고르지 않는다. 실패 알림이 저장보다 먼저 오면
  펼친 선택 작업의 operation만 기존 turns 관측 주기에 다시 확인한다. 종단 metadata를
  확인한 뒤에는 연결이 없는 경우에도 이 추가 조회를 끝낸다. 연결을 추정하지 않는다.
  보고서 UUID마다 scope 번호를 별도로 읽으며, 저장 당시 active는 `기록 당시 미완료`다.
  부분 조회·지원하지 않는 기록·중복 보고서·조회 실패를 빈 이력이나 성공으로 바꾸지 않는다.
  이 정보는 상세 진단이며 현재 진행줄을 바꾸지 않는다. 선택·저널 revision·workspace가
  바뀌면 이전 응답을 분리하고, 같은 저널 revision의 완료된 읽기는 재사용한다.
  같은 Keeper의 명시 재조회는 이전 요청 capability를 폐기하되 같은 원본 target의 마지막
  성공 관측을 남긴다. 재조회 대기·진행·실패를 구분해 표시하고 이전 기록을 최신으로
  확인한 것처럼 그리지 않는다. 다른 Keeper의 이력 새로고침은 이 읽기를 폐기하지 않는다.
  숨긴 상세의 완료는 원래 선택에만 보관하고, 새 실행·revision·workspace는 빌리지 않는다.
  조회 범위의 지원하지 않는 이벤트·잘못된 저널 행·잘못된 JSON 행은 별도 종류로 보존한다.
  잘못된 행은 선택 턴에 귀속할 수 없으며, 조회 범위 수와 반환 행 수를 실패 작업 수로 합치지
  않는다. 제외된 준비 보고서의 실제 해석·연결 거절 이유를 상세에 남기고 단일 행으로 정제한다.
- 준비 상세 GET도 `launch_workspace_json_read`와 공통 `get_json`을 쓴다. 로컬 authority·
  read epoch·identity·endpoint를 확인하고 실제 GET에 expected roots를 붙인다. 2xx와 304의
  서버 영수증 검증·캐시 갱신은 호출 fiber가 소유하며 별도 identity GET을 먼저 보내지 않는다.
  기존 target의 journal/revision·Turn_ref·operation 연결은 그대로 검증한다. JSON과 순수 report
  해석만 공통 CPU 경로에 넘기고 worker에서 workspace binding·HTTP/cache·선택을 바꾸지 않는다.
  `keeper.preparation.decode_wait`는 pool 대기·해석·반환 관측이며 순수 CPU·paint·유용한 작업
  완료 시간이 아니다. source 비교와 미실행 복합 시나리오는
  `docs/audits/2026-10-19-tui-preparation-workspace-admission.md`를 따른다.
- Lane·공유 메모리·Wiki 확인의 시간은 풀 대기와 취소 정리를 포함한 호출자 대기다.
  순수 IO 시간이라고 표시하지 않는다. 출처 조회 실패는 `조회 불가`이며 Tool 실행
  권한 거절과 다르다. world 준비 완료도 모든 출처가 정상이라는 판정이 아니다.
- 모델 응답 종료 이벤트가 오면 응답 활동 표시를 끝낸다. 개별 본문 조각이 끝나면 아직 열린
  Text·Thinking 조각 중 마지막으로 관측한 조각의 활동을 표시한다. 조각이 모두 닫혀도 전체 모델 응답이
  끝났다는 뜻은 아니다. Keeper 턴과 대기 중 도구는 계속 진행될 수 있다.
- 이어서 처리하기를 기다리는 요청은 진행줄을 그리지 않는다. 다음 실행이 시작되면 진행줄이 돌아온다.
- 같은 실행을 진행줄과 `기존 작업 처리 중`으로 중복 표시하지 않는다.
- 다른 Keeper의 실행과 `/interrupt <다른 이름>`은 입력 주변에 표시하지 않는다.
  Keepers 목록·Activity에서 관측하고 제어한다. 추적 중인 요청은 삭제하지 않는다.
- 전송 결과 미확인, 중단 실패, 관측 실패, 승인 질문은 기본 화면에서도 보인다.
  `Attention`은 기본 대화에서 상세를 접어도 남는다.
