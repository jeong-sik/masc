---
rfc: "workspace-root-resolution"
title: "workspace 는 진입점에서 한 번 정하고, 모든 명령이 같은 순서로 정한다"
status: Draft
created: 2026-09-15
updated: 2026-09-15
author: claude
supersedes: []
superseded_by: null
related: ["0274"]
---

# RFC: 한 번 정하는 workspace (workspace-root-resolution)

## 0. 요약

base path(`.masc` 를 담는 디렉터리)를 정하는 규칙이 명령마다 다르다. 정하는 입력이
여섯 개(`--base-path`, `MASC_BASE_PATH_INPUT`, `MASC_BASE_PATH`, 기록 파일, cwd,
프로세스 캐시)이고, 정한 값은 `putenv` 로 옮겨지고, 쓰는 쪽은 필요할 때마다 env 를
다시 읽는다. 그래서 같은 셸에서 `masc start` 와 `masc-tui` 가 다른 workspace 를 고르고,
workspace 안에서 `masc` 를 쳐도 `MASC_BASE_PATH is not set` 으로 끝난다.

이 RFC 는 `Workspace_root` 하나로 순서를 고정한다.

```
--base-path  >  MASC_BASE_PATH  >  .masc/config 가 있는 cwd  >  기록된 기본값  >  없음(오류)
```

결과는 realpath 를 거친 `private` 타입이고 어디서 왔는지를 variant 로 가진다.
모든 진입점(`masc`, `masc start`, `masc init`, `masc setup`, `masc doctor`, `masc-tui`,
stdio 서버)이 이 함수만 부른다. `MASC_BASE_PATH_INPUT` 은 지운다.

## 1. 실측

2026-09-15, 설치된 0.35.16 바이너리, `env -i HOME=<빈 디렉터리>` 로 잰 결과다.

| 명령 (cwd = `masc init --base-path` 로 만든 workspace) | 결과 |
|---|---|
| `masc init --config-only` | exit 1. 로그가 `MASC base: <cwd> (no git root found)` 를 찍고 바로 `MASC_BASE_PATH is not set` |
| `masc --port 8991` (터미널 아님) | exit 1, 같은 두 줄 |
| `masc start --port 8992` | exit 1, 같은 두 줄 |
| `masc start --base-path <ws>` | 부팅 |
| `masc start --base-path /tmp/<ws 링크>` | 부팅, health 의 `effective_base_path` 는 realpath |
| `masc-tui` (인자 없음) | 기록도 env 도 없으면 cwd 를 씀 (`config_dir_resolver.ml:138-143`) |

같은 날 이 개발 맥의 `~/.config/masc/default-base-path` 는
`/private/tmp/masc-rel-verify/ws` 였다. 릴리즈 검증용 설치가 installer 의
`--record-default`(`scripts/install.sh:1650`)로 기계 기본값을 덮었다. 셸이
`MASC_BASE_PATH` 를 export 하고 있어서 드러나지 않았을 뿐이다.

## 2. 지금 규칙 (코드)

| 진입점 | 순서 | 근거 |
|---|---|---|
| `masc start`, 터미널 아닌 `masc` | flag > `MASC_BASE_PATH` > 기록 > `default_base_path ()` | `server_base_path_guard.ml:50-61` |
| 위의 마지막 칸 | cwd 를 계산하지만 env·기록이 없으면 그 자리에서 `exit 1` | `server_mcp_transport_http_session.ml:29-35`, `workspace_utils_backend_setup.ml:170-195` |
| `masc init` 등 `base_path` term | flag > `default_base_path ()` (위와 같음) | `bin/main_eio.ml:432` |
| `masc doctor`, 설정 화면 | flag > `MASC_BASE_PATH_INPUT` > `MASC_BASE_PATH` > 기록 | `bin/main_eio.ml:3288-3291`, `env_config_core.ml:506-517` |
| `masc-tui` | flag > `MASC_BASE_PATH_INPUT` > `MASC_BASE_PATH` > 기록 > cwd | `bin/masc_tui.ml:859-864`, `config_dir_resolver.ml:138-143` |

생기는 문제:

1. **cwd 를 보는 명령이 하나뿐이다.** workspace 안에서 `masc` 를 치는 가장 흔한 동작이
   실패한다. 게다가 실패 메시지 앞줄은 cwd 를 base 로 골랐다고 말한다.
2. **guard 의 거부 경로에 닿지 않는다.** `Implicit_default` 와 `format_violation`
   (`server_base_path_guard.ml:62-89`)은 `default_base_path ()` 가 먼저 `exit 1` 해서
   `MASC_BASE_PATH_INPUT` 만 설정된 경우에만 실행된다. 그 경우엔 사용자가 명시한 값을
   "implicit" 이라며 거부한다.
