---
title: 브라우저 레인 매뉴얼
description: Firefox·Zen·ego lite를 연결하고 Addon 설치·검증 및 Hook 선택과 Browser Lane TUI 사용법.
---

브라우저 출처마다 Lane Addon 패키지와 worker가 따로 있습니다: `browser-firefox`,
`browser-ego`, `browser-external`. worker는 자기
출처만 띄우므로, 한 출처가 실패해도 그 worker만 끝납니다. 입력·응답 검증 Hook은
설치마다 고릅니다. 브라우저 이름과 transport는 지원 기능을 설명하며, 서로 다른
설치 체계는 아닙니다.

세 출처는 모두 live 연결을 제공합니다.

- `browser-external`은 WebExtension으로 연결한 기존 Firefox·Zen이나, 직접 띄운
  Firefox의 BiDi host를 받습니다.
- `browser-firefox`는 전용 Firefox를 자기 BiDi peer로 띄웁니다.
- `browser-ego`는 ego lite 작업 공간을 씁니다.

확장 연결은 기존 탭의 로그인을 쓰고, 전용 Firefox는 전용 프로필을 씁니다. native
hover·drag는 BiDi처럼 지원하는 연결이 필요합니다.

아직 탭에 결속되지 않은 요청은 사용 가능한 브라우저와 필요한 동작에 따라 자동 선택할
수 있습니다. 이후 탭·문서 작업에는 반환된 브라우저 identity를 유지합니다. 결속된 탭이나
명시한 연결을 다른 브라우저로 바꾸지 않습니다. 모든 transport가 같은 동작을 한다고
가정하지 말고 보고된 capability inventory를 확인합니다. Safari backend는 이 패키지에 없습니다.

## 브라우저 Addon 설치

`scripts/install-local-build.sh`가 `masc-browser-addon-worker`, `masc-native-addon-launcher`,
`masc-browser-process-owner`를 masc 옆에 설치합니다. 그다음 workspace에 대해
`masc browser-lane-setup --mode addon`을 실행합니다. `browser-lane-setup`의 다른 모드도 같은
일을 합니다. 이 명령은 workspace가 쓰는 출처마다 일합니다. firefox·ego는
`runtime.toml`에 표가 있거나 이번 실행이 그 표를 쓸 때, external은 native host가
설치돼 있을 때입니다. 출처마다 masc에 들어 있는 패키지를
`<base-path>/.masc/packages/browser-<출처>/`에 쓰고, 그 출처의 선언이 없으면 활성 설정 루트에
`lane-addons/browser-<출처>.toml`을 저장합니다. 이미 있는 선언은 그대로 둡니다. 설치 prefix를
서버 PATH에 포함합니다. Add-on이 필요 없으면 설치 스크립트에는 `--no-browser-addon`, setup에는
`--no-addon`을 줍니다. 그러면 브라우저 경로는 동작하지 않습니다.

Hook을 고르려면 setup이 쓴 선언에 더합니다. setup은 이미 있는 선언을 다시
쓰지 않습니다.

```toml
id = "browser-ego"
enabled = true
run_id = "browser-ego"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser-ego/lane.toml"
tool_hooks = ["validate_input", "validate_output"]

[binding]
sources = []
```

기본 디렉터리는 `<base-path>/.masc/config/lane-addons/`이며 기존 `MASC_CONFIG_DIR`
설정이 있으면 그 config root를 씁니다. Dashboard **TOML configuration**에 실제 위치가
표시되고 **New TOML / Edit TOML**이 같은 선언을 편집합니다. `manifest_path`는 절대 경로나
선언 파일 기준 상대 경로이며 shell 작업 디렉터리 기준이 아닙니다. 설치 ID·worker
incarnation·브라우저 `clientId`는 서로 다른 identity입니다.

| 독립 선택 | 의미 |
| --- | --- |
| `tool_hooks = ["validate_input"]` | dispatch 전 도구 입력 검증 |
| `tool_hooks = ["validate_output"]` | 아티팩트 중개가 끝난 최종 성공 응답 검증 |
| `tool_hooks = ["validate_input", "validate_output"]` | 두 도구 검증 사용 |
| `tool_hooks = []` | 선택적인 도구 검증 끄기 |

`tool_hooks`를 생략하면 해당 패키지 기본값을 따릅니다. 제공된 middleware 이름을
선택하며 임의 실행 코드를 Hook으로 로드하지 않습니다. `tool_hooks = []`여도 caller
권한·worker incarnation·필수 wire decode·문서/viewport 결속·아티팩트 소유권·정리 검사는
유지됩니다.

