# Dashboard와 Keeper에서 같은 Lane TOML 편집하기

Lane 설치의 정본은 `<resolved-config-root>/lane-addons/*.toml`이다. Dashboard와
Keeper의 선언 편집 경로도 이 파일을 읽고 저장한다. 패키지 구현은 `lane.toml`과
그 패키지가 제공하는 Skills·scripts·실행 환경에 있고, 설치 선언은 사용할 패키지와
MASC 원천·다른 Lane 출력 사이의 연결을 지정한다.

## Dashboard

Lane Add-ons의 **New TOML**에서 파일 이름과 선언 원문을 입력한다. 기존 선언은
설정 목록의 **Edit TOML**로 연다. 파일의 TOML이 잘못되어도 오류 옆에서 원문을
열어 수정할 수 있다. 선언 예제와 상대 경로의 기준은
[TOML 설치 가이드](lane-addon-toml.md)를 따른다.

저장 결과와 설치 상태는 별개다. **File saved**는 선언 파일을 저장했다는 뜻이며,
실제 worker와 입력 연결의 적용 여부는 기존 desired/applied revision과 관측 상태에서
확인한다. 저장 요청이 worker 시작이나 관측 완료를 기다리지는 않는다.

다른 편집자가 파일을 변경했다면 현재 원문과 내 초안을 비교한다. **Use current file
revision**은 내 초안을 유지하면서 다음 저장의 기준을 선택하고, **Replace draft with
current file**은 표시된 현재 원문으로 초안을 바꾼다. 이후 저장 시에도 변경 검사를
다시 수행한다. 오류가 났다는 이유로 사용자의 초안을 버리지 않는다.

## Keeper와 공통 API

Keeper는 기존 도구 선택 경로에서 `masc_lane_declaration_read`와
`masc_lane_declaration_save`를 사용한다. MCP에도 같은 이름으로 노출된다. Dashboard도 동일한
선언 소유자와 검증·저장 경로를 사용하는 HTTP API를 호출한다.

| 작업 | HTTP | 요청 |
|---|---|---|
| 읽기 | `GET /api/v1/lane-addons/declaration` | `source_path` query: 설정 목록에 표시된 정확한 선언 경로 |
| 생성 | `POST /api/v1/lane-addons/declaration` | `mode="create"`, `file_name`, `source_text` |
| 수정 | 같은 POST | `mode="save"`, `file_name`, `source_text`, 읽기 결과의 `expected_source_revision` |

`file_name`은 설정 디렉터리 바로 아래의 `.toml` 파일 이름이다. 임의의 호스트 파일이나
패키지 구현 파일을 편집하는 통로가 아니다. 생성 요청에는 revision을 넣지 않는다.
수정 요청은 읽었던 원문의 SHA-256을 요구하며, 빈 문자열이나 null로 이를 대신하지 않는다.

읽기 결과에는 원문과 `source_revision`, `desired_revision`, 검증 진단이 들어 있다.
기존 파일이 잘못되어도 원문을 읽어 고칠 수 있다. 저장할 새 선언이 잘못되었거나
다른 선언의 설치 ID와 충돌하면 파일을 교체하지 않고 오류를 반환한다. 기존 worker는
그 오류 때문에 중단되지 않는다.

## 세 revision과 저장 영수증

| 값 | 뜻 |
|---|---|
| `source_revision` | 읽은 파일 원문 bytes의 SHA-256. 주석만 바뀌어도 바뀐다. 편집 충돌 확인에 사용한다. |
| `desired_revision` | 패키지와 입력 연결을 해석한 의미적 설정 revision. 잘못된 선언에는 없을 수 있다. |
| `applied_revision` | 실제 설치에 적용된 설정 revision. 기존 Lane 설정 상태에서 확인한다. |

저장 영수증은 `created`, `saved`, `unchanged`를 구분한다. 파일 교체 뒤 디렉터리의
영속화를 확인하지 못한 경우 `durability="unconfirmed"`와 상세 내용을 반환한다.
이 결과를 파일이 바뀌지 않았다는 뜻으로 해석하거나 성공한 작업을 무조건 반복하지 않는다.
현재 원문과 실제 적용 상태를 다시 확인한다.

같은 MASC 프로세스의 HTTP·Keeper 편집과 재조정·제거는 같은 설정 잠금을 사용한다.
두 편집기 요청이 같은 원문 revision으로 저장하면 하나만 적용되고 나머지는 변경 충돌을
받는다. 이 보장은 해당 소유자를 통해 이루어진 저장 사이에 적용된다.

외부 프로그램의 직접 파일 수정은 계속 사용할 수 있지만 이 잠금을 공유하지 않는다.
저장 전 두 번의 원문 확인은 이미 보이는 외부 변경을 검출한다. 마지막 확인 이후 파일
교체 직전의 외부 저장까지 원자적으로 막지는 못하며, 그 구간에서는 나중 저장이 앞선
변경을 덮어쓸 수 있다. Dashboard/Keeper와 외부 프로그램이 동시에 같은 파일을 저장할
때는 이 차이를 고려해야 한다. 원문 revision만으로 임의의 외부 편집기까지 분산
compare-and-swap을 보장하지 않는다. 잘못된 외부 변경은 기존 재조정 진단으로 표시된다.

삭제는 기존 TOML 관리 설치의 **Detach**를 사용하거나 선언 파일을 제거한다. 해당
설치가 소유한 자원만 정리하며, 이전 관측과 선택한 근거를 삭제하는 기능은 아니다.
이 편집 경로는 Keeper의 기존 도구 권한이나 다른 활동의 필수 절차를 추가하지 않는다.
