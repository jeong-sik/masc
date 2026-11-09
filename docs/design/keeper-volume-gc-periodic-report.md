# Keeper Volume GC Periodic Report (`#50580`)

## 개요 및 배경

- **이미 착지한 선행 범위 (`#50572`)**: `masc_sandbox_volume_gc`의 이름 지정 삭제(`execute=true` + 첫 보고에 보인 Keeper 이름 목록 전달)와 TUI `V` 두 번 누르기 확인 흐름은 `#50572`에서 `main`에 먼저 병합됐다.
- **이 문서와 `#50580`의 범위**:
  - 서버가 부팅 후 첫 maintenance pulse(기본 60초) 뒤, 그리고 이후 6시간마다 `masc_sandbox_volume_gc`를 보고 전용(`Keeper_volume_gc.Report_only`, `execute=false`)으로 실행한다.
  - 주기 보고는 볼륨을 절대 삭제하지 않는다.
  - 마지막 주기 보고 시각과 결과(`reported` / `skipped` / `failed`), 회수 후보 수와 Keeper 이름을 `/api/v1/dashboard/tools` 봉투의 `sandbox_volume_gc_report` 필드로 내보내고, TUI 「전체 도구」 창의 `V` 줄 바로 아래에 표시한다.
  - 실제 볼륨 삭제는 여전히 운영자가 TUI에서 `V`를 두 번 눌러 첫 번째 `V`의 새 보고에 나타난 후보 이름들로만 수행한다.

## 간격과 비용 근거

- **주기 (`Server_sandbox_volume_gc_report.report_interval_sec`)**: `21600.0`초 (6시간).
- **첫 실행 지연**: 서버 부팅 중 다른 초기화와 겹치지 않도록 부팅 직후가 아니라 첫 maintenance pulse(기본 60초) 뒤에 첫 보고를 실행한다.
- **보고 1회당 실행 작업 (`Keeper_volume_gc.apple_keeper_volume_gc`)**:
  1. Apple Container 준비 확인: `container list -a` 1회 (`Keeper_volume_gc_host.ready`)
  2. 전체 볼륨 목록 조회: `container volume list` 1회
  3. 볼륨이 있는 Keeper마다 컨테이너 참조 확인: `container list --all` 1회
  4. 등록되지 않았고 참조 컨테이너도 없는 Keeper 작업 볼륨마다 `container run --rm` claims helper microVM 1회 실행
- **실측 비용 (`2026-11-06`, `bin/masc_tui_volume_gc.mli`)**:
  - Keeper 29명(목록 조회 1회당 0.05~0.18초), helper 3회(1회당 1.41~1.60초) 기준 보고 1회에 약 6~8초 소요.
  - 회수 후보는 Keeper가 은퇴할 때만 생기므로 6시간 간격(하루 4회 + 재시작 후 1회)이면 매 pulse마다 helper microVM을 띄우지 않고도 후보 수를 최신으로 유지할 수 있다.

## 저장 및 관측 경계

- **서버 메모리 단일 슬롯**:
  - `Server_sandbox_volume_gc_report`는 프로세스 메모리(`Atomic.t`)에 마지막 주기 보고 결과(`Keeper_volume_gc_periodic.t option`) 하나만 유지한다.
  - 새 파일이나 영구 저장소를 만들지 않으며, 서버 재시작 시 초기값은 `None`(봉투 JSON `null`)이고 첫 maintenance pulse 뒤에 채워진다.
  - 매 패스마다 서버 로그 1줄을 남긴다 (`reported`: Keeper 수·후보 수·후보 이름, `skipped`/`failed`: 사유).
- **보기 전용 불변식**:
  - 주기 보고 기록은 관측 전용이며 삭제 대상을 결정하지 않는다.
  - 운영자가 TUI에서 `V`를 눌러 삭제할 때는 주기 보고 캐시가 아니라 첫 번째 `V`가 실행한 최신 보고의 후보 이름 목록을 두 번째 `V`에 전달한다.

## 전달 경로와 코덱 (`Keeper_volume_gc_periodic`)

- **HTTP 봉투 필드**: `GET /api/v1/dashboard/tools` 응답 봉투에 `sandbox_volume_gc_report` 필드를 추가한다 (`Server_dashboard_http_runtime_info.attach_live_tools_projections`).
- **TUI 조회 경로**: TUI 「전체 도구」 창은 기존 `Tools_inventory_read` 경로로 같은 봉투를 읽으며, 별도 HTTP 라우트나 추가 폴링 요청을 만들지 않는다.
- **공유 코덱 (`Keeper_volume_gc_periodic`)**:
  - 서버 직렬화(`to_json`)와 TUI 역직렬화(`of_json`)가 동일한 모듈을 사용한다.
  - `Tui_decode_tools.decode_tool_snapshot`이 `ts_volume_gc_report` 필드로 디코드하며, 필드가 없거나 `null`이면 `None`, 스키마가 어긋나거나 `executed=true`인 응답이면 디코드 오류(`Error`)로 거절한다.

## 실패 및 건너뜀 처리

- **Apple Container 미지원/미실행 호스트 (`Skipped reason`)**:
  - Linux 호스트나 Apple Container 서비스가 중지된 macOS에서는 `Keeper_volume_gc_host.ready` 단계에서 `Skipped`로 기록하고 이후 볼륨 명령을 호출하지 않는다.
- **이미지 미해결·목록 조회 실패·예외 (`Failed reason`)**:
  - claims 이미지(`base`)를 찾지 못하거나 볼륨 목록 조회가 실패하면 `Failed`와 사유를 기록하고 다음 6시간 주기에 재시도한다.
  - `Eio.Cancel.Cancelled`는 그대로 재발생시켜 종료 경로를 보존하고, 그 외 예외는 `Failed`로 격리해 maintenance 루프가 멈추지 않게 한다.
- **삭제 불가 구조**:
  - `Keeper_volume_gc_periodic.observe`는 내부에서 `Keeper_volume_gc.Report_only`만 전달하므로 주기 보고 경로에서는 삭제 요청을 구성할 수 없다.