아래 backend 설정은 서버 시작 때 실제 `runtime.toml`에서 읽고 설치 부착 때 캡처합니다.
이 설정은 출처를 어떻게 띄울지만 말하고, 띄울지 말지는 말하지 않습니다. 표가 없는 출처는
시작하지 못하고, 그 패키지 줄이 이유를 보여 줍니다. 변경 후 서버를 재시작하며 기존 설치는
detach 후 재부착해야 새 설정을 캡처합니다. 설치 선언 변경은 시작과 기존 maintenance
pulse에서 reconciliation합니다. TOML 저장만으로 부착됐다고 볼 수 없으므로
`desired_revision`, `applied_revision`, `phase`, 설정 오류를 확인합니다. Dashboard Refresh는
상태를 읽으며 reconciliation을 강제하지 않습니다.

출처를 끄려면 그 선언의 최상위 `enabled = false`를 TUI의 패키지 줄이나 TOML 파일에서
설정하고, detach·정리 결과를 확인합니다. 그 출처의 worker만 멈춥니다. 선언 삭제는 완전한
설정 목록을 읽은 뒤 반영합니다. worker는 새 입력을 차단한 뒤 원래 소유한 자원을 정리하며,
확인되지 않은 정리는 실패로 남깁니다. 교체 인스턴스는 새로운 incarnation·연결 ID를
가집니다. 외부 확장·수동 브라우저는 운영자가 소유하며, 영속 프로필 내용은 보존합니다.

## 설정: live

브라우저가 실행되는 머신에 OCaml native host와 확장을 설치합니다. `--base-path`는 `.masc` 자체가 아닌 `.masc`를 포함하는 워크스페이스 경로입니다. host는 `masc` 옆에 설치된 `masc-browser-host`이고, 다른 것을 쓰려면 `--binary`로 지정합니다. `--binary`는 Firefox/Zen 실행 파일이 아닙니다.

```bash
masc browser-lane-setup --mode extension --base-path /path/to/workspace
```

launcher에는 서버 주소를 적지 않습니다. host는 워크스페이스의 `.masc/config/connection.toml`에서 포트를 읽습니다. poll이 실패하면 그 파일을 다시 읽고, 지금 서버가 더 이상 답하지 않으면서 파일이 가리키는 새 포트가 답할 때만 옮겨 갑니다. 그래서 서버가 다른 포트로 다시 떠도 다시 설치하지 않아도 됩니다.

확장 없이 전용 Firefox에 연결하려면 `browser-firefox` 출처를 설정합니다.

```bash
masc browser-lane-setup --mode bidi --base-path /path/to/workspace
```

이 명령은 `[browser.live.bidi]`와 전용 프로필을 준비합니다. 명시한 `--firefox`,
`--profile`, `--port`는 해당 키를 바꾸고 생략한 키는 유지합니다.
[Firefox BiDi 안내](../browser-bidi/)에 따라 관리되는 연결을 부착하고 확인합니다.
`--mode host`는 외부 연결용 standalone host·launcher를 설치하며 Addon을 부착하거나
브라우저를 시작하지 않습니다.

`--mode extension` 명령은 macOS와 Linux를 지원하며 Mozilla native messaging manifest를 등록합니다. 다른 manifest 디렉터리가 필요하면 `--manifest-dir`로 지정합니다. 확장은 `<base-path>/.masc/browser-lane/extension/`에 씁니다. Firefox 또는 Zen의 `about:debugging` → **임시 부가 기능 로드**에서 그 안의 `manifest.json`을 선택합니다. 브라우저가 종료되면 임시 로드도 끝납니다.

각 연결은 브라우저 종류와 `clientId` UUID를 보고합니다. live 연결이 하나면 자동으로 선택할 수 있고, 여러 개면 원하는 UUID를 선택해야 합니다. 탭 ID는 연결마다 별개이므로 서로 다른 브라우저에서 같은 숫자일 수 있습니다. 끊어진 UUID는 다른 브라우저로 대체하지 않고 거부합니다. 재연결하면 새 UUID를 탐색해 다시 선택합니다.

## Keeper와 MCP 도구

Keeper에 보이는 이름은 CamelCase이고, MCP 등록 이름은 `masc_browser_*`입니다.

