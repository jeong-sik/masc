# TUI에서 TOML Lane Add-on 설치·연결하기

같은 서버를 사용하는 `masc-tui --base-path <base-path> --port <server-port>`를 연다.
`Lanes` 화면에서 `o` 또는 `A`로 Lane Add-ons를 연다. 둘은 같은 화면을 열며, Lanes 하단 키 줄이 `o / A`로 함께 적는다.
입력창의 `/addons`나 `:` 팔레트의 `go Lane Add-ons`로도 연다.
`Lanes`는 Exact·Browser·기계·패키지를 한 목록에서 읽는다. Add-ons를 먼저 열지 않아도 선언과 설정 오류가 나온다. 선언 행 Enter는 원문을 표시하고 `E`로 편집한다. 수동 설치 행 Enter는 해당 인스턴스를 연다. Add-ons는 패키지 설치·연결·관측·이력의 상세 관리를 담당한다.
`Lanes`의 `d`는 선택한 행의 전체 읽기, `i`는 목록 조회 진단이다. Add-ons 안에서 `i`를 누르면 패키지 설치기를 연다.

## 설정을 남기고 켜기/끄기

선언 TOML 초안을 연 뒤 `Space`로 활성화 값을 바꾸고 `s`로 저장한다.
루트 `enabled`만 바꾸며 주석·다른 설정·작성 중인 초안은 유지한다.
저장 성공은 파일 반영이며 worker 정리 완료와 다르다. `r`로 상태를 읽고
Esc로 초안을 닫아 설치 목록을 본다. 끄기 요청 중인 worker나 정리 실패는
계속 표시한다. 다시 켜면 이전 worker 정리가 확인된 뒤 새 worker가 붙는다.
선언 파일과 보존 관측은 남으며 기존 제거 동작과 구별된다.
[활성화 계약과 부분 읽기](lane-package-activity.md)를 참고한다.

## 설치 목록

Add-ons를 열면 **설치 목록**이 나온다. 설치 선언(TOML)과 실행 인스턴스(worker)가 한 목록에 나란히 놓인다.
머리글은 서로 다른 세 수를 섞지 않는다 — 선언 수, 실행 중 인스턴스 수, 실패한 worker 수.
선언은 `desired/applied revision`, 인스턴스는 `phase`로 상태를 보여 준다. 선언이 있어도 인스턴스가 없을 수 있고, 수동 부착한 인스턴스는 선언 없이도 목록에 나온다.

`j/k`로 항목을 고르고 Enter로 연다. 커서가 가리키는 패키지의 설명으로 할 수 있는 일을 확인하고, 선언 항목의 Enter는 설치 선언 화면, 인스턴스 항목의 Enter는 Add-on 상세 화면이다.
`i`는 패키지 설치기를 열고 `n`은 새 TOML 선언을 쓴다. `r`은 다시 읽는다. 읽기가 오래된 화면은 머리글에 `STALE`을 붙인다.
`D`는 원문 보기(Technical), `f`는 흐름 보기(Flow), `?`는 도움말, `Esc`는 화면을 닫는다.

같은 패키지를 여러 번 설치하면 `panel-a`, `panel-b`, `judge`처럼 설치 이름이
패키지 제목 앞에 나온다. 목록의 `result rows`는 최신 결과 행 수이며 모델 호출 횟수가 아니다.
완료 관측에 결과 행이 없어도 패키지 설명과 입력 범위를 읽을 수 있다.
`Received snapshot coverage · all Add-ons`는 받은 스냅샷 전체의 범위다.
선택한 패키지만의 입력 범위로 해석하지 않으며, 누락 설명과 `2 Links`의 선언을 함께 확인한다.
첫 목록은 현재 워커와 설치 선언을 보여준다. 종료된 워커의 반복 항목은
`Retained history`의 개수로 접어 두고, `h`로 이력 목록을 연다.
이력은 설치 경로·실행·패키지별로 묶으며 각 인스턴스의 결과를 Enter로 열 수 있다.
다시 `h`를 누르면 현재 설치 목록으로 돌아간다. 이력 보기는 설치나 실행을 바꾸지 않는다.
실패한 워커와 정리 중인 워커는 현재 목록에 남아 조치할 수 있다.

## Add-on 상세

목록에서 인스턴스를 열면 그 Add-on의 **상세**가 네 화면으로 나뉜다. 숫자로 바로 이동하거나 `Tab`으로 다음 화면을 연다.

