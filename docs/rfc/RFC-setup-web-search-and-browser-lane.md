---
rfc: "setup-web-search-and-browser-lane"
title: "웹 검색과 브라우저 레인도 음성처럼 다시 열리는 설정 명령을 갖는다"
status: Draft
created: 2026-09-17
updated: 2026-10-13
author: claude
supersedes: []
superseded_by: null
related: ["browser-keeper-firefox", "browser-live-one-connection"]
---

# RFC: 다시 열리는 설정 명령 (setup-web-search-and-browser-lane)

## 0. 요약

설치를 끝까지 마쳐도 웹 검색은 쓸 수 있는 공급자가 하나도 없다. 브라우저 레인은
실행 파일까지 설치되지만 그다음 절차가 손에 남는다.

설정하는 방법이 아예 없는 것은 아니다. `runtime.toml` 원문 편집기가 TUI 와
대시보드에 있고, 브라우저는 README 의 curl 절차와 그것을 가리키는 안내가 있다.
없는 것은 **무엇을 써야 하는지 알려주는 쪽**이다. 웹 검색은 구조화된 설정 화면에
나오지 않아서 섹션 이름부터 알 수 없고, 어느 공급자가 지금 쓸 수 있는지 묻는
방법도 없다. 브라우저는 확장 파일을 태그에 맞춰 손으로 받아야 한다.

음성은 이 문제를 이미 풀어놨다. `Voice_setup` 이 `[voice]` 섹션만 쓰고,
`masc voice-local-setup` 으로 따로 열려 있고, 설치 마법사 3단계는 그 명령을 그대로
자식 프로세스로 부른다. 건너뛴 사람에게는 명령 이름을 알려준다.

이 RFC 는 웹 검색과 브라우저 레인을 같은 모양으로 만든다. 설치 마법사에 단계를
더하는 것이 아니라, 언제든 다시 실행되는 명령을 먼저 만들고 마법사가 그것을 부른다.

2026-10-13 개정. 웹 검색(§4.1)은 #42821 로 구현했다. 브라우저(§4.2, §4.3)는 이
RFC 를 쓴 9/17 뒤에 두 번째 경로가 생겨서 다시 썼다. MASC 서버가 전용 Firefox 와
host 를 직접 띄우는 BiDi 경로다(RFC browser-keeper-firefox, 10/09). 브라우저를
연결하는 길이 이제 둘이므로, 명령은 어느 쪽인지 묻고 그 길에 필요한 것만 쓴다.
웹 도구 지원 의존성(geckodriver, Firefox, SearXNG, Stagehand)은 기존 설치 카탈로그에
더하고 운영자가 목록에서 고른다(§4.5).

2026-10-14 개정. 목록은 미리 체크된 채로 시작한다(§4.3). 처음 설치한 imp 가 브라우저도
GitHub 도 못 쓰는 상태를 기본으로 두지 않기 위해서다. 미리 체크하는 것은 비밀을 새로
만들거나 외부에 포트를 열지 않는 automation 레인과 웹 검색 점검이고, imp 의 GitHub
로그인은 운영자 결정(2026-10-14)과 확정 전의 공지(계정·scope·토큰 출처·복사본이라는
사실)를 조건으로 예외로 체크해 둔다. 인증 없는 포트를 여는 BiDi 와 사람이 매번 불러야
하는 확장은 해제로 시작한다. `gh` 는 샌드박스 이미지에 이미 있어서 카탈로그에 넣지
않는다(§4.5). 이 결정이 `--mode automation` 을 요구한다(§7).

## 1. 지금 일어나는 일

### 1.1 웹 검색

새로 만든 워크스페이스에서 WebSearch 를 부르면 실패한다.
`lib/tool_misc_web_search.ml:228` 의 `provider_has_credentials` 가 자격증명이 있는
공급자만 검색 순서에 넣고, 하나도 없으면 빈 순서가 그대로 실패로 나온다.

기본 순서는 `searxng`, `brave`, `tavily`, `exa`, `bing`, `ollama` 여섯 개다.
`brave_llm_context` 는 응답 모양이 달라서(결과 행 없이 본문 덩어리) 기본 순서에
들어가지 않고 설정으로만 고른다.

각 공급자가 보는 변수는 이렇다.

| 공급자 | 변수 |
|---|---|
| searxng | `MASC_SEARXNG_URL` |
| brave · brave_llm_context | `BRAVE_SEARCH_API_KEY` |
| tavily | `TAVILY_API_KEY` |
| exa | `EXA_API_KEY` |
| bing | `BING_SEARCH_API_KEY` 또는 `AZURE_BING_SEARCH_API_KEY` |
| ollama | `OLLAMA_API_KEY` |

설치 마법사(`scripts/install-runtime-setup.py:2067` `journey`)는 워크스페이스,
모델 연결, 음성, 샌드박스, 첫 대화 다섯 단계를 지나는 동안 웹 검색을 한 번도
묻지 않는다.

설치를 마친 뒤에 설정하려면 `runtime.toml` 을 원문으로 여는 수밖에 없다. 여는
방법은 셋이고 셋 다 원문 편집기다.

| 방법 | 어디 |
|---|---|
| TUI | `/settings` 의 `runtime.toml` pane 에서 `e` 가 `$EDITOR` 를 연다. 저장 전 preview 로 검증하고 커밋 영수증을 낸다 |
| 대시보드 | `dashboard/src/components/runtime-toml-editor.ts` |
| 파일 | `<base-path>/.masc/config/runtime.toml` |

앞의 둘은 `POST /api/v1/runtime/config/raw` 를 지난다
(`lib/server/server_routes_http_routes_dashboard.ml:2239`). `CanAdmin` 권한,
loader 검증, 감사 기록이 붙으므로 파일을 직접 고치는 것보다 안전하다.

없는 것은 여는 방법이 아니라 **무엇을 써야 하는지 알려주는 것**이다.

- 구조화된 설정 화면에 웹 검색이 없다. TUI 의 `params` pane 은 `Runtime_params`
  레지스트리를 읽는데 거기에 웹 검색 항목이 하나도 없다. 그래서 `[web_search]`
  라는 섹션이 있다는 것도, 키가 여섯이라는 것도, 어느 공급자가 어느 변수를 보는지도
  화면에 나오지 않는다. 원문 편집기는 이미 아는 사람만 쓸 수 있다.
