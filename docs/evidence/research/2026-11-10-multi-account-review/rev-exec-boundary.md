> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

# 실행 경계 적대적 리뷰 (rev-exec-boundary)

실행 경계 적대적 리뷰 결과: P0 확정 0건, P0 후보 1건(Claude Code 동작에 달렸고 측정하지 못함), P2 3건, P3 4건.

읽기만 했고 아무것도 실행하지 않았다(빌드·시험·서버·CLI·네트워크 없음, 저장소 파일 변경 없음). worktree `.worktrees/authz-d1-1-20261108`(저장소 루트 기준). 아래 경로는 저장소 상대 경로다.

- 기준: 과제를 받을 때 branch `feat/authz-f3a-off-command-20261110`, head `85b8af5b0453`.
- 리뷰 도중 다른 세션이 이 worktree 를 `feat/authz-s1a-1-multi-account-boot-20261110` @ `9424cc7b5394` 로 옮겼고, 커밋하지 않은 변경이 있다(2026-11-10 18:02 KST `git status --short`).
- 줄 번호는 2026-11-10 18시 작업 트리 기준이다. `lib/runtime`, `lib/keeper`, `lib/auth_preview_keeper.ml` 은 기준 head 와 같다(`git diff --stat 85b8af5b0453`).
- 기준 head 와 다른 인용 파일: `bin/main_eio.ml`, `bin/masc_cli_auth.ml`, `lib/server/server_runtime_bootstrap.ml`, `lib/auth/authz_activation.ml`, `lib/auth/authz_boot_mode_read.ml`, 계획 문서. `bin/main_eio.ml` 은 리뷰 중에도 줄이 밀려서 함수 이름을 같이 적었다.
- 계획 = `docs/superpowers/plans/2026-10-27-multi-account-oidc-runtime-authorization.md`.

등급: P0 = 오늘 도는 경로에서 틀리다. P1 = 실제 서버가 다계정을 서빙하면 다른 계정 것을 쓰거나 읽거나 호스트 key 를 쓴다. P2 = 영향이 좁은 빈칸. P3 = 정리.

오늘 도는 경로: `masc auth preview`(미리보기), 단일 사용자 서버와 stdio, `masc auth off` 뒤의 단일 사용자 부팅, 운영자 CLI. 실제 다계정 서버는 아직 없다. S1a-1 은 커밋 전이고 `/health` 하나만 서빙한다(`lib/server/server_accounts.ml:48-51`).

확인 표기

- 코드를 읽음: 그 줄을 읽고 호출 경로를 따라갔다.
- 실행해 봄: 이 보고에는 없다.
- 추정: 읽은 코드 밖에 달린 부분이다(공식 클라이언트의 동작, 아직 없는 코드, 읽지 않은 파일).

## 요약

| # | 등급 | 한 줄 | 확인 | 신뢰도 |
|---|---|---|---|---|
| 1 | P0 후보 | `Native_none` 은 모델의 도구만 막는다. 사람의 글은 그대로 Claude Code 입력이 된다 | 저장소 쪽은 코드를 읽음. 클라이언트가 파일을 가리키는 표기를 처리하는지는 추정 | 저장소 경로 높음, 클라이언트 동작 모름 |
| 2 | P2, S1 에서 이름으로 묶으면 P1 | 로그에 Keeper 를 만들 때 이미 있는 Keeper TOML 이름과 겹치는지 보지 않는다 | 코드를 읽음. S1 부분은 추정 | 오늘 부분 높음 |
| 3 | P2 | Off 뒤 "로그의 Keeper 는 턴이 없다"는 공식 계정 판정에만 있다 | 코드를 읽음 | 높음 |
| 4 | P2, 잠재 | Codex 자식 환경에 홈의 `config.toml` 이 고른 변수가 allow-list 없이 들어간다 | 읽는 쪽은 코드를 읽음. "사람이 쓸 길이 없다"는 추정 | 중간 |
| 5 | P3 | Codex 에 `Native_none` 을 주면 CLI 를 띄운 뒤에 거절한다 | 코드를 읽음 | 높음 |
| 6 | P3 | `api_declaration` 이 Vertex 의 credential 함수를 남긴다 | 코드를 읽음 | 높음 |
| 7 | P3 | 판정 없이 클라이언트를 띄우거나 key 로 보내는 운영자 CLI 가 있다 | 코드를 읽음 | 높음 |
| 8 | P3 | 사람 홈 위쪽 디렉터리가 이미 있으면 주인·모드·링크를 보지 않는다 | 코드를 읽음 | 중간 |

결정 (a)·(b)·(c)의 강제는 읽은 범위에서 타입으로 묶여 있다. 빈칸은 3번(Off 뒤 API provider 와 Antigravity)과 7번(운영자 CLI)이다.

## Findings

### 1. P0 후보 — `Native_none` 은 모델의 도구만 막는다. 사람의 글은 그대로 Claude Code 입력이 된다

