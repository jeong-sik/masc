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

화면 설정은 `bin/masc_tui_config.ml` 이 `Runtime.edit_config_text` 로 직접 쓴다. 모두 `tui` 이름공간(`Runtime_toml_namespace.Tui`)이다.

| 함수 | 쓰는 값 |
|---|---|
| `record_chat_visit` (:128) | 마지막으로 연 Keeper 채팅 |
| `set_theme` (:158) | 테마 |
| `set_language` (:184) | 언어 |
| `set_tui_string` (:423) | 문자열 키. `set_board_sort`(:431), `set_candle`(:583) 이 쓴다 |
| `set_help_hint_shown` (:609) | 도움말 안내를 봤는지 |

Keeper 목록의 정렬과 보기(`submit_keeper_preference`)는 runtime.toml 이 아니라 같은 폴더의 `tui-keepers.toml` 에 쓴다. Config 화면은 이 파일을 읽지 않으므로 이 RFC 에 들지 않는다.

### 1.3 CLI 프로세스

| 명령 | 경로 |
|---|---|
| `masc config set` | `bin/masc_cli_config_set.ml:51` → `Runtime_setting_set.apply` → `edit_config_text` |
| `masc web-search setup` | `bin/masc_cli_web_search_setup.ml:180` → `Web_search_setup.apply` |
| voice setup | `bin/main_eio.ml:2489` → `Voice_setup.apply` |

CLI 는 "실행 중인 서버는 재시작할 때 읽는다"고 안내한다. 서버가 떠 있으면, 서버가 들고 있는 설정과 디스크의 설정이 재시작 전까지 서로 다르다.

## 2. 문제

1. 서버는 TUI·CLI 의 쓰기를 모른다. 그래서 알리지 못한다. 2초 읽기를 지우면 Config 화면은 다른 TUI 의 테마 변경이나 `masc config set` 을 보여 주지 못한다.
2. CLI 쓰기는 서버가 떠 있어도 서버를 지나지 않는다. 서버의 설정과 디스크의 설정이 재시작 전까지 갈라진다.
3. 같은 파일을 여러 프로세스가 각자 잠그고 쓴다. 잠금(`with_runtime_config_write_lock`)은 파일 잠금이라 프로세스 사이에서도 순서를 지키지만, 쓴 뒤의 일(catalogue 발행, 알림)은 쓴 프로세스에서만 일어난다.

## 3. 고른 길

### 3.1 TUI 화면 설정은 서버 API 로 쓴다

서버에 TUI 화면 설정을 쓰는 route `POST /api/v1/tui/preferences` 를 둔다. 권한은 runtime config 저장 route 와 같은 `CanAdmin` 이다.

