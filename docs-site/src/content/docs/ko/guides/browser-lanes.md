---
title: 브라우저 레인 매뉴얼
description: Firefox 또는 Zen을 연결하고 페이지 읽기·조작과 Browser Lane TUI를 사용하는 방법.
---

MASC에는 두 가지 브라우저 소스가 있습니다.

- **live**는 브라우저 확장과 OCaml native messaging host로 운영자의 Firefox 또는 Zen에 연결합니다. 기존 탭과 로그인 세션을 사용하며, 텍스트·요소 목록·viewport 스크린샷 읽기와 명시적으로 선택한 탭의 click·fill·scroll을 지원합니다. 조작은 페이지를 변경하거나 페이지의 이벤트 핸들러를 실행할 수 있으며, 그 결과 페이지가 이동할 수도 있습니다.
- **automation**은 MASC의 OCaml WebDriver 클라이언트와 geckodriver로 별도 Gecko 브라우저 세션을 관리합니다. 운영자의 로그인 정보가 없는 격리 프로필로 시작합니다. 세션 열기/닫기와 직접 URL 이동은 이 소스의 기능입니다. 서버가 세션을 소유하므로 다른 작업이 사용 중인 세션을 닫기 전에는 사용 관계를 확인합니다.

## 설정: live

브라우저가 실행되는 머신에 빌드된 OCaml native host를 설치합니다. 여기서 `--binary`는 Firefox/Zen 실행 파일이 아니라 **masc-browser-host**입니다. `--base-path`는 `.masc` 자체가 아닌 `.masc`를 포함하는 워크스페이스 경로입니다.

```bash
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace \
  --server http://127.0.0.1:8935
```

설치기는 macOS와 Linux를 지원하며 Mozilla native messaging manifest를 등록합니다. 다른 manifest 디렉터리가 필요하면 `--manifest-dir`로 지정합니다. Firefox 또는 Zen의 `about:debugging` → **임시 부가 기능 로드**에서 `connectors/browser/extension/manifest.json`을 선택합니다. 브라우저가 종료되면 임시 로드도 끝납니다.

각 연결은 브라우저 종류와 `clientId` UUID를 보고합니다. live 연결이 하나면 자동으로 선택할 수 있고, 여러 개면 원하는 UUID를 선택해야 합니다. 탭 ID는 연결마다 별개이므로 서로 다른 브라우저에서 같은 숫자일 수 있습니다. 끊어진 UUID는 다른 브라우저로 대체하지 않고 거부합니다. 재연결하면 새 UUID를 탐색해 다시 선택합니다.

## 설정: automation

geckodriver를 loopback에서 실행합니다.

```bash
geckodriver --host 127.0.0.1 --port 4444
```

해석된 설정 디렉터리의 `runtime.toml`에 다음을 넣고 MASC를 재시작합니다.

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
# 선택 사항: 설치된 Firefox 또는 Zen 실행 파일/app bundle 지정.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

`webdriver_url`은 loopback HTTP origin이어야 합니다. `binary`는 절대 경로여야 하며 `webdriver_url`이 함께 필요합니다. 생략하면 geckodriver가 브라우저를 탐색하므로, Firefox 또는 Zen을 명시적으로 고르려면 지정합니다. 이 설정은 live 연결을 선택하지 않습니다. automation은 기본적으로 headless로 열립니다.

## Keeper와 MCP 도구

Keeper에 보이는 이름은 CamelCase이고, MCP 등록 이름은 `masc_browser_*`입니다.

| Keeper 도구 | MCP 이름 | 소스와 동작 |
| --- | --- | --- |
| `BrowserTabs` | `masc_browser_tabs` | 양쪽: 탭 목록과 live 연결 식별자 탐색 |
| `BrowserRead` | `masc_browser_read` | 양쪽: 텍스트·보이는 요소·viewport PNG 읽기 |
| `BrowserInteract` | `masc_browser_interact` | 양쪽: 명시적으로 선택한 탭 click·fill·scroll |
| `BrowserSession` | `masc_browser_session` | automation: 세션 열기/닫기 |
| `BrowserGoto` | `masc_browser_goto` | automation: HTTP(S) URL로 이동 |
| `BrowserAct` | `masc_browser_act` | automation: 탭 열기/닫기, click·fill·press·select·scroll·back·forward·reload |

