# Web에서 패키지를 고르고 설정하기

Lane Add-ons 상단의 **Installed packages**에서 설치 ID·패키지·Run·파일 경로를
검색하고, 전체·주의 필요·변경 대기·꺼짐·worker 사용 가능 목록을 고른다.
설치 폼과 설정 편집기는 관측 이력 위에 있으며 기존 이력·수동 attach worker도
아래에서 계속 볼 수 있다.

**Requested activity**는 파일이 요청한 On/Off다. **Application / worker status**는
서버의 적용·정리 판정이며 두 값은 다를 수 있다. Off를 요청해도 정리 실패는
Needs attention이고, 정리가 확인된 `inactive`만 Configured off로 표시한다.
적용 판정이 없거나 목록이 불완전하면 미확인으로 남긴다. File and revisions에서는
원문 revision과 worker 입력의 desired/applied revision을 따로 확인한다.

각 설치의 **Edit TOML**과 **On / off**는 해당 파일의 기존 편집 흐름을 연다.
**Check observation**은 선언 ID·파일·적용 revision·instance·서버 적용 판정이
모두 일치하는 live worker에만 연결한다. 이전 worker나 retained 이력으로 대신
연결하지 않는다. 목록을 새로 읽는 중이거나 실패하면 이전 값은 남지만 이 설치 목록의
Check observation은 Refresh가 성공할 때까지 사용할 수 없다. 아래 worker 상세 표의
수동 Observe 진단은 별개다. Worker attached는 관측 결과의 성공이나
실시간 건강 상태를 뜻하지 않는다.

Monitoring의 Lane Add-ons에서 **Install package**를 연다. Workspace 폴더의
패키지 제목·revision·설명을 보고 Choose를 누르면 manifest와 image 상태를 다시 읽는다.
폴더를 열어 더 깊은 위치로 이동하거나 manifest 경로를 직접 입력할 수 있다.
잘못된 manifest와 읽기 실패는 빈 목록 대신 오류로 표시한다.

설치 ID와 Run ID를 입력하고 패키지가 선언한 필드를 채운다. 배열은 Add/Remove로
편집하며, 중첩 객체도 개별 필드로 입력한다. 선택형 입력과 oneOf 대안은 schema에서
읽는다. 선택하지 않은 optional 필드는 생략하고 false·0·빈 배열과 구별한다.
대안을 바꿔도 각 대안에 입력한 값은 현재 페이지 프로세스 안에서 보존한다.

`binding.sources`가 Lane output을 받으면 같은 Run의 관측된 설치와 output port를
목록에서 고를 수 있다. 현재 적용된 revision과 instance가 일치하는 생산자만 제안하며,
선택은 다음 관측의 성공을 보장하지 않는다. source_id는 새 입력에 붙일 이름이다.
다른 source kind와 snapshot 파일 경로·Fusion/Browser 식별자는 패키지가 선언한
필드로 입력한다. 이 화면이 해당 환경을 만들거나 모든 외부 자원을 검색하지는 않는다.

**Prepare TOML draft**는 로컬 원문 초안만 만든다. 기존 원문 초안을 덮어쓰지 않으며,
Open drafts에서 열린 초안을 전환할 수 있다. 같은 파일 이름의 초안이 있으면 새 이름을
선택하거나 기존 초안을 연다. **Save TOML**을 눌러야 기존 선언 저장 API로 전송한다.
서버의 최종 validation과 충돌 검사 결과가 적용되며 저장 성공과 worker 적용 완료는
별개다. 현재 적용 revision과 정리 상태는 선언 표에서 확인한다.

## 끄고 다시 연결한 결과 확인

설치의 **On / off**에서 activity 초안을 바꾸고 **Save activity**를 누른다.
Off는 선언과 관측 이력을 보존하며 worker 정리를 요청한다. **Read current activity**는
현재 파일과 서버 관측을 다시 읽는다. 저장 직후에는 서버가 이전 파일 revision을
관측하고 있을 수 있으므로 그때는 적용 미확인으로 표시한다.

상태는 서버의 `application` 판정이다. `cleaning`은 정리 대기, `inactive`는 정리 확인,
`starting`은 시작 대기, `applied`는 실행 중인 worker를 뜻한다. 실패·확인 불가와 불완전한
목록은 완료로 표시하지 않는다. worker ID가 없거나 revision이 같다는 사실만으로
정리·시작 성공을 추측하지 않는다.

