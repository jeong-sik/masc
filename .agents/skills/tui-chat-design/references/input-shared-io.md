# 입력 주변: 시작·workspace 재확인, Keeper 생성, 상세 활동·Logs, live-context, 응답 JSON 파싱 worker

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 입력 주변 — 시작·workspace 재확인, Keeper 생성, 상세 활동·Logs, live-context, 응답 JSON 파싱 worker

- 시작·workspace 재확인은 Keeper 메타데이터와 Work·agent 관측을 별도 공유 I/O job으로 읽는다.
  UI 스레드에서 전체 디렉토리를 읽고 initial identity 확인 응답을 늦추지 않는다.
  두 source는 대기 슬롯·데이터 타입·캐시 잠금·실패 상태를 따로 소유한다. Work 대기·실패는
  Keeper 입력 가능 여부나 목록을 바꾸지 않는다. 채팅 자동 열기·Task handoff는 Keeper
  메타데이터를 기다리고, 반영 뒤 초안·중단 상태를 보존한 채 후속 처리를 다시 확인한다.
  로컬 결과는 source·workspace authority·base path·요청 소유권을 함께 확인하고 한 번만 반영한다.
  source별 숫자 요청 번호가 같아도 서로 대신 쓸 수 없다. suspension은 두 worker 취소와
  읽기 소유권 회수를 모두 수행한다. 같은 경로로 돌아와도 이전 결과가 새 요청을 끝내거나
  덮지 않는다. 실패는 미조회·정상 빈 목록과 구분한다. 로그는 source와 요청 번호를 함께
  연결하고, worker 관측 구간을 키 응답·화면 표시 시간이나 작업 완료와 구분한다.
- 생성·Keeper 제어 결과·채팅 종료·명시적 새로고침에서도 로컬 디렉토리를 UI가 직접
  다시 읽지 않는다. 생성 완료는 Keeper 메타데이터만, Work도 바뀔 수 있는 나머지 경로는
  두 source를 따로 갱신한다. cadence는 진행 중 읽기를 공유한다. 갱신 중 들어온 명시적
  요구는 후속 읽기 하나로 합치고, 현재 읽기를 취소·재시작하지 않는다. 현재 결과는 관측으로
  반영하되 새 요구를 소비하지 않는다. 성공·실패 모두 후속 읽기를 이어간다. 요청별 취소
  소유자는 workspace 회수·clear와 실제 worker 정리에 쓰며 늦은 정리가 후속 소유자를 지우지 않는다.
  같은 workspace 재조회 중에는 마지막 관측과 초안을 유지한다. 새 Keeper별로 생성 뒤 요청한
  source-demand revision을 보존하고 이를 포함한 읽기와 실제 이름 관측이 모두 있어야 입력을
  연다. 오래된 읽기의 부재는 생성 중 채팅을 닫지 않는다. 여러 생성 대기는 서로 덮지 않는다.
  이 revision은 요청 순서이며 시간·turn·token 한도가 아니다. 확인된 삭제는 기존 identity
  기반 선택 규칙으로 반영한다. metadata 캐시는 실제 파일 경로, archive 캐시는 경로·mtime·
  size에 묶어 다른 workspace의 같은 이름·stat 값에서 관측을 빌리지 않는다.
  Work 반영은 입력·Task handoff wake를 대신하지 않는다. 로그에서 poll/refresh를 구분한다.
  cache lock은 실패·취소 전에 해제하고 원래 예외를 재전달한다. 실제 worker 정리는 공통
  executor 소유이며, 취소 요청 로그를 worker 종료 증거로 바꾸지 않는다.