- 근거
  - `lib/server/server_preview_keeper_turn.ml:27-45` 요청은 `keeper_id` 와 `message` 두 칸이다. 길이(4096바이트)와 빈 글만 본다.
  - `lib/server/server_preview_keeper_turn.ml:210-224` `message` 를 고치지 않고 `~prompt` 로 넘긴다(221행).
  - `lib/runtime/runtime_claude_code.ml:3022-3025` 프롬프트를 text 블록 하나로 클라이언트 stdin 에 쓴다.
  - `lib/runtime/runtime_claude_code.ml:2880-2937` argv 를 만든다. `Native_none` 이 정하는 것은 `--tools ToolSearch` 다(`lib/runtime/runtime_native_tools.ml:295-308`). 입력 단계에서 파일을 가리키는 표기와 명령 표기를 처리하지 않게 하는 인자는 없다.
- 무엇이 틀렸나: 사람이 자기 Keeper 에게 보낸 글에 파일을 가리키는 표기가 있고, Claude Code 가 그 표기를 도구가 아니라 입력 단계의 첨부로 읽는다면, 파일 내용이 모델 입력에 들어가고 답(`text`)으로 그 사람에게 돌아간다. 서버 프로세스의 사용자가 읽는 파일이 모두 범위에 든다. 다른 사람의 계정 홈도 그 안에 있다.
- 확인: 저장소 쪽은 코드를 읽음(글이 가공 없이 클라이언트에 닿고, 끄는 인자가 없다). 클라이언트가 이 argv 에서 파일을 가리키는 표기와 명령 표기를 처리하는지는 추정이다. 실행 금지라 측정하지 않았다.
- 추정의 근거
  - `lib/runtime/runtime_claude_environment_projection.ml:50-56` 주석: 같은 argv 형태에서 클라이언트가 도구 없이 파일(MEMORY.md)을 `instructions` 첨부로 실었고, `--setting-sources ""` 로는 꺼지지 않았다(Claude Code 2.1.282 측정).
  - 계획 659~660행은 `Native_none` 을 측정 없이 허용 목록에 넣었다. 665행의 D3c-3 측정은 다른 자세를 더할 때 쓰는 것으로 적혀 있다.
- 오늘 도는가: 미리보기에서 돈다. Claude 계정을 연결하고 Keeper 를 배정한 사람이면 된다. 미리보기의 cwd 는 턴마다 만드는 빈 임시 폴더라(`lib/server/server_preview_keeper_turn.ml:176-192`) 작업 폴더 밖을 가리킬 때만 뜻이 있다.
- S1 에서: Keeper 턴의 cwd 가 base path 다(`lib/keeper/keeper_claude_code_runtime.ml:1055`, `:1111`). 작업 폴더 안에 설치의 파일이 있고, 다른 사람이 보낸 글이 프롬프트에 섞인다.
- 닫는 방법: D3c-3 측정에 `Native_none` 행을 더한다. 재는 절차는 이 파생본에서 지웠다. 구독을 쓰므로 운영자가 돌린다.
- 신뢰도: 저장소 경로 높음. 클라이언트 동작은 모른다. 통하면 P0 이고, 안 통하면 이 항목은 없어진다.

### 2. P2, S1 에서 이름으로 묶으면 P1 — 로그의 Keeper 이름이 이미 있는 Keeper TOML 이름과 겹쳐도 받는다

- 근거
  - `lib/auth_preview_keeper.ml:26-33` 이름은 Keeper 문법과 로그 id 문법만 본다.
  - `lib/auth_preview_keeper.ml:106-142` `make` 는 로그에 같은 이름이 있는지만 본다(`made_before` 115-121). `lib/auth/authz_keeper.ml:48-52` 가 `Made` 를 쓴다.
  - `lib/auth/authz_types.mli:13-15` Keeper id 는 `.masc/config/keepers/<name>.toml` 의 이름이라고 계약이 적는다. `lib/runtime/runtime_account_access.mli:168` 도 같다.
  - `lib/auth/authz_activation.ml`, `lib/auth/authz_boot_mode_read.ml` 에는 Keeper 를 보는 코드가 없다(`rg -i keeper` 0건). 다계정을 켤 때 기존 Keeper 를 조건으로 두지 않는다.
  - `lib/runtime/runtime_account_access.ml:273-280`, `:301-304` Off 뒤에는 로그에 있는 이름의 Keeper 턴을 `Off_keeper` 로 거절한다. 요청은 `lib/keeper/keeper_turn_driver.ml:272-276` 이 Keeper 이름으로 만든다.
  - `lib/auth/authz_keeper_event.mli:37`, `:44` 사건은 `Made` 와 `Assigned` 뿐이다. 지우는 사건이 없다.
