# TUI에서 TOML Lane Add-on 설치·연결하기

같은 서버를 사용하는 `masc-tui --base-path <base-path> --port <server-port>`를 연다.
입력창에서 `/addons`를 보내거나, `:` 팔레트에서 `go Lane Add-ons`를 선택한다.
이 화면은 패키지 설치·연결·횡단 관측을 다룬다. `go Lanes`는 standalone 실행 Lane 목록이다.

## 패키지와 설치 선언

패키지의 `lane.toml`은 image·command·world outputs·Skills를 정의한다.
CI에서 준비한 이미지를 MASC의 Docker에 로드하고 패키지 파일을 서버가 읽을 위치에 둔다.
화면의 `TOML installations`에 나온 설정 디렉터리 바로 아래에 설치 `.toml`을 저장한다.
기본 위치는 `<base-path>/.masc/config/lane-addons/`이며, 화면에 표시된 실제 경로를 따른다.
`n` → 직접 하위 파일명 `dos-stats.toml` → Enter로 편집기를 열고 아래 선언을 작성한다.
먼저 `addons/dos-world/install.toml`로 `dos-demo` 설치를 준비하고, manifest 경로를 실제 경로로 바꾼다.

```toml
id = "dos-stats"
run_id = "dos-demo"
manifest_path = "<path-to-output-statistics>/lane.toml"
[binding]
[[binding.sources]]
source_id = "guest"
kind = "lane_output"
installation_id = "dos-demo"
output_id = "guest"
selection = "latest_completed"
```

`manifest_path`의 상대 경로 기준은 설치 선언 파일이다. 연결할 설치들은 같은 `run_id`를 쓴다.
생산자가 공개한 named output을 지정한다: MSX `frames`, DOS `guest`, 통계 `statistics`.
새 패키지를 연결할 때 패키지별 MASC MCP 도구·서버 dispatcher·TUI 메뉴를 추가할 필요가 없다.

## 편집과 적용 확인

| 키 | 동작 |
| --- | --- |
| `n` / `E` | 새 파일 이름 입력 / 선택한 선언 또는 초안 편집: `$EDITOR` 우선, 없거나 공백이면 `$VISUAL`; 둘 다 없으면 설정 필요 |
| `s` | 초안을 명시적으로 저장. 편집기 종료만으로 서버에 저장하지 않는다. |
| `l` | 현재 서버 원문과 revision을 읽고 내 초안을 보존 |
| `u` / `U` | 초안을 유지해 현재 revision을 저장 기준으로 선택 / 현재 원문으로 초안 교체 |
| `r` | 설치 상태 재조회: desired/applied revision·오류·인스턴스 phase 확인 |
| `Tab`, `j/k`, `J/K` | 설치·인스턴스·관측 행 선택 전환, 항목 이동, 내용 스크롤 |

저장 영수증은 파일 저장 결과다. 기존 재조정이 worker를 적용하며, TOML 저장은 이미지를 만들지 않는다.
잘못된 선언은 `E`로 원문을 고친다. 충돌 시 `l`로 비교한 뒤 `u` 또는 `U`를 선택하고 `s`로 저장한다.
`Esc`로 문서를 닫거나 화면을 나가도 초안은 현재 TUI 프로세스 안에 남는다.
인스턴스에서 binding·공개 output·Skills 경로를 확인한다. bundled Skills는 기존 읽기 전용 카탈로그에 등록된다.
Keeper는 카탈로그의 정확한 reference로 기존 `keeper_skill`에서 본문을 읽고, `file`로 참조·스크립트를 읽는다. 읽기는 실행과 별개다.

## 관측·행동·근거·제거

화면 안의 `:`는 Add-on 명령 입력이다. `o`는 선택한 인스턴스를 관측하고 `r`은 상태를 읽는다.
`:slice {"run_id":"dos-demo"}`로 여러 Lane을 가로질러 읽는다. `since`·`until`은 Unix 초, `lane_id`는 표시된 정확한 Lane ID다.
행동을 제공하는 인스턴스의 `action_schema`와 incarnation을 확인한 뒤 명시적으로 제출한다.
`:act {"instance_id":"<ID>","expected_incarnation":"<incarnation>","request_id":"<new-ID>","action":{"kind":"increment"}}`
`increment`는 DOS 예다. 다른 패키지는 표시된 스키마를 따른다. `t` 또는 `:action {동일 요청 JSON}`은 상태만 조회한다.
queued·running·confirmed·failed_before_effect·outcome_unknown과 executor·근거를 함께 확인한다.
Instances에서 소유자를 선택하고 Rows에서 그 인스턴스 행을 Space로 선택한 뒤 `e`로 근거를 고정한다. 직접 지정은 `:evidence {"instance_id":"<ID>","row_ids":["<row-ID>"]}`, 선택 전달은 `keeper_name`을 추가한다.
`d` 또는 `:detach <instance-ID>`는 해당 설치와 소유 worker를 제거한다. DOS 설치 제거는 그 DOS 머신도 종료한다.
통계·관측 패키지를 제거해도 별도 생산자는 계속 진행하며 과거 관측·근거는 남는다. `Esc`·`q`는 화면만 닫고, 기존 owner 작업 취소나 Keeper 필수 검토를 추가하지 않는다.