- 지금 어느 공급자가 쓸 수 있는 상태인지 묻는 방법이 없다. `masc_config` 는 읽기
  전용이고 유효한 설정만 낸다. 비어 있는 이유가 변수가 없어서인지 순서에서 빠져서인지
  구분해주지 않는다.
- CLI 하위 명령에 웹 검색용이 없다.
- MCP 도구에도 없다. `masc_web_search` 는 검색만 하고 설정하지 않는다.
- 웹 검색 전용 HTTP 라우트가 없다. 음성은 `lib/server/server_voice_setup_actions.ml`
  로 열려 있다.
- 설치 마법사가 묻지 않는다.

그리고 어느 방법으로 열어도 API 키는 넣을 수 없다.
`lib/config/keeper_runtime_setting_registry.ml:564` 가 그 이유를 적어두었다 —
`runtime.toml` 은 커밋되는 파일이라서 비밀에는 TOML 키를 주지 않는다. 키는
`Env_only` 로 고정이고, 서버를 띄우는 셸에 직접 export 해야 한다.

TOML 로 저장할 수 있는 것은 여섯 개다: `web_search.searxng_url`,
`web_search.provider`, `web_search.provider_order`, `web_search.fallbacks`,
`web_search.timeout_sec`, `web_search.cache_ttl_sec`.

SearXNG 는 키가 필요 없는 유일한 공급자이고, 그것을 로컬에 세우는 헬퍼가
`scripts/searxng-local.sh` 에 이미 있다. Docker 로 컨테이너를 올리고
`start` / `status` / `logs` / `stop` 을 갖췄다. 다만 저장소 안에만 있고
`install.sh` 가 배포하지 않으므로 바이너리로 설치한 사람에게는 없는 물건이다.

### 1.2 브라우저 레인

`scripts/install.sh:1505` 는 이미 `masc-browser-host` 를 설치 위치에 넣는다
(`install_release_companion` 이 릴리즈 자산을 받아 체크섬을 확인하고 실행 권한을
준다). 실행 파일은 있다. 없는 것은 그다음 절차다.

설치 절차는 `masc browser-lane-setup` 이 한다(#42866, #42867 이 `install-host.sh` 를
지우고 그 일을 바이너리로 옮겼다). `--mode extension` 은 다음을 한다.

1. `.masc/browser-lane/token` 을 0600 으로 만들거나 기존 것을 보존한다
2. `masc-browser-host` 를 `.masc/browser-lane/host/` 로 복사한다
3. 서버 주소를 박지 않은 `launch` 스크립트를 쓴다
4. `launch.json` 에 `destination` 과 launcher 의 SHA-256 을 쓴다
5. Firefox 의 native messaging manifest 를 OS 별 위치에 쓴다
   (macOS `~/Library/Application Support/Mozilla/NativeMessagingHosts`,
   Linux `~/.mozilla/native-messaging-hosts`)

확장 파일 두 개(`manifest.json`, `background.js`)는 바이너리에 들어 있고 같은 명령이
`.masc/browser-lane/extension/` 에 쓴다.

없는 것은 이 명령을 알려주는 쪽이다. `scripts/install.sh` 는 설치를 마치며 README
링크를 한 줄 찍고(`browser registration: …`), 키퍼가 브라우저 도구를 부르면
`Browser_lane_launcher` 의 `Not_installed` 메시지가 `masc browser-lane-setup --mode
<길>` 을 이름으로 지목한다. `scripts/install-local-build.sh` 는 등록된 manifest 와
`--mode bidi`·`--mode host` 로만 깐 작업공간의 host 를 새 빌드로 다시 설치한다. 다만
그것은 소스 체크아웃이 있는 사람의 업그레이드 경로이고, 처음 설치를 대신하지 않는다.

온보딩 체크만 침묵한다. `lib/operator/onboarding_status.ml:149` 의
`browser_lane_check` 는 판정이 `Absent` 이면 체크를 만들지 않는다. 설치한 뒤에
어긋난 경우만 조언으로 나온다.

### 1.3 두 번째 경로 — 서버가 띄우는 BiDi Firefox

1.2 는 9/17 에 확인한 것이다. 그 뒤로 확장 없이 붙는 길이 생겼다
(`docs/design/browser-bidi-live-host.md`, 확인 2026-10-13).

- `runtime.toml` 에 `[browser.live.bidi]` (`firefox`, `profile`, 선택 `port`) 가
  있고 `[browser.live] enabled` 가 꺼져 있지 않으면, 서버가 시작할 때 그 프로필의
  Firefox 와 host 를 띄운다. 서버를 다시 띄워도 둘은 계속 돌고, 죽었으면 다음 서버
  시작에 다시 띄운다.
- 조건이 하나 있다. 브라우저 레인이 먼저 설치되어 있어야 한다. host 를 설치된
  `launch` 로 띄우기 때문이고, 설치가 안 되어 있으면 서버는 둘 다 띄우지 않는다.
  그래서 1.2 의 설치 절차는 이 길에서도 앞에 서 있다.
- 확장이 필요 없다. 브라우저를 끄면 임시 부가기능이 사라지는 문제가 이 길에는 없다.
- 대신 얻는 것과 잃는 것이 있다. Remote Agent 포트에는 인증이 없어서 로컬
  프로세스 누구나 그 브라우저를 움직이고 쿠키를 읽는다. 지금 설계는 전용 프로필에
  일하는 사이트만 로그인해 두어 범위를 줄인다(RFC browser-live-one-connection
  결정 1). `activate_tab` 은 확장 연결만 한다. Firefox 만 된다. Zen 은 BiDi 로
  시도하지 않았다.
- 운영자가 그 Firefox 에 한 번 로그인해야 한다. 프로필이 로그인을 기억한다.
- 확장 연결과 BiDi 연결이 같이 있으면 라이브 레인에 브라우저가 둘이 되어, 연결을
  지정하지 않은 요청은 `ambiguous_browser_clients` 로 거절된다.
- 이 표는 지금 운영자가 손으로 쓴다. 서버는 이 표를 스스로 쓰지 않는다(RFC
  browser-keeper-firefox §2.3). `runtime.toml` 은 모르는 키를 로드 오류로
  거절하므로, 표를 아는 서버가 설치된 뒤에 써야 한다.

그래서 브라우저 연결에 필요한 일은 길마다 다르다.

