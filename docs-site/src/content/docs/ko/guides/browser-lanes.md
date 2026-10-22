---
title: 브라우저 레인 매뉴얼
description: Firefox·Zen 또는 Stagehand Chromium을 연결하고 Addon 설치·검증 및 모델 Hook 선택과 Browser Lane TUI 사용법.
---

브라우저 Lane Addon이 worker와 설정된 backend를 소유합니다. 한 번 설치한 뒤
입력·응답 검증 Hook과 모델 소비자를 해당 설치에서 각각 선택합니다. 브라우저 이름과
transport는 지원 기능을 설명하며, 서로 다른 설치 체계는 아닙니다.

- **live**는 WebExtension으로 기존 Firefox·Zen에 연결하거나, Addon이 소유한 BiDi
  backend로 전용 Firefox를 띄웁니다. 확장 연결은 기존 탭의 로그인을 쓰고 관리되는
  Firefox는 전용 프로필을 사용합니다. native hover·drag는 BiDi처럼 지원하는 연결이 필요합니다.
- **automation**은 worker의 OCaml WebDriver 클라이언트와 geckodriver로 격리된 Gecko
  세션을 제공합니다. Addon이 driver·브라우저·비공개 프로필을 소유합니다.
- **stagehand**는 Addon 소유 Chromium과 CDP로 연결한 Stagehand 확장을 사용합니다.
  native 조작과 선택적인 문장·모델 동작을 지원합니다. 설정한 영속 프로필은 로그인을
  유지하며, 생략하면 소유한 세션에 비공개 프로필을 만듭니다.

아직 탭에 결속되지 않은 요청은 사용 가능한 브라우저와 필요한 동작에 따라 자동 선택할
수 있습니다. 이후 탭·문서 작업에는 반환된 브라우저 identity를 유지합니다. 결속된 탭이나
명시한 연결을 다른 브라우저로 바꾸지 않습니다. 모든 transport가 같은 동작을 한다고
가정하지 말고 보고된 capability inventory를 확인합니다. Safari backend는 이 패키지에 없습니다.

## 브라우저 Addon 설치

`scripts/install-local-build.sh`가 `masc-browser-addon-worker`, `masc-native-addon-launcher`,
`masc-browser-process-owner`를 masc 옆에 설치합니다. 그다음 workspace에 대해
`masc browser-lane-setup --mode addon`을 실행합니다. `browser-lane-setup`의 다른 모드도 같은
일을 합니다. 이 명령은 masc에 들어 있는 패키지를 `<base-path>/.masc/packages/browser/`에 씁니다.
workspace에 이 패키지의 선언이 없으면 활성 설정 루트에 `lane-addons/browser.toml`을 저장합니다.
이미 있는 선언은 그대로 둡니다. 설치 prefix를 서버 PATH에 포함합니다. Add-on이 필요 없으면
설치 스크립트에는 `--no-browser-addon`, setup에는 `--no-addon`을 줍니다. 그러면 브라우저 경로는
동작하지 않습니다.

Hook이나 모델 출력을 고르려면 그 `browser.toml`에 더합니다. setup은 이미 있는 선언을 다시
쓰지 않습니다.

