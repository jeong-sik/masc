---
rfc: "setup-web-search-and-browser-lane"
title: "웹 검색과 브라우저 레인도 음성처럼 다시 열리는 설정 명령을 갖는다"
status: Draft
created: 2026-09-17
updated: 2026-09-17
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: 다시 열리는 설정 명령 (setup-web-search-and-browser-lane)

## 0. 요약

설치를 끝까지 마쳐도 웹 검색은 쓸 수 있는 공급자가 하나도 없고, 브라우저 레인은
그런 기능이 있다는 표시조차 나오지 않는다. 둘 다 설정하는 방법이 제품 안에 없다.
`runtime.toml` 을 직접 열거나 `connectors/browser/host/README.md` 의 curl 절차를
손으로 따라가는 것이 전부다.

음성은 이 문제를 이미 풀어놨다. `Voice_setup` 이 `[voice]` 섹션만 쓰고,
`masc voice-local-setup` 으로 따로 열려 있고, 설치 마법사 3단계는 그 명령을 그대로
자식 프로세스로 부른다. 건너뛴 사람에게는 명령 이름을 알려준다.

이 RFC 는 웹 검색과 브라우저 레인을 같은 모양으로 만든다. 설치 마법사에 단계를
더하는 것이 아니라, 언제든 다시 실행되는 명령을 먼저 만들고 마법사가 그것을 부른다.

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

설치를 마친 뒤에 바꾸려고 해도 갈 곳이 없다.

- `masc_config` 도구는 읽기 전용이다. 유효한 설정을 출처와 함께 보여주고 민감한
  값은 가린다. 쓰지는 않는다.
- CLI 하위 명령에 웹 검색용이 없다. 모델 런타임용 `runtime-default-set`,
  `runtime-probe`, `runtime-wizard-catalog` 만 있다.
- TUI 슬래시 명령에도 설정 화면이 없다.
- 서버 라우트에도 없다. 음성은 `lib/server/server_voice_setup_actions.ml` 로 열려
  있지만 `lib/server/` 어디에도 웹 검색 설정을 받는 자리가 없다.
- 남는 것은 `<base-path>/.masc/config/runtime.toml` 을 직접 여는 것뿐이다.

그런데 직접 열어도 API 키는 넣을 수 없다.
`lib/config/keeper_runtime_setting_registry.ml:564` 가 그 이유를 적어두었다 —
`runtime.toml` 은 커밋되는 파일이라서 비밀에는 TOML 키를 주지 않는다. 키는
`Env_only` 로 고정이고, 서버를 띄우는 셸에 직접 export 해야 한다.

TOML 로 저장할 수 있는 것은 네 개다: `web_search.searxng_url`,
`web_search.provider`, `web_search.provider_order`, `web_search.fallbacks`.

### 1.2 브라우저 레인

`scripts/install.sh:1376` 은 이미 `masc-browser-host` 를 설치 위치에 넣는다.
실행 파일은 있다. 없는 것은 그 다음 절차다.

`connectors/browser/install-host.sh` 가 하는 일은 다음과 같다.

1. `.masc/browser-lane/token` 을 0600 으로 만들거나 기존 것을 보존한다
2. `masc-browser-host` 를 `.masc/browser-lane/host/` 로 복사한다
3. 서버 주소를 박지 않은 `launch` 스크립트를 쓴다
4. `launch.json` 에 `destination` 과 launcher 의 SHA-256 을 쓴다
5. Firefox 의 native messaging manifest 를 OS 별 위치에 쓴다
   (macOS `~/Library/Application Support/Mozilla/NativeMessagingHosts`,
   Linux `~/.mozilla/native-messaging-hosts`)

확장 파일 두 개(`manifest.json`, `background.js`)는 이 스크립트가 건드리지 않는다.
소스 체크아웃이 없으면 GitHub 에서 태그를 맞춰 curl 로 받아야 한다.

온보딩 체크는 설치하지 않은 사람에게 아무것도 말하지 않는다.
`lib/operator/onboarding_status.ml:149` 의 `browser_lane_check` 는 판정이
`Absent` 이면 체크를 만들지 않는다. 설치한 뒤에 어긋난 경우만 조언으로 나온다.
그래서 처음 쓰는 사람은 이런 기능이 있다는 것을 알 방법이 없다.

## 2. 마법사에 단계만 더하면 안 되는 이유

설치할 때 한 번 지나가는 설정이 된다. 그 자리에서 건너뛴 사람, 나중에 키를 새로
발급받은 사람, 다른 공급자로 옮기려는 사람 모두 돌아올 곳이 없다. 지금 없는 것은
"설치 중에 묻는 화면" 이 아니라 "설정하는 방법" 이다.

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

쓰는 값은 TOML 이 이미 받는 네 개다.

```toml
[web_search]
searxng_url    = "http://localhost:8888"
provider       = "brave"
provider_order = "searxng,brave,tavily"
fallbacks      = "exa"
```

