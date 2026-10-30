# 복합 조회의 부분 수신

`tui-chat-design` Skill 의 일부다. 정본 파일과 공통 규칙은 그 Skill 의 SKILL.md 를 따른다.

## 복합 조회의 부분 수신

- 실제 반환한 Result에서 typed 관측을 만든다. Runtime 목록/사용량, Board 글/hearth,
  Keeper 목록/Candle의 구성별 수신·실패를 보존한다. 혼합 결과는 partial로 기록하며 전체
  수신·전체 실패로 누르지 않는다. 바깥 roster 오류처럼 구성 결과가 없는 경우는 만들어내지 않는다.
- partial은 received와 별도로 집계한다. 수치는 논리 reader 단위이며 HTTP 호출·Task 완료
  횟수가 아니다. roster 응답의 수신도 fleet 전수 관측이나 해당 데이터의 완전성을 뜻하지 않는다.
- Runtime·Keeper의 구성 결과는 부모 reader가 반환할 때 함께 관측하며 별도 시각을 추정하지
  않는다. Board 글/hearth는 실제 reader의 시작·반환·예외·취소에서 각각 기록한다. 부모가
  반환하기 전에도 받은 구성을 남기고, 부모 중단이 이미 끝난 구성의 결과·시각을 덮지 않는다.
  실제 취소를 받은 interrupted와 종료 시점까지 결과가 없는 unfinished를 구분한다.
- 진행 이벤트는 각 refresh의 atomic 수신함에 먼저 기록한다. 공용 bounded mailbox를 기다리지
  않으며 UI drain·종단 적용·초기 identity 재결속 전에 회수한다. 후속 refresh는 새 수신함을
  소유하고 늦은 worker는 이전 수신함만 쓴다. ticket·authority 검증은 UI 반영 시 유지한다.
  child 시간은 관측 구간이며 unfinished의 끝은 UI 종료 경계다. 실제 worker 종료·순수 HTTP
  시간·paint·입력 가능·작업 완료 증거로 확대하지 않는다.
- 공용 workspace 결과 수신함의 streaming observation도 같은 원칙을 따른다. 원래 등록을
  가진 publisher만 부분 사실을 FIFO로 발행하고 종단에서 등록을 소비한다. 부분·종단은
  같은 FIFO를 쓰며 먼저 주장한 유한 batch와 다음 발행 batch를 섞어 재정렬하지 않는다.
  취소·세션 종료 뒤 발행을 막아도 이미 주장한 batch의 UI 권한은 별도로 확인한다.
  producer의 실제 프로토콜 검증·부분 수신 시각·미도착 의미를 수신함이 대신 만들지 않는다.
- header는 실패한 구성과 받은 구성을 함께 보인다. JSON/log에는 구성별 결과를 남기되 현재
  workspace/read owner·dataset 반영·후속 조회 판단을 바꾸지 않는다. 화면 문구나 배치 검사 대신
  receipt·구성·소유권·종단 상태의 연결을 확인한다.
- Board 글과 hearth 데이터는 같은 요청의 별도 dataset 슬롯을 소유한다. 각 기존 GET의
  workspace precondition·서버 receipt를 유지하며 먼저 반환한 데이터를 형제 조회 전에
  보낸다. 한 쪽 수신·실패는 그 슬롯만 한 번 소비하고 다른 쪽의 결과·오류를 덮지 않는다.
  Board 대기는 남은 슬롯이 있으면 유지하며 실제 collector 종료와 구분한다. navigation은
  두 슬롯 모두 새 owner로 바꾸고, terminal bundle은 아직 반영하지 않은 슬롯만 처리한다.
  기존 글 cursor·초안과 census의 마지막 정상 관측 유지 정책을 보존한다. UI 반영 로그는
  source와 dataset을 구분하며 paint·실측 속도나 원자적 Board snapshot으로 부르지 않는다.
- census는 raw 목록 대신 기존 Fetched view로 미조회·최초 읽기·수신·이전 값과 실패·값 없는
  실패를 표현한다. 진행 여부는 기존 hearth dataset 소유권에서 읽으며 별도 요청 세대나
  타이머를 만들지 않는다. 재조회·실패 중 값은 목록·팔레트·hearth 이동에서 함께 유지한다.
  header·reader index의 전체 수치는 수신 후 census 대기가 없는 경우만 쓰고, 나머지는
  census 줄·팔레트에서 마지막 관측임을 밝힌다. 정상 empty와 조회 실패를 같은 0으로 만들지 않는다.