```toml
id = "browser"
enabled = true
run_id = "browser"
manifest_path = "/absolute/path/to/workspace/.masc/packages/browser/lane.toml"
tool_hooks = ["validate_input", "validate_output"]
exact_outputs = ["locate", "stagehand"]

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
| `exact_outputs = ["locate"]` | Gecko scene 노드 선택 모델 소비자 |
| `exact_outputs = ["stagehand"]` | Chromium 구조화 모델 소비자 |
| `exact_outputs = ["locate", "stagehand"]` | 두 모델 소비자 사용 |
| `exact_outputs = []` | 두 모델 소비자 끄기 |

배열을 생략하면 해당 패키지 기본값을 따릅니다. 제공된 middleware 이름과 선언된 모델
출력을 선택하며 임의 실행 코드를 Hook으로 로드하지 않습니다. 두 배열을 비워도 caller
권한·worker incarnation·필수 wire decode·문서/viewport 결속·아티팩트 소유권·정리 검사는
유지됩니다. backend가 지원하는 비모델 동작은 계속 사용할 수 있습니다.

출력을 선택하는 것과 모델 provider 설정은 별개입니다. `runtime.toml`의
`runtime.addon_exact_lanes.browser.locate` 및/또는
`runtime.addon_exact_lanes.browser.stagehand`에 기존 모델 slot을 따로 설정합니다.
모델 준비와 소비자 inventory는 별도로 확인합니다. route가 없거나 사용할 수 없으면
공통 Exact Output 대기·취소 정책을 따르며, 다른 브라우저 선택이나 입력 재실행을 허가하지 않습니다.

아래 backend 설정은 서버 시작 때 실제 `runtime.toml`에서 읽고 설치 부착 때 캡처합니다.
변경 후 서버를 재시작하며 기존 설치는 detach 후 재부착해야 새 설정을 캡처합니다.
설치 선언 변경은 시작과 기존 maintenance pulse에서 reconciliation합니다. TOML 저장만으로
부착됐다고 볼 수 없으므로 `desired_revision`, `applied_revision`, `phase`, 설정 오류를
확인합니다. Dashboard Refresh는 상태를 읽으며 reconciliation을 강제하지 않습니다.

이 설치를 종료하려면 최상위 `enabled = false`로 설정하고 detach·정리 결과를 확인합니다.
선언 삭제는 완전한 설정 목록을 읽은 뒤 반영합니다. worker는 새 입력을 차단한 뒤 원래
소유한 자원을 정리하며, 확인되지 않은 정리는 실패로 남깁니다. 교체 인스턴스는 새로운
incarnation·연결 ID를 가집니다. 외부 확장·수동 브라우저는 운영자가 소유하며, 영속 프로필
내용은 보존합니다.

## 설정: live

브라우저가 실행되는 머신에 OCaml native host와 확장을 설치합니다. `--base-path`는 `.masc` 자체가 아닌 `.masc`를 포함하는 워크스페이스 경로입니다. host는 `masc` 옆에 설치된 `masc-browser-host`이고, 다른 것을 쓰려면 `--binary`로 지정합니다. `--binary`는 Firefox/Zen 실행 파일이 아닙니다.

```bash
masc browser-lane-setup --mode extension --base-path /path/to/workspace
```

launcher에는 서버 주소를 적지 않습니다. host는 워크스페이스의 `.masc/config/connection.toml`에서 포트를 읽습니다. poll이 실패하면 그 파일을 다시 읽고, 지금 서버가 더 이상 답하지 않으면서 파일이 가리키는 새 포트가 답할 때만 옮겨 갑니다. 그래서 서버가 다른 포트로 다시 떠도 다시 설치하지 않아도 됩니다.

확장 없이 전용 Firefox에 연결하려면 Addon 소유 BiDi backend를 설정합니다.

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

## 설정: automation

먼저 호스트 브라우저 프로그램을 확인하거나 설치하려면 `masc prerequisite-actions firefox`와 `masc prerequisite-actions geckodriver`를 실행합니다. 그다음 `masc browser-lane-setup --mode automation`이 `[browser.automation]` 설정을 써 줍니다. `PATH`가 처음 찾는 `geckodriver`가 `--version`에 답하면 그것을 쓰고(`--geckodriver`로 다른 것을, `--browser`로 `binary`를 지정), 이미 있는 값은 바꾸지 않으며 host와 확장은 설치하지 않습니다. 직접 하려면 해석된 설정 디렉터리의 `runtime.toml`에 geckodriver 실행 파일 경로를 넣고 MASC를 재시작합니다.

```toml
[browser.automation]
geckodriver = "/absolute/path/to/geckodriver"
# 선택 사항: 설치된 Firefox 또는 Zen 실행 파일 지정.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

부착된 worker가 geckodriver를 빈 loopback 포트로 띄우고 detach 때 소유한 자원 정리를 기다리므로, 드라이버를 따로 실행하거나 포트를 고를 일이 없습니다. `geckodriver`는 절대 경로여야 합니다. `binary`도 절대 경로여야 하며 `geckodriver`가 함께 필요합니다. 생략하면 geckodriver가 브라우저를 탐색하므로, Firefox 또는 Zen을 명시적으로 고르려면 지정합니다. 이 설정은 live 연결을 선택하지 않습니다. automation은 기본적으로 headless로 열립니다.

## 설정: stagehand