**Workers with this installation ID**를 펼치면 같은 설치 ID의 worker마다 실제 경로,
instance, incarnation, 설치 revision, 완료된 관측 sequence와 보존된 행 수를 볼 수 있다.
경로를 바꾼 같은 ID의 기록도 포함하지만, 같은 파일에서 ID를 바꾼 이전 소유자의 전체
정리 목록은 아니다. On으로 다시 연결하면 새 incarnation의 관측을 확인한다.
이전 worker의 성공 결과를 새 worker의 결과로 세지 않는다.

`live`와 `retained`는 Runtime의 현재 연결 기록과 보존된 binding을 구분한다.
`live` 자체가 worker 프로세스의 생존을 증명하지는 않는다. retained worker에는 새 Action·Observe를
열지 않으며, 이미 요청한 action의 상태 조회는 원래 identity로 계속 제공한다.
실행 중이라는 상태와 완료된 관측, action receipt의 성공은 각각 별도 근거다.

실제 Docker/MCP worker를 해제·재연결하고 Dashboard에서 확인한 범위와 화면은
[재연결 관측 기록](../evidence/2026-10-21-addon-reconnect/README.md)을 참고한다.

입력은 화면 이동·컴포넌트 재진입·작업공간 왕복 중 보존되지만 브라우저 재시작 후
복구되는 저장소는 아니다. 작업공간 연결이 바뀌거나 재확인이 실패하면 새 preview를
받기 전에는 초안을 만들 수 없다. schema가 바뀌면 새 입력 세트를 열고 기존 값은
Retained package inputs에 보존한다. binding schema가 없는 패키지는 New TOML을 쓴다.

로컬 파일 탐색은 기존 [TUI 탐색](tui-lane-addons.md)과 같은 서버 경계를 사용한다.
조회 시 경로 검사는 동시 filesystem writer를 격리하는 원자적 sandbox가 아니다.

## 설정을 보존하며 켜고 끄기

선언 표의 **On / off**를 열면 현재 파일을 읽고 활동 초안을 보여준다.
스위치를 바꾼 뒤 **Save activity**를 눌러야 저장한다. Off는 선언 파일과 관측 기록을
보존하며 worker 정리를 요청한다. On은 같은 선언을 다시 reconcile 대상으로 만든다.

활동 초안은 원문 편집기의 초안과 독립적이다. 저장은 현재 파일의 root `enabled`
값만 바꾸며 binding·manifest·주석을 보존한다. 다른 저장과 충돌하면 **Reapply activity
only**로 활동 값만 최신 파일에 다시 적용한 뒤 저장한다. 파일이 다른 설치 ID를
가리키거나 잘못된 선언이면 원문부터 고친다.

화면 이동·작업공간 왕복 중 초안은 보존된다. 저장 응답이 유실되거나 durability가
미확정이면 **Read current activity**로 파일과 목록을 다시 읽고, 다시 적용하거나
초안을 버린다. 같은 값이 이미 파일에 있으면 재저장하지 않는다. 브라우저 재시작 후
초안 복구는 제공하지 않는다.

파일 설정과 마지막 inventory 관측, 저장 응답을 구분해 표시한다. Off 저장 성공은
worker 정리 완료가 아니다. 현재 설정 읽기는 한 번의 재조회이며, 제출 revision을
완료까지 지속 추적하는 기능은 별도 후속 작업이다.

활동 저장이 끝날 때는 현재 마운트된 목록에 갱신을 알린다. 저장 중 화면을 나갔다
돌아와도 새 화면이 저장 완료를 받아 목록을 다시 읽으며, 이 갱신이 선택·폼을 초기화하지 않는다.

## 목록 새로고침과 Slice 조회

**Refresh**는 설치 상태와 최신 관측 목록을 다시 읽는다. **Slice**는 입력한 범위의
관측을 고정해서 보여준다. 두 요청은 동시에 진행할 수 있으며, 활동 저장 뒤 자동
새로고침도 진행 중인 Slice를 취소하지 않는다. **Clear slice**는 Slice 조회와 고정된
결과만 지우고 최신 목록으로 돌아간다. 진행 중인 목록 조회는 계속된다.

각 조회의 진행 상태와 오류는 별도로 표시한다. Slice 성공으로 목록 조회 실패가
사라지지 않으며 그 반대도 같다. 실패한 조회는 해당 버튼으로 다시 시도한다.
이전 데이터가 있으면 유지하고, 첫 조회부터 실패한 경우에는 데이터가 없음을 표시한다.
작업공간 전환이나 화면 이탈은 두 조회를 취소하며 이전 작업공간의 늦은 결과를 표시하지 않는다.