| 키 | 화면 | 읽을 내용 |
| --- | --- | --- |
| `1` | Results | 선택한 결과 본문·표시값을 먼저 읽고, 아래 Activity timeline에서 사건을 비교 |
| `2` | Links | 설정된 입력 → worker → named output 연결과 관측 범위 |
| `3` | Installation | Source·Revision·Instance, 연결된 선언의 Desired·Applied·Issue |
| `4` | Records | 관측 행의 원문 필드와 근거 선택 |

Results에서 `j/k`는 사건을 선택하고 본문을 바꾼다. `>`가 현재 결과를 가리킨다.
패키지는 `interface.presentation`에 설명과 Lane별 표시 필드를 선언할 수 있다.
표시 필드가 선언된 패키지는 Results에서 해당 Lane의 결과만 읽고 이동한다. 공통 보고서 맥락 등 보조 레코드는 `4 Records`에서 원문을 읽고 근거로 선택할 수 있다. 표시 선언이 없는 패키지는 모든 레코드를 결과로 보여준다.
텍스트 본문은 줄바꿈을 유지하며, 선언된 필드가 없으면 unavailable로 표시된다.
입력의 complete와 분석 성공·전달·열람은 서로 다른 상태다. `D`는 원문 좌표와 근거를 펼친다.
Activity timeline에서 같은 시각의 사건도 각각 선택할 수 있다.
`←/→`는 이웃 Lane으로 이동한다. 선택 시각 이후의 첫 사건을 선택하고, 없으면 그 Lane의 마지막 사건을 선택한다.
화면보다 Lane이나 사건이 많으면 선택 위치를 따라 표시 범위가 이동한다. `J/K`로 긴 상세 내용을 스크롤한다.
`●`는 event, `◆`는 value, `↔`는 relation이다. 선택한 셀과 근거로 표시한 행은 별도 표시로 구분한다.

행 간격은 경과 시간이나 실행 길이가 아니다. 빈 셀은 읽어 온 범위에 사건이 없다는 뜻이다.
관측 누락이나 작업 종료를 뜻하지 않는다. Source coverage의 complete·partial·unknown과 함께 읽는다.
Source clock의 domain·value는 원천에서 받은 값이다. 게임 프레임이나 시뮬레이션 시간을 UTC로 바꾸지 않는다.
관계는 명시된 `related_ids`만 표시하며, 현재 slice 밖의 ID는 연결 대상이 보이지 않는다고 표시한다.
Links의 화살표는 선언된 binding이다. 성공한 전달이나 인과관계를 증명하지 않는다.
Links와 `f`의 연결 보기에서는 현재 Add-on의 의존 관계를 층으로 정렬한다.
`Bound external inputs`에서 자료 파일·Fusion run·캡처·Browser 입력이 어느 Add-on으로
들어가는지 확인한다. 파일 경로와 Browser 대상은 실제 binding에 선언된 값이다.
각 층 아래에는 worker 상태와 마지막 완료 관측의 결과 행 수가 표시된다.
관측이 아직 완료되지 않은 경우와 완료됐지만 결과가 빈 경우를 구분한다.
같은 Layer의 항목은 서로에게 입력을 요구하지 않으며, 다음 층은 앞선 생산자의 출력을 받는다.
입력이 확인되지 않거나 순환하는 항목은 `Layer unavailable`로 표시한다.
현재 설치 선언이 가리키는 인스턴스만 생산자로 연결하며, 보존된 이력의 binding에서는
실제 생산자 incarnation을 임의로 복원하지 않는다. Layer 숫자는 연결 구조이며 실행 순서·성공 기록이 아니다.
연결 화면의 공유 영수증은 이 TUI 세션에서 마지막으로 받은 근거 보존·전달 응답이다.
선택한 worker 전체의 공유 이력이나 Keeper 열람을 뜻하지 않는다. 영수증이 없으면
이 세션에서 받지 않았다고 표시하며, 실제로 공유한 적이 없다고 단정하지 않는다.
근거 영수증에는 보존 주체의 instance ID와 선택한 행 ID가 함께 표시된다.
특정 Keeper에게 전달한 경우 대상 이름은 성공·실패·결과 미확정 상태에도 남는다.
Keeper의 `accepted`와 Broadcast의 `committed`는 읽기·활용을 뜻하지 않는다.
상세 설계와 검증 항목은 [TUI Lane 경험 설계](../design/tui-lane-experience.md)를 참고한다.