쓰지 않는 값은 API 키다. 대신 명령이 공급자마다 지금 상태를 보여준다. 자격증명이
있는 공급자와 없는 공급자를 나누고, 없는 쪽에는 어느 변수 이름을 export 해야
하는지 정확한 철자로 낸다. 판정은 `Tool_misc_web_search.provider_has_credentials`
가 쓰는 것과 같은 읽기 경로(`Env_config_core.raw_value_opt`)로 한다. 두 곳이 다른
경로를 읽어서 생긴 문제가 이미 한 번 있었다 — 공급자가 고를 수 있는 상태로 보인
다음 호출에서 아무것도 못 찾았다(#21972 P2-3).

**키 이름을 설정할 수 있게 만들지 않는다.** 음성은 엔드포인트마다 `api_key_env`
를 받지만 웹 검색은 변수 이름이 코드, 설정 레지스트리, 문서 세 곳에 같은 철자로
고정되어 있다. 이름을 고를 수 있어서 풀리는 문제가 지금 없고, 고를 수 있게 만들면
`provider_has_credentials` 의 match 가 설정을 읽어야 해서 "설정에는 있는데 값이
없는" 상태가 하나 더 생긴다. 이름은 고정으로 두고 명령이 그 이름을 화면에 낸다.

### 4.2 `Browser_lane_setup` 과 `masc browser-lane-setup`

`install-host.sh` 가 하는 다섯 가지를 바이너리로 옮기고, 스크립트가 하지 않던
확장 파일 배치를 더한다.

확장 파일은 `embedded_config` 방식으로 바이너리에 넣는다. `lib/embedded_config/dune`
가 `ocaml-crunch -m plain` 으로 `config/` 트리를 넣는 것과 같은 방식이고, 그래서
`masc init` 이 네트워크 없이 `.masc/config/` 를 만든다. 확장도 같은 자리에 넣으면
소스 체크아웃도 curl 도 필요 없어지고, 확장과 native host 의 판이 항상 맞는다.
지금은 태그를 맞춰 받으라고 README 가 당부하는 것이 유일한 안전장치다.

명령이 하는 일:

1. `masc-browser-host` 를 찾는다 (PATH, 그다음 설치 위치)
2. 토큰, host 복사, `launch`, `launch.json`, native messaging manifest — 스크립트와
   같은 파일을 같은 권한으로 쓴다
3. 내장한 확장 파일 두 개를 `.masc/browser-lane/extension/` 에 쓴다
4. Firefox 나 Zen 이 있는지 보고, 있으면 `about:debugging#/runtime/this-firefox` 에서
   할 일을 알려준다
5. `Browser_lane_launcher.observe` 의 판정을 그대로 낸다

`install-host.sh` 는 지운다. 같은 일을 두 곳이 하면 한쪽만 고쳐지는 날이 온다.
`connectors/browser/host/README.md` 의 curl 절차도 새 명령으로 바꾼다.

### 4.3 마법사

마법사는 두 명령을 음성과 같은 방식으로 부른다. 설정 로직을 Python 으로 옮겨오지
않고 `masc web-search-setup`, `masc browser-lane-setup` 을 자식 프로세스로 실행한다.
마법사에서 한 것과 나중에 손으로 한 것이 같은 코드를 지나야 결과가 갈리지 않는다.

자리는 샌드박스 다음, 첫 대화 앞이다. 모델 연결이 끝난 뒤라야 의미가 있고, 첫 대화
전이라야 첫 턴에서 쓸 수 있다.

음성처럼 선택 단계이므로 여기서 실패해도 설치를 끝내지 않는다. `select_local_voice`
가 그 이유를 적어두었다 — 선택인 단계는 자기가 선택인 대상을 무너뜨릴 수 없다.

빠른 설치 경로에서는 둘 다 건너뛰고 명령 이름을 알린다. 음성이 지금 그렇게 한다 —
"imp stays text only. Run masc voice-local-setup to give it a voice later."

브라우저 단계는 Firefox 나 Zen 이 없으면 아예 묻지 않는다. 없는 사람에게 브라우저
설치부터 권하는 것은 설치 마법사가 할 일이 아니다.

### 4.4 온보딩 체크는 바꾸지 않는다

`browser_lane_check` 가 `Absent` 에서 아무것도 내지 않는 지금 동작을 그대로 둔다.
설치하지 않은 사람에게 조언을 띄우기 시작하면 브라우저 레인을 쓸 생각이 없는
사람에게 매번 같은 줄이 붙는다. 존재를 알리는 일은 마법사 단계와 README 가 맡는다.

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

## 6. 검증

| 확인할 것 | 방법 |
|---|---|
| 섹션이 생기고 주석이 살아남는다 | 주석과 다른 표가 든 `runtime.toml` 에 명령을 돌리고 그 바이트가 그대로인지 본다 |
| 두 번 돌려도 같다 | 같은 입력으로 두 번 돌리고 파일이 같은지 본다 |
| 자격증명 판정이 실제 호출과 맞다 | 변수를 하나만 둔 상태에서 명령이 낸 목록과 `provider_plan ()` 이 같은지 본다 |
| 브라우저 설정이 스크립트와 같은 결과를 낸다 | 같은 워크스페이스에 스크립트와 명령을 각각 돌려 파일 내용과 권한을 비교한다 |
| 판정이 바뀐다 | 설정 전후로 `Browser_lane_launcher.verdict` 가 `Absent` 에서 `Aligned` 로 가는지 본다 |

이미 있는 테스트: `test/test_install_script.ml`,
`test/test_browser_native_host.py`, `connectors/browser/tests/`.

## 7. 남는 문제

- temporary add-on 은 브라우저를 다시 켤 때마다 다시 로드해야 한다. 이 RFC 는
  풀지 않는다.
- 데스크톱에서 띄운 서버는 셸 rc 에 적은 export 를 읽지 못할 수 있다. 웹 검색 키가
  이 경우에 닿지 않는다. 지금도 같은 상태이고, 이 RFC 가 나쁘게 만들지도 낫게
  만들지도 않는다.