3. **같은 값의 env 이름이 둘이다.** `_INPUT` 은 `MASC_BASE_PATH` 보다 먼저 읽히는데
   guard 는 `_INPUT` 을 안 본다. 서버는 부팅 중에 둘을 다시 쓰지만(`server_runtime_bootstrap.ml:627-631`)
   서버 밖 CLI 들은 서로 다른 값을 고를 수 있다.
4. **정한 값을 env 로 옮긴다.** base path env 를 `putenv` 하는 줄이 12개(`main_eio.ml:682,1800-1801`,
   `main_stdio_eio.ml:47`, `masc_tui.ml:14942-14943`, `server_runtime_bootstrap.ml:627-631`,
   `workspace_utils_backend_setup.ml:103-104`)이고, `Env_config.base_path*` 로 env 를
   직접 읽는 곳이 lib 13곳·bin 4곳, `Host_config` 의 `base_path` 를 읽는 곳이 19곳이다. 누가 마지막으로
   썼는지가 결과를 정한다(#30904).
5. **workspace 판정이 제각각이다.** 기록은 `<path>/.masc` 가 있으면 쓰는데
   (`env_config_core.ml:495`), 사용자 skill 경로가 홈 디렉터리 아래 `.masc/skills` 라서
   홈 디렉터리의 `.masc` 는 workspace 가 아니어도 존재한다.
6. **기본값 기록이 비대화형 실행에서도 일어난다.** installer 는 매번, `masc setup --no-tui`
   도 매번 기록한다(`main_eio.ml:3187`). 반대로 설정 화면에서 "Choose another directory"
   를 고른 경우엔 `init` 에 `--record-default` 가 없어(`install-runtime-setup.py:1950`)
   기록하지 않으면서 "Your workspace is saved" 를 찍는다.

## 3. 결정

### 3.1 순서

```
Flag (--base-path)
  > Environment (MASC_BASE_PATH, 앞뒤 공백 제거 후 비어 있지 않을 때)
  > Current_directory (<cwd>/.masc/config 가 디렉터리일 때)
  > Recorded (기록 파일이 가리키는 <path>/.masc/config 가 디렉터리일 때)
  > No_workspace
```

- **명시한 값(Flag, Environment)은 workspace 판정을 하지 않는다.** 아직 없는 디렉터리를
  `init`·`setup`·`start` 가 만들 수 있어야 한다. `~` 확장과 cwd 기준 절대화만 한다.
- **추론한 값(Current_directory, Recorded)은 `.masc/config` 가 있을 때만 쓴다.**
  `.masc` 만으로는 부족하다(2.5).
- **cwd 의 부모로 올라가며 찾지 않는다.** git 과 다르다. 하위 디렉터리에서 실수로 상위
  workspace 의 소유권(lease)을 잡지 않는다.
- **Environment 가 cwd 보다 앞선다.** `GIT_DIR` 과 같은 자리다. 셸에서 `MASC_BASE_PATH`
  를 export 해 둔 사람은 `cd` 해도 그 workspace 를 쓴다. 이 트레이드오프는 받아들인다.

트레이드오프: 서버 guard 는 일부러 cwd 를 거부해 왔다("nobody chose it"). 이 RFC 는
`.masc/config` 가 있는 cwd 만 고른 것으로 본다. 그 디렉터리는 누군가 `init` 한 곳이다.
대가는 초기화된 workspace 안에서 서버를 켜면 그 workspace 를 잡는다는 점이다.

### 3.2 타입

```ocaml
(* lib/config/workspace_root.mli *)
type source =
  | Flag
  | Environment
  | Current_directory
  | Recorded of { record : string }

type t = private
  { root : string        (* 절대 경로. 존재하면 realpath *)
  ; requested : string   (* 사용자가 적은 그대로. 진단용 *)
  ; source : source
  }

type recorded =
  | No_record
  | Record of { record : string; path : string }

type observation =
  { flag : string option
  ; environment : string option
  ; cwd : string option
  ; recorded : recorded
  ; is_workspace : string -> bool      (* <dir>/.masc/config 가 디렉터리인가 *)
  ; realpath : string -> string option (* 없으면 None *)
  }

type error =
  | No_workspace of { cwd : string option; stale_record : (string * string) option }

val resolve : observation -> (t, error) result      (* 순수 *)
val observe : flag:string option -> unit -> observation  (* env·cwd·파일을 읽는다 *)
val error_message : error -> string
val source_label : source -> string
```

- `resolve` 는 순수 함수라 표로 전부 검사한다. 부수효과는 `observe` 에만 있다.
- `No_workspace` 메시지는 cwd, 무시한 기록과 그 이유, 세 가지 고치는 방법
  (`--base-path`, `MASC_BASE_PATH`, workspace 안에서 실행)을 모두 적는다.

### 3.3 옮기는 방법

- 진입점은 `resolve` 결과를 인자로 넘긴다.
- 자식 프로세스를 띄울 때만 `MASC_BASE_PATH=<root>` 를 환경에 넣는다. 자식은 그것을
  Environment 로 다시 `resolve` 한다.
- `MASC_BASE_PATH_INPUT` 은 쓰지도 읽지도 않는다. 원래 입력은 `t.requested` 에 있다.
- 4단계 전까지는 lib 안쪽이 아직 env 로 workspace 를 읽는다. 그래서 진입점마다
  `MASC_BASE_PATH` 를 직접 쓴다. `base_path` term 은 `publish_workspace_root`, 서버 부팅은
  `server_runtime_bootstrap`, 그 밖에 `voice-verify`·stdio 서버·`masc-tui` 가 각자 쓴다.
  하나라도 빠뜨리면 그 명령은 다른 workspace 를 읽는다. 이 줄들은 4단계에서 지운다.

## 4. 단계

각 단계는 main 에서 초록이 되는 PR 하나 이상이다. 한 PR 은 출력 20k token 안쪽이다.

| 단계 | 범위 | 끝난 상태 |
|---|---|---|
| 1 | `Workspace_root` 모듈과 표 테스트. `masc`, `start`, `init`, 그리고 `base_path` term 을 쓰는 CLI 가 이것을 부른다. guard 의 `Implicit_default`·`format_violation`, `default_base_path ()` 의 cwd 계산과 `exit 1` 을 지운다 | workspace 안에서 `masc start` 가 부팅한다. 없으면 `No_workspace` 메시지 하나로 끝난다 |
| 2 | `doctor`, `setup`, `masc-tui` 가 `Workspace_root` 를 부른다(stdio 서버는 1단계에 포함) | 모든 진입점이 같은 workspace 를 고른다(#30904) |
| 3 | `MASC_BASE_PATH_INPUT` 을 lib·bin·scripts·harness 에서 지운다. 운영자가 적은 원래 경로는 부팅 path diagnostics 가 명시 인자(`~input_base_path`)로 보관한다. 같은 값만 넣던 테스트 줄은 별도로 정리한다 | env 이름이 하나 |
| 4 | 부팅 뒤의 읽기는 RFC-0274(wave A–E)가 맡는다. 이 RFC 는 진입점에서 정하는 순서만 소유한다. RFC-0274 가 끝나면 `Config_dir_resolver.base_path_or_cwd`, 테스트 전용 git root 탐색, `resolved_base_path_cache`, `publish_workspace_root` 를 지운다 | base path 를 env 에서 읽는 곳이 `observe` 와 부팅 입력뿐 |
| 5 | 기본값 기록: 사람이 터미널에서 고를 때만 쓴다(installer 대화형, 설정 화면의 workspace 선택). 비대화형 installer 와 `setup --no-tui` 는 `--record-default` 가 있을 때만. 기록 판정도 `.masc/config` 로 맞춘다. installer 제안도 설정 화면과 같은 `~/MASC` 로 맞춘다 | 검증용 설치가 기계 기본값을 바꾸지 않는다 |
| 6 | README·INSTALL(영/한)·`--help` 문구를 3.1 순서로 고친다. `scripts/imp-onboarding-setup-pty.py` 는 imp 의 sandbox 를 넘겨 설정이 native 로 돌게 고친다(evidence README 가 이 스크립트를 쓴다) | 문서와 코드가 같은 순서를 말한다 |

## 5. 검증

- `test/test_workspace_root.ml`: `resolve` 표 테스트. 각 source 가 이기는 경우, 빈 env,
  `.masc` 만 있고 `config` 가 없는 cwd, 오래된 기록, 링크 경로.
- 진입점 PTY/프로세스 시나리오: 빈 HOME 에서 `masc init --base-path ws` → `cd ws` →
  `masc start` 부팅, health 의 `effective_base_path` 가 ws 의 realpath.
- `MASC_BASE_PATH=A` 로 `masc-tui --base-path B` 를 띄웠을 때 Keepers 가 B 에서 읽힌다
  (#30904 재현 시나리오).
- 설치 시나리오: `install.sh --base-path X --no-wizard` 가 `~/.config/masc/default-base-path`
  를 만들지 않는다.

## 6. 범위 밖

- 테스트 실행 파일을 이름으로 가려내는 guard(`running_under_test_executable`,
  #9903 HOME guard)를 주입 방식으로 바꾸는 일(#35472).
- 한 서버가 여러 workspace 를 다루는 구성.
- `.masc` 디렉터리 이름(`Common.masc_dirname`) 변경.
