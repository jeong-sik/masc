# TUI 화면 목록과 정리 기준

최상위 이동은 **운영 · 작업 · Keeper · 기능·플러그인 · 워크스페이스 · 시스템**이다.
[정보 구조 기준](OPERATOR-INFORMATION-ARCHITECTURE.md)에 따라 묶는다.
이 목록은 화면을 찾는 지도다. 소스에 있는 화면과 진입 경로를 정리했으며 실행 화면을
검증했다는 뜻은 아니다. 제품 방향은 [운영자 홈 결정](../../rfc/RFC-tui-measured-operator-home.md)과
[제품 계약](../../constitution.xml)을 따른다.

## 화면 23종

`surface` 생성자 기준이다. Keeper의 여섯 모드는 한 생성자에 속한다.
Tab 순환과 상단 선택 표시는 `surface_ring`과 `surface_ring_family`가 정한다.

| 소속 | 화면 / 생성자 | 하는 일과 상세 | 진입 경로 |
|---|---|---|---|
| 운영 | Operations / `Overview` | 운영자 결정과 대화 진입 | 첫 화면, Tab |
| Work | Goals·Tasks / `Planning` | 목표·측정·Task, 완료 조건·증거·Candle 지급, 생성·전이 | Tab, `t`로 Goals/Tasks |
| Work | Requests / `Approvals` | 보류한 도구, Gate, 운영자 승인, Keeper 질문·답변 | Work `p`, 팔레트 |
| Work | Task Review / `Verification` | 제출한 증거, 자동 검증 진행, 운영자 승인·반려 | Work `v`, 팔레트 |
| Work | Task Verdicts / `Harness` | 기록된 판정, 근거·계약·Goal 연결 | Work `v`, 팔레트 |
| Keepers | Keepers / `Keepers` | 목록·상세·대화·로그·호출·runtime 선택 | Tab, 목록 Enter, 상세의 키 |
| Keepers | Memory / `Memory` | 저장소 건강, Keeper별 사실 목록·원문·필터 | 팔레트, Keeper 문맥 |
| Keepers | Schedules / `Schedules` | 예약 목록·회차·실행 이력, 생성·편집·취소 | 팔레트, 예약 참조 |
| Keepers | Fusion / `Fusion` | 모델 패널 실행 목록·상세·새 실행 | 상세 Runs, 팔레트 |
| Keepers | Changes / `Changes` | Keeper가 남긴 파일 변경과 기록된 diff | 목록·상세 `f`, 팔레트 |
| 기능·플러그인 | Channels / `Connectors` | 전송 채널 목록·바인딩 | 팔레트 |
| 운영 | Usage / `Metrics` | Plan·Keepers·Calls·Trend, 계정 범위·관측 범위·운영 telemetry | 운영 `m`, 팔레트 |
| 작업 | Board / `Board` | 게시글 목록·본문·댓글·투표, 새 글, 토론 후속 글 | 작업의 게시판 링크, `: go Work / Board` |
| Workspace | Repositories / `Repositories` | 저장소 목록·전체 문맥·Keeper 활동 | Tab |
| Workspace | Code / `Code` | 파일 트리·본문·메모·이력·diff·LSP | 저장소 Enter, 팔레트 |
| System | Settings / `Config` | 설정·적용 상태, 설정 탭 7개와 원문 | Tab |
| System | Runtime / `Runtime` | lane 후보 순서·전체 runtime·상세·모델 설정 | System `9`, 팔레트 |
| 기능·플러그인 | Features / `Lanes` | 제공 기능·관측 상태·설정 적용·실행 이력·측정 상세 | Tab, Runtime `p`, 팔레트 |
| 기능·플러그인 | Clients / `Clients` | 접속한 Keeper·MCP client·fiber, 선택 상세 | Runtime `c`, 팔레트 |
| 기능·플러그인 | Resources / `Resources` | MCP 리소스·산출물 목록과 원문 | System `s`, 팔레트 |
| 기능·플러그인 | Tools & Skills / `Tools` | 아래 도구 탭 5개, 비동기 요청·연결 Task 상세 | System `t`, 팔레트 |
| System | Activity / `Acting` | Keeper 턴·호출 사건과 증거 | System `A`, 팔레트 |
| System | Logs / `System_logs` | 서버 로그·분류·수준·원문 | System `L`, Activity `l`, 팔레트 |