- 무엇이 틀렸나(오늘): 미리보기의 사람이 로그에 올리는 Keeper 이름이 운영자 Keeper 이름과 같아도 받는다. 일부러 하지 않아도 흔한 이름이면 겹친다. 그 뒤 `masc auth off` 로 끄면, 그 이름의 운영자 Keeper 는 Claude·Codex·Muse 턴이 계속 거절된다. 운영자는 Keeper 이름을 바꾸거나 지우고 새로 설치해야 한다.
- 무엇이 틀렸나(S1): 다계정 판정은 로그의 owner 로 한다(`lib/runtime/runtime_account_access.ml:247-264`). Keeper 를 계약대로 이름으로 TOML 에 묶으면, 운영자 Keeper 이름을 먼저 로그에 올린 사람이 그 Keeper 의 owner 가 된다. 세션 저장소도 Keeper 이름으로 찾는다(`lib/keeper/keeper_official_client_session_store.ml:1124`).
- 확인: 코드를 읽음. S1 부분은 아직 없는 코드라 추정이다.
- 시험 하나로 볼 수 있는 것: 로그에 `Made` 로 올라간 이름이면 Off 뒤 그 이름의 `Keeper_turn` 판정은 `Off_keeper` 다. 운영자 Keeper 가 같은 이름으로 따로 있어도 결과가 같다.
- 신뢰도: 오늘 부분 높음. S1 부분은 묶는 방식이 정해져야 안다.

### 3. P2 — Off 뒤 "로그의 Keeper 는 턴이 없다"는 공식 계정 판정에만 있다

- 근거
  - `lib/runtime/runtime_account_access.ml:296-327` `after_off` 는 `judge` 안에서만 불린다. `Authz_boot_mode_read.turned_off` 를 읽는 곳은 `:317` 하나다(lib·bin `rg`).
  - `lib/runtime/runtime_account_access.ml:355-367` `host_access` 와 `authorize_host` 는 단일 사용자면 Off 여부를 보지 않고 허용한다. `:381-383` `authorize_api` 도 같다.
  - `lib/keeper/keeper_turn_driver.ml:3578` API provider 턴, `:3133` Antigravity 턴은 Keeper 이름을 넘기지 않는다.
  - `bin/masc_cli_auth.ml:147-149` 안내문은 "no turn runs for a Keeper or on a Runtime of the log" 라고 말한다.
- 무엇이 틀렸나: Off 뒤 단일 사용자 부팅에서, 로그에 있는 이름의 Keeper 가 API provider Runtime 이나 Antigravity Runtime 을 쓰면 호스트 key 로 턴이 돈다.
- 오늘 도는가: 로그의 Keeper 에는 TOML 이 없다(계획 575행: TOML 쓰기와 턴 실행은 S1 과 D2). 그래서 2번처럼 이름이 겹칠 때만 닿고, 그때 도는 것은 운영자 Keeper 다. S1 이 로그의 Keeper 에 TOML 을 주면, Off 뒤 그 사람의 Keeper 가 호스트 key 로 돈다. 결정 (c)와 어긋난다.
- 같은 자리: Off 뒤 native 도구는 모든 자세가 허용된다(`lib/runtime/runtime_account_access.ml:413-414`). 계획 813행이 이미 적었고 F3a-3 으로 결정했다(2026-11-10). 코드는 아직 없다.
- 확인: 코드를 읽음.
- 신뢰도: 높음.

### 4. P2, 잠재 — Codex 자식 환경에 홈의 `config.toml` 이 고른 변수가 allow-list 없이 들어간다

- 근거
  - `lib/runtime/runtime_official_account.ml:85-121` 홈의 `config.toml` 에서 `model_providers.*.env_key` 와 `env_http_headers` 가 적은 변수 이름을 읽는다. 이름 모양만 본다.
  - `lib/runtime/runtime_official_account.ml:137-140`, `lib/runtime/runtime_codex_environment_projection.ml:38-50` 그 이름이면 allow-list 에 없어도 서버 환경의 값을 자식에게 넘긴다(47행).
  - `lib/server/server_runtime_startup_credentials.ml:12`, `:29` 단일 사용자 서버는 admin token 과 `MASC_INTERNAL_MCP_TOKEN` 을 자기 환경에 둔다(`lib/server/server_runtime_bootstrap.ml:1046`, `:1050`). 미리보기와 계정 서버는 이 길을 타지 않고, 운영자 셸이 준 환경을 그대로 가진다.
  - `lib/runtime/runtime_setup_login_client.ml:127-131` 다계정에서도 사람 홈 위에 Codex 가 뜬다(로그인 확인).
- 무엇이 틀렸나: 사람이 자기 Codex 홈의 `config.toml` 을 쓸 수 있게 되면, 서버 환경의 아무 변수나 이름으로 골라 자식 환경에 넣는다. 그 설정의 provider 주소로 요청이 나가면 값이 같이 나간다. 그 파일은 Codex 가 직접 읽는 설정이기도 하다(`CODEX_HOME`). Claude 쪽 argv 에는 `--setting-sources=` 가 있고(`lib/runtime/runtime_native_tools.ml:308`), Codex 쪽 argv 에는 홈의 설정을 끄는 인자가 없다(`lib/runtime/runtime_codex_app_server.ml:2871-2887`).
- 오늘 도는가: 사람이 자기 홈에 파일을 쓸 길을 찾지 못했다. 로그인 argv 는 고정이다(`lib/runtime/runtime_setup_login_client.ml:103-107`). 다계정에서 Codex 모델 턴은 거절되고, 사람 홈 위에서 도는 것은 `account/read` 까지다.
- 확인: 읽는 쪽은 코드를 읽음. "쓸 길이 없다"는 추정이다. Keeper 도구 감사를 하지 못했다(아래 "확인 못 함" 1번). Codex 가 `config.toml` 로 무엇까지 하는지, 두 클라이언트의 인자가 실제로 무엇을 끄는지도 추정이다.
- 신뢰도: 중간.

