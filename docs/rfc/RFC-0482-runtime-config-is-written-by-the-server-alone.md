---
rfc: "0482"
title: "runtime.toml 은 서버만 쓴다"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480"]
---

# RFC-0482 — runtime.toml 은 서버만 쓴다

## 0. 요약

TUI Config 화면은 2초마다 `GET /api/v1/runtime/config/raw` 로 runtime.toml 전체를 읽는다. 2026-11-04 운영 서버에서 136KB 였다.

서버 안에서 이 파일을 쓰는 곳은 모두 `Runtime.commit_config_text_locked` 를 지난다. #48036 은 그 함수가 새 내용을 디스크에 올릴 때 `runtime_config_changed` 를 알리게 한다. 하지만 TUI 와 CLI 몇 개는 서버를 거치지 않고 자기 프로세스에서 이 파일을 쓴다. 서버는 그 쓰기를 모른다. 그래서 2초 읽기를 지우면 Config 화면은 그 변경을 놓친다(RFC-0480 §3.4 조건 1).

이 RFC 는 서버가 떠 있는 동안 runtime.toml 을 쓰는 곳을 서버 하나로 모은다. 그러면 모든 쓰기가 같은 저장 함수를 지나고, 같은 알림을 낸다.

사용자 결정(2026-11-04): TUI·CLI 의 쓰기를 서버로 옮기는 RFC 를 먼저 쓰고, 그 뒤 Config 의 2초 읽기를 지운다.

## 1. 지금 runtime.toml 을 쓰는 곳

### 1.1 서버 프로세스

모두 `commit_config_text_locked` 를 지난다. `edit_config_text`, `save_config_text*`, `commit_runtime_config_text`, `Runtime_setup_batch` 가 그 함수를 부른다. 대시보드 원문 저장(`POST /api/v1/runtime/config/raw`), keeper 배정, prompt preset, web search·voice·credential·account 설정 route, lane 편집이 여기에 든다. #48036 의 독립 리뷰가 호출처를 하나씩 확인했다.

시작할 때의 rollback 과 config-root 시드는 이 함수를 지나지 않는다. 둘 다 알림 fiber 와 listener 가 서기 전에 돌아서, 그 쓰기를 놓치는 reader 는 없다.

### 1.2 TUI 프로세스

TUI 의 Config 편집기는 이미 서버로 저장한다. preview 를 받은 뒤 `POST /api/v1/runtime/config/raw` 를 보낸다(`bin/masc_tui.ml` `commit_runtime_config_text`).

화면 설정은 `bin/masc_tui_preference_writer.ml` 이 L1 route(`POST /api/v1/tui/preferences`)로 보낸다. 시작할 때는 L2a route 로 읽는다. TUI 프로세스에는 runtime.toml 을 직접 쓰는 곳이 없다.

Keeper 목록의 정렬과 보기(`submit_keeper_preference`)는 runtime.toml 이 아니라 같은 폴더의 `tui-keepers.toml` 에 쓴다. Config 화면은 이 파일을 읽지 않으므로 이 RFC 에 들지 않는다.

### 1.3 CLI 프로세스

여섯 명령 모두 이 워크스페이스의 서버가 답하면 서버로 보내고, 없으면 직접 쓴다(3.2).

| 명령 | 서버가 있을 때 | 서버가 없을 때 |
|---|---|---|
| `masc config set` | 원문 route (`Masc_cli_runtime_config_remote.save`) | `Runtime_setting_set.apply` |
| `masc web-search-setup` | 원문 route (`Masc_cli_runtime_config_remote.save`) | `Web_search_setup.apply` |
| `masc voice-local-setup` | voice setup route (`Masc_cli_runtime_config_remote.apply_voice_setup`) | `Voice_setup.apply` |
| `masc runtime-default-set` | 원문 route (`Runtime.runtime_default_text`, `--setup-lanes` 면 `Runtime.first_run_runtime_text`) | `Runtime.set_runtime_default`, `Runtime.set_first_run_runtime` |
| `masc browser-lane-setup` | 원문 route. bidi·automation·ego 표를 서버 원문에 계획하고 저장한다(`Masc_cli_runtime_config_remote.table_store`) | 같은 계획을 파일에 쓴다(`Runtime_table_edit.file_store`) |
| `masc runtime-setup-batch` | 서버 원문으로 정하고 임시 사본에서 검증한 뒤, 저장만 원문 route 로(`Runtime_setup_batch.configure_text`, `Masc_cli_runtime_config_remote.publish_setup_text`) | `Runtime_setup_batch.configure`. 임시 사본에 `runtime-default-set` 을 돌려 검증한 뒤 원래 파일에 쓴다 |