| 단계 | 확장 | BiDi |
|---|---|---|
| host 설치(토큰, 복사, `launch`, `launch.json`) | 필요 | 필요 |
| native messaging manifest | 필요 | 필요 없음 |
| 확장 파일 두 개 | 필요 | 필요 없음 |
| `[browser.live.bidi]` | 필요 없음 | 필요 |
| 브라우저에서 사람이 할 일 | `about:debugging` 에서 임시 로드(브라우저를 켤 때마다) | 전용 Firefox 에 한 번 로그인 |
| 서버 | 재시작 필요 없음 | 재시작 필요(표를 서버가 읽는다) |

### 1.4 live 가 아닌 레인 — automation(Firefox WebDriver)

1.2 와 1.3 은 운영자의 로그인된 브라우저에 붙는 live 레인이다. 로그인이 필요 없는
독립 조사에는 다른 레인이 이미 있다(`[browser.automation]`, 확인 2026-10-13).

- 서버가 시작할 때 geckodriver 를 띄우고, 서버가 끝나면 내린다. Keeper 가 세션을
  열고 닫는다(`BrowserSession`, `BrowserGoto`).
- 세션마다 새 프로필이라 로그인이 남지 않는다. live 브라우저로 등록되지도 않는다
  (`connectors/browser/host/README.md`).
- 필요한 것은 geckodriver 실행 파일의 절대 경로 하나다(`geckodriver`, 선택
  `binary`). host 설치도, 확장도, `[browser.live.bidi]` 도 필요 없다. 서버를 다시
  띄우면 읽는다.
- geckodriver 는 설치 경로가 깔아 주지 않는다. `scripts/install.sh`, `docs/INSTALL.md`,
  `README.md` 어디에도 이름이 없다.

live 와 automation 은 대체 관계가 아니다. 하는 일이 다르다. live 는 운영자가
로그인해 둔 사이트를 쓰고, automation 은 로그인 없이 공개된 페이지를 읽는다.

## 2. 마법사에 단계만 더하면 안 되는 이유

설치할 때 한 번 지나가는 화면이 된다. 그 자리에서 건너뛴 사람, 나중에 키를 새로
발급받은 사람, 다른 공급자로 옮기려는 사람은 §1.1 의 원문 편집기로 돌아간다.
원문 편집기는 이미 아는 사람에게만 쓸모가 있으므로, 마법사에서 한 번 본 화면이
그 사람이 받은 유일한 설명이 된다. 화면은 지나가고 설명은 남지 않는다.

지금 없는 것은 "설치 중에 묻는 화면" 이 아니라 "언제든 다시 열리는 설명" 이다.

마법사도 이미 다섯 단계다. 앞에 두 단계를 더 세우면 모델 연결까지 가는 길이
길어진다. 웹 검색과 브라우저는 모델 없이는 의미가 없으므로 뒤에 붙어야 하고,
뒤에 붙으면 건너뛰기 쉬운 자리가 된다. 건너뛰기 쉬운 자리일수록 다시 열리는
명령이 있어야 한다.

## 3. 따라갈 선례 — `Voice_setup`

`lib/voice_setup/voice_setup.mli` 가 이 모양을 이미 정해두었다.

- `[voice]` 섹션만 쓴다. 모든 변경이 `Runtime.edit_config_text` 를 지나므로 읽기,
  고치기, 커밋이 하나의 config 쓰기 잠금 안에서 일어난다.
- `Toml_line_editor` 를 쓰므로 주석과 상관없는 표가 바이트 단위로 살아남는다.
  운영자가 whisper 엔드포인트 위에 적어둔 측정값 — 전사 지연, 어느 필드를 비워야
  Authorization 헤더가 사라지는지, 서버가 붙들고 있는 메모리 — 을 섹션을 다시 만드는
  방식으로 쓰면 지워버린다.
- `Runtime_setup_batch` 위에 짓지 않았다. 그쪽은 파일 두 개를 `runtime-default-set`
  자식 프로세스 뒤에 준비하고 LLM 런타임이 도구 왕복에 답하는지 확인한다. 음성
  엔드포인트에는 해당하지 않는 절차이고, 음성을 쓰겠다고 `[runtime]` 을 다시 쓸
  이유도 없다.
- 비밀은 값이 아니라 이름으로 저장한다. 엔드포인트는 `api_key_env` 에 키가 담긴
  변수 이름을 적는다.

들어오는 문이 셋인데 쓰는 곳은 하나다.

| 문 | 어디 |
|---|---|
| CLI | `masc voice-local-setup` (`bin/main_eio.ml`) |
| 설치 마법사 | 그 CLI 를 `--voice`, `--model` 로 부르는 자식 프로세스 |
| HTTP | `lib/server/server_voice_setup_actions.ml` |

셋 다 `Voice_setup` 하나를 지난다. CLI 설명이 그것을 계약으로 적어두었다 —
"HTTP 라우트가 쓰는 것과 같은 writer 로 쓴다. 같은 revision guard, 그리고 loader 가
거부할 섹션은 publish 하지 않는다는 같은 원칙." 서버 쪽 모듈은 JSON 변환만 맡고
도메인을 갖지 않는다. `server_voice_setup_actions.mli` 가 그 경계를 적어두었다.

## 4. 제안

### 4.1 `Web_search_setup` 과 `masc web-search-setup`

`runtime.toml` 의 `[web_search]` 섹션만 쓰는 모듈을 만든다. `Voice_setup` 과 같이
`Runtime.edit_config_text` 와 `Toml_line_editor` 를 지나고, `Runtime_setup_batch`
위에 짓지 않는다. LLM 왕복 검증은 검색 공급자와 무관하다.

도메인은 모듈 안에 두고 CLI 는 그 위에 얇게 얹는다. HTTP 라우트는 이번에 만들지
않지만, 나중에 붙일 때 JSON 변환만 더하면 되도록 경계는 음성과 같게 둔다.

쓰는 값은 TOML 이 이미 받는 여섯 개다.

```toml
[web_search]
searxng_url    = "http://localhost:8888"
provider       = "brave"
provider_order = "searxng,brave,tavily"
fallbacks      = "exa"
timeout_sec    = 15
cache_ttl_sec  = 900.0
```

`provider_order` 를 쓸 때 주의할 것이 하나 있다. 기본 순서는 자격증명으로 걸러지지만
(`default_provider_order`), 설정된 순서는 걸러지지 않고 그대로 쓰인다
(`lib/tool_misc_web_search.ml:248`). 그래서 변수가 없는 공급자를 순서에 적으면
그 자리는 매번 실패한다. 명령은 저장하기 전에 그 상태를 알린다.

쓰지 않는 값은 API 키다.