### 5. P3 — Codex 에 `Native_none` 을 주면 CLI 를 띄운 뒤에 거절한다

- 근거: `lib/runtime/runtime_account_access.ml:415-416`(다계정은 none 을 허용), `lib/runtime/runtime_codex_app_server.ml:3246`(입구 판정 통과), `:2946`(spawn), `:2538-2557`(`account/read` 뒤 `permissions_profile_of_posture` 가 none 을 `Invalid_config` 로 거절, 정의는 `:414-421`), `:2881-2884`(none 일 때 shell 을 끄는 인자가 없다).
- 무엇이 틀렸나: 다계정 프로세스에서 Codex 턴이 `Native_none` 으로 들어오면 사람 홈 위에 app-server 가 뜨고 `account/read` 까지 간 뒤 끝난다. 계획 661행은 "거절된 턴은 CLI를 띄우지 않고 `Invalid_config`로 끝난다"고 적는다. Muse 는 띄우기 전에 거절한다(`lib/runtime/runtime_muse_serve.ml:1940-1942`).
- 오늘 도는가: 이 조합을 만드는 호출자가 없다. 미리보기는 기본 자세 read 를 띄우기 전에 403 으로 거절한다(`lib/server/server_preview_keeper_turn.ml:248`). Keeper 쪽은 `lib/keeper/keeper_codex_runtime.ml:1065-1074` 가 자세를 정한다.
- 확인: 코드를 읽음.
- 신뢰도: 높음.

### 6. P3 — `api_declaration` 이 Vertex 의 credential 함수를 남긴다

- 근거: `lib/runtime/runtime_account_access.ml:377-379` 는 `api_key` 와 `headers` 만 비운다. `lib/runtime/runtime_adapter.ml:754-760`, `:829` 는 Vertex provider 설정에 `Runtime_google_adc.credential_source ()` 를 싣는다. 그 함수는 `gcloud auth application-default print-access-token --quiet` 를 실행한다(`lib/runtime/runtime_google_adc.ml:3-19`).
- 무엇이 틀렸나: 판정 없이 받는 선언값에 호스트 ADC token 을 꺼내는 함수가 남아 있다. 읽는 쪽이 그 함수를 부르면 `authorize_api` 없이 호스트 credential 이 나온다.
- 오늘 도는가: 부르는 곳이 없다. `api_declaration` 을 읽는 곳은 10개 파일 16줄이고(`rg`, 2026-11-10 18시) 모두 model id, capability, label 같은 선언값만 읽는다. `credential_source` 를 읽는 곳은 `runtime_adapter.ml`, `runtime_google_adc.ml`, `lib/runtime/runtime_provider_usage_read.ml:50` 셋이고, 마지막은 `authorize_api`(48행) 뒤다.
- 확인: 코드를 읽음.
- 신뢰도: 높음.

### 7. P3 — 판정 없이 클라이언트를 띄우거나 key 로 보내는 운영자 CLI

- 근거
  - `masc runtime-account-login`: `bin/main_eio.ml:4315-4337`(`runtime_account_login_cmd`) → `bin/masc_cli_account_login.ml:19-41`. 게시도 판정도 없이 `--account-home` 위에서 로그인 클라이언트를 띄운다(32행). 홈은 주인과 모드만 본다(`lib/runtime/runtime_setup_login_client.ml:67-71`).
  - `masc runtime-discover-models`, `masc runtime-serving-context`: `bin/main_eio.ml:4358-4371`(보내는 줄 4367), `:4393-4407`(4403). 게시 없이 spec 의 credential 로 보낸다. 서버 쪽 같은 일은 판정한다(`lib/server/server_runtime_setup_actions.ml:455`).
  - `masc runtime-codex-models`, `masc runtime-muse-models`: `bin/masc_cli_codex_models.ml:4-14`, `bin/masc_cli_muse_models.ml:7-12`. `--base-path` 를 판정하고, `--account-home` 이 그 base path 아래인지는 보지 않는다.
- 무엇이 틀렸나: Off 뒤나 다계정 설치에서 운영자가 사람 홈(`.masc/accounts/<namespace>/…`)을 `--account-home` 으로 주면 클라이언트가 그 홈 위에서 뜬다. 안내문의 "no client starts on a home under .masc/accounts"(`bin/masc_cli_auth.ml:148-149`)와 어긋난다.
- 오늘 도는가: 돈다. 모두 호스트 셸이 있어야 한다. 그 사용자는 홈을 직접 읽을 수도 있다.
- 확인: 코드를 읽음.
- 신뢰도: 높음.