`runtime-setup-batch` 는 `scripts/install-runtime-setup.py` 가 `runtime-setup-inventory` 다음에 부른다. inventory 도 서버가 답하면 서버 원문을 읽어서, batch 가 비교하는 revision 과 같은 원문에서 나온다. batch 가 임시 사본에 부르는 `runtime-default-set` 은 그 사본의 서버를 찾지 못해서 사본에 직접 쓴다.

## 2. 문제

1. 서버는 TUI·CLI 의 쓰기를 모른다. 그래서 알리지 못한다. 2초 읽기를 지우면 Config 화면은 다른 TUI 의 테마 변경이나 `masc config set` 을 보여 주지 못한다.
2. CLI 쓰기는 서버가 떠 있어도 서버를 지나지 않는다. 서버의 설정과 디스크의 설정이 재시작 전까지 갈라진다.
3. 같은 파일을 여러 프로세스가 각자 잠그고 쓴다. 잠금(`with_runtime_config_write_lock`)은 파일 잠금이라 프로세스 사이에서도 순서를 지키지만, 쓴 뒤의 일(catalogue 발행, 알림)은 쓴 프로세스에서만 일어난다.

## 3. 고른 길

### 3.1 TUI 화면 설정은 서버 API 로 쓴다

서버에 TUI 화면 설정을 쓰는 route `POST /api/v1/tui/preferences` 를 둔다. 권한은 runtime config 저장 route 와 같은 `CanAdmin` 이다.

