---
rfc: "every-lane-is-one-row-in-one-registry"
title: "모든 Lane 은 목록 하나에 한 줄씩 선다"
status: Draft
created: 2026-09-27
updated: 2026-09-27
author: claude
related: ["event-spine-and-source-contract", "machine-spectating-goes-through-lanes", "0439", "browser-lane-stagehand", "0457"]
---

# RFC: 모든 Lane 은 목록 하나에 한 줄씩 선다

- 관련 문서: `docs/design/lane-addon-v0.md`, `docs/design/tui-lane-experience.md`, glossary 의 Lane 항목들, TUI 작업대 RFC(#39231, 아직 main 에 없음), RFC-tui-measured-operator-home(#38801, 아직 main 에 없음)
- 범위: Lane 의 정체(id), 설정으로 켜고 끄는 규칙, 상태를 말하는 단어, 목록을 읽는 endpoint 하나, TUI `Lanes` 목록. Lane 이 하는 일(판정, 브라우저 조작, 기계 실행, 패키지 관측)은 바꾸지 않는다.
- 근거 기준: `origin/main` = `7a8a5e109d` (2026-09-27). 줄 번호는 모두 이 커밋 기준이다. 라이브 설정(`~/me/.masc/config`)은 2026-09-27 에 읽었다.
- 표시: **[사실]** 은 코드·파일에서 확인한 것이다. **[제안]** 은 이 RFC 가 정하려는 것이다.

## 무슨 일이 있었나 (사람이 읽는 서두)

2026-09-27 에 운영자가 TUI `Lanes` 화면을 보고 이렇게 말했다.

> Lane add-on 이면 여기 있는 게 맞다. 그러면 지금 있는 Lane 도 전부 add-on 처럼 떼었다 붙일 수 있어야 한다.
> 지금 있는 Browser Lane 도, DOS 와 MSX 도 이렇게 들어와야 한다. 제대로 개발되지 않았다. 다 훑어보고 제대로 하라.

"떼었다 붙인다" 가 무슨 뜻이냐는 물음에 운영자는 **"목록 하나, 내장은 안에 남는다"** 를 골랐다.

- 모든 Lane 이 manifest 하나(id, 읽는 원천, 행동과 도구, 설정 자리, 상태)를 선언한다. 모두 한 목록에 선다. 설치·켜기·끄기·상태를 같은 방식으로 본다.
- 내장 Lane(standalone exact-output lane, Browser Lane backend, MSX, DOS)은 지금처럼 서버에 컴파일되어 서버 프로세스 안에서 돈다. 설정으로 켜고 끈다.
- Docker 로 도는 Lane Add-on 패키지는 그 목록 안의 프로세스 종류 하나가 된다.
- 타입이 있는 도구(`masc_msx_*`, `masc_dos_*`, `masc_browser_*`)는 그대로 둔다.
- 서버 안 기계의 성능은 그대로다. 잠금 없이 "그대로" 를 답하는 live 라우트와, DOS 실행 한 번에 기계 잠금을 최대 약 170ms 쥐는 구조를 바꾸지 않는다.

지금은 이것이 안 된다. 운영자 화면에서 "lane" 은 다섯 가지를 가리키고, 다섯 모두 정체 타입과 설정 자리와 켜고 끄는 법이 다르다(1장). 같은 화면이 "not loaded", "unavailable", "installed" 로 서로 다른 상태를 한 단어에 섞는다(1.4). 고르지 않은 두 안은 7장에 적는다.

## 1. 문제

### 1.1 운영자가 보는 "lane" 이 다섯 가지다

| 무엇 | 정체 | 설정 자리 | 켜고 끄기 | 프로세스 | TUI 입구 |
|---|---|---|---|---|---|
| Exact-output lane 6개 (Board Attention, HITL Auto Judge, Librarian, Workspace Curator, Verifier, Browser Stagehand) | 닫힌 타입 `Standalone_lane.t` (`lib/runtime/standalone_lane.mli:12-18`) | `[runtime.exact_output_lanes.<id>]` | lane 마다 다름 (1.4) | 서버 안 fiber | `Lanes` 의 Standalone 표 |
| Browser Lane backend 3개 (`live`, `automation`, `stagehand`) | 닫힌 타입 `Browser_lane.Lane_name.t`, `[@@deriving enumerate]` (`lib/browser_lane/browser_lane_name.mli:12`) | `live`: 없음(host 설치와 운영자 브라우저). `automation`: `[browser] geckodriver/binary` (`lib/browser_configuration.ml:23-36`). `stagehand`: `[browser.stagehand]` (`:38` 부터) | 설정 없으면 호출 때 `Lane_absent` | 서버 코드가 운영자 브라우저 또는 서버가 띄운 브라우저를 부린다 | Connectors 화면 아래 (`bin/masc_tui_types.ml:6643-6656`), `B`·Ctrl-^ |
| 기계 2개 (MSX, DOS) | 모듈 `Msx_lane`, `Dos_lane`. 합타입은 두 벌: `Lane_addon_sources.live_reader = Msx_screen \| Dos_screen` (`lib/lane_addon/lane_addon_sources.mli:23`), `Masc_tui_machine_live.source = Msx \| Dos` (`bin/masc_tui_machine_live.ml:4`) | 없음 | 늘 켜짐 | 서버 안 singleton | `&` 관전 화면 (`bin/masc_tui.ml:21596`) |
| Lane Add-on 설치 (라이브 2개) | 문자열 package `id` (`lib/lane_addon/lane_addon_types.mli:38-53`) | `<config-root>/lane-addons/*.toml` (`lib/lane_addon/lane_addon_runtime.ml:660-662`) | 파일이 있으면 설치 | 설치마다 Docker container 하나 | `o`/`A`, `/addons`, 팔레트 |
| Runtime candidate order | 문자열 이름 `Runtime_lane.t` | `[runtime.lanes.<name>]` | 해당 없음 | 프로세스가 아니다. Keeper turn 의 후보 순서다 | `Lanes` 머리글의 "Lanes N" 탭 (`bin/masc_tui_render.ml:5802-5806`, `:5832`) |

[사실] 운영자와 Keeper 가 보는 곳에 "lane" 이 두 번 더 나온다.

- Add-on 안에서 "lane" 은 관측 행이 놓이는 **열**이다. `row.lane_id` (`lane_addon_types.mli:9`), "Package-local lane IDs" (`:28-29`), `lane.toml` 의 `lanes = ["dos/guest"]` (`addons/dos-world/lane.toml:15`).
- Keeper 도구 `keeper_lane_status` 와 셸 명령 `masc lane status` 는 Keeper 의 **sandbox 실행 경로**(microvm_remote, remote_ssh, docker)를 말한다 (`config/tools/keeper_lane_status.toml:1-5`).

glossary 는 이미 일부를 나눴다. `[runtime.lanes.<이름>]` 은 **Runtime Candidate Order** 라고 적었다 (`docs/spec/00-glossary.md:836-838`, `:848-856`). 그런데 TOML 키, 타입 이름, TUI 탭 이름은 여전히 "lane" 이다.

### 1.2 공통 모델이 없다

[사실] family 마다 정체 타입이 따로다. `Standalone_lane.t`, `Browser_lane.Lane_name.t`, `Lane_addon_sources.kind`·`live_reader`, `Masc_tui_machine_live.source`, `Runtime_lane.id` 문자열, package `id` 문자열이다. 두 family 이상을 묶는 타입이나 manifest 는 찾지 못했다.

[사실] 한 family 안에서도 같은 사실을 여러 번 적는다.

- Exact lane 이 필수인지는 두 곳에 있다. projection 의 `required = true` (`lib/server/server_standalone_lane_projection.ml:78`, `:84`)와, 문자열 목록 `mandatory_exact_output_lane_ids` (`lib/server/server_runtime_bootstrap.ml:125-126`)다. 부팅 검사는 이 문자열을 `String.equal` 로 비교한다 (`:139`).
- 선택 lane 의 부팅 경고는 세 번째 손 목록이다 (`lib/runtime/runtime.ml:3726-3728`). Librarian, Verifier, Browser Stagehand 만 있고 Workspace Curator 는 빠졌다.
- `Standalone_lane.all` 은 손으로 쓴 목록이고 테스트가 `to_id` 와 묶는다 (`lib/runtime/standalone_lane.ml:9-12`).
- Board Attention 의 id 는 `to_id` 대신 문자열로 한 번 더 적었다 (`lib/keeper/keeper_board_attention_exact_flow.ml:4`).
- 기계 둘은 두 합타입(1.1 표)이 따로 적고, TUI 는 `"msx_capture"`·`"dos_capture"` 를 다시 쓴다 (`bin/masc_tui_machine_live.ml:6`). 두 타입은 type equation 으로 묶여 있지 않아서 컴파일러가 둘을 맞춰 보지 않는다.

[사실] 새 기계 하나가 닿는 파일을 DOS 로 셌다. `lib/dos_lane` 밖에서 DOS 를 이름으로 부르는 파일은 29개다(`git grep -l -i 'dos_lane\|masc_dos_\|dos_capture\|Dos_screen\|Dos_changed\|dos_live' -- lib bin scripts dune-project masc.opam`). 여기에 도구 TOML 11개(`config/tools/masc_dos_*.toml`), Skill 3개, glossary 가 더해진다.

| 컴파일러가 잡는다 | 조용하다 (문자열이나 손 목록) |
|---|---|
| `Tool_schemas_misc.misc_operation` (`[@@deriving enumerate]`, `lib/tool_schemas/tool_schemas_misc.ml:151-201`)이 강제하는 도구 이름, schema, dispatch, `activity_of_misc_operation` | `lib/tool/tool_catalog.ml:240-261` 도구 이름 문자열 |
| `Lane_addon_sources.source`·`kind`·`live_reader` 를 match 하는 서버 live 라우트와 TUI add-on 화면 | `lib/keeper/keeper_tool_descriptor.ml:2889-2912` 도구 descriptor 문자열 |
| | `lib/tool_schemas/tool_schemas_misc_toml.ml:40-42` `schema_of_name "masc_dos_*"` |
| | `lib/lane_addon/lane_addon_sources.ml:34-40` `kind_of_string`, `:249`·`:276` 의 `"workspace-msx"`·`"workspace-dos"` |
| | `bin/masc_tui_machine_live.ml:4-7` 의 따로 된 합타입 |
| | `bin/masc_tui_types.ml` 의 기계별 mutable 필드, `bin/masc_tui.ml:8321-8339` 관전 메뉴 |
| | `lib/dune`, `lib/server/dune`, `dune-project:61-69`, `masc.opam`, `scripts/opam-pin-external-deps.sh`, `lib/build_identity.ml:11`·`:1272` |

`test/` 에서 `misc_operations`·`all_of_misc_operation` 을 도는 테스트는 찾지 못했다. 그래서 catalog 와 descriptor 문자열을 도구 목록과 맞춰 보는 검사가 있는지 확인하지 못했다.

### 1.3 `dos-world` 는 두 번째 DOS 를 띄운다

[사실]

- 서버의 DOS 는 `ocaml-dos` 코어다. 서버 프로세스 안에 하나 있고, 모든 Keeper 가 `masc_dos_*` 로 같은 기계를 쓴다 (`lib/dos_lane/dos_lane.mli:1-7`, `dune-project:69`).
- `dos-world` 패키지는 container 안에서 js-dos/WASM DOS 를 따로 띄운다 (`addons/dos-world/README.md:3-7`, `addons/dos-world/lane.toml:5`, `:18`). Keeper 는 이 기계를 `masc_lane_act` 로 부린다. 원천을 받지 않는다 (`lane.toml:27-33`, `"maxItems": 0`).
- 라이브에 `dos-counter`(dos-world)와 `dos-output-statistics` 두 선언이 있다 (`~/me/.masc/config/lane-addons/`, 2026-09-27).
- 기록된 설계는 이렇다. lane-addon-v0 는 Add-on 을 "기존 실행 환경 위에 붙는 선택적 관측·관계 레이어" 로, 머신과 세션을 "재사용한다" 고 적었다 (`docs/design/lane-addon-v0.md:5-8`). 사건 척추 RFC 는 "기계는 서버 프로세스 안(L1)에 공유 1대 … 애드온 샌드박스로 내리지 않는다" 고 적었다 (`docs/rfc/RFC-event-spine-and-source-contract.md:89-91`).
- `dos-world` 는 공유 기계를 옮기지 않는다. 대신 에뮬레이터·도구·상태가 모두 다른 DOS 를 하나 더 띄운다. 운영자와 Keeper 는 "DOS" 를 두 개 보게 된다.
- artifact 바이트를 내는 패키지는 `dos-world` 하나다 (`rg -l artifacts addons --glob '*.{py,mjs,js}'`). 출력 합성 안내서 다섯 개, 예제 두 개, `test/test_lane_addon_config.ml` 이 `dos-world` 를 생산자 예로 쓴다.

### 1.4 상태 단어가 상태를 숨긴다

**"not loaded" 는 "아무도 묻지 않았다" 이다.** [사실]

1. `Lanes` 화면은 `launch_lanes_load` 로 standalone lane 만 읽는다 (`bin/masc_tui.ml:5707-5722`). Add-on 은 묻지 않는다. 코드 주석도 그렇게 적었다 (`bin/masc_tui_lane_addons.ml:1141-1147`).
2. 머리글 줄은 `state.lane_addons_cached` 를 읽는다 (`bin/masc_tui_render.ml:5875-5877`). 이 값은 `snapshot = None` 인 `initial` 로 시작한다 (`bin/masc_tui_types.ml:8124`, `bin/masc_tui_lane_addons.ml:49`).
3. `installed` 가 `Not_read` 를 돌려주고 (`bin/masc_tui_lane_addons.ml:1153-1162`), 화면은 `"not loaded"` 를 그린다 (`bin/masc_tui_types.ml:8420`, `:8438-8439`).
4. 첫 조회는 운영자가 add-on 화면을 열 때뿐이다 (`bin/masc_tui.ml:24316`, `:9482`, `:19957` → `:4889`).
5. 서버 쪽도 같은 말을 낸다. 첫 reconcile 전에는 `configuration_status` 가 `` `Null `` 이다 (`lib/lane_addon/lane_addon_runtime.ml:458`, 값을 넣는 곳 `:1033`·`:1051`). TUI 는 이것을 `None` 으로 읽는다 (`bin/masc_tui_lane_addons.ml:78-79`).

라이브에는 선언이 두 개 있다. 맞는 답은 "2" 다.

**"installed" 는 파일 수다.** [사실] 선언 파일 수를 센다. 문제만 낸 파일도 센다 (`bin/masc_tui_lane_addons.ml:94-97`). 도는 worker 수가 아니다.

**"unavailable" 은 세 원인을 한 단어로 합친다.** [사실]

- projection 은 `Unconfigured` 와 `Registry_unavailable` 을 모두 `"unavailable"` 로 낸다 (`server_standalone_lane_projection.ml:757`). 같은 행의 `config_state` 는 둘을 나누지만 (`:751-752`), 표가 그리는 것은 `status` 다.
- `Unconfigured` 는 다시 두 뜻이다. Workspace Curator 는 표를 지우는 것이 끄는 유일한 방법이다 (`lib/server/server_workspace_memory_curator.ml:307-313`). 다른 lane 에서는 "아무도 설정하지 않았다" 다.
- 그래서 "일부러 껐다", "설정을 잊었다", "설정 파일을 못 읽었다" 가 같은 글자로 보인다. glossary 도 이 문제를 적었다 (`docs/spec/00-glossary.md:899-904`).
- `"degraded"` 도 세 가지를 합친다. 받아들인 slot 이 없음, admission 오류, 마지막 실행 실패다 (`server_standalone_lane_projection.ml:758-767`). 앞의 둘은 일을 받을 수 없는 상태이고, 셋째는 다음 일을 받을 수 있는 상태다.

**Browser 의 `Lane_absent` 도 세 원인을 합친다.** [사실] 운영자 브라우저 미연결(`live`), WebDriver 미설정이나 시작 실패(`automation`), backend 미설치(`stagehand`)다 (`lib/tool_misc_browser_lane.ml:52-61`). main 에는 `install_stagehand_executor` 를 부르는 곳이 없다 (`lib/browser_lane/browser_lane.ml:413`, 호출자 0). 그런데 안내 문장은 "`[browser.stagehand]` 를 설정하라" 고 말한다. main 에서는 설정해도 바뀌는 것이 없다.

**표가 없을 때의 뜻이 lane 마다 다르다.** [사실]

| Lane | 설정이 없으면 |
|---|---|
| Board Attention, HITL Auto Judge | 부팅 거절 (`server_runtime_bootstrap.ml:125-126`) |
| Librarian, Verifier, Browser Stagehand(exact) | 부팅 경고 한 줄 (`runtime.ml:3726-3728`) |
| Workspace Curator | 아무 말 없이 꺼짐 |
| Browser `automation` | 호출 때 `Lane_absent` |
| MSX, DOS | 설정 자리가 없다. 늘 켜짐 |
| Add-on | 파일이 없으면 설치되지 않음 |

**머리글 숫자가 한 family 만 센다.** [사실] "Lanes N" 탭은 runtime candidate order 수다 (`masc_tui_render.ml:5802-5806`). "Standalone N lanes" 는 exact lane 만 센다 (`:5814-5817`, `:5834-5837`). Browser, 기계, add-on 은 세지 않는다.

라이브 runtime.toml 에는 exact 표가 넷 있다(verifier, librarian, hitl, board_attention). 그래서 Curator 와 Browser Stagehand 가 "unavailable" 로 보인다. 둘 중 어느 쪽이 일부러 끈 것인지는 설정에 남아 있지 않다.

## 2. 결정

### 2.1 Lane 의 정체는 닫힌 타입 하나다

[제안]

```ocaml
(* lib/lane_registry/machine_lane.mli *)
type t = Msx | Dos [@@deriving enumerate]

(* lib/lane_registry/lane_id.mli *)
type builtin =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
[@@deriving enumerate]

type t =
  | Builtin of builtin
  | Package of Package_declaration.t   (* 선언 파일 하나 *)

val to_wire : t -> string   (* exact/<to_id>, browser/<to_wire>, machine/msx, package/<파일 이름> *)
val of_wire : string -> t option
```

- 내장 Lane 목록은 손으로 쓰지 않는다. `[@@deriving enumerate]` 가 `all_of_builtin` 을 만든다. 인자 타입도 `all` 이 있어야 한다.
  - `Browser_lane.Lane_name.t` 는 이미 derive 한다 (`browser_lane_name.mli:12`).
  - `Standalone_lane.t` 는 손 목록을 derive 로 바꾼다. 손 목록과 그것을 지키던 테스트를 지운다. `masc.runtime` 에는 지금 `ppx_enumerate` 가 없다 (`lib/runtime/dune:67-68`). `masc.browser_lane` 은 이미 쓴다 (`lib/browser_lane/dune:8-9`).
- `Machine_lane.t` 는 새 사실이 아니다. 지금 두 벌로 따로 있는 합타입(1.2)을 하나로 줄인다. `Lane_addon_sources.live_reader` 와 `Masc_tui_machine_live.source` 를 지우고 이 타입을 쓴다.
- Package 의 정체는 선언 파일이다. 이유가 둘이다. 같은 패키지를 두 번 설치할 수 있다 (`lane-addon-v0.md:47-49`). 그리고 못 읽는 선언 파일에는 id 가 없을 수 있다 (issue 항목의 id 는 optional, `bin/masc_tui_lane_addons.ml:92`). 파일은 운영자가 저장하고 지우는 단위다.
- `of_wire` 는 `all_of_builtin` 을 `to_wire` 로 되읽는다. `Standalone_lane.of_id` (`standalone_lane.ml:26`)와 같은 방식이라 이름을 두 번 적지 않는다.

### 2.2 내장 Lane 의 manifest 는 코드의 exhaustive 함수가 만든다

[제안]

```ocaml
type process =
  | In_server                          (* exact lane, 기계 *)
  | In_server_with_operator_browser    (* live: 운영자의 Firefox/Zen + 확장 + native host *)
  | In_server_with_spawned_browser     (* automation: geckodriver+Firefox, stagehand: Chromium *)
  | Container                          (* package 설치 *)

type config_home =
  | Exact_output_table                 (* [runtime.exact_output_lanes.<id>] *)
  | Browser_table of Browser_lane.Lane_name.t   (* [browser.<lane>] *)
  | Machine_table of Machine_lane.t              (* [machines.<id>] *)
  | Declaration_file                             (* <config-root>/lane-addons/<파일>.toml *)

type obligation = Required | Optional

type manifest = {
  label : string;
  purpose : string;
  process : process;
  config_home : config_home;
  obligation : obligation;
  offers : Lane_addon_sources.kind list;         (* 다른 Lane 이 원천으로 묶을 수 있는 것 *)
  reads : Lane_addon_sources.kind list;          (* 이 Lane 이 원천으로 받는 것 *)
  tools : Tool_schemas_misc.misc_operation list; (* 이 Lane 이 내놓는 타입 도구 *)
  serves : Lane_id.builtin option;               (* 이 Lane 을 부르는 유일한 Lane *)
}

val builtin_manifest : Lane_id.builtin -> manifest   (* exhaustive. 와일드카드 없음 *)
val package_manifest : Lane_addon_types.package -> binding:Lane_addon_sources.source list -> manifest
```

내장 manifest 가 코드와 어긋나지 않게 하는 방법:

- **label·purpose·obligation.** `lane_spec` (`server_standalone_lane_projection.ml:72-110`)을 이 함수로 **옮긴다.** 복사하지 않는다. projection 은 옮긴 값을 읽는다. 필수 여부는 여기 한 곳에만 적는다. 문자열 목록 `mandatory_exact_output_lane_ids` 와 손으로 쓴 경고 세 줄은 이 값을 읽는 코드로 바뀐다(2.3).
- **tools.** 새 exhaustive 함수 `lane_of_misc_operation : Tool_schemas_misc.misc_operation -> Lane_id.builtin option` 를 둔다. manifest 의 `tools` 는 `Tool_schemas_misc.misc_operations` (`tool_schemas_misc.ml:203`)를 이 함수로 거른 결과다. `Misc_dos_*` 를 하나 더하면 이 함수를 채울 때까지 컴파일되지 않는다. `masc_lane_*` 는 `None` 이다. 이 도구들은 package 설치에 붙는다.
- **offers.** 기계 MSX 는 `Msx_capture_kind`, DOS 는 `Dos_capture_kind` 다. Browser `live`·`automation` 은 `Browser_document_kind` 다. Browser `stagehand` 는 없다. 지금도 add-on 이 stagehand 를 원천으로 받지 않는다 (`lib/lane_addon/lane_addon_sources.ml:85-86`). exact lane 도 없다. package 는 출력을 선언하면 `Lane_output_kind` 다.
- **reads.** 내장 Lane 은 `[]` 다. 내장 Lane 은 Lane 원천이 아니라 자기 도메인 저장소(Board 후보, 보류 승인, Keeper 기록 등)를 읽는다. 그 설명은 `purpose` 가 한다. package 는 선언의 binding 에서 온다.
- **serves.** `Exact Browser_stagehand` 만 `Some (Browser Stagehand)` 다. 이 exact lane 을 부르는 곳은 Stagehand backend 의 `llm.generate` 뿐이다 (RFC-browser-lane-stagehand §3.7, `docs/rfc/RFC-browser-lane-stagehand.md:282-289`). 목록은 이 값으로 "exact lane 은 준비됐는데 부를 backend 가 없다" 를 보인다(1.4 의 Browser Stagehand 혼동).

내장 Lane 에 `lane.toml` 을 주지 않는다. 코드와 파일 두 곳에 같은 사실을 적으면 둘이 어긋난다. 내장은 코드가, package 는 `lane.toml` 이 manifest 를 만든다. 둘 다 같은 `manifest` 레코드가 된다.

컴파일러가 잡지 못하는 것은 테스트가 잡는다. `all_of_builtin` 의 wire id 가 모두 다르고 `of_wire (to_wire x) = Some x` 인지, 모르는 wire 문자열이 `None` 인지 본다.

### 2.3 켜고 끄는 규칙은 하나다

[제안] 규칙:

1. 모든 Lane 은 설정 자리 한 곳을 가진다 (`config_home`).
2. 그 자리에 선언이 있으면 `enabled = true` 나 `enabled = false` 를 반드시 적는다. 빠지면 선언을 거절한다(`Declaration_rejected`). 기본값은 두지 않는다.
3. 선언이 없으면 `Not_declared` 다. 꺼짐(`Off`)과 다른 상태다. 목록에 그대로 보인다.
4. `Required` Lane 이 `Not_declared` 거나 `Off` 면 부팅을 거절한다. `Optional` Lane 이 `Not_declared` 면 부팅 보고에 한 줄 적는다. 모든 `Optional` Lane 에 똑같이 적는다. 지금처럼 셋만 적지 않는다.

**`enabled` 는 새 필드다. 없으면 사실 하나가 사라진다.** 지금 운영자가 "껐다" 는 사실은 어디에도 남지 않는다. Curator 는 표를 지워야 꺼지고, 지우면 slot 설정도 같이 사라진다. 그 결과는 "아무도 설정하지 않았다" 와 구별되지 않는다. 이 사실은 다른 데서 파생할 수 없다. 그래서 필드로 둔다.

| family | 설정 자리 | 지금 | 바뀌는 것 |
|---|---|---|---|
| Exact | `[runtime.exact_output_lanes.<id>]` | 표가 있으면 켜짐 | `enabled` 를 더한다 |
| Browser `live` | `[browser.live]` | 없음 | 새 표. `enabled` 만 |
| Browser `automation` | `[browser.automation]` | `[browser] geckodriver/binary` | 두 키를 옮기고 `enabled` 를 더한다 |
| Browser `stagehand` | `[browser.stagehand]` | 같은 자리 | `enabled` 를 더한다 |
| 기계 | `[machines.msx]`, `[machines.dos]` | 없음. 늘 켜짐 | 새 표. `enabled` 만 |
| Package | 선언 파일 | 파일이 있으면 설치 | `enabled` 를 더한다 |

"꺼짐" 이 하는 일은 각 주인이 지금 결정하는 자리에서 정한다. registry 는 켜고 끄지 않는다.

| family | 꺼지면 | 언제 반영되나 |
|---|---|---|
| Exact | registry 가 slot 을 받지 않는다. 호출자는 typed 거절 `Exact_lane_off` 를 받는다. `Exact_lane_unconfigured` 와 다른 생성자다 | config commit 때. 지금도 commit 마다 registry 를 바꾼다 (`runtime.ml:3719-3728`) |
| Browser | 요청이 typed 거절 `Lane_off` 를 받는다. `Lane_absent` 와 다른 답이다 | 끄기는 다음 요청부터. 켜기는 다음 부팅부터. executor 설치는 지금도 부팅 때 한다 (`lib/server/server_browser_webdriver.ml:245`) |
| 기계 | 도구 목록에는 남는다. 호출은 설정 키를 적은 typed 거절을 받는다. live 라우트는 `off` 를 답한다. 기계 메모리의 상태는 지우지 않는다 | 다음 호출부터 |
| Package | 지금 선언을 지울 때 하는 detach 를 한다. 선언 파일과 보존한 증거는 남는다. 목록 행도 `Off` 로 남는다 | 다음 reconcile 부터 |

**필수 Lane.** Board Attention 과 HITL Auto Judge 만 `Required` 다. 지금과 같다.

- Board Attention: 후보는 모델 호출 전에 영속화되고 만료가 없다 (constitution `keeper_attention`, `no_wall_clock_death`). 이 lane 이 없으면 어떤 후보도 판정되지 않는다. Keeper 끼리 Board 로 주고받는 일이 멈춘다. constitution 의 실패 조건 "여러 Keeper 가 자기들끼리 커뮤니케이션하지 않는다" 다.
- HITL Auto Judge: 코드는 필수로 두지만 이유를 적은 곳을 찾지 못했다. 3장 (d3) 에서 확인을 받는다.
- 나머지는 `Optional` 이다. 기계와 Browser 가 없어도 Keeper turn 은 돈다.

**배포 순서.** exact lane 표는 모르는 키가 있으면 load 를 실패시킨다 (`lib/runtime/runtime_toml.ml:2628-2648`). `enabled` 를 요구하는 바이너리와 `enabled` 가 있는 파일은 서로 짝이 맞아야 뜬다. 서버를 멈춘 뒤 바이너리를 설치하고, 라이브 파일(exact 표 넷, 선언 파일 둘)을 고치고, 띄운다. 호환 reader 는 만들지 않는다.

### 2.4 상태는 닫힌 타입 하나다. 만드는 곳을 정한다

[제안]

```ocaml
type status =
  | Config_unreadable of string
  | Not_declared
  | Declaration_rejected of string
  | Off
  | Not_in_binary
  | Not_applied
  | Disconnected
  | Idle
  | Running
  | Failed of string
```

| 상태 | 뜻 | 만드는 곳 | 지금 보이는 말 |
|---|---|---|---|
| `Config_unreadable` | 이 Lane 의 설정 자리를 읽지 못했다 | runtime.toml 자리: `Runtime_exact_output_registry.current ()` 의 `Error` (`server_standalone_lane_projection.ml:1012-1019`). package: 선언 디렉터리 읽기 실패 | "unavailable" |
| `Not_declared` | 설정 자리는 읽었다. 이 Lane 의 표가 없다 | registry projection 이 설정을 읽을 때 | "unavailable", `Lane_absent`, 없음(기계) |
| `Declaration_rejected` | 표는 있는데 거절했다. `enabled` 누락, slot 전부 거절, manifest 오류 | 설정 parser 와 admission. package 는 reconcile issue | "degraded", issue 줄 |
| `Off` | `enabled = false` | 설정 parser | 없음 |
| `Not_in_binary` | 켜짐으로 선언했지만 이 바이너리에 설치 코드가 없다 | backend 마다 설치 코드가 있는지 적는 exhaustive 함수. 지금 경우는 main 의 `stagehand` 하나다 | `Lane_absent` |
| `Not_applied` | 켜짐으로 선언했지만 주인이 아직 반영하지 않았다 | package: `desired_revision` ≠ `applied_revision` (지금 있는 값). Browser: 부팅 뒤 켠 backend | 없음 |
| `Disconnected` | `live` 에 연결된 운영자 브라우저가 없다 | `Browser_lane.active_clients ()` 가 비었을 때 (`browser_lane.ml:244`, `:259`) | `Lane_absent` |
| `Idle` | 일을 받을 수 있다. 도는 것이 없다 | 각 주인 | "idle", "no_retained_observation" |
| `Running` | 도는 일이 있다 | exact: 실행 중 run 수 > 0 (`server_standalone_lane_projection.ml:764`). package: phase `Observing`. 기계: 게시된 표식이 `Running` | "running" |
| `Failed` | Lane 이 일을 받을 수 없는 실패 | package: phase `Failed` (`lane_addon_types.mli:54`). Browser: 부팅 설치 실패. 지금은 로그 한 줄만 남고 slot 은 빈 채로 있다 (`server_browser_webdriver.ml:239`) | 로그 |

규칙:

- **마지막 실행 결과는 상태가 아니다.** 마지막 run 이 실패한 exact lane 도 다음 일을 받는다. 그 결과는 행의 상세(지금 있는 latest terminal)에 둔다. 그래서 exact lane 과 기계는 `Failed` 를 만들지 않는다. 기계 fault 는 실행 하나를 끝낼 뿐 기계는 남는다.
- **Browser 의 `Running`.** 지금 도는 verb 수를 세는 곳이 없다. 이 RFC 는 새 카운터를 만들지 않는다. Browser 행은 `Running` 을 내지 않는다.
- **`Not_in_binary` 는 조건부다.** #38739 가 이 단계보다 먼저 병합되면 쓸 곳이 없다. 그때는 이 생성자를 만들지 않는다.
- **생성자는 그것을 만드는 PR 에서 더한다.** `Off` 는 5장의 PR-4 에서 더한다. 아무도 만들지 않는 생성자를 먼저 두지 않는다.
- 서버의 lane 상태 wire 에서 `"unavailable"` 과 `"degraded"` 는 사라진다.

**"아직 읽지 않음" 은 서버 상태가 아니다.** 서버는 이 값을 만들지 않는다. TUI 가 목록을 아직 받지 못한 상태다. TUI 는 목록 전체를 `Not_read | Read_failed of string | Read of registry` 로 들고 있다. TUI 작업대 RFC(#39231) S7-1 의 `Masc_tui_fetched` 로 모으는 방향과 같다.

### 2.5 목록을 읽는 곳은 하나다: `GET /api/v1/lanes`

[제안]

- 한 번 읽으면 모든 행이 온다. 내장 Lane 행은 `all_of_builtin` 에서, package 행은 선언 파일에서 온다.
- 행마다 wire id, family, label, purpose, process, 설정 자리, obligation, status, offers, reads, 도구 이름, serves, family 별 상세가 온다. 상세는 이렇다.
  - exact: 지금 standalone projection 의 slot·run 필드
  - package: desired/applied revision, phase, instance id
  - 기계: 올린 프로그램, 조종권
  - Browser: 연결된 client 수
- **읽기 전용이다.** 시작·정지·재시도를 하지 않는다. 아무것도 쓰지 않는다. `Server_standalone_lane_projection` 의 약속과 같다 (`server_standalone_lane_projection.mli:1-7`).
- **projection 위에 projection 을 얹지 않는다.** standalone projection 의 행 만들기는 이 모듈의 exact 상세로 옮긴다. package 행은 add-on 주인의 상태를 직접 읽는다. HTTP handler 를 부르지 않는다. `/api/v1/dashboard/standalone-lanes` 는 TUI 와 Dashboard 가 모두 옮긴 PR 에서 지운다(5장 PR-3).
- **package 행이 첫 reconcile 을 기다리지 않는다.** 선언 파일은 "설치했다" 의 정본이다. 목록은 선언 디렉터리를 직접 읽는다. reconcile 은 적용 상태만 준다. 그래서 1.4 의 "첫 reconcile 전 `` `Null ``" 틈이 없다. 첫 reconcile 전의 행은 `Not_applied` 다.
- 권한은 지금 standalone-lanes 와 같다.

### 2.6 TUI `Lanes` 는 목록 하나다

[제안]

- `Lanes` 화면은 자기 load 에서 `/api/v1/lanes` 를 읽는다. "Lane Add-ons: …" 줄, `installed_reading`, 머리글이 add-on 캐시를 읽던 길을 지운다.
- 행은 family 로 묶는다. 순서는 Exact-output(6), Browser(3), Machines(2), Packages(N) 다. 묶음 제목은 수와 상태 수를 적는다. 예: `Machines 2 · idle 1 · off 1`.
- 머리글 숫자는 목록에서 센다. "Lanes N" 은 모든 family 의 합이다. 지금 "Lanes N" 탭이 세는 runtime candidate order 는 3장 (a) 에 따라 이름을 바꿔 다른 탭이 된다.
- 행에서 Enter:
  - exact 행: 지금 상세와 slot 편집(#39293)
  - Browser 행: Browser Lane 화면. 3장 (c)
  - 기계 행: 그 기계의 관전 화면(`open_msx_screen`, `bin/masc_tui.ml:8321`)
  - package 행: 그 설치를 고른 add-on 화면
- `&`, `B`, Ctrl-^, `A`, `/addons` 는 같은 곳으로 가는 지름길로 남는다.
- 팔레트의 "go MSX" 는 DOS 도 읽는 화면을 연다 (`bin/masc_tui.ml:8339`). 이름을 "go Machines" 로 바꾼다.
- TUI 작업대 RFC(#39231) §4.1 은 `Lanes(Standalone)`, `Runtime(Lanes, All runtimes)`, `Clients` 를 `System › Lanes` 한 화면에 모은다. 이 목록이 그 화면의 Lane 구역이 된다.

### 2.7 Add-on 은 프로세스 종류 하나가 된다

[제안] Lane Add-on 패키지 설치는 registry 에서 `process = Container` 인 Lane 이다. 설치·적용·제거 주기(`Lane_addon_runtime`)는 그대로 쓴다. 패키지를 더할 때 서버·TUI·Dashboard 코드를 고치지 않는다는 약속도 그대로다 (`lane-addon-v0.md:53`).

아래 문장은 이 RFC 가 대신한다. 5장 PR-6 이 문서를 고친다.

| 문서 | 지금 문장 | 바뀌는 것 |
|---|---|---|
| `docs/design/lane-addon-v0.md:5-8` | "Lane Add-on은 기존 MASC 원장과 실행 환경 위에 붙는 선택적 관측·관계 레이어다. MSX Lane의 머신, Browser Lane의 세션 … 재사용한다. 패키지 하나가 여러 Lane 행을 제공할 수 있다." | Lane Add-on 은 container 로 도는 Lane 이다. 내장 Lane 이 내놓는 원천을 읽거나 자기 환경을 가진다. "여러 Lane 행" 의 "Lane" 은 3장 (d1) 에 따라 바뀐다 |
| `docs/design/lane-addon-v0.md:53-54` | 첫 문장(패키지 추가에 코드 수정 없음)과 둘째 문장(원천 드라이버와 의미 레이어를 구분) | 첫 문장은 그대로다. 둘째 문장은 이렇게 바뀐다. 원천을 내놓는 것은 내장 Lane 이다. 새 원천은 `Lane_id.builtin` 에 생성자를 더하는 일이다 |
| `docs/design/lane-addon-v0.md:56-61` | "기존 MSX·Browser Lane과의 관계" | 내용(기계는 `Msx_lane` 이 가진다, 잠금 밖 처리)은 그대로다. 틀이 "Add-on 아래의 원천" 에서 "두 Lane 사이의 원천 묶음" 으로 바뀐다 |
| `docs/spec/00-glossary.md:1077-1090` Lane Add-on | "기존 MASC 원장과 실행 환경 위에 붙는 선택적 관측·관계 레이어" | 위와 같이 고친다 |
| `docs/spec/00-glossary.md:827-846` Lane | "모델이 도는 exact-output 작업을 위한 고정 실행 경로. 다섯 …" (실제는 여섯) | Lane 은 registry 의 한 줄이다. exact-output lane 은 그중 한 family 다 |
| `docs/spec/00-glossary.md:890-909` Standalone Lane | 표 이름과 `sl_status` 다섯 값 | 목록의 exact family 와 2.4 의 상태로 고친다 |
| `docs/rfc/RFC-event-spine-and-source-contract.md:54-61` | "Lane은 원시 개념이 아니다" | 대신한다. Lane 은 운영자가 켜고 끄는 단위의 이름이다. 사건 순서의 계약은 여전히 event source 다. 두 축은 겹치지 않는다 |
| `docs/rfc/RFC-event-spine-and-source-contract.md:89-91` | "기계는 서버 프로세스 안(L1)에 공유 1대 … 애드온 샌드박스로 내리지 않는다" | **그대로 둔다.** 운영자의 선택이 이 원칙을 지킨다 |
| `docs/design/tui-lane-experience.md:37` | "메인 `Lanes`는 standalone Lane 목록과 실행 상세를 유지한다" | 목록 하나(2.6) |
| `docs/guides/tui-lane-addons.md:6` | "`Lanes`는 standalone 실행과 실행 상세를 다룬다. Add-ons는 패키지 …" | 목록 하나(2.6) |

### 2.8 "lane" 이 멈추는 곳

[제안]

- 목록의 한 줄이 Lane 이다. 나머지는 Lane 이 아니다.
- runtime candidate order, add-on 행의 열, Keeper sandbox 실행 경로는 3장 (a), (d1), (d2) 에서 정한다.
- 서버 안 모듈 이름(`Keeper_lane` fiber, `Keeper_memory_lane`, `keeper_egress_lane`, `slack_lane`, `connector_ingress_lane` 등)은 바꾸지 않는다. 운영자와 Keeper 가 보는 말이 아니다. glossary 경계 문단(`00-glossary.md:836-841`)이 이미 구분한다. 수십 파일을 건드리는 이름 변경으로 얻는 것이 없다.

## 3. 운영자가 정할 것

**(a) runtime candidate order 의 이름**

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| a1 | `candidate order`. `[runtime.candidate_orders.<name>]`, `Runtime_candidate_order.t`, TUI 탭 "Candidate orders" | glossary 가 이미 이 이름이다 (`00-glossary.md:848-856`) | 길다 |
| a2 | `ladder`. `[runtime.ladders.<name>]` | 짧다. RFC-0457 이 "사다리" 로 불렀다 | glossary 와 한 번 더 맞춰야 한다 |
| a3 | "lane" 을 두고 registry 를 다른 이름으로 부른다 | 이름 변경이 없다 | 운영자가 "Lanes" 화면에 모으라고 했다. 한 말이 두 뜻으로 남는다 |

권고: **a1**. 파일 수: `Runtime_lane.` 을 쓰는 lib·bin 파일 10개, `runtime.lanes` 를 적은 파일 18개(lib·bin·dashboard·config·glossary). hard cut 이다. 라이브 runtime.toml 의 표 이름을 서버를 멈춘 사이에 바꾼다. #38892(Dashboard 에서 runtime lane 편집, 열림)와 충돌한다. #38892 가 먼저 병합되거나, #38892 가 새 이름으로 바뀐 뒤 진행한다.

**(b) `dos-world`**

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| b1 | 두 번째 DOS 로 그대로 둔다 | 작업 없음 | 목록에 "DOS" 가 둘이다. 에뮬레이터·도구·상태가 다르다 |
| b2 | 서버 DOS 를 원천(`dos_capture`)으로 받게 바꾼다 | DOS 가 하나가 된다 | act 를 잃는다. 원천은 관측만 가져온다 (`lane_addon_sources.mli:1-3`). 서버 기계에 입력을 넣는 원천은 없다. `dos_capture` 에는 화면·입력 기록·steps 만 있고 `STATE.BIN` 이 없다 (`lane_addon_sources.ml:262-282`). 패키지의 뜻이 바뀐다 |
| b3 | 지운다 (hard cut) | DOS 가 하나가 된다. js-dos 이미지와 CI(`.github/workflows/lane-dos-package.yml`)가 사라진다 | 자기 환경을 가진 패키지 예와 artifact 바이트를 내는 유일한 패키지가 사라진다. 안내서 다섯 개, 예제 두 개, 테스트 하나의 생산자를 바꿔야 한다. 라이브 선언 둘을 지운다 |
| b4 | 그대로 두되 이름에서 DOS 를 뺀다 (예: `counter-sandbox`). 제목과 README 가 "workspace DOS 가 아닌 패키지 전용 sandbox" 라고 말한다 | 2.7 의 새 정의(container Lane 은 자기 환경을 가질 수 있다)와 맞는다. 공유 기계는 서버에 남는다. artifact 경로와 합성 예제가 남는다 | 에뮬레이터 두 벌을 계속 유지한다. id 가 바뀌므로 라이브 선언 둘을 다시 저장한다 |

권고: **b4**. 기록된 layering 은 "공유 기계" 를 container 로 내리지 말라는 것이다. `dos-world` 는 공유 기계를 옮기지 않는다. 운영자와 Keeper 가 헷갈리는 원인은 이름이다. 운영자가 패키지 전용 에뮬레이터를 원하지 않으면 b3 이다.

**(c) Browser Lane 의 자리**

| 안 | 내용 |
|---|---|
| c1 | 목록의 Browser 행에서 Enter 로 연다. Connectors 에서는 뺀다. `B`, Ctrl-^ 는 지름길로 남는다 |
| c2 | Connectors 에 둔다. 목록 행은 상태만 보이고 Enter 로 Connectors 의 Browser Lane 을 연다 |

권고: **c1**. TUI 의 Connectors 는 "transport list" 다 (`bin/masc_tui_types.ml:11693-11697`). constitution 의 io 묶음(Connector, Dashboard, Slack, Discord)은 대화가 나가는 자리다. Browser Lane 은 Keeper 가 도구로 쓰는 환경이다. 기계와 같은 자리가 맞다. c2 는 입구가 두 곳이 된다.

**(d) 그 밖에 찾은 것**

- **(d1) add-on 행이 놓이는 열의 이름.** 지금 `row.lane_id`, `lane.toml` 의 `lanes`·`all_lanes`, `Selected_lanes`·`All_lanes`, Timeline 의 "Lane 열" 이다. 권고: `track`(`track_id`, `tracks`, `all_tracks`). 사건 척추 RFC 가 이미 "시각 트랙(swimlane)" 이라고 불렀다 (`RFC-event-spine-and-source-contract.md:56-57`). `world.outputs` parser 는 모르는 키를 거절한다 (`lib/lane_addon/lane_addon_manifest.ml:9-21`). 그래서 옛 `lane.toml` 은 조용히 출력을 잃지 않고 설치 오류로 보인다. 보존된 행에 `lane_id` 가 있으므로 "Fresh state required" 다. 파일 54개(`lane_id\|all_lanes\|Selected_lanes`, lib/lane_addon·bin·addons·dashboard). 대안은 이름을 두고 glossary 에 두 뜻을 적는 것이다.
- **(d2) `keeper_lane_status` / `masc lane status`.** Keeper 의 sandbox 실행 경로를 말한다. 권고: `keeper_sandbox_status` / `masc sandbox status`. Keeper 가 보는 이름이라 프롬프트와 Skill 도 고친다. 파일 40개(`keeper_lane_status`).
- **(d3) HITL Auto Judge 가 필수인 이유.** 코드는 필수로 둔다 (`server_runtime_bootstrap.ml:125-126`, `server_standalone_lane_projection.ml:84`). 이유를 적은 곳은 찾지 못했다. 이 RFC 는 필수로 둔다. 운영자가 이유를 확인해 주면 manifest 의 `purpose` 와 glossary 에 적는다.
- **(d4) exact lane `Browser Stagehand` 의 label.** 목록에는 exact 행 "Browser Stagehand" 와 Browser 행 "stagehand" 가 함께 선다. 권고: exact 행 label 을 "Stagehand model" 로 바꾸고, 2.2 의 `serves` 로 어느 backend 를 위한 것인지 보인다.

## 4. 열린 PR 과의 충돌과 순서

2026-09-27 `gh pr view` 기준이다.

| PR | 건드리는 곳 | 이 RFC 와의 관계 | 순서 |
|---|---|---|---|
| Stagehand 스택 #38736 → #38739 → #38747 → #38752 → #38760 | backend(#38736), 부팅 설치와 `server_browser_configuration`(#38739), `browser_lane.ml`·`lane_addon_sources.ml`·`tool_schemas_misc`·`tool_catalog`(#38747), 문서(#38752), TUI·executor·CI(#38760) | PR-1 은 새 모듈이라 겹치지 않는다. #38747 이 `misc_operation` 에 도구를 더하므로, 둘 중 나중에 들어오는 쪽이 `lane_of_misc_operation` 에 한 줄을 더한다. 컴파일러가 강제한다. PR-4b 는 #38739 와 같은 parser·부팅 설치를 고친다 | PR-1 은 나란히 간다. **PR-4b 는 스택 뒤.** #38739 가 먼저 들어오면 `Not_in_binary` 를 만들지 않는다 |
| #39333 | Lanes 머리글의 "not loaded / load failed" 가 읽는 오류를 `snapshot_read_error` 로 바꾼다 | PR-2a 가 그 머리글 줄을 지운다. 필드는 add-on 화면이 계속 쓴다 | **#39333 먼저** |
| #39293 | exact lane slot 편집 이동 (`masc_tui.ml`, `masc_tui_keys.ml`, `masc_tui_render.ml`) | PR-2 가 exact 행의 Enter 에서 이 편집을 그대로 연다 | **#39293 먼저** |
| #39324 | Browser Lane 실패 원인 한 번 표시 (`masc_tui_render.ml`, `masc_tui_types.ml`) | Browser Lane 화면 안이다. 겹치는 파일만 있다 | **#39324 먼저** |
| #39236 (TUI 작업대 S1-1) | 탭 hit map | PR-2 가 탭 줄과 목록 행을 바꾼다. hit map 은 그린 프레임을 읽으므로 크게 겹치지 않는다 | **#39236 먼저** |
| TUI 작업대 RFC #39231 과 그 스택 | §4.1 `System › Lanes` 로 모음, §7 "SLOT → RUNTIME", S1-4 가 손으로 센 `lanes_overview_hit` 을 지움 (`bin/masc_tui_types.ml:9028-9045`) | 이 RFC 의 목록이 `System › Lanes` 의 Lane 구역이다. (a) 가 그 RFC 의 `Runtime(Lanes, …)` 이름을 바꾼다 | PR-2 는 S1-4 뒤가 낫다. S1-4 가 늦으면 PR-2 가 `lanes_overview_hit` 을 목록 행에 맞게 고치고, S1-4 가 나중에 지운다 |
| #38801 (measured home) | Lanes 를 System 아래로 옮긴다. `masc_tui.ml`·`masc_tui_render.ml`·`masc_tui_types.ml` 를 크게 바꾼다 | 화면 위치만 바뀐다 | **#38801 먼저** |
| #39365 (draft) | glossary 의 Exact-output route 항목 | PR-6 과 같은 파일이다. 이 PR 은 Lane 항목의 "다섯" (`00-glossary.md:828`, `:893`)을 고치지 않는다 | **#39365 먼저** |
| #38892 | Dashboard 에서 runtime lane 편집과 배정 | (a) 이름 변경과 충돌 | (a) 는 #38892 뒤 |
| #39385 | ocaml-msx pin | 겹치지 않는다 | 무관 |

## 5. 구현 스택

PR 하나의 출력은 20k 토큰 이하로 나눈다 (constitution `work_unit`). 로컬 Dune 빌드는 하지 않는다. 병합은 Keeper 가 한다.

| # | 범위 | 확인 |
|---|---|---|
| PR-1 | `Machine_lane.t`, `Lane_id` (`[@@deriving enumerate]`), `builtin_manifest` (`lane_spec` 을 여기로 옮김), `lane_of_misc_operation`, `status`(이 PR 이 만드는 생성자만), `GET /api/v1/lanes`. `masc.runtime` 에 `ppx_enumerate` 를 더하고 `Standalone_lane.all` 손 목록과 그 테스트를 지운다 | 단위: 모든 내장 id 의 wire round-trip, id 가 겹치지 않음, 모르는 wire(`exact/nope`, `machine/`)는 `None`. route fixture: Curator 표가 없으면 `not_declared` 이고 `unavailable` 이 아님. runtime.toml 을 못 읽으면 runtime.toml 자리의 행만 `config_unreadable` 이고 package 행은 읽힘. manifest 가 틀린 선언 파일은 `declaration_rejected` 와 이유. 요청 한 번에 store 에 쓴 바이트 0. `lane_spec` 이 projection 에 남아 있지 않음(`rg 'let lane_spec' lib/server` 0) |
| PR-2a | TUI 가 `/api/v1/lanes` 를 `Lanes` 화면의 load 에서 읽는다. family 묶음 목록, 머리글 숫자. "Lane Add-ons:" 줄과 `installed_reading` 을 지운다. `Masc_tui_machine_live.source` 와 `Lane_addon_sources.live_reader` 를 `Machine_lane.t` 로 바꾼다 | PTY: TUI 를 처음 열고 add-on 화면을 열지 않은 채 머리글이 목록의 숫자를 보인다("not loaded" 회귀). 서버 503 이면 "load failed". Curator 미선언 행이 "not declared". 60열·80열 캡처 |
| PR-2b | 행 Enter 의 목적지. (c) 에 따라 Browser Lane 을 Connectors 에서 옮긴다. 팔레트 "go Machines" | PTY: DOS 행 Enter → DOS 관전, Browser 행 Enter → Browser Lane 화면, package 행 Enter → 그 설치를 고른 add-on 화면. `&`·`B`·`A` 가 같은 곳으로 간다 |
| PR-2c | live 라우트를 `/api/v1/lanes/live` 로 옮긴다. 이 라우트가 읽는 것은 package 가 아니라 기계 Lane 이다 (RFC-machine-spectating §2.1 l.52-55 의 이유가 목록으로 바뀐다) | `rg 'lane-addons/live' lib bin` 0. 라우트 테스트를 새 경로로 옮김 |
| PR-3 | Dashboard 가 `/api/v1/lanes` 를 읽는다. `/api/v1/dashboard/standalone-lanes`, `LANE_IDS`, `standalone-lanes-parity.test.ts` 를 지운다. label 은 manifest 에서 온다 | vitest. `rg 'standalone-lanes' lib bin dashboard/src` 0. 브라우저 화면 캡처 |
| PR-4a | exact lane `enabled`. 부팅 검사는 `obligation` 을 읽는다. `mandatory_exact_output_lane_ids` 문자열 목록과 손 경고 세 줄을 지운다. `Exact_lane_off`. Curator 시작 판단이 `enabled` 를 읽는다. 상태 `Off` 를 더한다 | 음성: `enabled` 가 없는 표는 그 키를 적은 load 오류. `Required` lane 이 `enabled = false` 면 부팅 거절. Curator `enabled = false` 면 시작하지 않고 행이 `off`. Curator 미선언이면 행이 `not_declared` 이고 부팅 보고에 한 줄. seed `config/runtime.toml` 과 fixture 를 고침 |
| PR-4b | Browser `[browser.live|automation|stagehand]` 와 `enabled`. `[browser] geckodriver/binary` 를 `[browser.automation]` 으로 옮긴다. `Lane_off` 답. **Stagehand 스택 뒤** | 음성: 옛 `[browser] geckodriver` 키는 load 오류. 끈 backend 요청은 `Lane_off` 이고 `Lane_absent` 가 아님 |
| PR-4c | `[machines.msx|dos]` 와 `enabled`. 끄면 도구 호출이 typed 거절, live 라우트가 `off` | 음성: 끈 DOS 에 `masc_dos_screen` → 설정 키를 적은 거절. 다시 켜면 기계 상태가 그대로 |
| PR-5 | 선언 파일의 `enabled`. `false` 면 reconcile 이 worker 를 떼고 선언은 남긴다 | 음성: `enabled` 없는 선언 → 행이 `declaration_rejected`. `false` → container 제거 확인(지금 detach 증명), 행은 `off` 로 남음. 다시 `true` → 붙음. 라이브 선언 둘을 고침 |
| PR-6 | 2.7 의 문서 고침. glossary Lane·Standalone Lane·Lane Add-on·MSX·DOS·Browser 항목. `addons/README.md` 가 패키지 8개를 모두 적음(지금 6개, `addons/README.md:10-17`). 원천 종류 목록을 코드의 다섯 개와 맞춤 | 2.7 표의 옛 문장이 남지 않음 |
| PR-7 | (b) 결정 | b4: id 를 바꾼 패키지가 CI 이미지·합성 예제·테스트를 통과. b3: `rg dos-world` 0 |
| PR-8 이후 | (a), (d1), (d2), (d4) 이름 변경. 하나씩 따로 | 각 PR 에서 옛 이름 `rg` 0 |

## 6. 하지 않는 것과 트레이드오프

- **Dynlink 나 컴파일된 코드의 hot loading 은 없다.** 내장 Lane 을 더하는 일은 생성자를 더하고 다시 빌드하는 일이다. 떼었다 붙이는 것은 설정의 `enabled` 이다. 코드를 빼는 것이 아니다.
- **기계는 서버 프로세스 안에 남는다.** live 라우트의 잠금 없는 "그대로" 답(RFC-machine-spectating l.36-43)과 DOS 실행 한 번의 잠금 약 170ms(l.19-20)는 그대로다.
- **타입 도구는 그대로다.** `masc_lane_act` 로 옮기지 않는다. `masc_lane_*` 는 package 설치에만 쓴다.
- **registry 는 켜고 끄지 않는다.** 각 주인이 지금 결정하는 자리에서 설정을 읽는다. 새 scheduler 나 Gate 는 없다.
- **꺼도 기계 메모리를 비우지 않는다.** 올린 프로그램을 내리지 않는다.
- **Browser backend 켜기는 다음 부팅부터다.** executor 설치가 부팅 때 한 번이기 때문이다. 그 사이 행은 `Not_applied` 다.
- **Keeper 가 목록을 읽는 도구는 더하지 않는다.** Keeper 는 꺼진 Lane 을 typed 거절로 안다.
- 트레이드오프: `enabled` 를 필수로 두면 모든 선언을 한 번씩 고쳐야 한다. 라이브에서는 exact 표 넷과 선언 파일 둘이다. 기본값을 두면 이 일이 없지만, 파일만 보고 켜짐인지 알 수 없다.
- 트레이드오프: TUI 단계(PR-2)는 TUI 작업대 스택과 같은 파일을 고친다. 순서를 지키면 한 번씩만 rebase 한다.

## 7. 고르지 않은 안

**모두 프로세스 밖 (모든 Lane 을 container 로, 타입 도구를 `masc_lane_act` 로)**

- 장점: 설치·적용·제거와 phase 를 가진 주기는 이미 add-on 에 있다 (`lib/lane_addon/lane_addon_runtime.mli:31-48`). 코드를 실제로 떼어 낼 수 있다. `dos-world` 가 작은 경우에 이 길이 돈다는 것을 보였다.
- 단점:
  - 사람과 Keeper 의 모든 기계 입력이 MCP 왕복과 container 한도를 거친다.
  - live 라우트의 잠금 없는 답은 같은 프로세스의 `Atomic` 게시에 기대고 있다.
  - MSX 관측 하나가 약 147KB 를 남긴다 (RFC-machine-spectating l.84). container 경계를 넘으면 매번 복사한다.
  - Keeper 계약이 바뀐다. `skills/dos-play`, `skills/sangokushi-3`, `skills/sangokushi-3-end-month`, `skills/msx-play` 가 타입 도구를 이름으로 부른다.
  - exact lane 은 AGENT_CORE exact-output 흐름과 영속 registry(Board attention 후보 등)를 가진다. container 로 옮기면 영속 상태의 주인이 바뀐다.
  - 운영자가 고르지 않았다.

**화면과 상태만 (TUI 에서 지금 목록들을 묶어 보이기만)**

- 장점: 작다. 설정이 바뀌지 않는다.
- 단점:
  - 정체 타입 다섯 벌, 손 목록 셋, Curator 의 조용한 꺼짐, lane 마다 다른 "표 없음" 의 뜻이 그대로다.
  - 목록을 다섯 endpoint 에서 모아야 한다. 머리글 숫자가 여전히 family 마다 다른 곳에서 온다.
  - 다음 기계도 파일 29개와 조용한 자리를 그대로 지난다.

## 8. 확인하지 못한 것

- 라이브 서버의 `/api/v1/dashboard/standalone-lanes`·`/api/v1/lane-addons` 실제 응답. 운영자 토큰이 필요해서 읽지 않았다. 1.4 의 라이브 서술은 라이브 설정 파일과 코드에서 나왔다.
- 도는 서버 바이너리가 `origin/main` 과 같은지.
- Keeper TOML 이나 composition 이 `masc_msx_*`·`masc_dos_*`·`masc_browser_*` 를 Keeper 별로 막는지.
- HITL Auto Judge 가 필수인 이유 (3장 d3).
- `tool_catalog`·`keeper_tool_descriptor` 의 문자열을 도구 목록과 맞춰 보는 테스트가 있는지 (1.2).