## 설치된 항목 사용하기

상세에서 `o`는 선택한 인스턴스를 관측한다. `a`는 패키지가 광고한 행동 목록을 열며, `j/k`와 Enter로 한 번 실행한다.
대상 ID·incarnation·새 요청 ID는 TUI가 채운다. 열린 메뉴는 원래 대상에 묶이며
인스턴스나 스키마가 바뀌면 다시 선택해야 한다. 같은 요청의 상태는 기존 refresh 간격으로
조회하고, 종단 응답 후 관측 목록을 갱신한다. `t`는 수동 상태 조회이며 재실행하지 않는다.

행동 메뉴는 JSON Schema의 enum/const와 필수 object 필드로 닫힌 값을 열거하고
기존 서버와 같은 validator로 검사한다. 특정 패키지 이름이나 행동 이름을 추측하지 않는다.
필수 자유 입력이 있는 스키마는 `A`로 명령 입력을 열고 `act {…}`를 제출한다. `D`는 원문 보기이며
원문 스키마·revision·연결·근거를 펼친다. 기본 화면에도 오류와 불완전한 입력은 표시된다.
상세의 `Tab`은 Results → Links → Installation → Records 순으로 화면을 바꾼다.
설치 TOML 원문은 설치 목록에서 편집 가능한 선언을 골라 `E`로 편집기를 열어 확인한다.

## 패키지와 설치 선언

패키지의 `lane.toml`은 image·command·world outputs·Skills를 정의한다.
CI에서 준비한 이미지를 MASC의 Docker에 로드하고 패키지 파일을 서버가 읽을 위치에 둔다.
설치 `.toml`은 서버가 읽는 lane-addons 설정 디렉터리 바로 아래에 둔다. 기본 위치는 `<base-path>/.masc/config/lane-addons/`이며(`MASC_CONFIG_DIR` 설정 시 `<resolved config root>/lane-addons/`),
화면의 `TOML installations`나 선언 항목의 Source가 가리키는 실제 경로를 따른다.
보고서 연결 예제로 `n` → 직접 하위 파일명 `fusion-report.toml` → Enter를 누른다.
먼저 [격리 Fusion 예제](../examples/lane-addons/fusion-compute/)의 `panel-a`,
`panel-b`, `judge` 선언을 실제 자료 경로와 모델 경로에 맞게 준비한다.
아래 보고서도 같은 `run_id`를 쓰고 manifest 경로를 실제 경로로 바꾼다.

```toml
id = "fusion-report"
run_id = "assembled-fusion"
manifest_path = "<path-to-fusion-report>/lane.toml"
[binding]
[[binding.sources]]
source_id = "judgement"
kind = "lane_output"
installation_id = "fusion-judge"
output_id = "result"
selection = "latest_completed"
```

`manifest_path`의 상대 경로 기준은 설치 선언 파일이다. 연결할 설치들은 같은 `run_id`를 쓴다.
생산자가 공개한 named output을 지정한다: Fusion 계산 `result`, 보고서 `report`.
MSX `frames`, DOS `guest`, 통계 `statistics`도 같은 연결 계약을 사용한다.
새 패키지를 연결할 때 패키지별 MASC MCP 도구·서버 dispatcher·TUI 메뉴를 추가할 필요가 없다.

## 편집과 적용 확인

| 키 | 동작 |
| --- | --- |
| `n` / `E` | 새 파일 이름 입력 / 선택한 선언 또는 초안 편집: `$EDITOR` 우선, 없거나 공백이면 `$VISUAL`; 둘 다 없으면 설정 필요 |
| `s` | 초안을 명시적으로 저장. 편집기 종료만으로 서버에 저장하지 않는다. |
| `l` | 현재 서버 원문과 revision을 읽고 내 초안을 보존 |
| `u` / `U` | 초안을 유지해 현재 revision을 저장 기준으로 선택 / 현재 원문으로 초안 교체 |
| `r` | 설치 상태 재조회: desired/applied revision·오류·인스턴스 phase 확인 |
| `Tab`, `j/k`, `J/K` | 인스턴스 상세에서 다음 화면 / 현재 화면의 항목 이동 / 내용 스크롤 |