고정 버전의 Stagehand 확장을 워크스페이스에 설치합니다. 스크립트는 npm 패키지를 레지스트리의 integrity 값과 대조하고, `runtime.toml`에 넣을 줄을 출력합니다.

```bash
bash connectors/browser/install-stagehand-extension.sh --base-path /path/to/workspace
```

출력된 줄을 Chromium 계열 실행 파일 경로와 함께 `[browser.stagehand]`에 넣고 MASC를 재시작합니다.

```toml
[browser.stagehand]
chrome = "/absolute/path/to/chrome"
extension = "/absolute/path/printed/by/the/installer"
# 선택 사항: 세션 사이에 유지할 운영자 소유 profile (로그인 유지용).
# profile = "/absolute/path/to/profile"
```

설정한 경로는 모두 절대 경로입니다. worker는 CDP의 `Extensions.loadUnpacked`로 확장을
올리므로 선택한 Chromium 빌드가 이 메서드를 지원해야 합니다. 디버깅 포트는 loopback에서
열립니다. `profile`은 MASC 실행 계정 소유의 기존 비공개 디렉터리를 사용하며 내용은
보존합니다. 생략하면 worker가 비공개 세션 프로필을 만듭니다.

`BrowserSession lane="stagehand" action="open"`은 해당 worker의 세션을 열거나 재사용합니다.
native 입력에는 모델이 필요하지 않습니다. `BrowserInstruct`는 위에서 독립 선택한
`stagehand` 소비자와 설치별 Exact Output route를 사용합니다. 꺼진 소비자는 거부하며,
선택한 소비자도 설정되고 사용 가능한 모델 route가 필요합니다.

세션 close와 Addon detach는 원래 자원의 정리를 기다립니다. 실패하거나 끊긴 세션은
종료 사유를 보존하며 계속하기 전에 현재 세션·탭을 다시 탐색합니다. 공유 세션을 닫기
전에는 사용 관계를 조율합니다. 연결이 바뀌었다는 이유로 결과 불확실한 입력을 반복하지 않습니다.

## Keeper와 MCP 도구

Keeper에 보이는 이름은 CamelCase이고, MCP 등록 이름은 `masc_browser_*`입니다.

| Keeper 도구 | MCP 이름 | 소스와 동작 |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | 세 소스 모두: 탭 목록과 live 연결 식별자 탐색 |
| `BrowserRead` | `masc_browser_read` | 세 소스 모두: 텍스트·보이는 요소·scene·regions·viewport PNG 읽기. frame·대화상자·다운로드는 automation |
| `BrowserInteract` | `masc_browser_interact` | 명시한 탭의 click·fill·scroll 등. native hover·drag·키보드·zoom은 transport capability에 따름 |
| `BrowserSession` | `masc_browser_session` | automation·stagehand: 세션 열기/닫기/상태 확인 |
| `BrowserGoto` | `masc_browser_goto` | automation·stagehand: HTTP(S) URL로 이동 |
| `BrowserAct` | `masc_browser_act` | automation: 탭·폼·history 조작; stagehand: 탭·history 조작; live BiDi: open_tab |
| `BrowserInstruct` | `masc_browser_instruct` | 선택한 stagehand 소비자: act·observe·extract; Gecko locate 소비자: observe |

탐색 결과의 `clientId`와 `tabId`를 이후 live 읽기·조작에 전달합니다. live 브라우저가 여러 개면 `clientId`가 필수이며, automation에는 전달하지 않습니다.

`BrowserRead`의 기본값은 `mode="text"`, `format="text"`, Unicode code point 50,000개입니다. `maxChars`는 최대 100,000이며 결과의 `truncated`를 확인합니다. `mode="elements"`는 레이블과 관측한 CSS selector를 포함해 응답 한도 안에서 보이는 컨트롤을 반환하므로 잘림과 범위를 확인합니다. `format="image"`에는 명시적인 `tabId`가 필요하며, Keeper 호출은 이미지 분석에 사용할 영속 artifact handle을 반환합니다. 텍스트와 요소 읽기는 현재 렌더된 페이지 기준이므로 숨겨지거나 가상 스크롤 뒤에 있는 모든 항목을 포함하지 않습니다.

