# 사람이 자기 API key 로 Claude Code 를 쓰게 하려면 — 공식 문서, CLI 측정, 지금 코드

- 날짜: 2026-11-17
- 관련 결정: [RFC-a-persons-api-key-is-their-own-provider-account](../rfc/RFC-a-persons-api-key-is-their-own-provider-account.md)
- 공식 문서: <https://code.claude.com/docs/en/authentication>, <https://code.claude.com/docs/en/cli-reference>. 2026-11-17 17시대(KST)에 읽었다. 인용은 원문 그대로다. 신뢰도 High.
- 측정 대상: Claude Code 2.1.326, macOS 27.2(arm64). 가짜 키만 썼다. 과금된 호출은 없다.
- 코드 사실: main `55c86a8b2ee5` 에서 읽었다.
- 이 문서는 연구 기록이다. 무엇을 만들지는 위 RFC 가 정한다.

## 0. 요약

- 공식 CLI 는 `ANTHROPIC_API_KEY` 환경 변수를 로그인보다 먼저 쓴다. `-p`(비대화) 실행에서는 그 변수가 있으면 항상 쓴다.
- `claude auth status` 는 키를 검증하지 않는다. 가짜 키를 줘도 "로그인됨, `api_key`"로 답한다. 키가 맞는지는 모델을 실제로 불러야 안다.
- 잘못된 키로 부르면 결과에 `is_error: true` 와 `api_error_status: 401` 이 온다. MASC 는 이 숫자를 이미 읽는다.
- CLI 는 키 문자열을 설정 폴더에 남기지 않았다. 대화 기록은 남긴다.
- MASC 의 다계정 서버는 선언된 계정 홈에 자격 변수를 하나도 넘기지 않는다. 사람이 키를 넣는 길도, 사람의 비밀값을 두는 곳도, 계정을 없애는 기록도 지금은 없다.
- 키 없이 API 과금으로 쓰는 길이 따로 있다. `claude auth login --console` 이다. 이 길은 재지 못했다.

## 1. 공식 문서가 말하는 것

| 주제 | 원문 | 여기서 쓰는 뜻 |
|---|---|---|
| 자격을 고르는 순서 | 1 cloud provider, 2 `ANTHROPIC_AUTH_TOKEN`, 3 `ANTHROPIC_API_KEY`, 4 `apiKeyHelper`, 5 `CLAUDE_CODE_OAUTH_TOKEN`, 6 Anthropic profile, 7 `/login` 의 구독 OAuth | 환경 변수 키는 구독 로그인보다 앞이다 |
| 비대화 실행 | "In non-interactive mode (`-p`), the key is always used when present" | 한 홈에 로그인과 키가 같이 있으면 키로 과금된다 |
| 로그인 명령 | "Use `--email` to pre-fill your email address, `--sso` to force SSO authentication, and `--console` to sign in with Anthropic Console for API usage billing instead of a Claude subscription" | 키를 다루지 않고 API 과금으로 쓰는 길이 있다 |
| 상태 명령 | `claude auth status` 는 JSON 을 내고, 로그인됐으면 0, 아니면 1 로 끝난다. "`authMethod` field is one of `none`, `claude.ai`, `oauth_token`, `api_key`, `api_key_helper`, or `third_party`" | 값은 여섯 가지다 |
| Console 로그인의 두 갈래 | Console 계정으로 로그인하면 OAuth token 을 Anthropic profile 로 두고 키를 만들지 않는다. "Create an API key (legacy)"는 Console 키를 만들어 다른 자격과 같이 둔다 | 갈래에 따라 자격이 놓이는 곳이 다르다 |
| profile 의 자리 | "Separate directories don't keep two Claude Console sign-ins without an API key apart, because Claude Code stores that kind of sign-in outside the configuration directory." | 설정 폴더만 나눠서는 두 사람의 Console 로그인이 섞인다 |
| 저장소 | macOS 는 Keychain 이고 설정 폴더로 구분한다. Linux 는 설정 폴더의 `.credentials.json`(0600)이다. "A Console login that creates an API key fails until the Keychain is writable" | 로그인 자격은 CLI 가 보관한다 |
| bare 모드 | "If your script passes `--bare`, authenticate with `ANTHROPIC_API_KEY` or an `apiKeyHelper` instead." | bare 모드에서도 환경 변수 키는 읽힌다 |
| 관리 설정 | `forceLoginMethod`, `forceLoginOrgUUID` 가 있으면 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper` 세션이 시작할 때 막힌다 | 그런 장비에서는 키로 쓰지 못한다 |
| 긴 token | `claude setup-token` 은 1년짜리 OAuth token 을 찍고 저장하지 않는다. 구독 전용이다 | API 과금과 무관하다 |

## 2. 이 장비에서 잰 것

### 2.1 방법

빈 폴더 둘(`HOME`, 설정 폴더)을 만들고, 환경을 비운 채 아래 이름만 줬다.
MASC 가 선언된 계정 홈에 주는 이름과 같은 종류다.

```sh
env -i HOME=<빈 폴더> USER=$USER PATH="$PATH" TMPDIR=<빈 폴더> TERM=dumb NO_COLOR=1 \
  CLAUDE_CONFIG_DIR=<빈 설정 폴더> ANTHROPIC_CONFIG_DIR=<빈 설정 폴더>/anthropic \
  [ANTHROPIC_API_KEY=<가짜 값>] claude auth status
