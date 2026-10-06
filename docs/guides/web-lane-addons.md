# Web에서 패키지를 고르고 설정하기

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

입력은 화면 이동·컴포넌트 재진입·작업공간 왕복 중 보존되지만 브라우저 재시작 후
복구되는 저장소는 아니다. 작업공간 연결이 바뀌거나 재확인이 실패하면 새 preview를
받기 전에는 초안을 만들 수 없다. schema가 바뀌면 새 입력 세트를 열고 기존 값은
Retained package inputs에 보존한다. binding schema가 없는 패키지는 New TOML을 쓴다.

로컬 파일 탐색은 기존 [TUI 탐색](tui-lane-addons.md)과 같은 서버 경계를 사용한다.
조회 시 경로 검사는 동시 filesystem writer를 격리하는 원자적 sandbox가 아니다.