탐색 결과의 `clientId`와 `tabId`를 이후 live 읽기·조작에 전달합니다. live 브라우저가 여러 개면 `clientId`가 필수이며, automation에는 전달하지 않습니다.

`BrowserRead`의 기본값은 `mode="text"`, `format="text"`, Unicode code point 50,000개입니다. `maxChars`는 최대 100,000이며 결과의 `truncated`를 확인합니다. `mode="elements"`는 레이블과 관측한 CSS selector를 포함해 보이는 컨트롤을 최대 200개 반환합니다. `format="image"`에는 명시적인 `tabId`가 필요하며, Keeper 호출은 이미지 분석에 사용할 영속 artifact handle을 반환합니다. 텍스트와 요소 읽기는 현재 렌더된 페이지 기준이므로 숨겨지거나 가상 스크롤 뒤에 있는 모든 항목을 포함하지 않습니다.

`BrowserInteract`의 click/fill과 `BrowserAct`의 요소 조작에는 관측한 selector를 사용하며, 정확히 하나의 요소와 일치해야 합니다. `BrowserInteract`의 `expectedUrl`에 직전에 읽은 URL을 넣으면 중간에 페이지가 이동한 경우 거부합니다. fill은 페이지 이벤트를 발생시키지만 자체적으로 Enter를 누르거나 submit하지 않습니다. 오류가 발생한 경우도 포함해 조작 후에는 페이지를 읽거나 캡처한 뒤 재시도 여부를 결정합니다.

## TUI 리더

`Ctrl-^`(Ctrl-Shift-6), `:` → `go Browser Lane`, 또는 Connectors의 `B`로 엽니다. 처음에는 live 소스입니다. `b`로 Firefox/Zen 연결 선택기를 열고 `j`/`k`와 Enter로 선택합니다. 선택기의 `r`은 재탐색, Esc는 리더로 복귀입니다. 읽기와 캡처는 선택한 연결에 고정되며, 연결이 끊어지면 새 연결을 명시적으로 선택해야 합니다.

| 키 | 동작 |
| --- | --- |
| `l` / `a` | live / automation 소스 |
| `b` | live 브라우저 연결 선택 |
| `[` / `]` | 이전 / 다음 탭으로 이동하며 읽기 |
| `j` / `k`, 방향키 | 페이지 텍스트 스크롤 |
| Page Up / Page Down, Home | 페이지 스크롤 / 맨 위 |
| `r` | 재탐색 및 새로고침 |
| `Ctrl-O` | 선택 탭 PNG 미리보기; 아무 키로 복귀 |
| `g` | automation URL 입력; Enter로 이동, Esc로 취소 |
| `o` / `x` | automation 세션 열기 / 닫기 |
| `Ctrl-^` / Esc / Left | 리더를 숨기고 이전 화면으로 복귀 |

automation 페이지는 `a`, `o`, `g` 순서로 누른 뒤 URL을 입력합니다. PNG 미리보기에는 터미널 이미지 지원이 필요하며, 미지원 시 리더가 한계를 안내합니다. 미리보기는 Keeper에게 전송하지 않습니다. TUI 키는 읽기·캡처·automation 세션 탐색을 제공하며, 요소 조작은 위 도구로 실행합니다.

리더를 숨겨도 이 TUI 세션의 선택 탭, 텍스트 스크롤, 작성 중인 채팅 임시본은 유지됩니다. Browser 진입은 연속 음성 모드를 종료하고 전송 대기 중인 녹취를 포함한 음성 캡처를 버립니다.