```

가짜 값은 `sk-ant-api03-` 로 시작하는, 키가 아닌 문자열이다.
턴은 같은 환경에서 `claude -p "hi" --output-format json` 으로 한 번 돌렸다.

### 2.2 결과

| 조건 | 종료 코드 | 답 |
|---|---|---|
| 자격 없음, `auth status` | 1 | `loggedIn: false`, `authMethod: "none"`, `apiProvider: "firstParty"` |
| 가짜 키, `auth status` | 0 | `loggedIn: true`, `authMethod: "api_key"`, `apiProvider: "firstParty"`, `apiKeySource: "ANTHROPIC_API_KEY"` |
| 가짜 키, `-p` 턴 | 1 | `type: "result"`, `subtype: "success"`, `is_error: true`, `api_error_status: 401`, `result: "Invalid API key · Fix external API key"`, `total_cost_usd: 0` |

- `auth status` 는 키가 있다는 것만 본다. 가짜 키도 "로그인됨"이다.
- 두 번째 행의 `apiKeySource` 는 위 문서에서 찾지 못한 필드다. 측정에서만 봤다.
- 설정 폴더에 생긴 것은 `.claude.json`, `backups/`, `plugins/`, `projects/`, `sessions/` 다. `projects/` 아래에 그 턴의 기록(`.jsonl`)이 있다.
- 가짜 키의 어느 부분도 두 폴더의 파일에 없었다(`rg` 로 확인).

## 3. 지금 코드

### 3.1 CLI 가 받는 환경

- 자식 프로세스의 환경은 허용 목록이다. 선언된 홈은 이름 14개만 받는다(`runtime_claude_environment_projection.ml:6`, `inherited_names`).
  `ANTHROPIC_API_KEY` 같은 자격·경로 변수는 빠진다.
- 홈을 선언하지 않았으면 `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, 클라우드 provider 선택·자격·endpoint 변수도 상속한다. `Runtime_official_account.capture` 의 최종 `validate_environment` 는 이름이 중복되면 거절한다. 따라서 파일 키를 받게 할 때는 홈 선언 여부와 별개로 상속 범위와 키가 하나만 실리는 규칙을 정해야 한다.
- 선언된 홈에는 `CLAUDE_CONFIG_DIR=<홈>` 과 `ANTHROPIC_CONFIG_DIR=<홈>/anthropic` 을 준다(같은 파일 `:52`, `of_inherited`).
  profile 이 설정 폴더 밖에 놓이는 것을 홈 안으로 돌리려는 것이다.