`BrowserInstruct`는 `action`(`act`·`observe`·`extract`), 문장 `instruction`(act와 extract에는 필수), `BrowserTabs lane="stagehand"`가 준 `tabId`를 받습니다. extract에는 돌려받을 데이터 모양을 JSON Schema 문자열로 `schema`에 줄 수 있습니다. 결과는 Stagehand의 `data`와 `metadata`입니다. 선택한 Gecko `locate` 소비자는 관측한 탭의 `BrowserInstruct action="observe" lane="automation"`을 제공합니다. act는 페이지를 바꿀 수 있으므로 뒤에 Stagehand `observe`나 `extract`로 확인하며, 실패한 act도 이미 동작했을 수 있습니다. observe와 extract는 읽기만 합니다.

`BrowserInteract`의 click/fill 같은 페이지 입력에는 관측한 selector를 사용하며, 정확히 하나의 요소와 일치해야 합니다. `BrowserInteract`의 `expectedUrl`에 직전에 읽은 URL을 넣으면 중간에 페이지가 이동한 경우 거부합니다. fill은 페이지 이벤트를 발생시키지만 자체적으로 Enter를 누르거나 submit하지 않습니다. 오류가 발생한 경우도 포함해 조작 후에는 페이지를 읽거나 캡처한 뒤 재시도 여부를 결정합니다.

BiDi·owned WebDriver의 관측한 요소 click은 native 포인터 입력을 사용하고 Stagehand는 native click 메서드를 사용합니다. WebExtension은 DOM click을 사용합니다. fill과 native typing은 별도 동작입니다. transport capability를 확인하고 입력 후 페이지를 다시 읽어 애플리케이션의 효과를 확인합니다.

## TUI 리더

`Ctrl-^`(Ctrl-Shift-6), `:` → `go Browser Lane`, 또는 Connectors의 `B`로 엽니다.
처음 선택은 **Automatic**입니다. `b`로 Automatic·별도 **Work browser**·기존 로그인이 있는
관측한 연결 중에서 고릅니다. `j`/`k`와 Enter로 선택하고 선택기의 `r`로 새로 탐색하며
Esc로 돌아갑니다. 읽기와 캡처는 선택한 연결에 유지되고 끊어졌다면 새 연결을 명시적으로
골라야 합니다.

별도 작업 세션은 `o`로 열고 `g`로 URL을 입력합니다. 기존 로그인을 사용하려면 `b`로
해당 연결을 고른 뒤 관측한 탭을 선택합니다. 특정 transport가 필요하면 `A`로 고급
backend 선택을 펼칩니다. `l`/`a`/`c` 단축키는 고급 모드에서만 동작합니다.

| 키 | 동작 |
| --- | --- |
| `b` | Automatic·Work browser·관측한 연결 선택 |
| `A` | 고급 backend 선택기를 열기 |
| `l` / `a` / `c` | 고급 모드에서만 live / automation / Stagehand 선택 |
| `h` | 선택한 Keeper의 브라우저 관측 기록 열기 (`[`/`]`로 저장 페이지 전환, `y`로 영수증·아티팩트 참조 복사) |
| `[` / `]` | 이전 / 다음 탭으로 이동하며 읽기 |
| `j` / `k`, 방향키 | 페이지 텍스트 스크롤 |
| Page Up / Page Down, Home | 페이지 스크롤 / 맨 위 |
| `r` | 재탐색 및 새로고침 |
| `Ctrl-O` | 선택 탭 PNG 미리보기; 아무 키로 복귀 |
| `g` | 소유한 작업 세션의 URL 입력; Enter로 이동, Esc로 취소 |
| `o` / `x` | 작업 세션 열기 / 선택한 소유 작업 세션 닫기 |
| `Ctrl-^` / Esc / Left | 리더를 숨기고 이전 화면으로 복귀 |

PNG 미리보기에는 터미널 이미지 지원이 필요하며 미지원 시 한계를 안내합니다. 미리보기는
Keeper에게 전송하지 않습니다. TUI 키는 읽기·캡처·작업 세션 탐색을 제공하고 그 밖의 조작은
위 도구로 실행합니다. 공유 작업 세션을 닫기 전에는 사용 관계를 조율합니다.

리더를 숨겨도 이 TUI 세션의 선택 탭, 텍스트 스크롤, 작성 중인 채팅 임시본은 유지됩니다. Browser 진입은 연속 음성 모드를 종료하고 전송 대기 중인 녹취를 포함한 음성 캡처를 버립니다.
