---
title: 브라우저 레인 매뉴얼
description: Firefox·Zen 또는 Stagehand Chromium을 연결하고 페이지 읽기·조작과 Browser Lane TUI를 사용하는 방법.
---

MASC에는 세 가지 브라우저 소스가 있습니다.

- **live**는 브라우저 확장과 OCaml native messaging host로 운영자의 Firefox 또는 Zen에 연결합니다. 기존 탭과 로그인 세션을 사용하며, 텍스트·요소 목록·viewport 스크린샷 읽기와 명시적으로 선택한 탭의 click·fill·scroll을 지원합니다. 조작은 페이지를 변경하거나 페이지의 이벤트 핸들러를 실행할 수 있으며, 그 결과 페이지가 이동할 수도 있습니다.
- **automation**은 MASC의 OCaml WebDriver 클라이언트와 geckodriver로 별도 Gecko 브라우저 세션을 관리합니다. 운영자의 로그인 정보가 없는 격리 프로필로 시작합니다. 세션 열기/닫기와 직접 URL 이동은 이 소스의 기능입니다. 서버가 세션을 소유하므로 다른 작업이 사용 중인 세션을 닫기 전에는 사용 관계를 확인합니다.
- **stagehand**는 서버가 [Stagehand](https://github.com/browserbase/stagehand) v4 확장을 올려 띄우는 Chromium이며, Chrome DevTools Protocol로 연결합니다. Keeper는 무엇을 할지·찾을지·읽을지를 문장 하나로 말하고, 요소 고르기는 Stagehand 런타임이 합니다. 런타임이 묻는 모델에는 MASC가 exact-output lane으로 답합니다. automation처럼 서버가 세션을 소유하며, profile을 설정하지 않으면 빈 profile로 시작합니다.

## 설정: live

브라우저가 실행되는 머신에 빌드된 OCaml native host를 설치합니다. 여기서 `--binary`는 Firefox/Zen 실행 파일이 아니라 **masc-browser-host**입니다. `--base-path`는 `.masc` 자체가 아닌 `.masc`를 포함하는 워크스페이스 경로입니다.

```bash
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace
```

launcher에는 서버 주소를 적지 않습니다. host는 워크스페이스의 `.masc/config/connection.toml`에서 포트를 읽습니다. poll이 실패하면 그 파일을 다시 읽고, 지금 서버가 더 이상 답하지 않으면서 파일이 가리키는 새 포트가 답할 때만 옮겨 갑니다. 그래서 서버가 다른 포트로 다시 떠도 다시 설치하지 않아도 됩니다.

설치기는 macOS와 Linux를 지원하며 Mozilla native messaging manifest를 등록합니다. 다른 manifest 디렉터리가 필요하면 `--manifest-dir`로 지정합니다. Firefox 또는 Zen의 `about:debugging` → **임시 부가 기능 로드**에서 `connectors/browser/extension/manifest.json`을 선택합니다. 브라우저가 종료되면 임시 로드도 끝납니다.

각 연결은 브라우저 종류와 `clientId` UUID를 보고합니다. live 연결이 하나면 자동으로 선택할 수 있고, 여러 개면 원하는 UUID를 선택해야 합니다. 탭 ID는 연결마다 별개이므로 서로 다른 브라우저에서 같은 숫자일 수 있습니다. 끊어진 UUID는 다른 브라우저로 대체하지 않고 거부합니다. 재연결하면 새 UUID를 탐색해 다시 선택합니다.

## 설정: automation

해석된 설정 디렉터리의 `runtime.toml`에 geckodriver 실행 파일 경로를 넣고 MASC를 재시작합니다.

```toml
[browser]
geckodriver = "/absolute/path/to/geckodriver"
# 선택 사항: 설치된 Firefox 또는 Zen 실행 파일 지정.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

MASC가 그 geckodriver를 빈 loopback 포트로 띄우고 서버가 끝날 때 내리므로, 드라이버를 따로 실행하거나 포트를 고를 일이 없습니다. `geckodriver`는 절대 경로여야 합니다. `binary`도 절대 경로여야 하며 `geckodriver`가 함께 필요합니다. 생략하면 geckodriver가 브라우저를 탐색하므로, Firefox 또는 Zen을 명시적으로 고르려면 지정합니다. 이 설정은 live 연결을 선택하지 않습니다. automation은 기본적으로 headless로 열립니다.

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

세 값 모두 절대 경로입니다. MASC는 디버깅 연결로 확장을 올립니다(`Extensions.loadUnpacked`). Chrome Canary 156과 Chrome for Testing 154에서 확인했습니다. 일반 Chrome은 137부터 `--load-extension`을 막았고, CDP로 올리는 방식을 받는지는 빌드마다 다를 수 있습니다. 디버깅 포트는 loopback에서 열립니다. origin 플래그는 확장의 WebSocket Origin을 허용하지만, Origin 헤더를 보내지 않는 로컬 클라이언트를 배제하지는 못합니다. 호스트와 로그인용 profile에 대한 접근을 그에 맞게 관리해야 합니다. `profile`이 없으면 세션마다 서버 소유 profile을 비우고 시작하며, 설정한 profile은 지우지 않습니다. 어느 쪽이든 폴더는 소유자만 접근할 수 있습니다.

Stagehand 런타임은 `llm.generate`로 모델을 요청합니다. MASC는 `runtime.toml`의 `browser_stagehand_exact` exact-output lane으로 답합니다. slot을 순서대로 시도하며, system prompt를 받지 않는 모델의 slot은 건너뜁니다. CLI slot을 선언한 lane은 거절합니다. 답은 JSON 값 하나인지만 확인하고, 모양은 확장이 자기 스키마로 확인합니다.

브라우저는 `BrowserSession`을 `lane="stagehand"`로 열 때 뜨고, 닫을 때·세션이 실패할 때·서버가 멈출 때 내려갑니다. 비정상 종료한 서버가 남긴 Chromium은 다음 시작 때 정리합니다.

Stagehand는 서버가 공유하는 세션 하나를 사용합니다. `BrowserSession action="open"`은 기존 세션을 재사용할 수 있으며, `reused: true`는 연결이 살아 있다는 증거가 아닙니다. 연결이 끊겼다는 답이 오면 `action="status"`의 `ended`를 확인합니다. 세션을 종료해도 되는지 확인한 뒤 `action="close"` → `action="open"`으로 다시 열고, `BrowserTabs`로 새 tab ID를 찾습니다. `open`만 반복하면 끊긴 세션에도 `reused: true`가 올 수 있습니다. 이미 페이지를 바꿨을 수 있는 act는 그대로 반복하지 않습니다.

`status`는 누가 세션을 열었거나 지금 쓰는지 알려주지 않습니다. 운영자가 종료해도 된다고 확인했거나 작업에 명시적인 독점 사용 범위가 있을 때만 닫고, 그 외에는 사용 관계를 조율해 인계합니다.

## Keeper와 MCP 도구

Keeper에 보이는 이름은 CamelCase이고, MCP 등록 이름은 `masc_browser_*`입니다.

| Keeper 도구 | MCP 이름 | 소스와 동작 |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | 세 소스 모두: 탭 목록과 live 연결 식별자 탐색 |
| `BrowserRead` | `masc_browser_read` | 세 소스 모두: 텍스트·보이는 요소·scene·regions·viewport PNG 읽기. frame·대화상자·다운로드는 automation |
| `BrowserInteract` | `masc_browser_interact` | live·automation: 명시적으로 선택한 탭 click·fill·scroll |
| `BrowserSession` | `masc_browser_session` | automation·stagehand: 세션 열기/닫기/상태 확인 |
| `BrowserGoto` | `masc_browser_goto` | automation·stagehand: HTTP(S) URL로 이동 |
| `BrowserAct` | `masc_browser_act` | automation: 탭 열기/닫기, click·fill·press·select·scroll·back·forward·reload |
| `BrowserInstruct` | `masc_browser_instruct` | stagehand: 문장 하나로 탭에서 동작·요소 찾기·데이터 읽기 |

탐색 결과의 `clientId`와 `tabId`를 이후 live 읽기·조작에 전달합니다. live 브라우저가 여러 개면 `clientId`가 필수이며, automation에는 전달하지 않습니다.

`BrowserRead`의 기본값은 `mode="text"`, `format="text"`, Unicode code point 50,000개입니다. `maxChars`는 최대 100,000이며 결과의 `truncated`를 확인합니다. `mode="elements"`는 레이블과 관측한 CSS selector를 포함해 보이는 컨트롤을 최대 200개 반환합니다. `format="image"`에는 명시적인 `tabId`가 필요하며, Keeper 호출은 이미지 분석에 사용할 영속 artifact handle을 반환합니다. 텍스트와 요소 읽기는 현재 렌더된 페이지 기준이므로 숨겨지거나 가상 스크롤 뒤에 있는 모든 항목을 포함하지 않습니다.

`BrowserInstruct`는 `action`(`act`·`observe`·`extract`), 문장 `instruction`(act와 extract에는 필수), `BrowserTabs lane="stagehand"`가 준 `tabId`를 받습니다. extract에는 돌려받을 데이터 모양을 JSON Schema 문자열로 `schema`에 줄 수 있습니다. 결과는 Stagehand의 `data`와 `metadata`입니다. act는 페이지를 바꿀 수 있으므로 뒤에 Stagehand `observe`나 `extract`로 확인하며, 실패한 act도 이미 동작했을 수 있습니다. observe와 extract는 읽기만 합니다.

`BrowserInteract`의 click/fill과 `BrowserAct`의 요소 조작에는 관측한 selector를 사용하며, 정확히 하나의 요소와 일치해야 합니다. `BrowserInteract`의 `expectedUrl`에 직전에 읽은 URL을 넣으면 중간에 페이지가 이동한 경우 거부합니다. fill은 페이지 이벤트를 발생시키지만 자체적으로 Enter를 누르거나 submit하지 않습니다. 오류가 발생한 경우도 포함해 조작 후에는 페이지를 읽거나 캡처한 뒤 재시도 여부를 결정합니다.

## TUI 리더

`Ctrl-^`(Ctrl-Shift-6), `:` → `go Browser Lane`, 또는 Connectors의 `B`로 엽니다. 처음에는 live 소스입니다. `b`로 Firefox/Zen 연결 선택기를 열고 `j`/`k`와 Enter로 선택합니다. 선택기의 `r`은 재탐색, Esc는 리더로 복귀입니다. 읽기와 캡처는 선택한 연결에 고정되며, 연결이 끊어지면 새 연결을 명시적으로 선택해야 합니다.

| 키 | 동작 |
| --- | --- |
| `l` / `a` / `c` | live / automation / stagehand 소스 |
| `b` | live 브라우저 연결 선택 |
| `[` / `]` | 이전 / 다음 탭으로 이동하며 읽기 |
| `j` / `k`, 방향키 | 페이지 텍스트 스크롤 |
| Page Up / Page Down, Home | 페이지 스크롤 / 맨 위 |
| `r` | 재탐색 및 새로고침 |
| `Ctrl-O` | 선택 탭 PNG 미리보기; 아무 키로 복귀 |
| `g` | automation·stagehand URL 입력; Enter로 이동, Esc로 취소 |
| `o` / `x` | automation·stagehand 세션 열기 / 닫기 |
| `Ctrl-^` / Esc / Left | 리더를 숨기고 이전 화면으로 복귀 |

automation 페이지는 `a`, `o`, `g` 순서로 누른 뒤 URL을 입력합니다. stagehand 페이지는 `a` 대신 `c`를 누릅니다. PNG 미리보기에는 터미널 이미지 지원이 필요하며, 미지원 시 리더가 한계를 안내합니다. 미리보기는 Keeper에게 전송하지 않습니다. TUI 키는 읽기·캡처·automation 세션 탐색을 제공하며, 요소 조작은 위 도구로 실행합니다.

리더를 숨겨도 이 TUI 세션의 선택 탭, 텍스트 스크롤, 작성 중인 채팅 임시본은 유지됩니다. Browser 진입은 연속 음성 모드를 종료하고 전송 대기 중인 녹취를 포함한 음성 캡처를 버립니다.