- 요청 본문은 변경 하나다. `{"change": <종류>, <값 필드>}` 꼴이고, 종류는 닫혀 있다. 서버는 받는 자리에서 파싱한다(Parse, don't validate). 1.2 표의 값마다 생성자 하나를 둔다(`lib/tui_preference.ml` 의 `change`). 아무 키나 받는 `set_tui_string` 은 키마다 생성자로 바꾼다. 모르는 종류, 빠지거나 남는 필드, 겹친 필드, 읽을 수 없는 값, 빈 테마·장치 이름은 400 이다.
- 언어·candle 은 닫힌 타입으로, board 정렬은 서버의 `Board_dispatch.sort_order` 로 읽는다. 테마 이름은 열린 이름이라 문자열로 받고, `null` 은 저장한 테마를 지운다. 비었거나 앞뒤에 공백이 붙은 이름은 받지 않는다.
- 편집 결과가 지금 파일과 같으면(같은 chat 을 다시 열거나, 이미 끈 도움말 안내) 서버는 쓰지 않는다. audit 도 알림도 없고, 응답은 `state: "unchanged"` 다. 비교는 읽을 때와 같은 쓰기 잠금 안에서 한다(`Runtime.edit_config_text_if_changed`).
- 서버는 `Runtime.edit_config_text` 로 `tui` 이름공간만 고친다. 그래서 `commit_config_text_locked` 를 지나고, `runtime_config_changed` 가 나간다. audit 에는 `tui_preference` 로 남는다. `tui` 키는 Skill catalog 가 읽지 않으므로 skill catalog 를 다시 만들지 않는다. TUI 가 직접 쓸 때도 그랬다.
- 응답은 변경과 commit receipt(`source_revision`, `durability`, `ignored_legacy_keys` 등)다. 파일 원문은 싣지 않는다.
- TUI 의 `Runtime.edit_config_text` 호출은 모두 지운다.

TUI 는 서버에 붙어서만 돈다. 그러니 화면 설정을 쓸 때 서버가 없을 수는 없다. 서버가 쓰기를 거절하면, TUI 는 지금 `edit_config_text` 의 오류를 보여 주는 자리에 그 이유를 보여 준다.

### 3.2 CLI 는 서버가 떠 있으면 서버로 쓴다

`masc config set`, `masc web-search setup`, voice setup 은 이렇게 쓴다.

- 그 워크스페이스의 서버가 답하면: 로컬에서 고친 원문을 TUI Config 편집기와 같은 길로 보낸다. preview 를 받고, `expected_source_revision` 과 함께 `POST /api/v1/runtime/config/raw` 를 보낸다. 서버가 저장하고 발행하고 알린다.
- 서버가 답하지 않으면: 지금처럼 직접 쓴다. 이때는 알림을 받을 reader 가 없다. TUI 는 서버 없이 돌지 않는다.

이건 대체 경로가 아니다. 서버가 있으면 서버가 유일한 쓰는 곳이고, 서버가 없으면 CLI 가 유일한 쓰는 곳이다. 둘이 동시에 쓰지는 않는다.

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
| L2 | TUI: 1.2 의 쓰기를 L1 route 로 바꾼다. `Runtime.edit_config_text` 호출과 TUI 쪽 `text_with_*` 편집 함수를 지우고, `[tui]` 키 읽기와 언어·candle·opening 타입은 `Tui_preference` 것을 쓴다 | bin/ 에 `Runtime.edit_config_text` 가 남지 않는지 |
| L3 | CLI: 3.2 의 세 명령이 서버가 답하면 서버로 쓴다 | 서버가 떠 있을 때 쓰면 알림이 나가고 서버 설정이 바로 바뀌는지, 서버가 없을 때는 지금처럼 쓰는지 |
| L4 | TUI Config 화면이 `runtime_config_changed` 에 읽고 실패하면 다시 읽는다. 2초 분기를 지운다 | 알림 하나에 읽기 하나, 주기에는 읽지 않는지(PTY) |

L4 는 L1~L3 과 #48036 뒤에만 들어간다.

## 5. 열린 질문

L2 에 앞서 정할 것:

- TUI 는 시작할 때 `[tui]` 를 자기 프로세스가 찾은 runtime.toml 에서 읽는다(`bin/masc_tui_config.ml` `runtime_toml_path`). 서버는 자기 환경으로 찾은 파일에 쓴다(`Config_dir_resolver.runtime_toml_path_for_base_path`). 두 프로세스의 `MASC_CONFIG_DIR` 가 다르면, 서버는 저장했다고 답하지만 TUI 는 다음 시작 때 옛 값을 읽는다. TUI 가 시작할 때 `[tui]` 도 서버에서 읽을지, 두 경로가 같은지 확인하고 다르면 거절할지 정해야 한다.
- route 권한은 `CanAdmin` 이다. TUI 가 토큰을 새로 받을 때는 이전 credential 의 역할을 그대로 쓴다(`bin/masc_tui_http.ml` `mint_operator_token`). 운영자가 더 좁은 역할을 준 TUI 는 L2 뒤에 화면 설정을 저장할 때마다 403 을 받는다. 이 route 에 더 좁은 권한을 둘지, 그런 TUI 는 화면 설정을 저장하지 못한다고 알릴지 정해야 한다.

L3 에 앞서 정할 것:

- CLI 가 그 워크스페이스의 서버를 찾는 방법. TUI 는 `--port` 로 서버를 정하고, `Masc_tui_http.install_operator_token` 이 `.masc/auth/masc-tui.token` 을 읽거나 잠금을 잡고 새로 받는다. CLI 가 이 모듈을 같이 쓸지, 다른 운영자 토큰을 쓸지 정해야 한다. 이 모듈은 지금 `bin/` 의 TUI 쪽에 있다.