### 8. P3 — 사람 홈 위쪽 디렉터리가 이미 있으면 주인·모드·링크를 보지 않는다

- 근거: `lib/server/server_setup_account_login.ml:57-60` `private_child` 는 `mkdir 0o700` 을 하고 이미 있으면 그대로 쓴다. `:65-73` 이 `accounts` 와 `<namespace>` 를 그렇게 만든다. `lib/runtime/runtime_setup_login_client.ml:34-42` `new_home` 은 `<namespace>` 를 주인과 0o022 로만 보고, `accounts` 는 보지 않는다.
- 무엇이 틀렸나: `accounts` 가 다른 곳을 가리키는 링크면 사람 홈이 그 아래에 만들어진다. 만들 수 있는 쪽은 `.masc` 에 쓸 수 있는 쪽뿐이다. 사람끼리는 같은 OS 사용자로 돌아서, 이 모드는 사람 사이를 가르지 않는다.
- 오늘 도는가: 미리보기 로그인에서 돈다. 사람이 `.masc` 에 쓸 길은 찾지 못했다.
- 확인: 코드를 읽음. Off 판정 쪽은 링크를 푼다. `under_persons` 가 적힌 철자와 실제 경로를 둘 다 본다(`lib/runtime/runtime_account_home_layout.ml:53-62`).
- 신뢰도: 중간.

## Q6 누가 턴을 일으키나 (결정 사항이라 결함으로 세지 않음)

- 판정 지점은 `lib/auth/authz_keeper_turn.ml:139-179` 와 `lib/auth/authz_decision.ml:167-169` 다. initiator 와 executor 를 owner 로 고정한다(152-153행). 보낸 사람은 입력에 없다(`decide zone ~keeper_id ~channel ~now`, 186행).
- `masc_keeper_msg` 는 인자에서 `name` 과 `message` 만 읽는다(`lib/keeper/keeper_tool_surface_ops.ml:943-959`). turn kind 는 늘 `Direct` 다(`lib/keeper/keeper_turn.ml:863`).
- Runtime 은 로그의 배정과 다르면 거절한다(`lib/runtime/runtime_account_access.ml:254-268`). resume id 는 세션 저장소에서만 온다(`lib/keeper/keeper_claude_code_runtime.ml:928-932`).
- 그래서 S1 에서는 "누가 A 의 Keeper 에게 글을 보낼 수 있나"라는 경로 권한이 유일한 문이다. B 가 보낼 수 있으면 그 턴은 A 의 계정으로 돈다. rev-server-doors 의 F3 과 같은 자리다.
- 확인: 코드를 읽음.

## Q1 census A — 공식 클라이언트 프로세스를 띄우는 곳 (12곳)

분류: 판정 있음 = 타입 증명(`authorized`, `muse_authorized`)이 있어야 부를 수 있다. 단일 사용자만 = `host_account` 가 있어야 하고 다계정은 거절된다. 판정 없음 = 증명 없이 뜬다. 모두 코드를 읽음.