- terminal이 census 슬롯을 가져갔지만 실제 반영하지 못했거나, 소유 collector가 결과 없이
  끝나면 미수신을 unavailable로 남긴다. 이전 collector가 현재 슬롯을 소유하지 않으면
  새 관측을 실패로 바꾸지 않는다. workspace 철회는 census 값과 후보도 지워 다른 Board
  데이터와 같은 경계를 지킨다. 이 상태·문구는 worker 종료나 paint·속도 증거가 아니다.
- 글 목록도 Fetched 관측 하나에 실제 글과 상태를 함께 둔다. 초기 글 조회 중과 미조회·정상
  empty·실패를 구분하고, 대기는 Board_posts 슬롯에서 읽는다. census 대기를 글 조회로
  표시하지 않는다. 같은 관측을 목록·검색·팔레트·상세 sidebar·키 입력 대상에 쓴다.
  재조회·실패 중 글과 선택·작성 초안을 유지하고 마지막 관측임을 표시한다.
- 상세 응답은 일치하는 글만 갱신하며 목록의 실패·진행 슬롯·순서를 바꾸지 않는다. 새 목록은
  기존 identity 기반 선택 규칙을 사용하고, filtered 목록의 부재로 원본 detail을 닫지 않는다.
  terminal 미반영·소유 collector의 미수신은 목록도 unavailable로 남기며 이전 cleanup은
  새 관측을 낮추지 않는다. 오류 알림의 마지막 발행 기록은 관측과 별도로 두어 내부 미수신
  상태가 같은 오류 알림을 반복 발행시키지 않게 한다. workspace 철회는 목록 후보도 지운다.
- 글 응답은 dispatch에서 고정한 정렬·hearth를 early/terminal 양쪽에 함께 운반한다.
  정상 empty도 그 query와 묶어 저장한다. 필터 변경·실패·상세 갱신이 보존한 글의 출처를
  현재 controls로 바꾸지 않게 한다. 목록/sidebar·팔레트는 query 불일치도 마지막 관측으로
  밝히고 정렬 설명·시간 열·census total은 실제 목록의 query/hearth를 쓴다. 선택 controls는
  요청 조건을 유지한다. query 일치는 formatted 문자열이 아니라 typed sort와 정확한
  optional hearth로 판단한다. metadata는 기존 workspace/refresh/dataset owner를 대신하지
  않으며 미수신은 정상 query 결과가 아니다. 추가 GET·owner 세대·timer·화면 행을 만들지 않는다.
- 글 반영 진단은 실제 반영 함수가 반환한 불변 관측을 early/terminal 로그에 함께 쓴다.
  성공·실패는 원래 응답 query, 반영 당시 요청 controls, 남은 정상 목록 query를 따로 둔다.
  미수신은 delivery query가 없고, 최초 실패는 정상 목록 query도 없다. 정상 empty의 query와
  모두 구분한다. terminal의 남은 소유 슬롯과 workspace admission을 통과한 경우만 missing을
  기록하며 consumed·superseded·거절된 슬롯에 가짜 반영 기록을 만들지 않는다. 진단 JSON은
  제어 입력으로 쓰지 않고 본문·오류 text를 복사하지 않는다. 로그 필드의 소스 구현은 실제
  로그 발생·worker 종료·paint·실측 속도 증거가 아니며 화면 문구 검사를 추가하지 않는다.
- full/navigation dispatch의 context는 원래 요청·현재 opaque owner·예정 Board query를
  함께 보존한다. cold identity가 owner를 바꿔도 원래 query를 현재 controls에서 다시 만들지
  않는다. 미요청 Board의 null intent와 결과 미수신의 null delivery query를 구분한다.
  worker의 early/terminal admission에는 기존 current request를 그대로 쓰고 metadata를
  권한·범위 게이트로 쓰지 않는다. dispatch 로그는 실제 GET 시작이 아니며 rebind는 UI owner
  생성/ack 제안이다. cleanup 로그는 finalizer 밖에 두고 기존 취소·예외 전달을 유지한다.
  시작만 남은 요청은 미완료 관측으로 보존하며 시간 경과로 종료·실패를 추정하지 않는다.