- 환경을 만드는 곳은 `Runtime_official_account.capture` 하나다(`runtime_official_account.ml:123`).
  이 타입은 JSON 이나 출력용 변환이 없다. 환경에 자격이 들어 있을 수 있어서다.
- `claude-code` provider 가 `credentials` 를 선언하면 거절한다(`runtime_adapter.ml:1057`).

### 3.2 `auth status` 를 읽는 곳

- `Runtime_claude_code.parse_subscription`(`runtime_claude_code.ml:604`)이 읽는다. `loggedIn` 이 false 면 `authMethod` 를 읽지 않고 "로그인 필요"로 끝난다.
- `authMethod` 는 `claude.ai`, `api_key`, `oauth_token`, `third_party` 만 안다. `api_key_helper` 가 오면 프로토콜 오류다.
- 사람의 로그인은 `claude auth login` 으로 띄운다(`runtime_setup_login_client.ml:116`). 플래그가 없다.

### 3.3 실패한 턴을 읽는 곳

- 결과 프레임의 `is_error` 와 `api_error_status` 를 값으로 읽는다(`runtime_claude_code.ml:2154`).
- 오류면 `Turn_failed_with_observation { api_error_status; … }` 가 된다. 문장을 보고 가르지 않는다.

### 3.4 사람의 계정

- 사람의 계정은 로그인으로만 생긴다. 로그인이 확인되면 권한 로그에 `{"event":"linked","provider_account_id","user_id"}` 를 쓴다(`server_setup_account_login.ml:125`, `Authz_provider_account.link`).
- 계정이 어느 provider 것인지는 로그인 영수증 파일(`Runtime_setup_login_receipt`)의 `integration_id` 가 말한다. 턴과 확인이 이 값을 읽는다(`server_setup_account_login.ml:412`, `person_runtime`).
- 계정 홈은 `<.masc>/accounts/<namespace>/official-clients/<client>/<account id>` 다(`runtime_account_home_layout.mli`).
- 사람의 route 에 키를 받는 것과 계정을 없애는 것이 없다(`server_login_http.ml:481`).
- 권한 로그에 계정을 없애는 기록이 없다. 턴 판정은 로그에 있는 계정을 모두 Active 로 본다(`authz_keeper_turn.mli`).
- 지우는 기록은 대화에만 있다. `Purge_pending` → `Purged` 또는 `Purge_failed` 다(`authz_purge_event.mli`, 설계 §8.5).

### 3.5 비밀값을 두는 곳

- 운영자의 API key 저장소(`Runtime_setup_credentials`)는 단일 사용자용이다. 파일은 0600 이고 `runtime.toml` 이 경로로 가리킨다.
- 사람별 비밀 저장소는 없다.
- 키 파일을 읽는 검사는 있다. 절대 경로, 현재 사용자의 소유, group·other 권한 없음, JSON 문서가 아님이다(`runtime_credential_selection.ml:25`).

### 3.6 HTTP provider

- 다계정 프로세스는 실행 표의 API provider 를 부르지 않는다. `authorize_api` 가 `Host_account Api_provider` 로 거절한다(`runtime_account_access.ml:365`).
- 계획 D4 의 결정이다. 실행 표의 자격 증명은 호스트 계정이고 사람의 것이 아니다.

## 4. 재지 못한 것

- 진짜 키로 돌린 턴. 과금이 생겨서 하지 않았다.
- `stream-json` 출력에서 401 이 어떻게 오는지. `json` 출력만 쟀다. MASC 는 `stream-json` 을 읽는다.
- `claude auth login --console` 뒤의 `auth status` 답과, 그 자격이 놓이는 곳.
- 구독 로그인이 있는 홈에 환경 변수 키를 같이 줬을 때의 답. 문서로만 안다.
- Linux. 측정은 macOS 한 대다.
- 관리 설정이 걸린 장비.