- 요청 본문은 변경 하나다. `{"change": <종류>, <값 필드>}` 꼴이고, 종류는 닫혀 있다. 서버는 받는 자리에서 파싱한다(Parse, don't validate). TUI 가 저장하는 값마다 생성자 하나를 둔다(`lib/tui_preference.ml` 의 `change`). 모르는 종류, 빠지거나 남는 필드, 겹친 필드, 읽을 수 없는 값, 빈 테마·장치 이름은 400 이다.
- 언어·candle 은 닫힌 타입으로, board 정렬은 서버의 `Board_dispatch.sort_order` 로 읽는다. 테마 이름은 열린 이름이라 문자열로 받고, `null` 은 저장한 테마를 지운다. 비었거나 앞뒤에 공백이 붙은 이름은 받지 않는다.
- 편집 결과가 지금 파일과 같으면(같은 chat 을 다시 열거나, 이미 끈 도움말 안내) 서버는 쓰지 않는다. audit 도 알림도 없고, 응답은 `state: "unchanged"` 다. 비교는 읽을 때와 같은 쓰기 잠금 안에서 한다(`Runtime.edit_config_text_if_changed`).
- 서버는 `Runtime.edit_config_text` 로 `tui` 이름공간만 고친다. 그래서 `commit_config_text_locked` 를 지나고, `runtime_config_changed` 가 나간다. audit 에는 `tui_preference` 로 남는다. `tui` 키는 Skill catalog 가 읽지 않으므로 skill catalog 를 다시 만들지 않는다. TUI 가 직접 쓸 때도 그랬다.
- 응답은 변경과 commit receipt(`source_revision`, `durability`, `ignored_legacy_keys` 등)다. 파일 원문은 싣지 않는다.
- TUI 의 `Runtime.edit_config_text` 호출은 모두 지운다.
- TUI 는 시작할 때 `[tui]` 도 서버에서 읽는다(`GET /api/v1/tui/preferences`). 쓰는 곳과 읽는 곳이 서버 하나라서, 두 프로세스가 runtime.toml 을 서로 다른 경로로 찾아도 TUI 는 서버가 쓴 값을 읽는다. 읽기 권한은 `CanReadState` 다.
- 쓰기 권한은 `CanAdmin` 그대로다. runtime.toml 은 서버 설정 파일이라서다. 운영자가 Worker 로 좁힌 TUI 는 고른 값을 화면에는 바로 쓰고, 저장하지 못했다는 안내를 한 번 보여 준다.

사용자 결정(2026-11-04): 시작할 때 `[tui]` 를 서버에서 읽는다. 쓰기 권한은 `CanAdmin` 을 유지한다.

TUI 는 서버에 붙어서만 돈다. 그러니 화면 설정을 쓸 때 서버가 없을 수는 없다. 서버가 쓰기를 거절하면, TUI 는 지금 `edit_config_text` 의 오류를 보여 주는 자리에 그 이유를 보여 준다.

### 3.2 CLI 는 서버가 떠 있으면 서버로 쓴다

`masc config set`, `masc web-search-setup`, `masc voice-local-setup` 은 이렇게 쓴다.

- 서버 찾기: port 는 다른 CLI 명령과 같은 순서로 정한다(`--port`, `MASC_HTTP_PORT`, 워크스페이스에 저장된 port, 기본값). 이 워크스페이스의 서버가 누구인지는 커널에 묻는다(`Server_upgrade_preparation.owner_without_making`). 워크스페이스 lease 를 쥔 프로세스가 그 port 의 알림 바이트(`<lease>.single-user-server`)도 쥐고 있으면 그 프로세스가 서버다. port 가 뭐라고 답하는지는 판정에 쓰지 않는다. 그 서버의 `/health/ready` 가 200 이면, `masc login` 이 저장한 토큰(`Auth_login.read_persisted_http_token`)으로 서버에 보낸다. 토큰을 보낼 때마다 직전에 커널에 다시 묻고, 서버가 바뀌었으면 더 보내지 않는다. `masc runtime-resume` 도 같은 방식이다(`bin/masc_cli_model_resume.ml`).
- 커널이 말한 서버가 준비됐으면: `GET /api/v1/runtime/config/raw` 로 서버가 읽는 원문과 revision·경로를 받고, 같은 편집을 그 원문에 한다. `expected_source_revision`·`expected_source_path` 와 함께 `POST /api/v1/runtime/config/raw` 를 보낸다. 서버가 저장하고 발행하고 알린다. 저장 route 가 preview 와 같은 검사를 하고 거절 이유를 돌려주므로 preview 는 따로 부르지 않는다. 그사이 파일이 바뀌었으면(409) 저장하지 않고 다시 실행하라고 알린다.
- 서버가 아직 준비 중이거나, 답하지 않거나, sign-in 토큰이 없으면: 쓰지 않고 멈춘다. 서버 몰래 파일을 쓰게 되기 때문이다.
- lease 를 쥔 프로세스가 있는데 그 port 를 한 사용자 서버로 알리지 않으면: 쓰지 않고 멈춘다. 다른 port 를 알리면 그 port 를 알려 준다. 아무 port 도 알리지 않으면(아직 뜨는 중이거나, 포트를 알리지 않는 옛 MASC 가 띄운 서버) pid 를 알려 준다. 계정 서버면 계정 서버라고 알려 준다. 어느 경우에도 토큰을 보내지 않는다.
- lease 를 쥔 프로세스가 없으면: 이 워크스페이스의 서버는 없다. 직접 쓴다. 그 port 에 누가 답하든 묻지 않는다. 이때는 알림을 받을 reader 가 없다. TUI 는 서버 없이 돌지 않는다.
- voice setup 은 runtime.toml 말고 `voice_config.json` 도 본다. 그래서 원문 route 가 아니라 서버의 voice setup route(`POST /api/v1/voice/setup`)로 보낸다. 명령은 먼저 서버의 voice 관측(`GET /api/v1/voice/setup`)을 읽고, 그 revision 과 speaking endpoint 로 바꿀 것을 정한다. 서버는 이 프로세스와 다른 설정 파일을 볼 수 있다(`MASC_CONFIG_DIR`). 그 revision 과 변경 목록을 보낸다(`Voice_wizard.request_json`, TUI voice wizard 와 같은 철자). 서버는 자기 잠금 안에서 revision 이 같을 때만 적용하고, 다르면 409 로 거절한다.

이건 대체 경로가 아니다. lease 를 쥔 프로세스가 있으면 서버가 유일한 쓰는 곳이고, 없으면 CLI 가 유일한 쓰는 곳이다. 둘이 동시에 쓰지는 않는다.

`runtime-default-set --setup-lanes` 의 편집은 CLI 가 읽은 모델 카탈로그로 정한다(어느 runtime 이 만들어지는지, 판정 lane 에 넣을 수 있는지). CLI 는 서버 시작과 같은 카탈로그 원본을 읽지만, 셸에서 `AGENT_CORE_MODEL_CATALOG` 를 서버와 다르게 내보내면 서버의 저장 검사가 거절하거나(400), 서버였다면 고르지 않았을 판정 slot 이 저장될 수 있다. `runtime-setup-batch` 의 임시 사본 검증과 probe 도 CLI 의 카탈로그로 하고, 저장할 때 서버가 다시 검사한다. 이 차이를 없애려면 서버 route 로 선택만 보내야 한다. 서버의 setup route(`/api/v1/setup/connections`)는 선택을 받지만 credential 파일 경로는 받지 않고 credential 을 서버에서 준비한다. 그래서 `runtime-store-credential` 이 만든 임시 credential 을 참조하는 CLI 의 선택은 그대로 보낼 수 없다.

재시작이 필요한 설정은 서버로 저장해도 바로 쓰이지 않는다. 서버는 부팅 때 적용한 값과 저장된 값을 비교하고, 다르면 그 키를 `pending_restart` 로 보여 준다(`lib/keeper_runtime/keeper_runtime_config.ml` `application_status`). 그래서 CLI 의 "실행 중인 서버는 재시작할 때 읽는다" 안내는 서버로 쓸 때도 맞다.

### 3.3 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| TUI 화면 설정을 `tui.toml` 같은 클라이언트 파일로 옮김 | Config 화면이 보는 파일에서 빠지니 알림은 필요 없어진다. 하지만 hard cut 이라 기존 설정을 한 번 잃는다. 이름공간 `tui` 도 runtime.toml 에서 지워야 한다. 서버 API 쪽이 쓰는 곳을 하나로 모으는 결정과 더 잘 맞는다 |
| 서버가 runtime.toml 파일 변경을 감시 | 저장소에 파일 감시 장치가 없다. kqueue/inotify 의존성이 새로 생긴다. 쓰는 곳이 여럿인 상태를 그대로 둔다 |
| 쓴 프로세스가 서버에 "바꿨다"고 알림 | 알림을 빠뜨리는 새 호출자가 생기면 조용히 멈춘다(RFC-0480 §3.4 조건 2) |

## 4. 층

| 층 | 내용 | 통과 조건 |
|---|---|---|
| L1 | 서버: TUI 화면 설정 route 와 닫힌 변경 타입(`lib/tui_preference.ml`). `edit_config_text` 로 `tui` 이름공간만 고친다 | 변경마다 `runtime_config_changed` 가 나가는지, 모르는 키를 파싱에서 거절하는지 |
| L2a | 서버: `GET /api/v1/tui/preferences`. `[tui]` 키와 `[voice].send_on_stop` 을 읽는 함수를 `Tui_preference` 로 옮기고, 타입이 있는 JSON 으로 돌려준다. runtime.toml 원문은 싣지 않는다(provider 설정이 들어 있다) | 응답에 `[tui]` 밖의 키가 없는지, 파일이 없을 때·못 읽을 때가 지금 TUI 의 `load` 와 같은 값인지 |
| L2b | TUI: 시작할 때 L2a 로 읽는다. 토큰 준비와 읽기의 순서, 서버가 아직 없는 첫 설치, 읽기가 실패했을 때 기본값으로 여는 규칙을 둔다 | 서버가 쓴 값으로 열리는지, 서버가 없으면 기본값으로 열리고 그 사실을 알리는지(PTY) |
| L2c | TUI: 1.2 의 쓰기를 순서를 지키는 writer 하나로 L1 route 에 보낸다(`Masc_tui_preference_writer`). Worker TUI 는 저장하지 못했다고 한 번 알린다 | 빠르게 두 번 고른 값이 고른 순서대로 저장되는지 |
| L2d | TUI: `[tui]` 는 L2a·L1 로만 읽고 쓴다. 언어·candle·opening 은 `Tui_preference` 타입을 쓴다 | bin/ 에 `Runtime.edit_config_text` 가 남지 않는지 |
| L3 | CLI: 3.2 의 세 명령이 서버가 답하면 서버로 쓴다. L3a 는 서버 찾기와 원문 저장 client, `masc config set`. L3b 는 `masc web-search-setup`, L3c 는 `masc voice-local-setup` | 서버가 떠 있을 때 쓰면 알림이 나가고 서버 설정이 바로 바뀌는지, 서버가 없을 때는 지금처럼 쓰는지 |
| L3d | CLI: `masc runtime-default-set`, `masc runtime-setup-batch`, `masc browser-lane-setup` 도 서버가 답하면 서버로 쓴다. L3a 처럼 각 쓰기를 원문 편집으로 나누고 원문 route 로 저장한다(사용자 결정 2026-11-04). 명령마다 PR 하나: L3d-1 `runtime-default-set`, L3d-2 `browser-lane-setup`, L3d-3 `runtime-setup-batch` | L3 과 같다 |
| L4 | TUI Config 화면이 `runtime_config_changed` 에 읽고 실패하면 다시 읽는다. 2초 분기를 지운다 | 알림 하나에 읽기 하나, 주기에는 읽지 않는지(PTY) |

L2b·L2c·L2d 는 PR 하나로 들어간다. 읽기만 서버로 옮기면, 쓰기를 옮길 때까지 TUI 는 서버 파일을 읽고 자기 파일에 쓴다. 두 프로세스가 runtime.toml 을 서로 다른 경로로 찾는 경우 바로 그 기간에 설정을 잃는다. 쓰기만 먼저 옮겨도 같다.

- 시작 순서: credential 준비를 설정 읽기 앞에 둔다. 읽기는 그 준비가 넣은 bearer 로 보낸다. 지금까지는 설정을 적용하고 터미널을 차지한 뒤에 credential 을 준비해서, 시작 읽기에는 bearer 가 없었다.
- 워크스페이스: 읽기와 쓰기 모두 이 터미널의 경로를 `Request_workspace_precondition` header 로 보낸다. 같은 port 에서 다른 워크스페이스의 서버가 답하면 409 다.
- 읽지 못하면(서버 없음, 401·409, 응답을 읽지 못함) 기본값으로 열고 이유를 한 번 보여 준다. `masc tui` 가 서버를 직접 띄우면 서버는 시작 읽기 뒤에 뜬다. 그래서 서버에 처음 닿을 때 한 번 더 읽고, 그사이 이 세션에서 고른 값은 덮지 않는다. 여는 화면은 다시 정하지 않는다(사용자 결정 2026-11-04).
- 쓰기는 writer 하나가 고른 순서대로 한 번에 하나씩 보낸다. 결과는 writer 의 완료를 처리하는 곳에서 한 번에 알린다. 권한이 없다는 답(401·403)은 세션에 한 번만 알린다.

L4 는 L1~L3d 와 #48036 뒤에만 들어간다.