| # | 띄우는 줄 | 거치는 함수 | 부르는 곳(판정 줄) | 분류 |
|---|---|---|---|---|
| A1 | `lib/runtime/runtime_claude_code.ml:673` `claude auth status` | `probe_subscription ~account`(3305) | `lib/keeper/keeper_claude_code_runtime.ml:1117`(`keeper_turn_driver.ml:291`), `lib/runtime/runtime_setup_login_client.ml:140`(124), `lib/server/server_dashboard_official_client_probe.ml:244`(229), `lib/fusion/fusion_official_client.ml:777`(761), `bin/main_eio.ml:2885`(2820) | 판정 있음 |
| A2 | `lib/runtime/runtime_claude_code.ml:3119` 모델 턴 | `run_turn ~account`(3316), 자세 판정 3329 | `lib/server/server_preview_keeper_turn.ml:221`(285, 자세 198), `lib/keeper/keeper_claude_code_runtime.ml:1479`(`keeper_turn_driver.ml:291`), `lib/runtime/runtime_verification.ml:956`(628), `lib/fusion/fusion_official_client.ml:787`(761), `lib/keeper/keeper_capability_probe.ml:523`(498) | 판정 있음 + 자세 |
| A3 | `lib/runtime/runtime_codex_app_server.ml:2946` 모델 턴 | `run_turn ~account`(3218), 자세 판정 3246 | `lib/server/server_preview_keeper_turn.ml:249`(285, 자세 248), `lib/keeper/keeper_codex_runtime.ml:1647`(`keeper_turn_driver.ml:291`), `lib/runtime/runtime_verification.ml:1055`(628), `lib/fusion/fusion_official_client.ml:832`(820), `lib/keeper/keeper_capability_probe.ml:575`(550) | 판정 있음. 다계정 모델 턴은 거절 |
| A4 | 같은 줄, 턴 아님 | `probe_subscription`(3206), `list_models`(3210), `read_rate_limits`(3214), `delete_threads`(3201). 모두 `~account` | `lib/runtime/runtime_setup_login_client.ml:131`(124), `lib/server/server_dashboard_official_client_probe.ml:157`(142), `bin/main_eio.ml:2921`(2820), `lib/runtime/runtime_codex_model_refresh.ml:30`(`bin/masc_cli_codex_models.ml:12`), `lib/runtime/runtime_provider_usage_read.ml:81`(95), `lib/keeper/keeper_codex_runtime.ml:304` | 판정 있음. 자세 판정은 없다(계획 663행) |
| A5 | `lib/runtime/runtime_muse_serve.ml:762` 모델 턴 | `run_turn ~account`(1902), 자세 판정 1925 | `lib/keeper/keeper_muse_runtime.ml:1616`(`keeper_turn_driver.ml:296`), `lib/runtime/runtime_verification_muse.ml:53`(`runtime_verification.ml:632`, `keeper_capability_probe.ml:786`), `lib/fusion/fusion_official_client.ml:954`(921) | 판정 있음. 다계정 모델 턴은 없다(none 은 1940행에서 띄우기 전에 거절) |
| A6 | 같은 줄, 턴 아님 | `read_usage`(1964), `list_models`(1975) | `lib/runtime/runtime_provider_usage_read.ml:113`, `lib/runtime/runtime_muse_model_discovery.ml:39`(`bin/masc_cli_muse_models.ml:12`), `lib/keeper/keeper_muse_runtime.ml:1737` | 판정 있음 |
| A7 | `lib/runtime/runtime_antigravity.ml:885` | `run_turn ~host` | `lib/keeper/keeper_antigravity_runtime.ml:1101`(`keeper_turn_driver.ml:3133`), `lib/runtime/runtime_verification_antigravity.ml:37`(`runtime_verification.ml:639`), `lib/fusion/fusion_official_client.ml:888`(590), `lib/keeper/keeper_capability_probe.ml:744`(661) | 단일 사용자만 |
| A8 | `lib/runtime/runtime_antigravity_context.ml:208`, `:224`, `lib/runtime/runtime_antigravity_usage.ml:93`, `lib/runtime/runtime_antigravity_setup.ml:110` | `~host` 를 받는 관찰·사용량·모델 목록 | `bin/masc_cli_antigravity.ml:22`, `lib/runtime/runtime_provider_usage_read.ml:124` | 단일 사용자만 |
| A9 | `bin/masc_cli_antigravity.ml:28-33` 로그인 fork/exec | `Setup.prepare ~host` 뒤 | 같은 파일 22행 | 단일 사용자만 |
| A10 | `lib/runtime/runtime_vibe_cli.ml:284`, `lib/runtime/runtime_vibe_acp_readiness.ml:435` | `run ~host`, `read ~host` | `lib/fusion/fusion_official_client.ml:740`(590), `bin/masc_lane_cli_probe.ml:86`(71) | 단일 사용자만. Keeper 턴은 `keeper_turn_driver.ml:2942` 에서 거절 |
| A11 | `lib/runtime/runtime_setup_login_session.ml:142` 로그인 helper | argv 는 `lib/runtime/runtime_setup_login_client.ml:103-107` 고정 | `lib/server/server_setup_account_login.ml:100`(운영자 `lib/server/server_routes_http_routes_setup.ml:87`, 사람 `lib/server/server_login_http.ml:264`) | 판정 없음(Antigravity 만 `runtime_setup_login_client.ml:82`). 새 홈은 부른 쪽 root 아래에만 만든다 |
| A12 | `bin/masc_cli_account_login.ml:32` | `masc runtime-account-login` | `bin/main_eio.ml:4332` | 판정 없음(발견 7) |

## Q1 census B — provider HTTP 와 호스트 key 를 쓰는 곳 (17곳)

모두 코드를 읽음. B1~B9 와 B11~B15 는 추상 타입(`api_sealed`, `host_account`)을 거쳐야 key 가 나온다. 문자열만으로 닿는 곳은 B10, B16, B17 이다.