- Keeper 생성은 editor가 반환한 뒤 workspace 확인과 create-only POST를 소유 fiber에서
  수행한다. 확인 중·전송 중·종료 상태는 원래 요청에 묶고, 전송 전 중단·서버 거절·
  생성 확인·결과 미확인을 구분한다. POST 진입 뒤 취소·연결 실패는 결과 미확인이며
  자동 재전송하지 않는다. 종료 결과를 요청 전용 atomic 칸에 먼저 게시한 뒤 취소 가능한
  알림을 보낸다. 공용 큐가 가득 차도 기존 drain은 게시된 결과를 회수하며, 종료 중인
  worker가 취소를 막은 채 큐 공간을 기다리지 않는다. 원래 workspace가 회수돼도 영수증과 미해결 선언문은
  세션 상태에 남기되 새 workspace의 읽기·입력 권한으로 쓰지 않는다.
  성공은 자기 초안만 지운다. 여러 생성·편집의 초안과 초점은 별도 owner이며,
  후속 사용자 입력이나 대기 중 입력이 있으면 늦은 성공이 대화를 강제로 열지 않는다.
  현재 workspace의 확인된 생성만 metadata 갱신을 요청하고, 실제 입력은 기존
  Keeper별 freshness barrier와 이름 관측을 기다린다. 미해결 선언문은 다음 editor
  진입에서 복구할 수 있으며 재시작 복구를 증명하지 않는다. 로그는 선언문을 싣지
  않고 요청 시작·phase 반영을 기록한다. 이 시각은 화면 표시·네트워크 RTT가 아니다.
- Keeper 상세의 활동 요약과 Logs는 같은 `Masc_tui_fetched` 관측을 사용한다.
  입력 handler와 cadence는 파일을 읽지 않고 원래 workspace authority·base path·Keeper·
  물리 행 범위에 묶인 I/O 요청을 보낸다. 응답은 원래 read scope와 ticket도 일치해야
  반영한다. 같은 대상의 poll은 진행 중 읽기를 공유하고, 명시적 refresh는 후속 읽기
  하나로 모은다. 실패해도 요청한 후속 읽기는 이어간다. 새 대상은 이전 값을 빌리지 않는다.
  활동 요약이 없는 다른 detail tab은 metrics를 요청하지 않는다. Info의 명시적 새로고침도
  같은 source 요구를 사용한다. 화면을 떠나면 진행 중 읽기를 retire하고 마지막 관측만 보관한다.
  같은 대상의 재조회·실패는 마지막 snapshot을 남기고 읽는 중·마지막 관측·실패·부분 행
  진단을 구분한다. 미조회·조회 실패를 정상 빈 기록이나 활동 0으로 표시하지 않는다.
  workspace 확인이 끊기면 소유 읽기를 retire하고 마지막 관측만 보여준다. 재확인 뒤에는
  새 read scope에서 다시 읽는다. 늦은 worker 정리는 다음 요청의 취소 owner를 지우지 않는다.
  읽기는 canonical metrics 위치를 직접 열며 writer 디렉터리·설정·캐시를 준비하지 않는다.
  기존 물리 행 범위와 공통 executor 정책은 유지한다. 로그의 시작·반환·반영 시각은
  worker 순수 IO·키 응답·화면 표시 시간과 다르다. 화면 문구/행 순서 검사는 만들지 않는다.
- 선택된 Keeper의 live-context도 공유 I/O worker에서 읽는다. UI는 메타데이터 반영·행 이동·
  상세 열기에서 이 저장소 읽기를 기다리지 않는다. 소유권은 workspace read scope·base path·
  Keeper·trace와 요청 세대에 묶는다. 채팅에서는 roster 커서가 아니라 대화 대상이 소유한다.
  같은 소유자의 재조회 중에는 마지막 관측을 유지하고, 실패하면 그 관측과 실패를 함께 남긴다.
  선택·trace가 바뀌면 이전 읽기를 취소 요청하며, 실제 worker 정리는 공통 executor가 소유한다.
  새 대상·workspace에는 이전 값을 빌려주지 않는다. source 재확인 주기와 명시적 새로고침만
  같은 key를 다시 읽고, 매 frame에서 완료·실패를 재시도하지 않는다. 진단은 시작·worker 반환·
  UI 반영 관측을 나누며, 미완료 시작도 남긴다. 이 시간은 키 응답·화면 표시·모델 진행이 아니다.
- 응답 본문의 JSON 파싱과 큰 목록의 타입 변환은 공유 CPU worker에서 수행한다.
  worker에는 불변 입력과 순수 해석만 넘긴다. HTTP 요청·credential 교체·ETag 캐시
  갱신·workspace 확인·화면 데이터 반영은 기존 호출자가 소유한다. 늦게 끝난 해석이
  새 화면의 읽기 소유권을 빌리지 않으며, 비동기 해석 완료도 화면 표시나 작업 완료를
  뜻하지 않는다. runtime-event의 `decode_wait`는 풀 대기와 결과 전달을 포함한다.