명령의 값어치는 쓰는 쪽보다 보여주는 쪽에 있다. 네 값은 원문 편집기로도 쓸 수
있지만, 무엇을 쓸지 아는 사람만 그렇게 할 수 있다. 명령은 공급자마다 지금 상태를
보여준다. 자격증명이 있는 공급자와 없는 공급자를 나누고, 없는 쪽에는 어느 변수
이름을 export 해야 하는지 정확한 철자로 낸다. 판정은 `Tool_misc_web_search.provider_has_credentials`
가 쓰는 것과 같은 읽기 경로(`Env_config_core.raw_value_opt`)로 한다. 두 곳이 다른
경로를 읽어서 생긴 문제가 이미 한 번 있었다 — 공급자가 고를 수 있는 상태로 보인
다음 호출에서 아무것도 못 찾았다(#21972 P2-3).

**키 이름을 설정할 수 있게 만들지 않는다.** 음성은 엔드포인트마다 `api_key_env`
를 받지만 웹 검색은 변수 이름이 코드, 설정 레지스트리, 문서 세 곳에 같은 철자로
고정되어 있다. 이름을 고를 수 있어서 풀리는 문제가 지금 없고, 고를 수 있게 만들면
`provider_has_credentials` 의 match 가 설정을 읽어야 해서 "설정에는 있는데 값이
없는" 상태가 하나 더 생긴다. 이름은 고정으로 두고 명령이 그 이름을 화면에 낸다.

**구현됨: #42821.** 이 RFC 와 달라진 점이 둘 있다.

- 공급자 목록, 라벨, 자격증명 변수 이름을 `Tool_misc_web_search` 안에 두지 않고
  `Web_search_provider`(`lib/config`)로 뺐다. 검색 도구의 키 조회 6곳과 설정 명령이
  같은 표를 읽는다. 위 "같은 읽기 경로" 요구를 판정 함수 하나가 아니라 변수 이름
  전부로 넓힌 것이다.
- 명령이 정하는 파일은 서버가 읽는 경로다(`MASC_CONFIG_DIR` 포함). 워크스페이스
  안의 `.masc/config` 를 고정으로 쓰는 다른 설정 명령과 다르다.

### 4.2 `Browser_lane_setup` 과 `masc browser-lane-setup`

`install-host.sh` 가 하던 다섯 가지를 바이너리로 옮기고, 브라우저를 연결하는 길을
고르게 한다. 길은 `--mode extension` 과 `--mode bidi` 이고, 둘 다 줄 수 있다.
`--mode host` 는 host 만 깔고, `--mode automation` 은 연결이 아니라 automation 레인의
geckodriver 설정이다(아래). 고르지 않으면 아무것도 쓰지 않고 지금 상태와 두 길의
차이를 보여준다.

**항상 하는 일**(1.3 의 표에서 두 길이 같이 필요한 것):

1. `masc-browser-host` 를 찾는다(PATH, 그다음 설치 위치).
2. 토큰, host 복사, `launch`, `launch.json` 을 스크립트와 같은 파일, 같은 권한으로
   쓴다.

**`--mode extension` 이 더하는 일:**

3. native messaging manifest 를 OS 별 위치에 쓴다.
4. 내장한 확장 파일 두 개를 `.masc/browser-lane/extension/` 에 쓴다.
5. 브라우저에서 할 일을 알린다. `about:debugging#/runtime/this-firefox` 에서
   `manifest.json` 을 임시로 불러오고, 브라우저를 다시 켜면 다시 불러야 한다.

확장 파일은 `embedded_skills` 가 `skills/` 를 넣는 것과 같은 방식으로 바이너리에
넣는다(`ocaml-crunch -m plain`, `lib/embedded_config/dune`). 소스 체크아웃도 curl
도 필요 없어지고, 확장과 host 의 판이 항상 맞는다. 지금은 태그를 맞춰 받으라고
README 가 당부하는 것이 유일한 안전장치다.

**`--mode bidi` 가 더하는 일:**

3. `runtime.toml` 에 `[browser.live.bidi]` 를 쓴다. `Voice_setup` 과 같이
   `Runtime.edit_config_text` 와 `Toml_line_editor` 를 지나므로 주석과 다른 표는
   그대로 남는다. 쓴 뒤 `Browser_configuration` 으로 다시 읽어 loader 가 거절할
   표는 쓰지 않는다.
   - `firefox`: `--firefox PATH`. 주지 않으면 macOS 는
     `/Applications/Firefox.app/Contents/MacOS/firefox`, Linux 는 PATH 의
     `firefox` 를 절대 경로로 풀어 쓴다. loader 가 절대 경로만 받는다. 못 찾으면
     아무것도 쓰지 않고 `--firefox` 를 알린다.
   - `profile`: `--profile PATH`. 주지 않으면 `$HOME/masc-keeper-firefox-profile`.
     숨김 디렉터리 밑에 두지 않는다. Snap 으로 깐 Firefox 는 홈의 숨김 파일에 닿지
     못한다. 디렉터리가 없으면 만든다.
   - `port`: `--port N`. 주지 않으면 표에 쓰지 않고 기본값 9222 를 쓴다. 그
     포트가 이미 답하고 있으면 알린다. 일상 Firefox 가 그 플래그로 떠 있으면
     host 가 세션을 거절한다.
   - 표가 이미 있으면 값을 바꾸지 않고 현재 값을 보여준다. 운영자가 고른 프로필을
     덮어쓰면 로그인을 잃는다. 바꾸려면 플래그를 명시한다.
4. 사람이 할 일을 알린다. 서버를 다시 띄운 뒤 그 Firefox 가 뜨면 일하는 사이트에
   한 번 로그인한다. 포트에 인증이 없다는 것과 그것을 전용 프로필로 줄인다는 것을
   같이 적는다.

**`--mode host`**(구현하면서 더했다, #42976): 공통 부분만 한다. host 와 launcher 와
토큰만 쓰고 확장, manifest, `runtime.toml` 은 쓰지도 요구하지도 않는다. 브라우저를 손으로
붙이는 운영자와, 설치된 레인의 host 를 지금 빌드로 맞추는 쪽(`install-local-build.sh`)이
쓴다.

**`--mode automation`**(#43093): `runtime.toml` 에 geckodriver 절대 경로를 쓴다. 이름을
주지 않으면 PATH 가 처음 찾는 `geckodriver` 이고(카탈로그의 감지와 같은 함수다), 그
파일이 `--version` 에 답할 때만 쓴다. `--browser` 는 `binary` 키를 쓰고 이름을 줄 때만
쓴다. host, 확장, manifest, 토큰은 만들지 않는다. 키가 이미 있으면 값을 바꾸지 않고
있던 자리(`[browser.automation]` 또는 `[browser]` 직속)에서 고친다. 점 키나 인라인 표로
쓴 파일은 엄격한 TOML 판독기가 거절하는 모양이 되어서 편집하지 않는다(`--mode bidi` 도
같다. `Runtime_table_edit` 가 둘을 같이 지킨다).

**두 길 공통, 마지막에:** `Browser_lane_launcher.observe` 의 판정과 `masc doctor`
의 `browser_bidi_host` 줄이 말하는 것을 그대로 낸다. RFC
browser-live-one-connection 이 "설정 명령의 확인 단계"로 남겨 둔 일이 이것이다.
둘 다 고른 경우에는 연결을 지정하지 않은 요청이 거절될 수 있다는 것도 적는다.

`install-host.sh` 는 지웠다(#42867). 같은 일을 두 곳이 하면 한쪽만 고쳐지는 날이
온다. 부르는 쪽도 같이 바꿨다.

- `scripts/install-local-build.sh` 는 등록된 manifest 를 돌며 새 명령을 실행한다.
- `Browser_lane_launcher` 의 `install` 문장이 새 명령 이름을 말한다.
- `connectors/browser/host/README.md` 의 curl 절차가 새 명령으로 바뀌었다.

### 4.3 마법사

마법사는 명령을 음성과 같은 방식으로 부른다. 설정 로직을 Python 으로 옮겨오지 않고
`masc web-search-setup`, `masc browser-lane-setup` 을 자식 프로세스로 실행한다.
마법사에서 한 것과 나중에 손으로 한 것이 같은 코드를 지나야 결과가 갈리지 않는다.

자리는 샌드박스 다음, 첫 대화 앞이다. 모델 연결이 끝난 뒤라야 의미가 있고, 첫
대화 전이라야 첫 턴에서 쓸 수 있다. 단계 번호는 5 이고 첫 대화가 6 이 된다(#43119).

한 단계 안에서도 줄마다 때가 다르다. 서버가 브라우저 표를 시작할 때만 읽으므로
브라우저 줄은 `masc setup` 앞에 실행한다(`masc setup` 은 서버가 이미 답하면 새로 띄우지
않으므로, 그때는 재시작하라고 알린다). imp 는 `masc setup` 이 만들고 `keeper-github` 는
없는 keeper 를 거절하므로, GitHub 줄은 `masc setup` 이 끝난 뒤에 실행한다. 사람이 확정한
GitHub 줄은 `masc setup` 이 실패해 "Finish later" 로 나가도 잊히지 않게 나중에 할 명령을
알려 준다.

음성처럼 선택 단계이므로 여기서 실패해도 설치를 끝내지 않는다. `select_local_voice`
가 그 이유를 적어두었다. 선택인 단계는 자기가 선택인 대상을 무너뜨릴 수 없다.

빠른 설치 경로에서는 체크된 항목을 실행하지 않는다. 목록과 항목마다 명령 한 줄을
출력하고 끝낸다. 음성이 지금 그렇게 한다. "imp stays text only. Run masc
voice-local-setup to give it a voice later." 빠른 설치에는 줄을 표시하는 화면이 없으므로
아무도 고르지 않은 설치를 만들지 않는다. 목록을 만들려고 프로그램의 `--version` 과
`gh auth status` 는 실행한다. 설치하거나 쓰는 것은 없다. 무인 실행 플래그(`--yes`)는
만들지 않았다(#43119). 부르는 곳이 없고, GitHub 줄은 어느 경우에도 무인으로 실행하지
않는다.

브라우저 단계는 설치된 브라우저에 맞춰 보여준다.

- Firefox 실행 파일을 찾으면 두 길을 보여준다. 한 줄씩이다. 확장은 "일상 쓰는
  브라우저에 붙는다. 브라우저를 다시 켜면 부가기능을 다시 불러야 한다." BiDi 는
  "MASC 가 전용 Firefox 를 직접 띄운다. 다시 불러올 것이 없다. 그 Firefox 에 한 번
  로그인해야 하고, 같은 컴퓨터의 프로그램이 그 브라우저를 움직일 수 있다."
- Zen 만 있으면 확장 길만 보여준다. BiDi 는 Zen 으로 시도하지 않았다.
- 둘 다 없으면 아예 묻지 않는다. 브라우저 설치부터 권하는 것은 설치 마법사가 할
  일이 아니다.

기본값은 "한다"로 둔다(운영자 결정, 2026-10-14). 처음 설치한 imp 는 브라우저도 GitHub
도 못 써서 할 수 있는 일이 거의 없다. 그 상태를 기본으로 두면 설치를 끝낸 사람이 다시
설정 명령을 찾아 나서야 한다. 그래서 목록은 미리 체크된 채로 시작하고 사람이 빼는
쪽이다. 고르는 방식은 그대로다. 아무것도 자동으로 깔리지 않고, 사람이 목록을 보고
확정해야 실행된다.

미리 체크하는 것은 비밀을 새로 만들거나 외부에 포트를 열지 않는 것으로 한정한다. GitHub
로그인만 예외이고, 그 이유는 운영자 결정(2026-10-14)과 확정 전의 공지(계정·scope·토큰
출처·복사본이라는 사실)다.

| 항목 | 기본 | 이유 |
|---|---|---|
| automation 레인(`Geckodriver`, `Firefox`, `[browser.automation]` 쓰기) | 체크 | 로그인도 포트도 필요 없다. imp 가 공개 페이지를 읽는 일은 이것만으로 된다 |
| 웹 검색 점검(`masc web-search-setup`, §8 5b — 구현됨 #43145) | 체크 | 키가 없을 때 어느 공급자도 안 되는 이유를 보여준다. 키는 만들어 주지 않는다 |
| imp 의 GitHub 로그인 | 체크 | 이 컴퓨터의 `gh` 로그인이 있으면 체크 목록의 줄로 보여주고 확정 전에 알림을 먼저 찍는다(기본 체크). 없으면 `masc keeper-github login --keeper imp` 의 기기 코드를 사람이 승인한다. 체크를 풀거나 승인하지 않으면 아무것도 남지 않는다 |
| BiDi 길 | 해제 | 인증 없는 디버깅 포트를 연다. 그 Firefox 에 사람이 한 번 로그인해야 쓸모가 있다 |
| 확장 길 | 해제 | 브라우저를 켤 때마다 사람이 `about:debugging` 에서 불러야 한다 |

GitHub 로그인은 두 갈래다(운영자 결정, 2026-10-14).

- 이 컴퓨터의 `gh` 에 로그인이 있으면 체크 목록에 그 줄을 넣고 확정 전에 알림을 먼저
  찍는다. 계정, 호스트, scope, 토큰이 어디서 왔는지(키체인인지 `GH_TOKEN` 인지)를
  보여주고 목록에서 체크된 채로 시작한다. 그대로 확정하면 `gh auth token` 으로 읽은
  토큰을 `masc keeper-github set-token --keeper imp` 의 표준 입력으로 imp 의 신원에
  쓴다. 인자로 넘기면 다른 프로세스가 읽을 수 있고 출력에도 쓰지 않는다. 파일을 복사하지
  않는다. 토큰이 키체인에 있으면 `hosts.yml` 에 토큰이 없기 때문이다(2026-10-14 이
  컴퓨터에서 확인). `masc setup` 이 몇 분 걸릴 수 있어서 읽을 때는 동의한 계정을
  이름으로 부른다(`gh auth token --user <계정>`). 환경 변수 토큰(`GH_TOKEN`)은 `--user`
  로 찾지 못하므로 이름 없이 읽는다.
- 로그인이 없으면 `masc keeper-github login --keeper imp` 의 기기 코드를 사람이
  승인한다.

빠른 설치는 어느 갈래도 실행하지 않고 명령만 알린다. 토큰을 넘기는 일은 사람이 화면을
보고 확정해야 한다. 활성 계정이고 GitHub 가 토큰을 받아들이는 경우만 로그인으로 내놓는다.
`gh auth status --json hosts` 가 토큰 없이 계정, scope, 토큰이 있는 곳을 준다.

이 질문에 scope 로 기본값을 가르지 않는다. 대신 알려 둔다. imp 는 그 토큰으로 이 계정의
이름으로 push 와 PR 을 한다. scope 에 `workflow` 가 있으면 워크플로 파일을 바꿀 수
있다. 복사본이라 호스트 쪽 토큰을 폐기하거나 갱신하면 imp 쪽이 끊긴다. 이 질문은 imp
에게만 한다. 다른 Keeper 에는 같은 토큰을 자동으로 주지 않는다. 엔드포인트의 공용 토큰
환경 변수를 거절하는 이유(모든 Keeper 가 한 신원이 된다)와 같다.

BiDi 길의 로그인은 마법사가 못 한다. 서버를 띄우기 전에는 그 Firefox 가 없기
때문이다. 마법사는 끝에 "서버가 뜨면 이 Firefox 에서 한 번 로그인하세요" 를 적는다.

### 4.4 온보딩 체크는 바꾸지 않는다

`browser_lane_check` 가 `Absent` 에서 아무것도 내지 않는 지금 동작을 그대로 둔다.
설치하지 않은 사람에게 조언을 띄우기 시작하면 브라우저 레인을 쓸 생각이 없는
사람에게 매번 같은 줄이 붙는다. 존재를 알리는 일은 마법사 단계와 README 가 맡는다.

### 4.5 도구 지원 의존성을 카탈로그에 더한다

운영자 결정(2026-10-13): 설치는 목록에서 고른다. 자동으로 깔지 않는다. 범위는 가능한
한 넓게 가고 Stagehand 까지 넣는다. 운영자 결정(2026-10-14): 목록은 미리 체크된 채로
시작한다. 어느 항목을 체크해 두는지는 §4.3 의 표가 정한다.

새 틀은 만들지 않는다. `Sandbox_prerequisites` 가 이미 그 틀이다. 의존성이 닫힌
variant 이고, 동작은 운영자가 고르며, 쉘 문자열이 아니라 argv 로만 실행하고, 권한을
몰래 올리지 않는다. `masc prerequisite-actions <의존성> [--execute <ID>]` 와
`masc setup` 의 "Prepare imp's workspace" 가 이 카탈로그를 쓴다. 지금 카탈로그에는
샌드박스, 구독 CLI, PDF 도구, 발표자료 도구, whisper 가 있고 웹 도구 지원은 하나도
없다. 그래서 설치 직후 웹 검색도 브라우저도 안 된다.

variant 에 더하는 의존성:

| 의존성 | 켜주는 것 | macOS 동작 | Linux 동작 | 켜졌는지 보는 법 |
|---|---|---|---|---|
| `Geckodriver` | `[browser.automation]` | `brew install geckodriver` | 공식 릴리스 안내 열기 | 실행 파일이 `--version` 에 답한다 |
| `Firefox` | automation 의 브라우저, BiDi 길 | `brew install --cask firefox` | 배포판 안내 열기 | 실행 파일이 `--version` 에 답한다 |
| `Searxng` | 키 없는 웹 검색 | Docker 컨테이너를 띄운다 | 같음 | Docker 가 준비되어 있고 컨테이너가 답한다 |
| `Chromium` | stagehand 레인의 브라우저 | `brew install --cask chromium` | 안내 열기 | 실행 파일이 `--version` 에 답한다 |
| `Stagehand_extension` | stagehand 레인 | `install-stagehand-extension.sh` 가 하는 일(버전 고정, npm 무결성 검사) | 같음 | 확장 디렉터리가 있다 |

Homebrew 의 `geckodriver` formula 와 `firefox`·`chromium` cask 가 있는 것은
2026-10-13 에 `brew info` 로 확인했다. Linux 는 배포판마다 패키지 이름이 달라서
카탈로그의 기존 방식대로 공식 안내를 열고 감지를 다시 한다.

마법사는 이 카탈로그를 한 번에 감지해서 체크 목록으로 보여준다.

- 한 줄에 이름, 켜주는 기능, 지금 상태, 실행될 명령 한 줄, 관리자 권한이 필요한지를
  적는다. 체크 여부는 §4.3 의 표를 따른다. 그 표에 없는 항목(`Searxng`, `Chromium`,
  `Stagehand_extension`)은 해제로 시작한다. Docker 컨테이너를 띄우거나, 아직 잰 적
  없는 것이기 때문이다.
- 고른 것만 실행하고, 실행 뒤에 감지를 다시 한다(`Commands_completed_recheck_required`).
  실행한 동작이 성공했다고 켜졌다고 말하지 않는다.
- Homebrew 가 없으면 그 사실을 맨 앞에 적는다. Homebrew 를 설치하는 동작은 만들지
  않는다. 지금 카탈로그가 그렇게 정했다.
- API 키가 필요한 검색 공급자는 설치 대상이 아니다. 같은 목록에 "키 필요" 줄로
  보여주고 `masc web-search-setup` 을 가리킨다.

`gh` 는 이 카탈로그에 넣지 않는다(2026-10-14 확인). Keeper 샌드박스의 `base` 이미지
(`sandbox-images/base/Dockerfile`)가 이미 `gh` 를 담고 있고, MASC 가 Keeper 의 GitHub
CLI 설정을 게스트에 마운트한 뒤 거기서 `gh auth status` 를 확인한다. 이미지 주석은
"자격증명만 싣고 그것을 읽는 프로그램을 싣지 않아서 커밋은 되는데 PR 을 못 여는
Keeper" 를 만든 적이 있다고 적는다. 부족한 것은 프로그램이 아니라 Keeper 의 로그인이다.
로그인은 `masc keeper-github login <keeper>`(기기 코드 승인)나 `set-token` 이 한다.
호스트에 `gh` 를 깔아도 imp 의 샌드박스 안에서는 바뀌는 것이 없다. 호스트에 이미 로그인이
있으면 §4.3 의 동의를 받아 그 토큰을 imp 에게 넘길 수 있다.

알려진 어려움 둘:

- **SearXNG**: `scripts/searxng-local.sh` 는 JSON 출력을 켠 `settings.yml` 을 쓰고
  컨테이너를 띄운다. 이 스크립트는 저장소 안에만 있어서 바이너리로 설치한 사람에게는
  없다. 설정 파일 내용을 바이너리에 넣고, 카탈로그의 `writes` 필드로 쓰는 파일을
  밝히는 쪽이 이 틀에 맞다. Docker 가 먼저 준비되어 있어야 한다.
- **Stagehand**: `install-stagehand-extension.sh` 는 `npm` 과 `openssl` 을 요구한다.
  바이너리 설치는 Node.js 를 요구하지 않으므로(INSTALL.md), 이 동작은 Node.js 가 없는
  사람에게는 그 앞 단계가 막힌다. RFC browser-lane-stagehand 가 "아직 잰 적은
  없다"고 적은 가설이므로 목록 맨 끝에 둔다.

## 5. 하지 않는 것

- **서명 확장 배포(AMO).** 지금 확장은 temporary add-on 이라 브라우저를 껐다 켜면
  사라진다. 설정 명령을 돌려도 마찬가지다. 이것을 없애려면 서명과 배포 경로가
  필요하고, 설치 마법사의 범위를 벗어난다. 명령은 이 한계를 숨기지 않고 알린다.
- **웹 검색 키를 담는 새 파일 저장소.** 모델 공급자가 쓰는 `credential_file` 을
  웹 검색으로 넓히는 방법이 있지만, 지금 막힌 것은 키를 둘 곳이 아니라 무엇을
  어디에 두어야 하는지 알 방법이다. 안내로 풀리는 것을 저장소를 늘려서 풀지 않는다.
- **`runtime.toml` 에 비밀 허용.** 커밋되는 파일이다.
- **키 변수 이름을 설정 가능하게.** §4.1 에 이유를 적었다.
- **HTTP 라우트.** 음성에는 있지만 이번에는 만들지 않는다. 대시보드에서 이 설정을
  바꾸려는 요구가 아직 없다. 경계만 같게 두어 나중에 JSON 변환만 더하면 되게 한다.
- **웹 검색을 `Runtime_params` 에 등록하기.** 등록하면 TUI 의 `params` pane 에
  이름과 타입이 나오므로 §1.1 의 첫 번째 문제는 줄어든다. 그런데 나머지가 남는다.
  `params` pane 은 값을 보여주지 지금 어느 공급자가 쓸 수 있는지 판정하지 않고,
  API 키는 여기서도 못 쓴다. `Runtime_params` 는 살아 있는 서버를 조율하는 자리인데
  웹 검색 값은 요청할 때 읽으므로 성격도 다르다. 설정 명령을 만든 뒤에도 이 등록이
  따로 이득이면 그때 별도로 다룬다.

- **Remote Agent 포트의 인증.** Firefox 의 성질이라 이 명령이 바꿀 수 없다. loopback
  만 쓰고 전용 프로필로 범위를 줄이는 설계(RFC browser-live-one-connection 결정 1)를
  그대로 둔다.
- **일상 Firefox 에 Remote Agent 켜기.** 명령줄 플래그로만 켜므로 이미 떠 있는
  Firefox 에는 못 한다.
- **서버가 `[browser.live.bidi]` 를 스스로 쓰기.** RFC browser-keeper-firefox §2.3
  이 정한 대로 `runtime.toml` 은 운영자 것이다. 운영자가 이 명령을 실행해야 쓴다.
- **Zen 의 BiDi.** 시도하지 않았다. 명령은 `--firefox` 가 가리키는 파일을 막지
  않지만 동작을 약속하지 않는다.

## 6. 검증

| 확인할 것 | 방법 |
|---|---|
| 섹션이 생기고 주석이 살아남는다 | 주석과 다른 표가 든 `runtime.toml` 에 명령을 돌리고 그 바이트가 그대로인지 본다 |
| 두 번 돌려도 같다 | 같은 입력으로 두 번 돌리고 파일이 같은지 본다 |
| 자격증명 판정이 실제 호출과 맞다 | 변수를 하나만 둔 상태에서 명령이 낸 목록과 `provider_plan ()` 이 같은지 본다. `provider_order` 를 설정한 경우는 따로 본다 — 그때 `provider_plan ()` 은 자격증명으로 거르지 않으므로 두 목록이 갈리는 것이 정상이고, 명령은 그 차이를 알리는 쪽이어야 한다 |
| 브라우저 설정이 스크립트와 같은 결과를 낸다 | 같은 워크스페이스에 스크립트와 명령을 각각 돌려 파일 내용과 권한을 비교한다 |
| 업그레이드 경로가 끊기지 않는다 | `install-local-build.sh` 가 등록된 manifest 를 새 명령으로도 같은 수만큼 갱신하는지 본다 |
| 판정이 바뀐다 | 설정 전후로 `Browser_lane_launcher.verdict` 를 본다. 서버를 띄운 뒤라야 `Aligned` 가 되고, 띄우지 않으면 `Unverified` 에서 멈춘다 (`lib/browser_lane_launcher.ml:85`) |

이미 있는 테스트: `test/test_install_script.ml`,
`test/test_browser_native_host.py`, `connectors/browser/tests/`.

BiDi 길과 두 길 선택을 더한다.

| 확인할 것 | 방법 |
|---|---|
| `[browser.live.bidi]` 가 생기고 주석이 살아남는다 | 주석과 다른 표가 든 `runtime.toml` 에 `--mode bidi` 를 돌리고 그 바이트가 그대로인지, `Browser_configuration.of_file` 이 표를 읽는지 본다 |
| 있는 표를 덮어쓰지 않는다 | 다른 프로필이 적힌 표에 플래그 없이 돌리고 파일이 그대로인지 본다 |
| Firefox 를 못 찾으면 쓰지 않는다 | PATH 를 비우고 `--firefox` 없이 돌려 파일과 종료 코드를 본다 |
| 절대 경로가 아닌 값은 쓰지 않는다 | `--firefox firefox`, `--profile ~/x` 를 주고 loader 의 문장이 나오는지 본다 |
| 확장 길이 스크립트와 같은 결과를 낸다 | 같은 워크스페이스에 스크립트와 `--mode extension` 을 각각 돌려 파일 내용과 권한을 비교한다 |
| 두 길을 같이 골라도 같은 host 설치를 두 번 하지 않는다 | `--mode extension --mode bidi` 를 두 번 돌려 파일이 같은지 본다 |
| 판정이 바뀐다 | `masc doctor` 의 `browser_bidi_host` 와 `Browser_lane_launcher.verdict` 를 설정 전후로 본다 |

서버가 이 표로 Firefox 와 host 를 띄우는 일은 RFC browser-keeper-firefox 가 실측했다.
이 RFC 는 표를 쓰는 데까지만 검증한다.

## 7. 남는 문제

- temporary add-on 은 브라우저를 다시 켤 때마다 다시 로드해야 한다. 이 RFC 는
  풀지 않는다.
- 데스크톱에서 띄운 서버는 셸 rc 에 적은 export 를 읽지 못할 수 있다. 웹 검색 키가
  이 경우에 닿지 않는다. 지금도 같은 상태이고, 이 RFC 가 나쁘게 만들지도 낫게
  만들지도 않는다.

- 마법사의 기본 선택은 §4.3 의 표로 정했다(2026-10-14). 남은 것은 BiDi 를 기본으로
  켤지인데, 인증 없는 포트를 여는 일이라 운영자가 요청할 때만 바꾼다.
- 두 길을 같이 쓰면 연결을 지정하지 않은 요청이 거절된다. 명령은 그 사실을 알리고,
  어느 쪽을 기본으로 삼을지는 Keeper 의 연결 선택 규칙(RFC
  browser-live-one-connection)에 맡긴다.
- BiDi 길의 로그인은 사람이 한다. 서버가 뜬 뒤라야 그 Firefox 가 생기므로 설치
  마법사 안에서는 끝낼 수 없다.
- `--mode automation` 은 만들었다(2026-10-14 결정, #43093). 카탈로그가 geckodriver 와 Firefox 를
  깔아도 서버는 `runtime.toml` 의 `[browser.automation]` 을 읽을 때만 쓰므로(§1.4),
  기본으로 체크된 automation 항목은 그 표를 써야 끝난다. 쓰는 키는 `geckodriver` 절대
  경로이고 `binary` 는 운영자가 이름을 줄 때만 쓴다. BiDi 와 같이 표가 이미 있으면
  값을 바꾸지 않고(§4.2), 쓰기 전에 로더로 다시 읽는다.
- §4.5 의 `Stagehand_extension` 은 Node.js 를 요구한다. 설치기가 Node.js 없이도
  Stagehand 확장을 놓을 방법(확장을 릴리스에 넣을 수 있는지, 그 라이선스)은 확인하지
  않았다.

## 8. 구현 순서

한 PR 이 작업 한 단위(예상 출력 20k token 이하)를 넘지 않게 나눈다. 위에서 아래로
쌓는다.

1. 웹 검색 명령: #42821. 구현됨.
2. 카탈로그에 의존성을 더한다(§4.5). 감지와 동작만 더하고 마법사는 건드리지 않는다.
   `masc prerequisite-actions` 로 확인한다. 둘로 나눈다.
   - 2a. `Geckodriver`, `Firefox`: 명령 한 줄이거나 공식 페이지 열기뿐이라 기존 동작
     종류(`Run_commands`, `Open_official_installer`)로 된다. 구현됨(#42843).
   - 2b. `Searxng`: 설정 파일을 쓰고 컨테이너를 띄워야 한다. 새 동작 종류와 Docker
     준비 확인이 필요해서 따로 한다.
3. `Browser_lane_setup` 공통 부분과 `--mode extension`: host 설치를 바이너리로 옮기고
   확장 파일을 내장하고 `install-host.sh` 를 지운다. 부르는 쪽(`install-local-build.sh`,
   launcher 문장, README)도 같이 바꾼다. 구현됨(#42866, #42867).
4. `--mode bidi`: `[browser.live.bidi]` 를 쓴다. Firefox 탐색과 프로필 기본값. 구현됨
   (#42941). 같은 스택에서 `--mode host` 를 더했다(#42976).
4b. `--mode automation`: `[browser.automation]` 에 geckodriver 경로를 쓴다(§7). 구현됨
   (#43093).
5. 마법사 단계: 미리 체크된 목록(§4.3), 카탈로그의 항목들(§4.5), 세 명령
   (`web-search-setup`, `browser-lane-setup`, `keeper-github login`)을 부른다. 브라우저는
   설치된 것에 맞춰 길을 보여준다. 나눠서 한다.
   - 5a. 브라우저(automation) 줄과 GitHub 줄. 구현됨(#43119). 같은 PR 이 `pick` 에
     "아무것도 고르지 않음"(`allow_empty`)을 더했다.
   - 5b. 웹 검색 점검 줄. 옵션 없이 `masc web-search-setup` 을 실행해 아무것도 쓰지
     않고 공급자별 키 상태를 보여준다. 서버가 받을 환경(`MASC_BASE_PATH`,
     `MASC_CONFIG_DIR` 제외)으로 실행한다. 구현됨(#43145).
   - 5c. 해제로 시작하는 줄(BiDi, 확장, Searxng). BiDi 와 확장 줄은 구현됨(#43138).
     Searxng 은 2b 가 먼저다.
6. `Chromium`, `Stagehand_extension`: 값이 측정되지 않았으므로 마지막에 한다.