| # | 쓰는 곳 | 판정 줄 | 분류 |
|---|---|---|---|
| B1 | Keeper 턴 `lib/keeper/keeper_turn_driver_try_provider.ml:2764` | `lib/keeper/keeper_turn_driver.ml:3578` | 단일 사용자만 |
| B2 | `lib/fusion/fusion_agent_core.ml:416`, `bin/masc_cli_runtime_sample.ml:71`, `bin/masc_librarian_continuity.ml:150`, `lib/keeper/keeper_capability_probe.ml:368` | `lib/runtime/runtime_agent_core_runner.ml:90` | 단일 사용자만 |
| B3 | 검증 `lib/runtime/runtime_verification.ml:881` | 같은 파일 645(→802) | 단일 사용자만 |
| B4 | add-on sampling `lib/server/server_lane_addon_sampling.ml:145` | 같은 파일 163 | 단일 사용자만 |
| B5 | vision `lib/keeper/keeper_vision_tool.ml:774` | 같은 파일 764 | 단일 사용자만 |
| B6 | 사용량 읽기 `lib/runtime/runtime_provider_usage_read.ml:191` | 같은 파일 48 | 단일 사용자만 |
| B7 | 대시보드 probe `lib/server/server_dashboard_http_runtime_info.ml:985` | 같은 줄 | 단일 사용자만 |
| B8 | exact-output 대상 `lib/runtime/runtime.ml:958`, 교체 카탈로그 `:1001` | 같은 줄 | 단일 사용자만 |
| B9 | setup 모델 목록·서빙 창 `lib/server/server_runtime_setup_actions.ml:487`, `:509` | 같은 파일 455 | 단일 사용자만 |
| B10 | `bin/main_eio.ml:4367`, `:4403` | 없음 | 판정 없음(발견 7) |
| B11 | Files API `lib/keeper/keeper_tool_in_process_runtime.ml:1972`, `:1997`, `:2012` | 같은 파일 1953 | 단일 사용자만 |
| B12 | web search `lib/tool_misc_web_search.ml:764-802` | 같은 파일 944 | key 를 쓰는 provider 는 단일 사용자만. SearXNG 는 key 없이 다계정에서도 보낸다(D4d) |
| B13 | SystemOne `lib/tool_local_runtime_systemone.ml:592` | cloud 는 602 | cloud 는 단일 사용자만. local 은 판정 없음(key 없음) |
| B14 | voice `lib/voice/voice_speak.ml:14`, `lib/voice/voice_probe.ml:14`, `:19` | `lib/voice/voice_endpoint_key.ml:25` | key 이름이 있으면 단일 사용자만 |
| B15 | TypeSafe AI | `lib/typesafeai/typesafeai_config.ml:79` | 단일 사용자만. `has_key`(42)는 있는지만 읽는다 |
| B16 | `lib/tool_local_runtime_verify.ml:111` 로컬 endpoint 에 1토큰 completion | 없음 | 판정 없음(key 없음) |
| B17 | `lib/runtime_model/runtime_model_string.ml:55-99` 환경의 key 로 설정을 만든다 | 없음 | lib·bin 에 호출자가 없다 |

게시하는 곳(모두 거절이면 멈춘다): 미리보기 `bin/masc_cli_auth.ml:202`, 단일 사용자 owner 초기화 `lib/server/server_runtime_bootstrap.ml:754`, 커밋 전 계정 서버 `lib/server/server_accounts.ml:143`, host tool `bin/main_eio.ml:2070`·`2817`·`2966`, `bin/masc_cli_antigravity.ml:18`, `bin/masc_lane_cli_probe.ml:188`, `bin/deployment_preflight_helper.ml:1155`, `bin/fusion_run.ml:575`, `bin/masc_cli_codex_models.ml:7`, `bin/masc_cli_muse_models.ml:7`, `bin/keeper_capability_probe_cli.ml:409`, `bin/masc_librarian_continuity.ml:480`.

## Checked and found correct

모두 코드를 읽음.

- 게시 전에는 세 판정이 모두 거절한다(`lib/runtime/runtime_account_access.ml:315`, `:357`, `:411-412`). `publish` 는 한 번만 된다(88행). 시험용 지름길은 lib·bin 에 없다(시험은 `test/deps/masc_test_host_access.ml` 을 쓴다).
- 다계정에서 `Operator_call` 은 거절(241행), 환경이 고른 홈은 거절(230행), Keeper 턴은 로그가 배정한 Runtime(254행)과 owner 의 홈(232행)일 때만 통과한다.
- 자세 판정은 프로세스를 띄우는 `run_turn` 안에 있다(Claude 3329, Codex 3246, Muse 1925). 건너뛰는 호출자는 없다.
- Claude 는 선언된 계정이면 환경 이름 14개와 `CLAUDE_CONFIG_DIR`, 고정값 넷만 자식에게 준다(`lib/runtime/runtime_claude_environment_projection.ml:3-45`, `:57-62`). API key 이름은 빠진다. Muse 는 allow-list 다(`lib/runtime/runtime_muse_serve.ml:539-563`).
- 미리보기에서 남의 Keeper 는 404 다(`lib/server/server_preview_keeper_turn.ml:51-70`). `cli_path` 는 운영자 설정에서 온다. 사람이 고르는 것은 글, Keeper 이름, 운영자가 선언한 모델 중 하나다.
- Runtime id 는 계정 id(추첨값)에서 나온다(`lib/server/server_setup_account_login.ml:370-377`). namespace 는 입장 때 추첨하고(`lib/auth/authz_login.ml:98`) 대문자와 `/` 가 없다.
- 다계정의 홈 비교는 문자열이 정확히 같을 때만 통과한다(`lib/runtime/runtime_account_access.ml:232`). 기대하는 홈과 선언된 홈은 같은 함수가 만든다(`lib/runtime/runtime_account_home_layout.ml:64-73`).
- Off 뒤의 `under_persons` 는 적힌 철자와 실제 경로를 둘 다 본다. 아직 없는 홈은 있는 가장 깊은 조상까지 풀고 나머지를 붙인다(`lib/runtime/runtime_account_home_layout.ml:40-62`). 빈칸 하나: 아직 없는 폴더를 거쳐 되돌아오는 철자는 사람 쪽으로 읽히지 않는다. 그 철자는 그 폴더가 생기기 전에는 열리지 않고, Off 뒤 홈을 적는 쪽은 운영자의 설정뿐이라 발견으로 세지 않았다. 철자의 예는 이 파생본에서 지웠다.
- 세션 저장소는 Keeper 이름으로 찾지만 tool surface hash 에 계정 홈이 들어간다(`lib/keeper/keeper_claude_code_runtime.ml:914-918`). 홈이 바뀌면 새 세션이다.
- 판정 경로 파일 10개에 `Option.value` 가 없다(`rg`). catch-all 은 문자 분류, JSON 모양 거절, 환경 이름 allow-list 이고 모두 닫는 쪽이다. 하나(`lib/server/server_setup_account_login.ml:261`)는 오류 알림에 싣는 표시용 JSON 이다.
- Muse 로그인 확인(`Runtime_muse_home.prepare`)은 프로세스를 띄우지 않는다(`lib/runtime/runtime_setup_login_client.ml:145-148`).
- 사람 계정 검증(`lib/server/server_setup_account_login.ml:450-472`)은 서버가 쓴 프롬프트로 돈다. 사람의 글이 들어가는 턴은 미리보기의 Keeper 턴 하나다.