| Keeper 도구 | MCP 이름 | 동작 |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | 탭 목록과 live 연결 식별자 탐색 |
| `BrowserRead` | `masc_browser_read` | 텍스트·보이는 요소·scene·regions·viewport PNG 읽기 |
| `BrowserInteract` | `masc_browser_interact` | 명시한 탭의 click·fill·scroll 등. native hover·drag·키보드·zoom은 transport capability에 따름 |
| `BrowserSession` | `masc_browser_session` | 관측한 ego Space를 공유 Goal에 묶기: `bind_goal`, `goal_status`, `unbind_goal` (실험 단계) |
| `BrowserGoto` | `masc_browser_goto` | 탭을 HTTP(S) URL로 이동: `open_tab`으로 연 BiDi 탭이나 ego가 관리하는 Page. WebExtension은 이동하지 않음 |
| `BrowserAct` | `masc_browser_act` | BiDi: `open_tab`, `open_window`, 그리고 자기가 연 탭의 최상위 `back`·`forward`·`reload`·`close_tab`. ego: `open_tab`, `close_tab`, `back`, `forward`, `reload`와 `hand_off` 같은 작업 공간 동작 |

탐색 결과의 `clientId`와 `tabId`를 이후 live 읽기·조작에 전달합니다. live 브라우저가 여러 개면 `clientId`가 필수입니다.

`BrowserRead`의 기본값은 `mode="text"`, `format="text"`, Unicode code point 50,000개입니다. `maxChars`는 최대 100,000이며 결과의 `truncated`를 확인합니다. `mode="elements"`는 레이블과 관측한 CSS selector를 포함해 응답 한도 안에서 보이는 컨트롤을 반환하므로 잘림과 범위를 확인합니다. `format="image"`에는 명시적인 `tabId`가 필요하며, Keeper 호출은 이미지 분석에 사용할 영속 artifact handle을 반환합니다. 텍스트와 요소 읽기는 현재 렌더된 페이지 기준이므로 숨겨지거나 가상 스크롤 뒤에 있는 모든 항목을 포함하지 않습니다.

`BrowserInteract`의 click/fill 같은 페이지 입력에는 관측한 selector를 사용하며, 정확히 하나의 요소와 일치해야 합니다. `BrowserInteract`의 `expectedUrl`에 직전에 읽은 URL을 넣으면 중간에 페이지가 이동한 경우 거부합니다. fill은 페이지 이벤트를 발생시키지만 자체적으로 Enter를 누르거나 submit하지 않습니다. 오류가 발생한 경우도 포함해 조작 후에는 페이지를 읽거나 캡처한 뒤 재시도 여부를 결정합니다.

BiDi의 관측한 요소 click은 native 포인터 입력을, ego는 SDK의 native click을 사용합니다. WebExtension은 DOM click을 사용합니다. fill과 native typing은 별도 동작입니다. transport capability를 확인하고 입력 후 페이지를 다시 읽어 애플리케이션의 효과를 확인합니다.

## TUI 리더

`Ctrl-^`(Ctrl-Shift-6), `:` → `go Browser Lane`, 또는 Connectors의 `B`로 엽니다.
처음 선택은 **Automatic**입니다. `b`로 Automatic·기존 로그인이 있는
관측한 연결 중에서 고릅니다. `j`/`k`와 Enter로 선택하고 선택기의 `r`로 새로 탐색하며
Esc로 돌아갑니다. 읽기와 캡처는 선택한 연결에 유지되고 끊어졌다면 새 연결을 명시적으로
골라야 합니다.

기존 로그인을 사용하려면 `b`로 해당 연결을 고른 뒤 관측한 탭을 선택합니다. `A`를
누르면 선택기에 transport의 제한과 BiDi host 진단이 보입니다.

| 키 | 동작 |
| --- | --- |
| `b` | Automatic·관측한 연결 선택 |
| `A` | transport 제한과 BiDi host 진단을 보여 주는 선택기 열기 |
| `h` | 선택한 Keeper의 브라우저 관측 기록 열기 (`[`/`]`로 저장 페이지 전환, `y`로 영수증·아티팩트 참조 복사) |
| `[` / `]` | 이전 / 다음 탭으로 이동하며 읽기 |
| `j` / `k`, 방향키 | 페이지 텍스트 스크롤 |
| Page Up / Page Down, Home | 페이지 스크롤 / 맨 위 |
| `r` | 재탐색 및 새로고침 |
| `Ctrl-O` | 선택 탭 PNG 미리보기; 아무 키로 복귀 |
| `Ctrl-^` / Esc / Left | 리더를 숨기고 이전 화면으로 복귀 |

PNG 미리보기에는 터미널 이미지 지원이 필요하며 미지원 시 한계를 안내합니다. 미리보기는
Keeper에게 전송하지 않습니다. TUI 키는 읽기·캡처를 제공하고 그 밖의 조작은
위 도구로 실행합니다.

리더를 숨겨도 이 TUI 세션의 선택 탭, 텍스트 스크롤, 작성 중인 채팅 임시본은 유지됩니다. Browser 진입은 연속 음성 모드를 종료하고 전송 대기 중인 녹취를 포함한 음성 캡처를 버립니다.