저장 영수증은 파일 저장 결과다. 기존 재조정이 worker를 적용하며, TOML 저장은 이미지를 만들지 않는다.
잘못된 선언은 `E`로 원문을 고친다. 충돌 시 `l`로 비교한 뒤 `u` 또는 `U`를 선택하고 `s`로 저장한다.
`Esc`로 문서를 닫거나 화면을 나가도 초안은 현재 TUI 프로세스 안에 남는다.
인스턴스에서 binding·공개 output·Skills 경로를 확인한다. bundled Skills는 기존 읽기 전용 카탈로그에 등록된다.
Keeper는 카탈로그의 정확한 reference로 기존 `keeper_skill`에서 본문을 읽고, `file`로 참조·스크립트를 읽는다. 읽기는 실행과 별개다.

## 관측·행동·근거·제거

`A`는 Add-on 명령 입력을 연다. 아래 명령을 콜론 없이 입력하고 Enter로 제출한다.
`:`는 전역 이동 팔레트다. `o`는 선택한 인스턴스를 관측하고 `r`은 상태를 읽는다.
`slice {"run_id":"dos-demo"}`로 여러 Lane을 가로질러 읽는다. `since`·`until`은 Unix 초, `lane_id`는 표시된 정확한 Lane ID다.
행동을 제공하는 인스턴스의 `action_schema`와 incarnation을 확인한 뒤 명시적으로 제출한다.
`act {"instance_id":"<ID>","expected_incarnation":"<incarnation>","request_id":"<new-ID>","action":{"kind":"increment"}}`
`increment`는 DOS 예다. 다른 패키지는 표시된 스키마를 따른다. `t` 또는 `A`에서 입력한 `action {동일 요청 JSON}`은 상태만 조회한다.
queued·running·confirmed·failed_before_effect·outcome_unknown과 executor·근거를 함께 확인한다.
Records에서 행을 `Space`로 표시한 뒤 `e`로 근거를 고정한다.
표시한 행 수와 export 대상 인스턴스를 확인한다. Activity timeline의 선택 Lane과 export 대상 인스턴스는 별개다.
직접 지정은 `A`에서 `evidence {"instance_id":"<ID>","row_ids":["<row-ID>"]}`를 입력하고, 선택 전달은 `keeper_name`을 추가한다.
`e`의 마지막 선택인 `Preserve and share the reference via Broadcast`는 선택한 근거의
읽기 가능한 참조를 workspace Broadcast로 공유한다. 기본값은 보존만 하기이며,
선택 후 Enter로 제출한다. 직접 지정할 때는 `broadcast:true`와 보내기 동작마다 새 `request_id`를 추가하고 `keeper_name`은 함께 쓰지 않는다.
응답을 받지 못한 같은 동작을 재시도할 때는 원래 `request_id`를 유지한다. TUI는 같은 근거의 미응답 보내기를 다시 열면 그 ID를 유지하고, 저장 영수증을 받은 후의 새 보내기에는 새 ID를 만든다.
재시도는 원래 아티팩트와 이미 저장된 메시지의 영수증을 반환한다. 첫 요청의 Keeper 전달이 아직 진행 중이어도 메시지를 중복 생성하지 않는다.
보고서 원문을 메시지에 끼워 넣지 않으며, Broadcast 영수증의 request ID·sequence는
실제 메시지 저장 결과다. `committed`는 공유 기록이며 Keeper 열람이나 실행 완료가 아니다.
공유가 실패해도 근거는 보존되고 자동으로 다시 보내지 않는다.
전달 중 예외로 결과를 확정할 수 없으면 `outcome_unknown`으로 표시한다.
이 경우 실제 공유·접수 기록을 확인한 뒤 재전송 여부를 결정한다.
`d` 또는 `A`에서 입력한 `detach <instance-ID>`는 해당 설치의 소유 worker를 정리한다.
TOML 관리 설치라면 일치하는 설치 선언 파일도 디스크에서 삭제하므로, 다음 설정 읽기에서 자동으로 다시 설치되지 않는다.
그 사이 변경된 선언은 거절하고, 다른 인스턴스가 이어받은 선언은 보존한다. DOS 설치 제거는 그 DOS 머신도 종료한다.
통계·관측 패키지를 제거해도 별도 생산자는 계속 진행하며 과거 관측·근거는 남는다. `Esc`·`q`는 화면만 닫고, 기존 owner 작업 취소나 Keeper 필수 검토를 추가하지 않는다.
목록에 없는 실행을 붙일 때는 `A`에서 `attach {"manifest_path":…,"run_id":…,"binding":…}`를 입력해 선언 없이도 붙일 수 있다.