## Not reachable yet

- 다계정 프로세스의 Keeper 턴. 판정 코드는 있고(`lib/runtime/runtime_account_access.ml:239-269`), 계정 서버는 Keeper 를 띄우지 않는다.
- Off 뒤 사람 홈이 남아 있으면 native 도구를 끄는 층(F3a-3). 결정만 있다.
- D3c-3 측정 스크립트. 발견 1 을 닫으려면 여기에 `Native_none` 행이 있어야 한다.

## 확인 못 함

1. Keeper 에게 보이는 MASC 도구, 샌드박스 마운트, 브라우저가 `.masc/accounts` 에 닿는지(Q4 뒷부분). 맡긴 서브에이전트가 safeguards 로 멈췄다. 안내에 따라 그 일을 직접 하지 않았다. 읽은 사실은 둘이다. D3c-1 시험(`test/test_keeper_account_home_reach.ml`)은 Docker 마운트 source, Apple guest 마운트와 게시 소켓, `resolve_keeper_read_path` 셋만 본다. `under_persons` 를 부르는 곳은 Off 판정 한 곳이다(`lib/runtime/runtime_account_access.ml:310`). 멈춘 알림의 원문은 이 파생본에서 지웠다.
2. Claude Code 가 이 argv 에서 파일을 가리키는 표기와 명령 표기를 입력 단계에서 어떻게 처리하는지(발견 1). 실행 금지라 측정하지 않았다.
3. 사람이 자기 Codex 홈에 `config.toml` 을 쓸 길이 정말 없는지(발견 4). 1번이 빠져서 확정하지 못했다.
4. `host_client` 목록 밖의 호스트 credential 통로가 다계정에서 닫히는지. `lib/keeper/keeper_github_app_broker.ml`, `lib/keeper/keeper_chat_slack.ml`, `lib/gate/slack_*`, `lib/gate/discord_rest_client.ml`, `lib/mcp_client/mcp_client.ml`, `lib/server/server_keeper_oauth.ml` 은 `Runtime_account_access` 를 부르지 않는다(`rg` 0건). 본문은 읽지 않았다.
5. Explore 서브에이전트 두 번은 보고 없이 끝났다. provider HTTP census 는 직접 했다. 지금 기다리는 서브에이전트는 없다.

멈춘 알림: 원문은 이 파생본에서 지웠다. 알림에는 요청 id 둘과 안내 링크 셋이 있었다. 알림은 그 일을 직접 하지 말고 세션의 사용자에게 전하라고 안내했고, 리뷰는 그 안내를 따랐다.

## Did not read

- `lib/fusion/fusion_official_client.ml`, `lib/keeper/keeper_capability_probe.ml`, `lib/keeper/keeper_muse_runtime.ml`, `lib/keeper/keeper_antigravity_runtime.ml`, `lib/keeper/keeper_tool_in_process_runtime.ml` 은 판정 줄과 그 앞뒤만 읽었다.
- 로그인 receipt 저장, `Auth_preview` 의 gate, `Runtime_account_home.of_string`(선언된 홈 철자를 받는 곳).
- 커밋 전 S1a 변경. `lib/server/server_accounts.ml` 은 경로 표와 게시 순서만 읽었다.
- 시험 코드는 `test/test_keeper_account_home_reach.ml` 하나만 읽었다.
- 공식 클라이언트(Claude Code, Codex, Muse, Antigravity)의 실제 동작.