같은 사건을 다루더라도 원천과 권한이 다른 화면은 구분한다. Task Review는 현재 제출,
Task Verdicts는 이미 기록된 판정이다. Activity는 실행 사건, Logs는 서버 로그다.
Changes는 기록된 Keeper 편집이고 Workspace의 Git changes는 현재 Git 작업 트리다.
Runtime은 시스템의 모델 배치다. 기능·플러그인은 관측 상태와 제공 기능을 먼저 보여 주고,
Plugins 상세에서 선언·적용·현재/보존 워커를 구분한다.
Keeper 상세의 Automation과 Channels는 해당 Keeper의 별도 읽기 탭이다.
전체 Schedules·Connectors 화면으로 이동하는 진입점으로 세지 않는다.

## 하위 화면

| 소속 | 목록 |
|---|---|
| Keeper 모드 | 목록, 상세, 대화, 로그, 호출, runtime 선택 |
| Keeper 상세 탭 11개 | Info, Items, Sandbox, Settings, Secrets, GitHub, Identity, Channels, Automation, Runs, Terminal |
| System 설정 탭 7개 | runtime.toml, models, params, prompts, presets, themes, voice |
| Tools 탭 5개 | 유효 도구, 비동기 요청, Skill 활성화, Skill 사용, 전체 카탈로그 |
| Runtime | lane 후보, 전체 runtime, 선택 runtime 상세·후보 선택·모델 편집 |
| Features | 기능 목록, inventory 상세, lane 실행 목록·원문, 측정 상세 |
| Usage | Plan, Keepers, Calls, Trend, 계정 범위 선택·telemetry |
| Board | 글 목록, 글·댓글, 작성 초안 |
| Work | Goal 목록·상세, Task 목록·상세·이력, 검증 제출·판정 상세 |
| Workspace | 저장소 상세·활동, Git changes·diff, Code 파일·이력·메모 |

## 겹쳐 여는 화면

아래 화면은 별도 Tab 정류장이 아니다. 입력을 받는 폼과 조회 창도 포함한다.

| 묶음 | 화면 |
|---|---|
| 탐색 | 명령 팔레트, Keeper 탐색, 도움말·검색, 기능 안내, About |
| 코드 탐색 | 파일 찾기, 파일 내용 검색, branch·worktree 목록, LSP 이름·위치 선택 |
| 대화 | 대기 큐·메시지 상세, Agenda, 질문 답하기, 원래 요청·Task 생성 상세 |
| 대화 근거 | Context inspector·원문, 도구·patch 상세, 링크·이미지·음악 미리보기 |
| 음악 작업대 | `/music` 라이브러리·작업대, `/music midi` MIDI 편집기, `/score` 악보 화면. 별도 프로세스에 터미널을 넘기고 종료 후 TUI로 복귀 |
| 설정·복구 | Keeper 생성·삭제 기록, 계정 로그인, runtime·모델 폼, 음성 설정·녹음 |
| Browser | 브라우저 선택, 탭·페이지·영역·스크린샷, Keeper가 읽은 페이지 이력 |
| Play | 공유 DOS 초대·링크 카드, DOS 관전, MSX 관전·제어·게임/디스크 선택 |
| Plugins | 현재 설치·연결, 설정·instance 상세, 보존한 실행·Results·증거 |
| 화면 크기 | 입력을 보존하는 터미널 크기 안내 |

## 정리 기준

- 같은 동작의 별칭은 검색어로 묶는다. 기본 팔레트에 같은 목적지를 두 번 나열하지 않는다.
- 빈 팔레트는 최상위 여섯 목적지부터 보여 준다. 상세 화면·Keeper·Task·글·계정·설정 변경은
  검색으로 찾는다. 새 키나 별도 메뉴 체계를 추가하지 않는다.
- 화면 이름에는 소속을 붙인다. Work의 검증과 System의 runtime을 독립 최상위 기능처럼 나열하지 않는다.
- Candle 지급은 Goal 상세에서 한다. Goal 목록만 여는 명령을 지급 화면처럼 부르지 않는다.
- 전송 상태·권한 상실·실패·미확인 관측·원본 증거는 남긴다. 반복 개수·고정 설명·중복 단축키는 줄인다.
- 화면의 문구·행 순서·배치는 테스트 계약으로 고정하지 않는다. 요청·저장 상태·결정이 검증 대상이다.

정본: [화면·모드 타입](../../../bin/masc_tui_types.ml),
[탐색 소속](../../../bin/masc_tui_surface_navigation.ml),
[화면 선택](../../../bin/masc_tui_render.ml),
[겹친 화면 렌더러](../../../bin/masc_tui_render_overlays.ml),
[팔레트](../../../bin/masc_tui_palette.ml), [사용 가이드](../../TUI-GUIDE.md).
